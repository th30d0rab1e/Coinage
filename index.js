var ca = require('./modules/coinbaseAuth.js')
var db = require('./modules/database.js')
const crypto = require('crypto')
var equity = require('./modules/equityAuth.js')
var etfPlan = require('./modules/etfPlan.js')
// IEX snapshots → stock.price for enabled ETF tickers. Secrets load from
// the Alpaca bot config outside this repo (see alpacaMarketData.js).
var alpacaMd = require('./modules/alpacaMarketData.js')
// Completed USD deposits/withdrawals -> usd_transfer (GET-only against
// Coinbase; writes only that table). See modules/usdTransferSync.js.
var usdTransferSync = require('./modules/usdTransferSync.js')
// 2026-10-07: new-listing watcher -> listing_watch.trading_open_at (when a
// new -USD pair's trading ACTUALLY opens). Public endpoints only; writes
// only listing_watch. See modules/listingWatch.js.
var listingWatch = require('./modules/listingWatch.js')
// 2026-10-07: USD -> USDC convert helper (quote / commit / status), used only
// by sweepProfitToUsdc() below to move realized profit into USDC.
var convertUsdc = require('./modules/convert.js')
// Set each run before thee_procedure. False means the equity NORMAL session
// is closed: place no new ETF order and reserve no USD (resting limits are
// still synced / expired every run). When it is true, etfAttemptsThisRun is
// this minute's ETF orders (daily market buy and/or ladder limits, see the
// ETF block below) and config.etf_usd_reserve is their total so
// thee_procedure cannot spend that Default USD on a new crypto plan.
let equitySessionOpen = false
let etfAttemptsThisRun = []
main()

///Volumes/2TBSSD/theodorecrossX/Coinbase tedTosterone/

async function main () {
    try {

        //fetch fresh data first so thee_procedure sees current orders, fills, and balance
        const pnc = processNewCoins();
        const pnb = processNewBalance();
        const pnf = processNewFills();
        const poo = processOpenOrders();
        const ppd = processPriceData();
        // 2026-10-05: top-of-book for every product in ONE call ->
        // bulk_best_bid_ask, so thee_procedure can gate new planned buys on
        // spread (book gates moved from processBuyOrders into the procedure).
        const pba = processBestBidAsk();

        const [productsPayload] = await Promise.all([pnc, pnb, pnf, poo, ppd, pba]);

        // 2026-10-07: listing snipe window now starts when trading ACTUALLY
        // opens (first trade / restrictions cleared), not Coinbase new_at.
        // Must run BEFORE thee_procedure so the listing INSERT sees this
        // minute's listing_watch.trading_open_at. Reuses this minute's
        // products payload; only candidate new listings cost an API call
        // (public, capped). Never throws.
        await listingWatch.run(db, productsPayload);

        // 2026-10-07: a resting listing limit buy is never auto-cancelled,
        // but if it was cancelled outside the bot (Theodore cancels it by
        // hand) or partially filled then cancelled, fix the position row so
        // the one-listing slot / ETF gate free up (no fill) or the bag
        // matches what was actually bought (partial). Reacts to Coinbase's
        // own order status only; places and cancels nothing.
        await reconcileListingBuys();

        // Equity session before the buy pass. A closed session (weekend full
        // close, holiday, or a failed check) leaves the flag false: no ETF
        // order. Crypto plans do not read this flag. This does not place an order.
        await refreshEquitySession();

        // Pull Alpaca IEX prices for every enabled etf row into stock.price
        // (bare ticker). Runs whether or not the equity session is open so
        // the table stays fresh; dip decisions still gate on session below.
        // Cron starts a fresh node each minute, so no bot restart is needed.
        // Same per-minute cadence: record any newly completed USD deposit or
        // withdrawal in usd_transfer. Started here but NOT awaited until the
        // end of this run, so a slow Coinbase v2 call can never delay ETF or
        // crypto order handling. syncRecent() catches and logs its own
        // errors and never rejects, so it cannot break this loop.
        const usdTransfers = usdTransferSync.syncRecent(db);
        await syncEtfStockPrices();

        // 2026-10-06 ETF limit ladder: every run (session open or not),
        // move resting limit rows to FILLED / CANCELLED and cancel any whose
        // bot-side expiry (expires_at) has passed. Places nothing; runs after
        // processNewFills so this minute's fills are in bulk_fills.
        await syncEtfLimitOrders();

        // Reserve before thee_procedure inserts crypto plans. The dollars
        // are only the ETF orders this run will place (daily market buy not
        // yet done today, ladder limits for tickers with none resting, and
        // Default cash can cover them). A closed session writes 0.
        await reserveEtfCash();

        // 2026-10-05: moved here from after aggregate() so thee_procedure sees
        // a FRESH (< 3 min) L2 snapshot for every coin it may plan or keep a
        // planned buy for -- its imbalance / thin-ask gates and clean-up use
        // only snapshots from the last 3 minutes. Retargeted (pending buys,
        // then top buy candidates, then held coins oldest-first), cap 50.
        // Read-only: no place/cancel inside.
        await processBookSnapshots();

        //call thee procedure (now sees fresh bulk_open_orders, bulk_fills, bulk_currency)
        await db.executeQuery('Call thee_procedure();');
        //surface anything thee_procedure just logged to unmatched_fills so the
        //30-min health check (greps outputLog.txt for ERROR/FAILED) catches it
        await checkUnmatchedFills();
        // 2026-10-07: move realized profit (profit_history.profit_converted_usdc,
        // filled in by thee_procedure at close) from USD to USDC once the
        // unswept total reaches config.usdc_sweep_min_usd (state is kept on
        // profit_history.usdc_convert_status / _trade_id / usdc_converted_at). Catches and logs its
        // own errors and never throws, so a Coinbase hiccup here cannot break
        // the rest of this minute (buys, sells, remakes still run).
        await sweepProfitToUsdc();
        //call aggregation
        await db.executeQuery('CALL aggregate();')

        //process historical data
        await processHistoricalPrices();

        //cancel buy orders 
        //await processBuyOrdersOutOfRange(pnfR)

        // 2026-10-05: processBookSnapshots() used to run here (after the
        // procedure, feeding index.js book gates). It now runs before
        // thee_procedure -- see above.

        // When free USD is under $1, cancel the farthest open buy stops first so
        // remakes / heal-placements have a chance at cash this cycle. Must run
        // BEFORE processBuyOrders (which bails when available <= $1).
        await processFarBuyCashRelease();

        //make buy orders (also heals naked buys: buy_coinbase_order_id NULL)
        await processBuyOrders();

        //make sell orders
        await processSellOrders();

        //cancel buy orders that triggered but ran past their limit price and are unlikely to ever fill
        await processObseleteBuyOrders();

        //Remake Orders
        await processRemakeOrders();

        // Re-take the open-orders copy AFTER all place/cancel/re-place calls,
        // so bulk_open_orders (and vw_position_order_balance_audit) matches what
        // position now points at between runs. Without this, every re-place shows
        // up as a fake ghost + orphan pair until the next run. Costs 1 API call.
        await processOpenOrders();

        // Let the USD transfer sync started above finish before this run ends.
        await usdTransfers;


    } catch (error) {
        console.log("main", error)
    } finally {
        //await db.end();
        console.log(`End Program ${new Date().toLocaleString()}`)
        console.log('<-------------------------------------------------------------->');
    }
}

// 2026-10-07: keep a listing position row honest when its resting GTC limit
// buy ends WITHOUT a full fill outside the bot (Theodore cancels it by hand;
// the bot itself never cancels it). Candidates: listing rows whose buy order
// is no longer in this minute's open-orders snapshot, placed > 3 minutes ago
// (fills of an order that just closed are archived by then), and whose fills
// do not already cover the planned shares. For each, ask Coinbase for the
// order's real status (one GET; normally 0-1 rows thanks to the one-listing
// mutex):
//   * CANCELLED / EXPIRED / FAILED with 0 filled -> delete the row (guarded:
//     never filled, no sell order). Frees the one-listing slot and the ETF
//     skip gate; the coin can never be re-sniped because its window is over.
//   * CANCELLED / EXPIRED with a partial fill -> shares = filled size, so the
//     filled part is kept as the position and the normal sell logic sells
//     what was actually bought.
//   * OPEN / FILLED / unknown -> nothing (fill matching runs in thee_procedure).
async function reconcileListingBuys() {
    try {
        const rows = await db.executeQuery(`
            SELECT p.buy_order_id, p.name, p.buy_coinbase_order_id, p.shares
            FROM position p
            WHERE p.period_type = 'listing'
            AND p.buy_coinbase_order_id IS NOT NULL
            AND p.sell_coinbase_order_id IS NULL
            AND p.buy_placed_at < NOW() - INTERVAL '3 minutes'
            AND NOT EXISTS (SELECT 1 FROM bulk_open_orders o WHERE o.order_id = p.buy_coinbase_order_id)
            AND COALESCE((SELECT SUM(f.size) FROM fills f WHERE f.order_id = p.buy_coinbase_order_id), 0) < p.shares * 0.999
        `)
        for (const r of rows || []) {
            const order = await ca.getOrderById(r.buy_coinbase_order_id)
            const status = order?.status
            const filled = parseFloat(order?.filled_size || 0)
            if (!['CANCELLED', 'EXPIRED', 'FAILED'].includes(status)) continue
            if (filled > 0) {
                await db.query(`UPDATE position SET shares = $1 WHERE buy_order_id = $2 AND period_type = 'listing'`, [filled, r.buy_order_id])
                console.log(`Listing buy ${status} after partial fill: ${r.name} | kept ${filled} of ${r.shares} shares as the position`)
            } else {
                await db.query(`DELETE FROM position WHERE buy_order_id = $1 AND period_type = 'listing' AND buy_filled_price IS NULL AND sell_coinbase_order_id IS NULL`, [r.buy_order_id])
                console.log(`Listing buy ${status} with no fill: ${r.name} | row removed (listing slot / ETF gate freed)`)
            }
        }
    } catch (error) {
        console.log('reconcileListingBuys() ERROR', error?.message || error)
    }
}

async function processNewCoins() {
    try {
        let results = await ca.fetchProducts('')
        console.log(`New Coins: ${results.length}`)
        await db.downloadStocks(results);
        return results;
    } catch (error) {
        console.log("processNewCoins() ERROR", error)
    }
}

async function processNewFills () {
    try {
        let results = await ca.gatherFills()
        console.log(`Fills: ${results.length}`)
        await db.insertFills(results)
    } catch (error) {
        console.log("processNewFills() ERROR", error)
    }
}

async function processOpenOrders () {
    try {
        let results = await ca.gatherOrders();
        // gatherOrders() returns undefined on an API error (e.g. the 502 at 4:23 AM CT 9/26).
        // Log it clearly and keep last run's copy instead of crashing at results.length.
        if (!Array.isArray(results)) {
            console.log("processOpenOrders() ERROR: gatherOrders returned no data; bulk_open_orders left stale");
            return;
        }
        let buyCount = 0, sellCount = 0, buyAmount = 0, sellAmount = 0;
        for (let i = 0; i < results.length; i++) {
            const element = results[i];
            if(element.side == 'BUY'){
                buyCount++
                buyAmount = buyAmount + Number(element.total_value_after_fees)
            } else if(element.side == 'SELL') {
                sellCount++;
                sellAmount = sellAmount + Number(element.total_value_after_fees);
            }
        };
        console.log(`Open Orders — Buy: ${buyCount} ($${buyAmount.toFixed(2)}) | Sell: ${sellCount} ($${sellAmount.toFixed(2)})`)
        await db.insertOpenOrders(results);
    } catch (error) {
        console.log("processOpenOrders() ERROR", error)
    }
}

async function checkUnmatchedFills () {
    try {
        const rows = await db.executeQuery(`
            SELECT order_id, product_id, side, price, size, fee, trade_time
            FROM unmatched_fills WHERE detected_at > NOW() - INTERVAL '90 seconds'
        `)
        for (const r of rows) {
            console.log(`ERROR: unmatched fill detected -- ${r.product_id} ${r.side} ${r.size} @ ${r.price} (order ${r.order_id}, fee ${r.fee}, filled ${r.trade_time})`)
        }
    } catch (error) {
        console.log("checkUnmatchedFills() ERROR", error)
    }
}

async function processNewBalance () {
    try {
        let results = await ca.gatherBalance();
        await db.insertCurrency(results);
        // 2026-10-07 (Theodore): also log USDC available + hold. USDC is
        // already downloaded every minute (gatherBalance returns every
        // account, insertCurrency stores it in bulk_currency, vw_balance
        // exposes it as name = 'USDC'); this only prints it so the output
        // log shows the USDC balance the profit sweep fills and USDC-funded
        // ETF buys spend. No history table, by request. Crypto buy gates still
        // read only name = 'USD'.
        const balResult = await db.executeQuery(`
            SELECT
                MAX(CASE WHEN name = 'USD' THEN available ELSE 0 END) AS usd,
                MAX(CASE WHEN name = 'USDC' THEN available ELSE 0 END) AS usdc,
                MAX(CASE WHEN name = 'USDC' THEN hold ELSE 0 END) AS usdc_hold,
                ROUND(SUM(CASE WHEN name NOT IN ('USD', 'USDC') THEN value ELSE 0 END)::numeric, 2) AS equity
            FROM vw_balance
        `)
        const usd = parseFloat(balResult[0]?.usd ?? 0).toFixed(2);
        const usdc = parseFloat(balResult[0]?.usdc ?? 0).toFixed(2);
        const usdcHold = parseFloat(balResult[0]?.usdc_hold ?? 0).toFixed(2);
        const equity = balResult[0]?.equity ?? 0;
        console.log(`Balance: ${results.length} accounts | USD: $${usd} | USDC: $${usdc} (hold $${usdcHold}) | Position Equity: $${equity}`)
    } catch (error) {
        console.log("processNewBalance() ERROR", error);
    }
}

// Chicago calendar date (YYYY-MM-DD) for the once-per-day ETF buy.
function chicagoToday() {
    return new Intl.DateTimeFormat('en-CA', {
        timeZone: 'America/Chicago',
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
    }).format(new Date())
}

// Read BLOX equity_product_details and store config.equity_session_open.
// Closed (including weekend full close) stays 'false': no ETF order.
// Crypto planning does not read this flag. The reserve is a separate
// config value written only when the flag is true.
async function refreshEquitySession() {
    try {
        const session = await equity.equitySession()
        equitySessionOpen = session.open === true
        const value = equitySessionOpen ? 'true' : 'false'
        await db.query(
            `INSERT INTO config (key, value) VALUES ('equity_session_open', $1)
             ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
            [value]
        )
        console.log(`Equity session ${equitySessionOpen ? 'OPEN' : 'closed'}: ${session.reason}`)
    } catch (error) {
        equitySessionOpen = false
        console.log('refreshEquitySession() ERROR', error?.message || error)
        try {
            await db.query(
                `INSERT INTO config (key, value) VALUES ('equity_session_open', 'false')
                 ON CONFLICT (key) DO UPDATE SET value = 'false'`
            )
        } catch (dbErr) {
            console.log('refreshEquitySession() config ERROR', dbErr?.message || dbErr)
        }
    }
}

// ---------------------------------------------------------------------------
// ETF buys (2026-10-06 redesign). Two kinds of order, both tracked in etf_buy:
//
//  1. Daily market buy (order_type 'market'): one $1 market buy per enabled
//     ticker per Chicago day, the first minute the NORMAL session is open
//     and Default USD covers it. Unconditional (no dip / red P&L check).
//  2. Limit ladder (order_type 'limit'): each enabled ticker keeps exactly
//     ONE resting limit buy for ~$1 (quote_usd). Price = basis *
//     (1 - etf_limit_step_pct/100), where basis = VWAP of the latest BUY
//     order's real fills (fills.price; the morning market fill counts), or
//     the best bid (Coinbase, else Alpaca IEX) if the ticker never filled.
//     When it fills, the next one goes a step under that fill. Coinbase has
//     no GTD for equities, so it is GTC and syncEtfLimitOrders cancels it at
//     expires_at (placed + etf_limit_ttl_hours) and a fresh one is placed.
//
// RETIRED 2026-10-06 (they bought $1 at market nearly every minute because
// a stale/wide IEX mid always sat under the last Coinbase fill):
//  - the special same-day market dip re-buy ("price < last fill"),
//  - the regular same-day market dip re-buy ("price < last fill * 0.99"),
//  - the 2:45-3:00 PM CT special market catch-up,
//  - the held-shares red-P&L / under-average gate on the first buy of the
//    day (the daily market buy is now unconditional, per the 2026-10-06 spec).
// ---------------------------------------------------------------------------

// Insert one market-buy row. Limit rows are written by placeEtfLimit.
async function recordEtfAttempt(row) {
    await db.query(
        `INSERT INTO etf_buy
            (ticker, chicago_date, quote_usd, filled, closed_session, coinbase_order_id, client_order_id, error_message, dip_price, fill_price,
             order_type, status, quote_currency, product_id)
         VALUES ($1, $2::date, $3, $4, $5, $6, $7, $8, $9, $10, 'market', $11, $12, $13)`,
        [
            row.ticker,
            row.chicagoDate,
            row.quoteUsd,
            row.filled,
            row.closedSession,
            row.coinbaseOrderId || null,
            row.clientOrderId || null,
            row.errorMessage || null,
            // dip_price is legacy (retired dip rules); always null now.
            null,
            row.fillPrice == null ? null : row.fillPrice,
            // FILLED, OPEN (accepted, fill not confirmed yet; reconcile
            // flips it to FILLED once fills land), or REJECTED.
            row.status,
            // 2026-10-07: USD or USDC, and the product id the order went to
            // (etf.product_id or etf.usdc_product_id).
            row.quoteCurrency || null,
            row.productId || null,
        ]
    )
}

// Upsert stock.price from Alpaca IEX for every enabled etf.ticker. No
// longer drives any buy decision (the dip rules are retired); kept so
// stock.price stays a fresh reference for dashboards.
async function syncEtfStockPrices() {
    try {
        await alpacaMd.syncEnabledEtfStockPrices(db)
    } catch (error) {
        console.log('syncEtfStockPrices() ERROR', error?.message || error)
    }
}

// Build this minute's ETF orders and write config.etf_usd_reserve before
// thee_procedure, so a new crypto plan cannot spend the dollars these
// orders need. A failure reserves nothing and places nothing.
async function reserveEtfCash() {
    etfAttemptsThisRun = []
    // 2026-10-06: listing snipe is priority one. If any listing bag is still
    // open (pending buy or filled-unsold), reserve $0 so ETF-hours buys do
    // not take cash ahead of it.
    try {
        const listingOpen = await db.query(
            `SELECT 1 FROM position
             WHERE period_type = 'listing' AND sell_filled_price IS NULL
             LIMIT 1`
        )
        if ((listingOpen?.rows || []).length > 0) {
            await setEtfUsdReserve(0)
            console.log('ETF reserve $0: active listing position (priority one)')
            return
        }
    } catch (error) {
        console.log('reserveEtfCash() listing gate ERROR', error?.message || error)
    }
    if (!equitySessionOpen) {
        await setEtfUsdReserve(0)
        console.log('ETF reserve $0: equity session closed (resting limits stay; nothing new placed)')
        return
    }
    try {
        const plan = await buildEtfPlan()
        etfAttemptsThisRun = plan.attempts
        // plan.reserve is USD only; USDC-funded attempts (2026-10-07) are
        // not reserved from USD, they spend the separate USDC pot.
        const reserved = await setEtfUsdReserve(plan.reserve)
        const names = plan.attempts.map((row) => `${row.ticker}(${row.kind}/${row.quoteCurrency})`).join(', ')
        const usdcText = plan.usdcPlanned > 0 ? ` + ${plan.usdcPlanned.toFixed(2)} USDC` : ''
        console.log(`ETF reserve $${reserved.toFixed(2)} USD${usdcText} for ${names || 'none'}`)
        for (const note of plan.notes) console.log(note)
    } catch (error) {
        etfAttemptsThisRun = []
        await setEtfUsdReserve(0)
        console.log('reserveEtfCash() ERROR', error?.message || error)
    }
}

async function setEtfUsdReserve(amount) {
    const value = Number(amount)
    const safe = Number.isFinite(value) && value > 0 ? value.toFixed(2) : '0'
    await db.query(
        `INSERT INTO config (key, value) VALUES ('etf_usd_reserve', $1)
         ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
        [safe]
    )
    return Number(safe)
}

// True only when a MARKET etf_buy row may still be working. A zero fill
// ("not filled (status CANCELLED/unknown)") is done. OPEN/PENDING/QUEUED
// may still fill. No status word and a non-empty error (a reject such as
// INSUFFICIENT_FUND) is done. An order id with no error is ambiguous, so
// it stays pending. Limit rows use etf_buy.status instead.
function mightStillFill(errorMessage) {
    const text = String(errorMessage || '')
    const match = text.match(/status\s+([A-Za-z0-9_]+)/)
    if (match) {
        return ['OPEN', 'PENDING', 'QUEUED', 'UNSETTLED'].includes(match[1].toUpperCase())
    }
    return text.trim() === ''
}

// Market rows only: fills is the source of truth for whether the daily
// market buy filled (readFill often still says OPEN right after place).
async function reconcileEtfBuysFromFills(chicagoDate) {
    const result = await db.query(
        `UPDATE etf_buy AS e
         SET filled = true,
             fill_price = f.avg_price,
             error_message = NULL,
             status = 'FILLED'
         FROM (
             SELECT order_id,
                    AVG(price)::numeric AS avg_price
             FROM fills
             WHERE order_id IS NOT NULL
               AND price IS NOT NULL
             GROUP BY order_id
         ) AS f
         WHERE e.coinbase_order_id = f.order_id
           AND e.order_type = 'market'
           AND e.chicago_date = $1::date
           AND (
               e.filled IS NOT TRUE
               OR e.fill_price IS NULL
               OR e.error_message IS NOT NULL
               OR e.status IS DISTINCT FROM 'FILLED'
           )
         RETURNING e.etf_buy_id, e.ticker, e.fill_price`,
        [chicagoDate]
    )
    for (const row of result?.rows || []) {
        console.log(`ETF reconcile market buy from fills: ${row.ticker} fill_price=${row.fill_price}`)
    }
    return (result?.rows || []).length
}

// Market rows only: a still-open daily market buy with no fills row yet,
// ask Coinbase once.
async function probeOpenEtfBuys(chicagoDate) {
    const open = await db.query(
        `SELECT e.etf_buy_id, e.ticker, e.coinbase_order_id, e.error_message
         FROM etf_buy e
         WHERE e.chicago_date = $1::date
           AND e.order_type = 'market'
           AND e.filled IS NOT TRUE
           AND e.closed_session IS NOT TRUE
           AND e.coinbase_order_id IS NOT NULL
           AND NOT EXISTS (
               SELECT 1 FROM fills f WHERE f.order_id = e.coinbase_order_id
           )`,
        [chicagoDate]
    )
    let updated = 0
    for (const row of open?.rows || []) {
        if (!mightStillFill(row.error_message)) continue
        const fill = await equity.readFill(row.coinbase_order_id)
        if (fill.unknown) continue
        const filled = fill.filledSize > 0 || fill.filledQuote > 0
        if (!filled) continue
        const fillPrice = fill.filledSize > 0 && fill.filledQuote > 0
            ? fill.filledQuote / fill.filledSize
            : null
        await db.query(
            `UPDATE etf_buy
             SET filled = true,
                 fill_price = COALESCE($2::numeric, fill_price),
                 error_message = NULL,
                 status = 'FILLED'
             WHERE etf_buy_id = $1`,
            [row.etf_buy_id, fillPrice]
        )
        updated += 1
        console.log(`ETF probe readFill (market): ${row.ticker} fill_price=${fillPrice}`)
    }
    return updated
}

// Numeric config value, or the fallback when missing / not a number.
async function configNumber(key, fallback) {
    const result = await db.query(`SELECT value FROM config WHERE key = $1`, [key])
    const n = Number(result?.rows?.[0]?.value)
    return Number.isFinite(n) ? n : fallback
}

// 2026-10-07: 'true' / 'false' config value, or the fallback when missing.
async function configBool(key, fallback) {
    const result = await db.query(`SELECT value FROM config WHERE key = $1`, [key])
    const v = String(result?.rows?.[0]?.value ?? '').trim().toLowerCase()
    if (v === 'true') return true
    if (v === 'false') return false
    return fallback
}

// Fills for one order from fills UNION this run's bulk_fills (thee_procedure
// copies bulk_fills into fills later in the run, so a fill from this minute
// is only in bulk_fills yet). De-duplicated by trade_id. Returns
// { vwap, count }. sizeIsQuote: market $1 orders report fill size in USD,
// limit orders (base_size) report shares, so the VWAP formula differs.
async function orderFillVwap(orderId, sizeIsQuote) {
    if (!orderId) return { vwap: null, count: 0 }
    const result = await db.query(
        `SELECT COUNT(*)::int AS n,
                CASE WHEN $2::boolean
                     THEN SUM(size) / NULLIF(SUM(size / price), 0)
                     ELSE SUM(price * size) / NULLIF(SUM(size), 0)
                END AS vwap
         FROM (
             SELECT DISTINCT ON (trade_id) trade_id, price, size
             FROM (
                 SELECT trade_id, price, size FROM fills WHERE order_id = $1
                 UNION ALL
                 SELECT trade_id, price, size FROM bulk_fills WHERE order_id = $1
             ) u
             WHERE price > 0 AND size > 0
             ORDER BY trade_id
         ) d`,
        [orderId, sizeIsQuote === true]
    )
    const row = result?.rows?.[0] || {}
    const vwap = row.vwap == null ? null : Number(row.vwap)
    return { vwap: Number.isFinite(vwap) ? vwap : null, count: Number(row.n) || 0 }
}

// VWAP of the most recent BUY order for a product (by its latest fill
// time), from fills UNION bulk_fills. This is the ladder's basis: the
// morning market fill and every limit fill both land here. null if the
// product has never filled.
// 2026-10-07: takes one id or a list. ETFs pass both their USD and USDC
// product ids, so the ladder steps from the latest fill whichever product
// (currency) it was bought on -- same order book, same price.
async function latestBuyFill(productIds) {
    const ids = (Array.isArray(productIds) ? productIds : [productIds]).filter(Boolean)
    const result = await db.query(
        `WITH u AS (
             SELECT DISTINCT ON (trade_id) order_id, trade_id, price, size, trade_time
             FROM (
                 SELECT order_id, trade_id, price, size, trade_time
                 FROM fills WHERE product_id = ANY($1::text[]) AND side = 'BUY'
                 UNION ALL
                 SELECT order_id, trade_id, price, size, created_at
                 FROM bulk_fills WHERE product_id = ANY($1::text[]) AND side = 'BUY'
             ) x
             WHERE price > 0 AND size > 0
             ORDER BY trade_id
         )
         SELECT u.order_id,
                MAX(u.trade_time) AS last_time,
                -- size is USD for market $1 orders, shares for limit orders.
                CASE WHEN MAX(eb.order_type) = 'limit'
                     THEN SUM(u.price * u.size) / NULLIF(SUM(u.size), 0)
                     ELSE SUM(u.size) / NULLIF(SUM(u.size / u.price), 0)
                END AS vwap
         FROM u
         LEFT JOIN etf_buy eb ON eb.coinbase_order_id = u.order_id
         GROUP BY u.order_id
         ORDER BY MAX(u.trade_time) DESC
         LIMIT 1`,
        [ids]
    )
    const row = result?.rows?.[0]
    const vwap = row?.vwap == null ? null : Number(row.vwap)
    return Number.isFinite(vwap) && vwap > 0 ? { orderId: row.order_id, price: vwap } : null
}

// Every run, session open or not: walk PLACING/OPEN limit rows and move
// them to FILLED / CANCELLED / EXPIRED. Cancels a resting limit once
// expires_at has passed (our stand-in for GTD). Never places an order.
// A failed GET leaves the row OPEN so a second limit is never stacked.
async function syncEtfLimitOrders() {
    try {
        const open = await db.query(
            `SELECT e.etf_buy_id, e.ticker, e.coinbase_order_id, e.client_order_id,
                    e.status, e.expires_at, e.limit_price,
                    (e.expires_at IS NOT NULL AND NOW() >= e.expires_at) AS expired,
                    (NOW() - e.created_at::timestamptz) > INTERVAL '5 minutes' AS stale
             FROM etf_buy e
             WHERE e.order_type = 'limit' AND e.status IN ('PLACING', 'OPEN')
             ORDER BY e.ticker`
        )
        for (const row of open?.rows || []) {
            if (row.status === 'PLACING') {
                // A PLACING row is normally flipped to OPEN/REJECTED within
                // the same run. Older than 5 minutes means the run died
                // between insert and create: adopt the order if Coinbase
                // has it open (matched by client_order_id), else abandon
                // the row so the ticker is not blocked forever.
                if (!row.stale) continue
                const found = await db.query(
                    `SELECT order_id FROM bulk_open_orders WHERE client_order_id = $1 LIMIT 1`,
                    [row.client_order_id]
                )
                const orderId = found?.rows?.[0]?.order_id
                if (orderId) {
                    await db.query(
                        `UPDATE etf_buy SET status = 'OPEN', coinbase_order_id = $2 WHERE etf_buy_id = $1`,
                        [row.etf_buy_id, orderId]
                    )
                    console.log(`ETF limit adopted stale PLACING row: ${row.ticker} order ${orderId}`)
                } else {
                    await db.query(
                        `UPDATE etf_buy SET status = 'ABANDONED', closed_at = NOW(),
                                error_message = 'PLACING row with no open order after 5 minutes'
                         WHERE etf_buy_id = $1`,
                        [row.etf_buy_id]
                    )
                    console.log(`ETF limit abandoned stale PLACING row: ${row.ticker}`)
                }
                continue
            }
            const state = await equity.readOrder(row.coinbase_order_id)
            if (!state.ok) {
                console.log(`ETF limit ${row.ticker}: order read failed (${state.reason}); treating as still open`)
                continue
            }
            if (state.status === 'FILLED') {
                // Prefer the real fills (VWAP of fills.price); Coinbase's own
                // average_filled_price only when fills have not landed yet.
                const fromFills = await orderFillVwap(row.coinbase_order_id, false)
                const price = fromFills.vwap != null ? fromFills.vwap : state.avgFilledPrice
                await db.query(
                    `UPDATE etf_buy SET status = 'FILLED', filled = true, fill_price = $2,
                            error_message = NULL, closed_at = NOW()
                     WHERE etf_buy_id = $1`,
                    [row.etf_buy_id, price]
                )
                console.log(`ETF limit FILLED: ${row.ticker} limit ${row.limit_price} fill ${price} (${fromFills.count > 0 ? 'fills VWAP' : 'Coinbase average_filled_price'})`)
                continue
            }
            if (['CANCELLED', 'EXPIRED', 'FAILED'].includes(state.status)) {
                // Closed by Coinbase or by hand. A partial fill still counts
                // as a fill (filled = true) so the ladder steps from it.
                const partial = state.filledSize > 0
                const fromFills = partial ? await orderFillVwap(row.coinbase_order_id, false) : { vwap: null }
                await db.query(
                    `UPDATE etf_buy SET status = $2, filled = $3, fill_price = $4,
                            error_message = $5, closed_at = NOW()
                     WHERE etf_buy_id = $1`,
                    [row.etf_buy_id, state.status === 'FAILED' ? 'REJECTED' : 'CANCELLED', partial,
                        partial ? (fromFills.vwap != null ? fromFills.vwap : state.avgFilledPrice) : null,
                        `Coinbase status ${state.status}${partial ? ` (partial ${state.filledSize})` : ''}`]
                )
                console.log(`ETF limit closed by Coinbase: ${row.ticker} status ${state.status}${partial ? ' (partial fill)' : ''}`)
                continue
            }
            if (row.expired) {
                // Our TTL passed and it is still working: cancel it. If the
                // cancel fails (e.g. it just filled), leave the row OPEN and
                // the next run reads the real status.
                const cancel = await equity.cancelOrder(row.coinbase_order_id)
                if (cancel.ok) {
                    const partial = state.filledSize > 0
                    await db.query(
                        `UPDATE etf_buy SET status = 'EXPIRED', filled = $2, fill_price = $3, closed_at = NOW(),
                                error_message = 'expired: cancelled by bot at expires_at'
                         WHERE etf_buy_id = $1`,
                        [row.etf_buy_id, partial, partial ? state.avgFilledPrice : null]
                    )
                    console.log(`ETF limit EXPIRED (cancelled by bot): ${row.ticker} limit ${row.limit_price}`)
                } else {
                    console.log(`ETF limit expiry cancel FAILED: ${row.ticker} ${cancel.reason}; will re-check next run`)
                }
            }
        }
    } catch (error) {
        console.log('syncEtfLimitOrders() ERROR', error?.message || error)
    }
}

// Best bid for a never-filled ticker: Coinbase product / best_bid_ask
// first (usually blank on equities), then the Alpaca IEX bid.
async function bidBasis(row, product) {
    if (Number(product.bestBid) > 0) return { price: Number(product.bestBid), source: 'coinbase_bid' }
    const cb = await equity.bestBid(row.product_id)
    if (Number(cb) > 0) return { price: Number(cb), source: 'coinbase_bid' }
    try {
        const snap = await alpacaMd.fetchIexSnapshots([row.ticker])
        const bid = Number(snap?.bySymbol?.[String(row.ticker).toUpperCase()]?.latestQuote?.bp)
        if (bid > 0) return { price: bid, source: 'iex_bid' }
    } catch (error) {
        // fall through: no basis, the ticker is skipped this run
    }
    return null
}

// Session is open. Decide this minute's orders: the daily market buy for
// tickers that have not had one today, and a ladder limit for tickers
// with no resting limit. Returns funded attempts + the reserve.
async function buildEtfPlan() {
    const today = chicagoToday()
    const notes = []
    await reconcileEtfBuysFromFills(today)
    await probeOpenEtfBuys(today)
    const listed = await db.query(
        // usdc_product_id (2026-10-07): set = buy on the USDC product with
        // USDC; NULL (TOPW) = USD only.
        `SELECT ticker, product_id, usdc_product_id, quote_usd FROM etf WHERE enabled ORDER BY ticker`
    )
    const rows = listed?.rows || []
    const book = await equity.equitySnapshot()
    if (!book.ok) {
        notes.push(`ETF plan skipped: Default USD unreadable (${book.reason})`)
        return { attempts: [], reserve: 0, notes }
    }
    const stepPct = await configNumber('etf_limit_step_pct', 0.10)
    // Today's market rows: filled = the daily buy is done; an unfilled one
    // that might still fill blocks a second market send.
    const market = await db.query(
        `SELECT DISTINCT ON (ticker) ticker, filled, closed_session, coinbase_order_id, error_message,
                bool_or(filled) OVER (PARTITION BY ticker) AS any_filled
         FROM etf_buy
         WHERE order_type = 'market' AND chicago_date = $1::date
         ORDER BY ticker, created_at DESC, etf_buy_id DESC`,
        [today]
    )
    const marketDone = new Set()
    const marketPending = new Set()
    for (const r of market?.rows || []) {
        if (r.any_filled) marketDone.add(r.ticker)
        else if (!r.closed_session && r.coinbase_order_id && mightStillFill(r.error_message)) marketPending.add(r.ticker)
    }
    const openLimits = await db.query(
        `SELECT ticker FROM etf_buy WHERE order_type = 'limit' AND status IN ('PLACING', 'OPEN')`
    )
    const limitOpen = new Set((openLimits?.rows || []).map((r) => r.ticker))
    // Coinbase BUY orders on these products that etf_buy does not track as
    // a limit (e.g. placed by hand). They block both kinds of order.
    const untracked = await db.query(
        `SELECT DISTINCT o.product_id
         FROM bulk_open_orders o
         WHERE o.side = 'BUY' AND o.status = 'OPEN' AND o.product_id IS NOT NULL
           AND NOT EXISTS (
               SELECT 1 FROM etf_buy e WHERE e.coinbase_order_id = o.order_id AND e.order_type = 'limit'
           )`
    )
    const untrackedOpen = new Set((untracked?.rows || []).map((r) => r.product_id))
    // A filled order in the last 10 minutes whose fills have not landed in
    // fills/bulk_fills yet: wait, so the next limit steps from the real fill
    // price and not from the previous fill.
    const recentFilled = await db.query(
        `SELECT DISTINCT ON (ticker) ticker, coinbase_order_id, order_type
         FROM etf_buy
         WHERE filled AND coinbase_order_id IS NOT NULL
           AND created_at > NOW() - INTERVAL '12 hours'
           AND COALESCE(closed_at, created_at::timestamptz) > NOW() - INTERVAL '10 minutes'
         ORDER BY ticker, COALESCE(closed_at, created_at::timestamptz) DESC`
    )
    const recentByTicker = new Map((recentFilled?.rows || []).map((r) => [r.ticker, r]))

    const chosen = []
    for (const row of rows) {
        const t = row.ticker
        // Either product (USD or USDC) counts: both share one order book.
        if (untrackedOpen.has(row.product_id) || (row.usdc_product_id && untrackedOpen.has(row.usdc_product_id))) {
            notes.push(`ETF skip ${t}: an untracked open BUY order exists on Coinbase`)
            continue
        }
        if (marketPending.has(t)) {
            notes.push(`ETF skip ${t}: today's market buy might still fill`)
            continue
        }
        if (!marketDone.has(t)) {
            // The ladder waits for this fill; it steps from it next minute.
            chosen.push({ kind: 'market', ticker: t, product_id: row.product_id, usdcProductId: row.usdc_product_id || null, notional: Number(row.quote_usd), reason: 'daily $1 market buy (first of the Chicago day)' })
            continue
        }
        if (limitOpen.has(t)) {
            notes.push(`ETF hold ${t}: a limit is already resting`)
            continue
        }
        const recent = recentByTicker.get(t)
        if (recent) {
            const f = await orderFillVwap(recent.coinbase_order_id, recent.order_type === 'market')
            if (f.count === 0) {
                notes.push(`ETF wait ${t}: fill of ${recent.coinbase_order_id} not in fills yet`)
                continue
            }
        }
        // Rules / increments are read from the USD product: it carries
        // equity_trading_flags (the USDC alias does not) and the two
        // products have identical increments and $1 minimum (checked
        // 2026-10-07), so the same limit works on either.
        const product = await equity.equityProduct(row.product_id)
        if (!product.ok) {
            notes.push(`ETF skip ${t}: product read failed (${product.reason})`)
            continue
        }
        if (product.blocked) {
            notes.push(`ETF skip ${t}: ${product.blocked}`)
            continue
        }
        let basis = null
        const last = await latestBuyFill([row.product_id, row.usdc_product_id])
        if (last) basis = { price: last.price, source: 'last_fill' }
        else basis = await bidBasis(row, product)
        if (!basis) {
            notes.push(`ETF skip ${t}: no fill and no bid to price a limit from`)
            continue
        }
        const limitPrice = etfPlan.limitPriceFrom(basis.price, stepPct, product.priceIncrement)
        // Notional: quote_usd ($1), raised to Coinbase's minimums if higher.
        const target = Math.max(Number(row.quote_usd) || 0, product.notionalMin || 0, product.quoteMinSize || 0)
        const baseSize = limitPrice ? etfPlan.baseSizeFor(target, limitPrice, product.baseIncrement) : null
        if (!limitPrice || !baseSize) {
            notes.push(`ETF skip ${t}: could not size a limit (basis ${basis.price})`)
            continue
        }
        chosen.push({
            kind: 'limit',
            ticker: t,
            product_id: row.product_id,
            usdcProductId: row.usdc_product_id || null,
            limitPrice,
            baseSize,
            notional: Number(baseSize) * Number(limitPrice),
            basisPrice: basis.price,
            priceBasis: basis.source,
            reason: `limit ${stepPct}% under ${basis.source} ${Number(basis.price).toFixed(4)}`,
        })
    }
    // 2026-10-07: profit queued for the USDC sweep is not spendable on ETFs.
    // That reserve is USD still waiting to be converted, so it comes off the
    // USD pot only.
    const sweepReserve = await usdcSweepReserve()
    if (sweepReserve > 0) notes.push(`ETF cash minus $${sweepReserve.toFixed(2)} profit queued for USDC`)
    // 2026-10-07 (Theodore): USDC-capable ETFs pay with USDC. Spendable USDC
    // = Default portfolio USDC available_to_trade (held USDC excluded). No
    // sweep state holds USDC back: the sweep only spends USD and adds USDC,
    // and its unconverted profit is already reserved on the USD side above,
    // so nothing is double-counted.
    const usdcPot = Math.max(0, Number(book.usdcAvailable) || 0)
    const fallbackUsd = await configBool('etf_usdc_fallback_usd', true)
    if (book.usdcReason) notes.push(`ETF USDC unreadable (${book.usdcReason}); treating USDC as 0`)
    notes.push(`ETF pots: $${Math.max(0, book.available - sweepReserve).toFixed(2)} USD, ${usdcPot.toFixed(2)} USDC (USD fallback ${fallbackUsd ? 'on' : 'off'})`)
    const funded = etfPlan.fundAttemptsByCurrency(chosen, { usd: Math.max(0, book.available - sweepReserve), usdc: usdcPot }, fallbackUsd)
    for (const c of chosen) notes.push(`ETF plan ${c.ticker}: ${c.kind} — ${c.reason}${c.kind === 'limit' ? ` → ${c.baseSize} @ ${c.limitPrice}` : ''}${c.usdcProductId ? ' [USDC-capable]' : ' [USD only]'}`)
    // Remember the fallback setting on each attempt for the send step.
    for (const a of funded.attempts) a.fallbackUsd = fallbackUsd
    notes.push(...funded.notes)
    return { attempts: funded.attempts, reserve: funded.reserve, usdcPlanned: funded.usdcPlanned, notes }
}

// Mark the equity session closed after a closed-market reject.
async function markEquitySessionClosed() {
    equitySessionOpen = false
    await db.query(`UPDATE config SET value = 'false' WHERE key = 'equity_session_open'`)
}

// 2026-10-07: the product id an ETF attempt is sent to. orderProductId is
// set by etfPlan.fundAttemptsByCurrency (the USDC product for a USDC-funded
// row, else the USD product); product_id (USD) is the safe default.
function etfOrderProductId(row) {
    return row.orderProductId || row.product_id
}

// Reserve the PLACING row first (the unique index refuses a second
// PLACING/OPEN limit for the ticker), then create the GTC limit, then
// flip the row to OPEN (or REJECTED). expires_at = NOW() + ttl hours.
async function placeEtfLimit(row, today, ttlHours) {
    const clientOrderId = crypto.randomUUID()
    let inserted
    try {
        inserted = await db.query(
            `INSERT INTO etf_buy
                (ticker, chicago_date, quote_usd, filled, closed_session, client_order_id,
                 order_type, status, limit_price, base_size, basis_price, price_basis, expires_at,
                 quote_currency, product_id)
             VALUES ($1, $2::date, $3, false, false, $4,
                     'limit', 'PLACING', $5, $6, $7, $8, NOW() + ($9::numeric * INTERVAL '1 hour'),
                     $10, $11)
             RETURNING etf_buy_id, expires_at`,
            [row.ticker, today, Number(row.notional).toFixed(4), clientOrderId,
                row.limitPrice, row.baseSize, row.basisPrice, row.priceBasis, ttlHours,
                // 2026-10-07: which currency / product this limit uses.
                row.quoteCurrency || 'USD', etfOrderProductId(row)]
        )
    } catch (error) {
        if (error?.code === '23505') {
            console.log(`ETF limit skipped: ${row.ticker} already has a PLACING/OPEN limit (unique index)`)
            return { placed: false }
        }
        throw error
    }
    const id = inserted.rows[0].etf_buy_id
    const expiresAt = inserted.rows[0].expires_at
    // 2026-10-07: USDC product id when funded with USDC, else the USD one.
    const response = await equity.createLimitBuy(etfOrderProductId(row), row.baseSize, row.limitPrice, clientOrderId)
    if (response?.success === true) {
        const orderId = response.success_response?.order_id
        await db.query(
            `UPDATE etf_buy SET status = 'OPEN', coinbase_order_id = $2 WHERE etf_buy_id = $1`,
            [id, orderId]
        )
        const expCt = new Date(expiresAt).toLocaleString('en-US', { timeZone: 'America/Chicago' })
        console.log(`ETF limit placed: ${row.ticker} ${row.baseSize} @ ${row.limitPrice} (~${Number(row.notional).toFixed(2)} ${row.quoteCurrency || 'USD'}; ${row.reason}) expires ${expCt} CT, order ${orderId}`)
        return { placed: true }
    }
    const closed = equity.isClosedMarket(response)
    const message = response?.error_response?.message || 'unknown'
    await db.query(
        `UPDATE etf_buy SET status = 'REJECTED', closed_session = $2, error_message = $3, closed_at = NOW()
         WHERE etf_buy_id = $1`,
        [id, closed, message]
    )
    console.log(`ETF limit FAILED: ${row.ticker} ${row.baseSize} @ ${row.limitPrice} (${row.quoteCurrency || 'USD'}): ${message}`)
    if (closed) await markEquitySessionClosed()
    return { placed: false, closed }
}

// Daily $1 market buy (kept from the pre-2026-10-06 morning path).
async function placeEtfMarket(row, today) {
    const quote = Number(row.notional)
    // 2026-10-07: quote_size is in the product's quote currency, so on the
    // USDC product this spends USDC.
    const currency = row.quoteCurrency || 'USD'
    const productId = etfOrderProductId(row)
    console.log(`ETF buy attempt: ${row.ticker} ${quote.toFixed(2)} ${currency} market (${row.reason})`)
    const clientOrderId = crypto.randomUUID()
    const response = await equity.createMarketBuy(productId, quote, clientOrderId)
    if (equity.isClosedMarket(response)) {
        const message = response?.error_response?.message || 'equity session closed'
        await recordEtfAttempt({ ticker: row.ticker, chicagoDate: today, quoteUsd: quote, filled: false,
            closedSession: true, clientOrderId, errorMessage: message, status: 'REJECTED',
            quoteCurrency: currency, productId })
        await markEquitySessionClosed()
        console.log(`ETF session closed on ${row.ticker} (${message}); not today's buy`)
        return { filled: false, closed: true }
    }
    if (response?.success !== true) {
        const message = response?.error_response?.message || 'unknown'
        await recordEtfAttempt({ ticker: row.ticker, chicagoDate: today, quoteUsd: quote, filled: false,
            closedSession: false, clientOrderId, errorMessage: message, status: 'REJECTED',
            quoteCurrency: currency, productId })
        console.log(`ETF buy FAILED: ${row.ticker} (${currency}) ${message}`)
        return { filled: false }
    }
    const orderId = response.success_response?.order_id
    // Prefer fills when the trade already landed; otherwise readFill. A
    // later minute's reconcileEtfBuysFromFills repairs OPEN rows. A failed
    // fill GET is recorded filled = true so the $1 is not sent twice.
    const fromFills = await orderFillVwap(orderId, true)
    let filled = false
    let fillPrice = null
    let fillStatus = null
    if (fromFills.vwap != null) {
        filled = true
        fillPrice = fromFills.vwap
    } else {
        const fill = await equity.readFill(orderId)
        filled = fill.unknown || fill.filledSize > 0 || fill.filledQuote > 0
        fillPrice = fill.filledSize > 0 && fill.filledQuote > 0 ? fill.filledQuote / fill.filledSize : null
        fillStatus = fill.status
    }
    await recordEtfAttempt({ ticker: row.ticker, chicagoDate: today, quoteUsd: quote, filled,
        closedSession: false, coinbaseOrderId: orderId, clientOrderId,
        errorMessage: filled ? null : `not filled (status ${fillStatus || 'unknown'})`,
        fillPrice: filled ? fillPrice : null, status: filled ? 'FILLED' : 'OPEN',
        quoteCurrency: currency, productId })
    console.log(filled ? `ETF buy filled: ${row.ticker} ${quote.toFixed(2)} ${currency} market` : `ETF market buy accepted, fill not confirmed yet: ${row.ticker} (${currency}) status ${fillStatus}`)
    return { filled }
}

// Send the orders reserved at the start of this run (no re-pick, no
// re-reserve). Runs first inside processBuyOrders, before crypto.
async function processEquityEtfBuys() {
    if (!equitySessionOpen) return
    // 2026-10-06: listing snipe is priority one over ETF-hours. Re-check after
    // thee_procedure so a listing row inserted this same minute still blocks
    // ETF placement (covers pending buy and filled-unsold).
    try {
        const listingOpen = await db.query(
            `SELECT 1 FROM position
             WHERE period_type = 'listing' AND sell_filled_price IS NULL
             LIMIT 1`
        )
        if ((listingOpen?.rows || []).length > 0) {
            etfAttemptsThisRun = []
            console.log('ETF orders skipped: active listing position (priority one)')
            return
        }
    } catch (error) {
        console.log('processEquityEtfBuys() listing gate ERROR', error?.message || error)
    }
    if (etfAttemptsThisRun.length === 0) {
        console.log('ETF orders: nothing to place this run')
        return
    }
    try {
        const bal = await equity.defaultUsdAvailable()
        if (!bal.ok) {
            console.log(`ETF orders skipped: Default USD unreadable (${bal.reason})`)
            return
        }
        // 2026-10-07: minus profit queued for the USDC sweep (same reserve
        // the crypto buy gates in thee_procedure subtract). USD pot only.
        const sweepReserve = await usdcSweepReserve()
        let cash = Math.max(0, bal.available - sweepReserve)
        // 2026-10-07: separate USDC pot for rows planned on the USDC product.
        let usdcCash = Math.max(0, Number(bal.usdcAvailable) || 0)
        console.log(`ETF Default USD available: $${cash.toFixed(2)}${sweepReserve > 0 ? ` (after $${sweepReserve.toFixed(2)} profit queued for USDC)` : ''} | USDC available: ${usdcCash.toFixed(2)}`)
        const today = chicagoToday()
        const ttlHours = await configNumber('etf_limit_ttl_hours', 12)
        for (const planned of etfAttemptsThisRun) {
            if (!equitySessionOpen) break
            let row = planned
            const cost = Number(row.notional)
            if (!(cost > 0)) {
                console.log(`ETF ${row.kind} skipped: ${row.ticker} bad notional ${row.notional}`)
                continue
            }
            // Re-check the planned pot with live balances. USDC moved since
            // the plan (rare: a manual convert) -> same fallback rule as the
            // plan: USD on the USD product if allowed and affordable.
            if (row.quoteCurrency === 'USDC' && !(usdcCash >= cost)) {
                if (row.fallbackUsd && cash >= cost) {
                    console.log(`ETF ${row.ticker}: USDC short at send (${usdcCash.toFixed(2)} < ${cost.toFixed(2)}), falling back to USD`)
                    row = { ...row, quoteCurrency: 'USD', orderProductId: row.product_id }
                } else {
                    console.log(`ETF ${row.kind} skipped: ${row.ticker} needs ${cost.toFixed(2)} USDC, have ${usdcCash.toFixed(2)} USDC`)
                    continue
                }
            }
            if (row.quoteCurrency !== 'USDC' && !(cash >= cost)) {
                console.log(`ETF ${row.kind} skipped: ${row.ticker} needs $${cost.toFixed(2)}, have $${cash.toFixed(2)}`)
                continue
            }
            const result = row.kind === 'market'
                ? await placeEtfMarket(row, today)
                : await placeEtfLimit(row, today, ttlHours)
            if (result.closed) break
            if (result.filled || result.placed) {
                if (row.quoteCurrency === 'USDC') usdcCash -= cost
                else cash -= cost
            }
        }
    } catch (error) {
        console.log('processEquityEtfBuys() ERROR', error?.message || error)
        // Crypto placement below is independent of this failure.
    }
}

async function processBuyOrders () {
    try {
        // bulk_currency is already truncated by the time this runs (thee_procedure()
        // truncates it at the end, and that runs before this), so check live rather
        // than via vw_balance. If there isn't at least $1 free, don't even look at
        // the pending-buy backlog -- every one of them would just fail anyway.
        //
        // ETF attempts that were reserved before thee_procedure go first.
        // Crypto reads the live balance after they return, so it still
        // trades this minute with whatever Default USD is left. pause_buys
        // does not apply to the ETF call.
        await processEquityEtfBuys()

        // Naked-buy heal path: remake cancel+create can leave buy_coinbase_order_id
        // NULL (see processRemakeOrders). thee_procedure clears error_message on
        // unfilled buys each cycle, so those rows show up here and get a fresh
        // client_order_id. Inventory CAP does NOT apply here — this only places
        // already-inserted pending rows (recovery), not brand-new signals.
        const accounts = await ca.gatherBalance();
        const usd = accounts?.find(a => a.currency === 'USD');
        const available = usd ? parseFloat(usd.available_balance.value) : 0;
        if (!(available > 1)) {
            console.log(`processBuyOrders() skipped: only $${available.toFixed(2)} available`);
            return;
        }

        const orders = await db.executeQuery(`
            SELECT p.* FROM position p
            JOIN stock s ON s.stock_id = p.stock_id
            WHERE p.buy_coinbase_order_id IS NULL AND p.error_message IS NULL
            AND p.buy_filled_price IS NULL
            -- 2026-10-05: every planned row thee_procedure keeps is meant to be
            -- sent THIS minute. The old placement filters here were moved into
            -- the procedure (its INSERT gates + planned-row clean-up), so rows
            -- no longer sit unsent:
            --   * trading_disabled coin          -> clean-up (b)
            --   * 30-min far-release cooldown    -> clean-up (c) deletes released rows
            --   * price not under trigger        -> INSERT gate + clean-up (e) + post-cap delete
            --   * order-book gates               -> INSERT gates + clean-up (f)/(g)
            --   * per-row cash check (cashLeft)  -> INSERT cost gate + affordability walk
            -- Left here: error_message IS NULL (a Coinbase rejection; the
            -- procedure clears it each run so the row is retried next minute)
            -- and this one same-run guard: a row processFarBuyCashRelease()
            -- released moments ago in THIS run is not re-placed into the cash
            -- it just freed; thee_procedure deletes it at the start of the next
            -- run, so it never sits.
            AND p.buy_released_at IS NULL
            -- 2026-10-07: a listing snipe row (at most one, inserted by
            -- thee_procedure only inside the first listing_window_minutes
            -- after trading opened) goes FIRST so normal rows cannot spend
            -- the cash it was gated on.
            ORDER BY (p.period_type = 'listing') DESC, s.priority DESC NULLS LAST
        `)
        console.log(`Buy Orders to Process: ${orders.length}`);

        // 2026-10-05: the per-row cashLeft skip (2026-09-27) and the live L2
        // book gate that used to sit here were removed. Both only SKIPPED a row
        // (left it planned), which is how rows sat for hours. thee_procedure
        // now (a) only inserts a row whose cost incl. the 1.2% fee pad fits
        // free cash after the planned backlog and ETF reserve, (b) deletes
        // planned rows that no longer fit (greedy walk in priority order, same
        // as the old cashLeft loop) and (c) applies the spread / imbalance /
        // thin-ask gates (thresholds in config: book_max_spread_pct,
        // book_skip_imbalance, book_min_ask_notional_mult). If Coinbase still
        // rejects (e.g. INSUFFICIENT_FUND after a race), the else branch below
        // records error_message and the row is retried / cleaned up next run.
        for (i = 0; i < orders.length; i++) {
            const element = orders[i];
            // Coinbase treats client_order_id as an idempotency key: reusing one
            // already used for a since-cancelled order returns that SAME dead
            // order back with success: true, not a genuinely new one. Confirmed
            // live 2026-09-05 -- this is why nulling buy_coinbase_order_id on a
            // failed/cancelled position and letting it retry kept resurrecting
            // the exact same dead order every time. processSellOrders() already
            // generates a fresh id per attempt; this didn't.
            const newOrderId = crypto.randomUUID()
            // 2026-10-07: listing snipe = PLAIN LIMIT buy (limit_limit_gtc),
            // no stop trigger and no expiry. Why: the snipe window opens at
            // the pair's first trade, which is normally still inside
            // Coinbase's launch LIMIT-ONLY phase (CT-USD: first match 10:16
            // UTC, market orders only from ~15:15 UTC), where only limit
            // orders are accepted. thee_procedure already set buy_price =
            // first trade price + listing_limit_cushion_pct (rounded to the
            // price increment) and shares = ~$listing_buy_usd at that limit.
            // GTC per Theodore: it rests until it fills or he cancels it --
            // the bot never auto-cancels it (see the listing exemptions in
            // processFarBuyCashRelease / processObseleteBuyOrders /
            // vw_edit_orders / thee_procedure). Every other row keeps the
            // normal stop-limit buy.
            const isListing = element.period_type === 'listing'
            let response = isListing
                ? await ca.createLimitOrder('buy', element.buy_price, element.shares, element.name, newOrderId)
                : await ca.createStopLimitOrder('buy', element.buy_price, element.shares, element.name, element.buy_stop_price, newOrderId);
            if(response?.success == true) {
                // buy_placed_at (2026-09-25): order age, so far-release won't cancel a fresh order
                await db.executeQuery(`UPDATE position SET buy_order_id = '${newOrderId}', buy_coinbase_order_id = '${response.success_response.order_id}', buy_placed_at = NOW() WHERE buy_order_id = '${element.buy_order_id}'`)
                console.log(`${isListing ? 'Listing LIMIT Buy Created (GTC, no expiry)' : 'Buy Order Created'}: ${element.name} | shares: ${element.shares} | price: ${element.buy_price}`)
            } else {
                const errMsg = (response?.error_response?.message || 'unknown').replace(/'/g, "''")
                await db.executeQuery(`UPDATE position SET error_message = '${errMsg}' WHERE buy_order_id = '${element.buy_order_id}'`)
                // 2026-10-07: a listing rejection (e.g. still auction / cancel-
                // only, post-only, or a size/price rule) needs no special path:
                // thee_procedure drops the unsent listing row next minute and
                // re-inserts it with fresh gates only while the window is
                // still open, so it is retried each minute inside the window
                // and simply stops after.
                console.log(isListing ? `Listing Buy FAILED (retried next minute only while the window is open): ${element.name}` : `Buy Order FAILED: ${element.name}`, response)
                // 2026-09-25: 'Invalid product_id' means the product no longer exists
                // on Coinbase (delisted, e.g. LRC-USD) -- retrying can never succeed.
                // Flag the coin so nothing picks it again, and drop this planned row.
                // The DELETE is guarded so it can only remove a row that never
                // filled and has no live Coinbase order (nothing real is lost).
                if (response?.error_response?.message === 'Invalid product_id') {
                    await db.executeQuery(`UPDATE stock SET trading_disabled = TRUE WHERE stock_id = ${Number(element.stock_id)}`)
                    await db.executeQuery(`DELETE FROM position WHERE buy_order_id = '${element.buy_order_id}' AND buy_filled_price IS NULL AND buy_coinbase_order_id IS NULL`)
                    console.log(`Delisted coin disabled, planned buy removed: ${element.name}`)
                }
            }
        }

    } catch (error) {
        console.log("processBuyOrders() ERROR", error)
    }
}

async function processSellOrders () {
    try {
        // Skip underwater bags: when the current price is at or below the fee-floor
        // stop, Coinbase rejects a STOP_DOWN stop-limit
        // (PREVIEW_STOP_PRICE_ABOVE_LAST_TRADE_PRICE), so trying only burns two API
        // calls per bag and floods the log. A NULL price still goes through so
        // missing price data never leaves a bag without a sell attempt.
        const orders = await db.executeQuery(`SELECT p.*, s.price AS current_price, s.price_rounding FROM position p JOIN stock s ON p.stock_id = s.stock_id WHERE p.buy_filled_price IS NOT NULL AND p.sell_coinbase_order_id IS NULL AND p.sell_price IS NOT NULL AND (s.price IS NULL OR s.price > p.sell_stop_price);`)
        console.log(`Sell Orders to Process: ${orders.length}`);
        for(let i = 0; i < orders.length; i++) {
            let element = orders[i];
            const newSellOrderId = crypto.randomUUID()
            let response
            // Always a stop-limit order, underwater or not -- no plain-limit
            // fallback (a resting GTC limit isn't a stop-limit order, per the
            // user's explicit rule for this). When the fee-floor
            // sell_stop_price sits above market (underwater), Coinbase rejects
            // the STOP_DOWN preview (PREVIEW_STOP_PRICE_ABOVE_LAST_TRADE_PRICE)
            // -- handled below by leaving the position unprotected and
            // retrying next cycle, per thee_procedure.sql's "Initial sell
            // stop" comment: never respond to that rejection by substituting
            // a lower (loss-making) price.
            response = await ca.createStopLimitOrder('sell', element.sell_price, element.shares, element.name, element.sell_stop_price, newSellOrderId)
            if(response?.success == true) {
                await db.executeQuery(`UPDATE position SET sell_coinbase_order_id = '${response.success_response.order_id}', sell_order_id = '${newSellOrderId}', error_message = NULL WHERE buy_order_id = '${element.buy_order_id}'`)
                console.log(`Sell Order Created: ${element.name} | shares: ${element.shares} | price: ${element.sell_price}`)
            } else if(response?.error_response?.preview_failure_reason === 'PREVIEW_STOP_PRICE_ABOVE_LAST_TRADE_PRICE') {
                // Race: market dipped under the stop between our check and Coinbase's
                // preview. Do not lower the floor — next cycle will use the limit-TP path.
                console.log(`Sell Order deferred (underwater): ${element.name} | current: ${element.current_price} | floor: ${element.sell_stop_price}`)
            } else {
                const errMsg = (response?.error_response?.message || 'unknown').replace(/'/g, "''")
                await db.executeQuery(`UPDATE position SET error_message = '${errMsg}' WHERE buy_order_id = '${element.buy_order_id}'`)
                console.log(`Sell Order FAILED: ${element.name}`, response)
            }
        }
    } catch (error) {
        console.log("processSellOrders() ERROR", error)
    }
}

async function processObseleteBuyOrders () {
    try {
        // A buy stop-limit order that has triggered (price crossed the stop, so
        // Coinbase converted it into a working limit order) but then had price
        // run past the limit price too is stuck: a limit BUY can't fill above
        // its own limit, so it'll sit open indefinitely unless price falls all
        // the way back down -- meanwhile its hold ties up cash that could go
        // toward a fresh pick. Confirmed stuck on MINA-USD and LSETH-USD for
        // weeks (trigger_status STOP_TRIGGERED, current price 2x+ the stop).
        // Gated on the position being at least an hour old (not on a separately
        // tracked "since stuck" timestamp) so a coin that triggers and clears
        // its own limit again within the hour is left alone -- reuses
        // date_created instead of adding new state to track.
        const orders = await db.executeQuery(`
            SELECT p.buy_order_id, p.name, p.buy_coinbase_order_id
            FROM position p
            JOIN bulk_open_orders o ON o.order_id = p.buy_coinbase_order_id AND o.side = 'BUY'
            JOIN stock s ON s.stock_id = p.stock_id
            WHERE p.buy_coinbase_order_id IS NOT NULL
            AND p.buy_filled_price IS NULL
            AND p.date_created < NOW() - INTERVAL '1 hour'
            AND o.trigger_status = 'STOP_TRIGGERED'
            -- 2026-10-07: listing limit buys are never auto-cancelled (no stop,
            -- so never STOP_TRIGGERED anyway; explicit for safety).
            AND p.period_type IS DISTINCT FROM 'listing'
            AND s.price > p.buy_price;
        `)
        for (let i = 0; i < orders.length; i++) {
            const element = orders[i]
            // Only delete the position once the cancel is confirmed -- a failed
            // cancel can mean the order already filled, and deleting the row on
            // top of that would silently lose a real position.
            const cancelResponse = await ca.cancelOrder(element.buy_coinbase_order_id)
            if (cancelResponse == true) {
                await db.executeQuery(`DELETE FROM position WHERE buy_order_id = '${element.buy_order_id}'`)
                console.log(`Obsolete Buy Order Cancelled: ${element.name} | order: ${element.buy_coinbase_order_id}`)
            } else {
                console.log(`Obsolete Buy Order Cancel FAILED: ${element.name}`, cancelResponse)
            }
        }
    } catch (error) {
        console.log("processObseleteBuyOrders() ERROR", error)
    }
}


async function processFarBuyCashRelease () {
    try {
        // Problem: ~$1 tickets sit in open STOP_UP buys, free USD often <$1, so
        // processBuyOrders never heals naked rows and remake recreates race on
        // hold lag. Policy: if live free USD is not above $1, cancel up to
        // FAR_BUY_CANCEL_LIMIT open buy stops that are farthest above market
        // (largest (buy_stop_price - price) / price). Null buy_coinbase_order_id
        // so thee_procedure can refresh stop/limit toward market and
        // processBuyOrders can re-place later — do NOT delete the position.
        const FAR_BUY_CANCEL_LIMIT = 3
        const accounts = await ca.gatherBalance();
        const usd = accounts?.find(a => a.currency === 'USD');
        const available = usd ? parseFloat(usd.available_balance.value) : 0;
        if (available > 1) {
            return;
        }
        // ---- 2026-09-25 loop fix ------------------------------------------
        // Every planned buy is priced 5% above market (thee_procedure), so every
        // live buy always looked "far" and this cancelled 3 orders every time
        // cash was low -- then processBuyOrders re-placed the SAME orders the next
        // minute (they were the highest-priority pending rows), an endless
        // cancel/re-place loop with no benefit. Now we only release cash when:
        //   1. there is a beneficiary: a pending row with no live order (not in
        //      its own 30-min cooldown) that processBuyOrders would place;
        //   2. each victim has LOWER priority than that beneficiary (a genuine
        //      swap toward something better, never a lateral churn);
        //   3. each victim order is at least 30 min old (buy_placed_at);
        //   4. free cash + the victims' holds would actually cover the
        //      beneficiary's clip (otherwise the cancel achieves nothing).
        const FAR_BUY_MIN_AGE_MIN = 30
        const FEE_PAD = 1.012   // clip/hold estimate incl. ~1.2% taker fee
        const beneficiaries = await db.executeQuery(`
            -- pending buys with no live order, same eligibility/order as processBuyOrders
            SELECT p.buy_order_id, p.name, COALESCE(s.priority, 0)::numeric AS priority,
                   (p.shares * p.buy_price)::numeric * ${FEE_PAD} AS clip
            FROM position p
            JOIN stock s ON s.stock_id = p.stock_id
            -- 2026-10-05: the price-vs-trigger, order-book, trading_disabled and
            -- 30-min cooldown filters were removed here (and in processBuyOrders):
            -- thee_procedure now deletes any planned row that fails them, so
            -- every remaining planned row is one processBuyOrders will send.
            -- NOTE: the procedure also deletes planned rows free cash cannot
            -- cover, so when free USD is <= $1 there is normally no planned row
            -- left to be a beneficiary and this function just logs "skipped".
            WHERE p.buy_coinbase_order_id IS NULL
            AND p.buy_filled_price IS NULL
            AND (p.error_message IS NULL OR p.error_message NOT IN ('Invalid product_id'))
            ORDER BY s.priority DESC NULLS LAST
            LIMIT 1
        `)
        if (!beneficiaries.length) {
            console.log(`processFarBuyCashRelease() skipped: $${available.toFixed(2)} free but no pending buy would use released cash`)
            return
        }
        const best = beneficiaries[0]
        const orders = await db.executeQuery(`
            SELECT p.buy_order_id, p.name, p.buy_coinbase_order_id, p.buy_stop_price, s.price AS market,
                (p.buy_stop_price::numeric - s.price::numeric) / NULLIF(s.price::numeric, 0) AS gap_pct,
                (p.shares * p.buy_price)::numeric * ${FEE_PAD} AS hold_est
            FROM position p
            JOIN stock s ON s.stock_id = p.stock_id
            WHERE p.buy_coinbase_order_id IS NOT NULL
            AND p.buy_filled_price IS NULL
            -- 2026-10-07: never cancel a resting listing limit buy (Theodore:
            -- it rests GTC until it fills or he cancels it). Its NULL
            -- buy_stop_price already fails the next line; explicit for safety.
            AND p.period_type IS DISTINCT FROM 'listing'
            AND p.buy_stop_price > s.price
            -- only swap for something better than the order being cancelled
            AND COALESCE(s.priority, 0)::numeric < ${Number(best.priority)}
            -- never cancel a fresh order (NULL = placed before this column existed)
            AND (p.buy_placed_at IS NULL OR p.buy_placed_at < NOW() - INTERVAL '${FAR_BUY_MIN_AGE_MIN} minutes')
            ORDER BY gap_pct DESC NULLS LAST
            LIMIT ${FAR_BUY_CANCEL_LIMIT}
        `)
        if (!orders.length) {
            console.log(`processFarBuyCashRelease() skipped: $${available.toFixed(2)} free, no older/lower-priority buy stop to swap for ${best.name}`)
            return
        }
        const freeable = orders.reduce((sum, o) => sum + Number(o.hold_est), 0)
        if (available + freeable < Number(best.clip)) {
            console.log(`processFarBuyCashRelease() skipped: releasing $${freeable.toFixed(2)} still can't cover ${best.name} clip $${Number(best.clip).toFixed(2)}`)
            return
        }
        // --------------------------------------------------------------------
        console.log(`processFarBuyCashRelease(): $${available.toFixed(2)} free — canceling ${orders.length} farthest buy stop(s)`)
        for (let i = 0; i < orders.length; i++) {
            const element = orders[i]
            const cancelResponse = await ca.cancelOrder(element.buy_coinbase_order_id)
            if (cancelResponse == true) {
                // buy_released_at marks the row as released: processBuyOrders will
                // not re-place it in this run, and (2026-10-05) thee_procedure
                // deletes it at the start of the next run (clean-up (c)) instead
                // of the old 30-min cooldown during which it sat unsent.
                await db.executeQuery(`UPDATE position SET buy_coinbase_order_id = NULL, error_message = NULL, buy_released_at = NOW() WHERE buy_order_id = '${element.buy_order_id}'`)
                console.log(`Far Buy Cancelled: ${element.name} | gap: ${(Number(element.gap_pct)*100).toFixed(1)}% | stop: ${element.buy_stop_price} | mkt: ${element.market} | for: ${best.name}`)
            } else {
                console.log(`Far Buy Cancel FAILED: ${element.name}`, cancelResponse)
            }
        }
    } catch (error) {
        console.log("processFarBuyCashRelease() ERROR", error)
    }
}

async function processRemakeOrders () {
    try {
        // No LIMIT: an unaffordable/skipped candidate anywhere in the list would
        // otherwise block every candidate behind it from ever being considered in
        // the same cycle -- confirmed on MAMO-USD (perpetually top of the queue,
        // perpetually insufficient funds) starving BLZ-USD out of ever getting a
        // turn back when this was LIMIT 1. Now protected against runaway API
        // usage by the real rate limiter in getApiCall() (10 req/sec) instead of
        // an arbitrary row cap. Explicit ORDER BY here matches vw_edit_orders'
        // own ordering exactly -- a bare `SELECT * FROM view` doesn't reliably
        // preserve a view's internal ORDER BY once queried from outside it.
        // vw_edit_orders remake rules (buy and sell both go through this query):
        // every open buy bag can be remade (no creation_hierarchy filter);
        // sells only remake creation_hierarchy = 1 (cheapest fill per coin,
        // ranked by thee_procedure on buy_filled_price / buy_stop_price).
        const orders = await db.executeQuery(`SELECT * FROM vw_edit_orders ORDER BY last_remade_at ASC NULLS FIRST, price_diff DESC;`)
        for(let i = 0; i < orders.length; i++){
            let element = orders[i];
            const preview = await ca.previewStopLimitOrder(element.order_type, element.order_price, element.shares, element.name, element.new_stop_price)
            if(!preview.ok) {
                const errMsg = JSON.stringify(preview.errors).replace(/'/g, "''")
                await db.executeQuery(`UPDATE position SET error_message = '${errMsg}' WHERE buy_order_id = '${element.buy_order_id}'`)
                console.log(`Remake Preview FAILED: ${element.name} ${element.order_type}, skipping`, preview.errors)
                continue
            }
            // Buy remakes: do not require spare USD above the existing hold.
            // Cancel first so that hold frees; then recreate. If recreate fails,
            // buy_coinbase_order_id is nulled below and processBuyOrders can retry.
            // Only proceed to create a replacement if the cancel genuinely succeeded —
            // a failure can mean the old order already filled, and creating a
            // replacement on top of that would double the position.
            let cancelResponse = await ca.cancelOrder(element.coinbase_order_id)
            if(cancelResponse == true) {
                // Give Coinbase a moment to release the USD hold before recreating.
                // Buy remakes especially hit INSUFFICIENT_FUND when create follows
                // cancel in the same tick (confirmed MON/ETC/BCH overnight).
                if (element.order_type === 'buy') {
                    await new Promise(r => setTimeout(r, 500))
                }
                let newOrderId = crypto.randomUUID()
                let reMakeResponse = await ca.createStopLimitOrder(element.order_type, element.order_price, element.shares, element.name, element.new_stop_price, newOrderId)
                // One retry only: flat wait bumps (300→500) helped most cases but
                // bursts of back-to-back remakes still race the hold release.
                // Retrying once after another 500ms covers the lag without
                // sleeping on every successful remake.
                const insuff = reMakeResponse?.error_response?.error === 'INSUFFICIENT_FUND'
                    || reMakeResponse?.error_response?.preview_failure_reason === 'PREVIEW_INSUFFICIENT_FUND'
                if (reMakeResponse?.success != true && insuff && element.order_type === 'buy') {
                    console.log(`Remake Create INSUFFICIENT_FUND — retry once: ${element.name}`)
                    await new Promise(r => setTimeout(r, 500))
                    newOrderId = crypto.randomUUID()
                    reMakeResponse = await ca.createStopLimitOrder(element.order_type, element.order_price, element.shares, element.name, element.new_stop_price, newOrderId)
                }
                if(reMakeResponse?.success == true) {
                    if(element.order_type === 'buy') {
                        await db.executeQuery(`UPDATE position SET buy_order_id = '${newOrderId}', buy_coinbase_order_id = '${reMakeResponse.success_response.order_id}', buy_stop_price = ${element.new_stop_price}, buy_price = ${element.order_price}, buy_counter = buy_counter + 1, last_remade_at = NOW(), buy_placed_at = NOW(), error_message = NULL WHERE buy_order_id = '${element.buy_order_id}'`)
                    } else {
                        // sell_price intentionally absent: it's frozen (see
                        // vw_edit_orders.sql), and element.order_price is
                        // always that same already-set value -- only
                        // sell_stop_price ever moves on a sell remake.
                        await db.executeQuery(`UPDATE position SET sell_order_id = '${newOrderId}', sell_coinbase_order_id = '${reMakeResponse.success_response.order_id}', sell_stop_price = ${element.new_stop_price}, sell_counter = sell_counter + 1, last_remade_at = NOW(), error_message = NULL WHERE buy_order_id = '${element.buy_order_id}'`)
                    }
                    console.log(`Remake OK: ${element.name} ${element.order_type} | shares: ${element.shares} | new stop: ${element.new_stop_price} | est profit: ${element.estimated_profit} | counter: ${element.counter + 1}`)
                } else {
                    // Null the live id so we do not pretend the canceled order still
                    // exists. Leave error_message NULL on buys: thee_procedure already
                    // clears errors on unfilled buys, and processBuyOrders heals when
                    // free USD > $1 (after far-buy cash release if needed).
                    if(element.order_type === 'buy') {
                        await db.executeQuery(`UPDATE position SET buy_coinbase_order_id = NULL, error_message = NULL WHERE buy_order_id = '${element.buy_order_id}'`)
                    } else {
                        const errMsg = (reMakeResponse?.error_response?.message || 'unknown').replace(/'/g, "''")
                        await db.executeQuery(`UPDATE position SET sell_coinbase_order_id = NULL, error_message = '${errMsg}' WHERE buy_order_id = '${element.buy_order_id}'`)
                    }
                    console.log(`Remake Create FAILED: ${element.name} ${element.order_type}`, reMakeResponse)
                }
            } else {
                const errMsg = `cancel failed for ${element.coinbase_order_id}`
                await db.executeQuery(`UPDATE position SET error_message = '${errMsg}' WHERE buy_order_id = '${element.buy_order_id}'`)
                console.log(`Remake Cancel FAILED: ${element.name} ${element.order_type}`, cancelResponse)
            }
        }
    } catch (error) {
        console.log("processRemakeOrders() ERROR", error)
    }
}



// Shared near-mid book metrics for logging and buy gates.
// imbalance in [-1,1]: +bid-heavy, -ask-heavy. bandPct default 0.5%.
function computeBookMetrics (book, bandPct = 0.005) {
    const bids = (book?.bids || []).map(x => ({ p: Number(x.price), s: Number(x.size) }))
        .filter(x => Number.isFinite(x.p) && Number.isFinite(x.s))
    const asks = (book?.asks || []).map(x => ({ p: Number(x.price), s: Number(x.size) }))
        .filter(x => Number.isFinite(x.p) && Number.isFinite(x.s))
    if (!bids.length || !asks.length) return null
    const bestBid = bids[0].p
    const bestAsk = asks[0].p
    const mid = (bestBid + bestAsk) / 2
    if (!(mid > 0)) return null
    const band = mid * bandPct
    const nearBidUsd = bids.filter(b => b.p >= mid - band)
        .reduce((sum, lvl) => sum + lvl.p * lvl.s, 0)
    const nearAskUsd = asks.filter(a => a.p <= mid + band)
        .reduce((sum, lvl) => sum + lvl.p * lvl.s, 0)
    if (!Number.isFinite(nearBidUsd) || !Number.isFinite(nearAskUsd)) return null
    const denom = nearBidUsd + nearAskUsd
    const imbalance = denom > 0 ? (nearBidUsd - nearAskUsd) / denom : 0
    const spreadPct = ((bestAsk - bestBid) / mid) * 100
    return {
        bestBid, bestAsk, mid, spreadPct, nearBidUsd, nearAskUsd,
        imbalance, bandPct, bidLevels: bids.length, askLevels: asks.length
    }
}

// 2026-10-05: the BOOK_SKIP_IMBALANCE (-0.4) / BOOK_MAX_SPREAD_PCT (0.75) /
// BOOK_MIN_ASK_NOTIONAL_MULT (5) constants that lived here were removed. The
// book buy gates now run inside thee_procedure, with the thresholds in the
// config table: book_skip_imbalance, book_max_spread_pct,
// book_min_ask_notional_mult (the procedure falls back to these same
// defaults if a key is missing). computeBookMetrics() above still produces
// the book_snapshot rows those gates read.

// 2026-10-05: load best bid / best ask for EVERY Coinbase product (one API
// call, ~1000 products, ~200 ms) into bulk_best_bid_ask, replacing the
// whole table in one transaction so readers never see a half-loaded copy.
// thee_procedure (called later this run) rejects a new or existing planned
// buy whose spread_pct > config.book_max_spread_pct -- but only while the
// table is fresh (loaded_at within 3 minutes). On any failure the table is
// emptied, so the procedure fails OPEN (skips the spread gate) instead of
// judging on stale quotes. spread_pct = (ask - bid) / mid * 100; NULL when
// either side is missing/<= 0 or the book is crossed (counts as failing
// while the data is fresh). Read-only against Coinbase; writes only this
// table. Never throws.
async function processBestBidAsk () {
    let client
    try {
        const books = await ca.getBestBidAskAll()
        const byId = new Map()
        for (const b of (books || [])) {
            if (!b?.product_id || byId.has(b.product_id)) continue
            const bid = Number(b.bids?.[0]?.price)
            const bidSize = Number(b.bids?.[0]?.size)
            const ask = Number(b.asks?.[0]?.price)
            const askSize = Number(b.asks?.[0]?.size)
            const okBid = Number.isFinite(bid) && bid > 0
            const okAsk = Number.isFinite(ask) && ask > 0
            const spread = (okBid && okAsk && ask >= bid) ? ((ask - bid) / ((ask + bid) / 2)) * 100 : null
            byId.set(b.product_id, {
                id: b.product_id,
                bid: okBid ? bid : null,
                bidSize: Number.isFinite(bidSize) ? bidSize : null,
                ask: okAsk ? ask : null,
                askSize: Number.isFinite(askSize) ? askSize : null,
                spread,
                time: (typeof b.time === 'string' && b.time) ? b.time : null,
            })
        }
        const rows = [...byId.values()]
        client = await db.connect()
        await client.query('BEGIN')
        await client.query('DELETE FROM bulk_best_bid_ask')
        if (rows.length) {
            await client.query(`
                INSERT INTO bulk_best_bid_ask
                    (product_id, best_bid, best_bid_size, best_ask, best_ask_size, spread_pct, quote_time)
                SELECT * FROM UNNEST($1::text[], $2::float8[], $3::float8[], $4::float8[],
                                     $5::float8[], $6::float8[], $7::timestamptz[])
            `, [
                rows.map(r => r.id), rows.map(r => r.bid), rows.map(r => r.bidSize),
                rows.map(r => r.ask), rows.map(r => r.askSize), rows.map(r => r.spread),
                rows.map(r => r.time),
            ])
        }
        await client.query('COMMIT')
        if (rows.length) {
            console.log(`Best bid/ask: ${rows.length} products loaded`)
        } else {
            console.log('Best bid/ask: no data from Coinbase -- table emptied, procedure spread gate fails open this run')
        }
    } catch (error) {
        console.log('processBestBidAsk() ERROR', error?.message || error)
        if (client) {
            try { await client.query('ROLLBACK') } catch (_) { /* already logged above */ }
        }
        // Fail open: an empty table makes thee_procedure skip the spread gate.
        try {
            await db.query('DELETE FROM bulk_best_bid_ask')
        } catch (cleanupErr) {
            console.log('processBestBidAsk() cleanup ERROR', cleanupErr?.message || cleanupErr)
        }
    } finally {
        if (client) client.release()
    }
}

// Read-only order-book logger (book_snapshot), the data source for
// thee_procedure's imbalance / thin-ask gates. No place/cancel here.
// 2026-10-05 retarget: runs BEFORE thee_procedure (was after) and picks,
// in this order, up to MAX_PER_CYCLE coins:
//   (a) every coin with an unfilled buy (planned or live) -- the clean-up
//       judges planned rows on a < 3 min snapshot, so these always come first;
//   (b) the top CANDIDATES coins the procedure could plan next (same core
//       filters as its INSERTs: year trend > 0, day dip, tradable, no
//       pending buy, and either not held or price under the add-on cap;
//       spread OK when bulk_best_bid_ask is fresh), by priority -- before
//       this, new picks were judged on hours-old snapshots or none;
//   (c) held coins, oldest snapshot first, to fill the rest (rotation).
// Before: open/pending coins only, alphabetical, first 40 -- so coins late in
// the alphabet were never refreshed.
async function processBookSnapshots () {
    try {
        const MAX_PER_CYCLE = 50
        const CANDIDATES = 20
        const pending = await db.executeQuery(`
            SELECT DISTINCT p.name, p.stock_id
            FROM position p
            JOIN stock s ON s.stock_id = p.stock_id
            WHERE p.buy_order_id IS NOT NULL
            AND p.buy_filled_price IS NULL
            AND p.sell_filled_price IS NULL
            AND s.trading_disabled IS NOT TRUE
            AND p.name LIKE '%-USD'
        `) || []
        const candidates = await db.executeQuery(`
            SELECT s.name, s.stock_id
            FROM vw_signal s
            JOIN stock st ON st.stock_id = s.stock_id
            JOIN vw_signal d ON d.stock_id = s.stock_id AND d.period_type = 'day'
            LEFT JOIN bulk_best_bid_ask bba ON bba.product_id = s.name
            WHERE s.period_type = 'year'
            AND s.historical_avg_change_percent > 0
            AND d.current_change_percent < d.historical_avg_change_percent
            AND st.trading_disabled IS NOT TRUE
            AND st.name LIKE '%-USD'
            AND NOT EXISTS (
                SELECT 1 FROM position x
                WHERE x.stock_id = s.stock_id
                AND x.buy_order_id IS NOT NULL
                AND x.buy_filled_price IS NULL
            )
            AND (
                NOT EXISTS (
                    SELECT 1 FROM position f
                    WHERE f.stock_id = s.stock_id
                    AND f.buy_filled_price IS NOT NULL
                    AND f.sell_filled_price IS NULL
                )
                OR st.price < (
                    SELECT MIN(f.buy_filled_price) FROM position f
                    WHERE f.stock_id = s.stock_id
                    AND f.buy_filled_price IS NOT NULL
                    AND f.sell_filled_price IS NULL
                ) * COALESCE((SELECT value::numeric FROM config WHERE key = 'add_buy_cap_ratio'), 0.99)
            )
            AND (
                NOT EXISTS (SELECT 1 FROM bulk_best_bid_ask WHERE loaded_at > NOW() - INTERVAL '3 minutes')
                OR bba.spread_pct <= COALESCE((SELECT value::double precision FROM config WHERE key = 'book_max_spread_pct'), 0.75)
            )
            ORDER BY s.priority DESC NULLS LAST
            LIMIT ${CANDIDATES}
        `) || []
        const held = await db.executeQuery(`
            SELECT h.name, h.stock_id
            FROM (
                SELECT DISTINCT p.name, p.stock_id
                FROM position p
                JOIN stock s ON s.stock_id = p.stock_id
                WHERE p.buy_filled_price IS NOT NULL
                AND p.sell_filled_price IS NULL
                AND s.trading_disabled IS NOT TRUE
                AND p.name LIKE '%-USD'
            ) h
            LEFT JOIN LATERAL (
                SELECT MAX(bs.date_created) AS last_snap
                FROM book_snapshot bs
                WHERE bs.name = h.name
            ) ls ON TRUE
            ORDER BY ls.last_snap ASC NULLS FIRST, h.name
        `) || []

        // Merge in priority order (a) -> (b) -> (c), one snapshot per coin.
        const seen = new Set()
        const targets = []
        const counts = { pending: 0, candidates: 0, held: 0 }
        for (const [group, list] of [['pending', pending], ['candidates', candidates], ['held', held]]) {
            for (const row of list) {
                if (targets.length >= MAX_PER_CYCLE) break
                if (seen.has(row.name)) continue
                seen.add(row.name)
                targets.push(row)
                counts[group]++
            }
        }
        if (!targets.length) {
            console.log('Book snapshots: 0 products')
            return
        }
        let logged = 0
        for (const row of targets) {
            const book = await ca.getProductBook(row.name, 20)
            const m = computeBookMetrics(book)
            if (!m) continue
            await db.executeQuery(`
                INSERT INTO book_snapshot (
                    stock_id, name, best_bid, best_ask, mid, spread_pct,
                    near_bid_usd, near_ask_usd, imbalance, band_pct,
                    bid_levels, ask_levels, date_created
                ) VALUES (
                    ${Number(row.stock_id)},
                    '${String(row.name).replace(/'/g, "''")}',
                    ${m.bestBid}, ${m.bestAsk}, ${m.mid}, ${m.spreadPct},
                    ${m.nearBidUsd}, ${m.nearAskUsd}, ${m.imbalance}, ${m.bandPct},
                    ${m.bidLevels}, ${m.askLevels}, NOW()
                )
            `)
            logged++
        }
        await db.executeQuery(`DELETE FROM book_snapshot WHERE date_created < NOW() - INTERVAL '48 hours'`)
        console.log(`Book snapshots: ${logged}/${targets.length} logged (cap ${MAX_PER_CYCLE}; pending ${counts.pending}, candidates ${counts.candidates}, held ${counts.held})`)
    } catch (error) {
        console.log('processBookSnapshots() ERROR', error)
    }
}


async function processPriceData () {
    try{
       // Current time in seconds
        const nowUnixSeconds = Math.floor(Date.now() / 1000); // Divide by 1000 to convert milliseconds to seconds

        // Subtract 24 hours (24 hours * 60 minutes * 60 seconds)
        const oneDayAgoUnixSeconds = nowUnixSeconds - 48 * 60 * 60;

        const priceData = await ca.yoinkPriceData('BTC-USD', oneDayAgoUnixSeconds, nowUnixSeconds, 'ONE_DAY');
        
        let highest = -Infinity; // Start with lowest possible number
        let lowest = Infinity; // Start with highest possible number

        for (let i = 0; i < priceData.length; i++) {
            const high = Number(priceData[i].high); // Convert to number
            const low = Number(priceData[i].low); // Convert to number

            if (high > highest) {
                highest = high;
                //console.log(`New highest: ${high}`);
            }
            if (low < lowest) {
                lowest = low;
                //console.log(`New lowest: ${low}`);
            }
        }
        const spread = ((highest - lowest) / lowest) * 100
        //console.log(spread, highest, lowest, priceData)
        return spread;
    } catch (error) {
        console.log('processPriceData()', error)
    }
}

async function processBuyOrdersOutOfRange (fills) {
    try{
        let sellDate = new Date(fills[0].trade_time)
        console.log(`Latest Order ${fills[0].side} ${sellDate}`)
        
        if(fills[0].side == 'SELL'){
            let openOrders = await ca.gatherOrders();
            for(i=0;i<openOrders.length; i++){
                let element = openOrders[i]
                //console.log(element.created_time)
                let buyDate = new Date(element.created_time)
                if(element.side == 'BUY' && sellDate > buyDate){
                    
                    //cancel it
                    await ca.cancelOrder(element.order_id)
                    console.log(`Cancel: ${element.order_id}`)
                }
            }
        }
        
    } catch (error) {
        console.log("processBuyOrdersOutOfRange()", error)
    }
}

async function processHistoricalPrices () {
    try {
        //get next stock
        let results = await db.fetchNextHistorical();
        let coin = results[0].name;
        let start_date = results[0].start_date;
        let end_date = results[0].end_date;
        let stockID = results[0].stock_id

        //Math.floor(new Date(yourDate).getTime() / 1000)
        let unixStartDate = Math.floor(new Date(start_date).getTime() / 1000)
        let unixEndDate = Math.floor(new Date(end_date).getTime() / 1000)

        // Coinbase candle API limit is 350 per request; cap to 349 days per call
        const maxUnixEnd = unixStartDate + 349 * 86400
        if (unixEndDate > maxUnixEnd) unixEndDate = maxUnixEnd

        //fetch from api
        let prices;
        console.log(`Next historical is`, stockID, coin, start_date, unixStartDate, end_date, unixEndDate);
        
        try {
            prices = await ca.yoinkPriceData(coin, unixStartDate, unixEndDate, 'ONE_DAY')
            console.log(prices.length, 'remaining historical');

            //download it to table
            await db.downloadHistoricalPrices(stockID, prices);

            //execute procedure
            await db.executeQuery(
                `Update stock s
                SET historical_last_date = x.earliest_date
                FROM (
                    SELECT stock_id, MIN(TO_TIMESTAMP(start)::DATE) as earliest_date
                    FROM bulk_historical
                    group by stock_id
                    ) x
                WHERE s.stock_id = x.stock_id;`
                )

            
        } catch (error)
        {
            await db.executeQuery(`UPDATE stock SET historical_finished = 1::bit WHERE stock_id = ` + stockID)
            await db.executeQuery('CALL insert_aggregate();')
        }

        if(prices.length == 0 || !prices) {
            await db.executeQuery(`UPDATE stock SET historical_finished = 1::bit WHERE stock_id = ` + stockID)
            await db.executeQuery('CALL insert_aggregate();')
        }

    } catch (error) {
        console.log('processHistoricalPrices()', error?.response);

        await db.executeQuery('CALL insert_aggregate();')
       // await db.executeQuery(`UPDATE stock set historical_finished = 1 WHERE stock_id = ${stockID}`
        
    }
}

// ---------------------------------------------------------------------------
// 2026-10-07: profit -> USDC sweep (Theodore).
//
// thee_procedure stores each close's net profit (after both fees, losses = 0)
// in profit_history.profit_converted_usdc. This sweeps the unswept total from
// USD into USDC so the bot (which only spends USD) cannot trade it away. The
// state lives on the profit_history rows themselves:
//   usdc_convert_status   NULL -> 'pending' -> 'completed' | 'failed'
//   usdc_convert_trade_id Coinbase convert trade id (written just BEFORE the
//                         commit is sent, so pending + trade id = commit sent)
//   usdc_converted_at     set when Coinbase confirms
//
//   1. config.usdc_sweep_enabled must be 'true' (kill switch).
//   2. One sweep at a time: a Postgres advisory lock (an overlapping cron run
//      just skips), and rows are claimed ('pending') in one transaction that
//      refuses if any row is already pending.
//   3. Settle leftovers first (resolveUsdcSweepRows): pending/failed rows that
//      carry a trade id are re-checked with Coinbase before anything retries.
//   4. Sum profit_converted_usdc > 0 over rows with status NULL or 'failed'.
//      Do nothing below config.usdc_sweep_min_usd ($1.00; Coinbase's own
//      convert minimum is lower, a $0.25 quote was accepted) or when live
//      free USD does not cover it.
//   5. Claim those rows as 'pending', quote that exact amount USD -> USDC,
//      sanity check it (>= 99.5% back, no fee), save the trade id on the
//      rows, commit, poll briefly.
//   6. COMPLETED -> one transaction: status 'completed', usdc_converted_at.
//      Refused / failed -> status 'failed' (next minute retries, after
//      re-checking the trade). No answer yet -> stays 'pending' with its
//      trade id; the next minute asks Coinbase again (never re-sends).
// Until rows are completed, vw_usdc_sweep_reserve keeps that profit out of
// the buy gates, so it is still in USD when the sweep runs.
// ---------------------------------------------------------------------------
const USDC_SWEEP_LOCK_KEY = 2026100701   // arbitrary, unique to this sweep
const USDC_SWEEP_POLL_TRIES = 5           // x 2 s: keep the minute cycle short
const USDC_SWEEP_POLL_MS = 2000

// Dollars of profit queued for the sweep (0 if the view is missing or the
// kill switch is off). Used to shrink ETF cash; thee_procedure reads the
// same view directly.
async function usdcSweepReserve() {
    try {
        const res = await db.query('SELECT reserve_usd FROM vw_usdc_sweep_reserve')
        const n = Number(res?.rows?.[0]?.reserve_usd)
        return Number.isFinite(n) && n > 0 ? n : 0
    } catch (error) {
        console.log('usdcSweepReserve() ERROR', error?.message || error)
        return 0
    }
}

// Success: mark every row of this attempt completed in ONE statement (one
// transaction), keyed by the trade id so only that attempt's rows change.
async function completeUsdcSweep(client, tradeId, trade) {
    const res = await client.query(
        `UPDATE profit_history
         SET usdc_convert_status = 'completed', usdc_converted_at = NOW()
         WHERE usdc_convert_trade_id = $1 AND usdc_convert_status IN ('pending', 'failed')
         RETURNING profit_converted_usdc`,
        [tradeId]
    )
    const usd = res.rows.reduce((a, r) => a + Number(r.profit_converted_usdc), 0)
    console.log(`USDC sweep OK: $${usd.toFixed(2)} USD -> ${trade?.received || '?'} (${res.rowCount} closes completed, trade ${tradeId})`)
}

// Failure: flag this attempt's rows 'failed' so the next minute retries them
// (after re-checking the trade). ids = the claimed rows; the trade id is kept
// for that re-check when we had one.
async function failUsdcSweep(client, ids, reason) {
    await client.query(
        `UPDATE profit_history SET usdc_convert_status = 'failed'
         WHERE profit_history_id = ANY($1::int[]) AND usdc_convert_status = 'pending'`,
        [ids]
    )
    console.log(`USDC sweep FAILED (${ids.length} closes): ${reason} -- will retry next minute`)
}

// Settle rows left by an earlier run. We hold the advisory lock, so no other
// run is mid-sweep: any 'pending' row here belongs to a run that ended.
//   pending, no trade id      -> commit never sent: back to NULL (retry)
//   pending/failed + trade id -> ask Coinbase about that trade:
//       COMPLETED -> completed;  CANCELED / never committed -> failed;
//       STARTED (still running) -> wait, no new sweep this minute.
// Returns true when it is safe to start a new sweep.
async function resolveUsdcSweepRows(client) {
    await client.query(
        `UPDATE profit_history SET usdc_convert_status = NULL
         WHERE usdc_convert_status = 'pending' AND usdc_convert_trade_id IS NULL`
    )
    const open = await client.query(
        `SELECT usdc_convert_trade_id AS trade_id,
                BOOL_OR(usdc_convert_status = 'pending') AS any_pending,
                ARRAY_AGG(profit_history_id) AS ids
         FROM profit_history
         WHERE usdc_convert_status IN ('pending', 'failed')
         AND usdc_convert_trade_id IS NOT NULL
         GROUP BY usdc_convert_trade_id`
    )
    for (const g of open.rows) {
        const t = await convertUsdc.getConvertTrade(g.trade_id, 'USD', 'USDC')
        if (t.status === 'TRADE_STATUS_COMPLETED') {
            await completeUsdcSweep(client, g.trade_id, t)
        } else if (t.status === 'TRADE_STATUS_STARTED') {
            console.log(`USDC sweep waiting: trade ${g.trade_id} still STARTED`)
            return false
        } else if (g.any_pending) {
            // CANCELED, or a quote that was never committed (UNSPECIFIED /
            // CREATED): nothing moved, so these rows can be retried.
            await failUsdcSweep(client, g.ids, `trade ${g.trade_id} ended ${t.status}${t.cancellationReason ? ` (${t.cancellationReason})` : ''}`)
        }
        // already 'failed' and still not completed: leave as is, it is retried below
    }
    return true
}

async function sweepProfitToUsdc() {
    let client
    let locked = false
    try {
        const cfg = await db.query(
            `SELECT key, value FROM config WHERE key IN ('usdc_sweep_enabled', 'usdc_sweep_min_usd')`
        )
        const conf = Object.fromEntries((cfg?.rows || []).map(r => [r.key, r.value]))
        if ((conf.usdc_sweep_enabled ?? 'true') !== 'true') return
        const minUsd = Math.max(Number(conf.usdc_sweep_min_usd) || 1.00, 0.01)

        // Cheap early exit (no extra connection / API call) when nothing is due.
        const quick = await db.query(
            `SELECT COALESCE(SUM(profit_converted_usdc), 0) AS due,
                    COUNT(*) FILTER (WHERE usdc_convert_status IS NOT NULL) AS open_rows
             FROM profit_history
             WHERE profit_converted_usdc > 0
             AND usdc_convert_status IS DISTINCT FROM 'completed'`
        )
        const q = quick?.rows?.[0] || {}
        if (Number(q.due) < minUsd && Number(q.open_rows) === 0) return

        // Dedicated connection: a session advisory lock has to be taken and
        // released on the same connection. A second overlapping run gets
        // false and simply skips this minute.
        client = await db.connect()
        const lock = await client.query('SELECT pg_try_advisory_lock($1) AS ok', [USDC_SWEEP_LOCK_KEY])
        locked = lock.rows[0].ok === true
        if (!locked) {
            console.log('USDC sweep skipped: another run holds the sweep lock')
            return
        }

        if (!(await resolveUsdcSweepRows(client))) return

        const due = await client.query(
            `SELECT COALESCE(SUM(profit_converted_usdc), 0)::numeric AS amt
             FROM profit_history
             WHERE profit_converted_usdc > 0
             AND (usdc_convert_status IS NULL OR usdc_convert_status = 'failed')`
        )
        // Values are whole cents (TRUNC 2 in thee_procedure).
        const amount = Math.round(Number(due.rows[0].amt) * 100) / 100
        if (!(amount >= minUsd)) return

        const accounts = await ca.gatherBalance()
        const usd = accounts?.find(a => a.currency === 'USD')
        const freeUsd = usd ? parseFloat(usd.available_balance.value) : 0
        if (!(freeUsd >= amount)) {
            console.log(`USDC sweep waiting: $${amount.toFixed(2)} profit due, only $${freeUsd.toFixed(2)} USD free`)
            return
        }

        // Claim the rows in one transaction. The NOT EXISTS refuses the claim
        // if any row is already pending (an in-flight sweep), so even without
        // the advisory lock two runs could never sweep the same profit.
        await client.query('BEGIN')
        let claimed
        try {
            claimed = await client.query(
                `UPDATE profit_history
                 SET usdc_convert_status = 'pending', usdc_convert_trade_id = NULL
                 WHERE profit_converted_usdc > 0
                 AND (usdc_convert_status IS NULL OR usdc_convert_status = 'failed')
                 AND NOT EXISTS (SELECT 1 FROM profit_history x WHERE x.usdc_convert_status = 'pending')
                 RETURNING profit_history_id, profit_converted_usdc`
            )
            await client.query('COMMIT')
        } catch (error) {
            await client.query('ROLLBACK')
            throw error
        }
        const ids = claimed.rows.map(r => r.profit_history_id)
        if (ids.length === 0) return
        // Convert exactly what was claimed (sum in cents, no float drift).
        const claimedUsd = claimed.rows.reduce((a, r) => a + Math.round(Number(r.profit_converted_usdc) * 100), 0) / 100
        console.log(`USDC sweep: converting $${claimedUsd.toFixed(2)} profit from ${ids.length} closes USD -> USDC`)

        // Quote (moves nothing) and sanity check.
        let quote
        try {
            quote = await convertUsdc.createConvertQuote('USD', 'USDC', claimedUsd)
        } catch (error) {
            await failUsdcSweep(client, ids, `quote: ${error.message}`)
            return
        }
        const problems = convertUsdc.checkQuote(quote, 'USD', 'USDC')
        if (problems.length) {
            await failUsdcSweep(client, ids, `quote refused: ${problems.join('; ')}`)
            return
        }

        // Save the trade id on the rows BEFORE sending the commit: if this
        // process dies mid-call, the next run re-checks this trade with
        // Coinbase instead of guessing.
        await client.query(
            `UPDATE profit_history SET usdc_convert_trade_id = $2
             WHERE profit_history_id = ANY($1::int[]) AND usdc_convert_status = 'pending'`,
            [ids, quote.tradeId]
        )
        let status
        try {
            status = await convertUsdc.commitConvertTrade(quote.tradeId, 'USD', 'USDC')
        } catch (error) {
            if (error.status && error.status >= 400 && error.status < 500) {
                // Coinbase answered and rejected it: nothing moved.
                await failUsdcSweep(client, ids, `commit rejected: ${error.message}`)
            } else {
                // No / 5xx answer: outcome unknown, stays pending for next run.
                console.log(`USDC sweep ERROR: commit outcome unknown (${error.message}) -- will re-check trade ${quote.tradeId} next run`)
            }
            return
        }
        for (let i = 0; i < USDC_SWEEP_POLL_TRIES; i++) {
            if (status.status === 'TRADE_STATUS_COMPLETED' || status.status === 'TRADE_STATUS_CANCELED') break
            await new Promise(r => setTimeout(r, USDC_SWEEP_POLL_MS))
            status = await convertUsdc.getConvertTrade(quote.tradeId, 'USD', 'USDC')
        }
        if (status.status === 'TRADE_STATUS_COMPLETED') {
            await completeUsdcSweep(client, quote.tradeId, status)
        } else if (status.status === 'TRADE_STATUS_CANCELED') {
            await failUsdcSweep(client, ids, `Coinbase canceled the trade${status.cancellationReason ? `: ${status.cancellationReason}` : ''}`)
        } else {
            console.log(`USDC sweep: trade ${quote.tradeId} still ${status.status}, will re-check next run`)
        }
    } catch (error) {
        console.log('sweepProfitToUsdc() ERROR', error?.message || error)
    } finally {
        if (client) {
            if (locked) {
                try { await client.query('SELECT pg_advisory_unlock($1)', [USDC_SWEEP_LOCK_KEY]) } catch (e) { /* connection gone = lock gone */ }
            }
            client.release()
        }
    }
}

async function processTransfers () {
    try {
        const pending = await db.executeQuery(`
            SELECT buy_order_id, name, transfer_amount
            FROM position
            WHERE sell_filled_price IS NOT NULL
            AND transfer_amount > 0
            AND transfer_complete = false
        `)
        if (pending.length === 0) return

        const accounts = await ca.gatherBalance()
        let usdId, usdcId
        for (const account of accounts) {
            if (account.currency === 'USD')  usdId  = account.uuid
            if (account.currency === 'USDC') usdcId = account.uuid
            if (usdId && usdcId) break
        }

        if (!usdId || !usdcId) {
            console.log('processTransfers() ERROR: could not find USD or USDC account')
            return
        }

        for (const pos of pending) {
            const result = await ca.createTransfer(pos.transfer_amount, usdId, usdcId)
            if (result !== false) {
                await db.executeQuery(`UPDATE position SET transfer_complete = true WHERE buy_order_id = '${pos.buy_order_id}'`)
                console.log(`Transfer OK: ${pos.name} $${pos.transfer_amount} USD → USDC`)
            } else {
                console.log(`Transfer FAILED: ${pos.name} $${pos.transfer_amount}`)
            }
        }
    } catch (error) {
        console.log('processTransfers() ERROR', error)
    }
}

async function transferProfit (accounts, fills) {
    try {
        //if(fills[0].side == 'SELL'){

            let usdc, usd, sellShares = fills[0].size, sellPrice = fills[0].price, sellFee = fills[0].commission;
            for(i = 0; i < accounts.length; i++){
                if(accounts[i].currency == 'USDC'){
                    usdc = accounts[i].uuid
                } else if(accounts[i].currency == 'USD'){
                    usd = accounts[i].uuid
                }

                if(usdc && usd){
                    break;
                }
            }

            if(!usdc && usd){
                //transfer a penny
                let response = await ca.createTransfer('USD', 'USDC', 0.01, usd, usdc)
                console.log("Transfer Success?", response)
            }

            //console.log(usd, usdc)
            // for(i=0;i<fills.length;i++){
            //     let element = fills[i];

            // }
          
        //}
    } catch (error) {
        console.log('transferProfit()', error)
    }
}