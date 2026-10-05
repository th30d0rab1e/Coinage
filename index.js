var ca = require('./modules/coinbaseAuth.js')
var db = require('./modules/database.js')
const crypto = require('crypto')
var equity = require('./modules/equityAuth.js')
var etfPlan = require('./modules/etfPlan.js')
// IEX snapshots → stock.price for enabled ETF tickers. Secrets load from
// the Alpaca bot config outside this repo (see alpacaMarketData.js).
var alpacaMd = require('./modules/alpacaMarketData.js')
// Set each run before thee_procedure. False means the equity session is
// closed: do not buy ETFs, and do not reserve USD. When it is true,
// etfAttemptsThisRun is the dip-eligible attempts this minute will send,
// and config.etf_usd_reserve is their quote total so thee_procedure cannot
// spend that Default USD on a new crypto plan. Crypto still places after
// those attempts, in processBuyOrders. Nothing is transferred.
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

        await Promise.all([pnc, pnb, pnf, poo, ppd]);

        // Equity session before the buy pass. A closed session (weekend full
        // close, holiday, or a failed check) leaves the flag false: no ETF
        // order. Crypto plans do not read this flag. This does not place an order.
        await refreshEquitySession();

        // Pull Alpaca IEX prices for every enabled etf row into stock.price
        // (bare ticker). Runs whether or not the equity session is open so
        // the table stays fresh; dip decisions still gate on session below.
        // Cron starts a fresh node each minute, so no bot restart is needed.
        await syncEtfStockPrices();

        // Reserve before thee_procedure inserts crypto plans. The dollars
        // are only the ETF attempts this run still needs (session open,
        // dip rules passed, not already filled, and Default cash can cover
        // them). A closed session writes 0. Crypto placement is later.
        await reserveEtfCash();

        //call thee procedure (now sees fresh bulk_open_orders, bulk_fills, bulk_currency)
        await db.executeQuery('Call thee_procedure();');
        //surface anything thee_procedure just logged to unmatched_fills so the
        //30-min health check (greps outputLog.txt for ERROR/FAILED) catches it
        await checkUnmatchedFills();
        //call aggregation
        await db.executeQuery('CALL aggregate();')

        //process historical data
        await processHistoricalPrices();

        //cancel buy orders 
        //await processBuyOrdersOutOfRange(pnfR)

        // Read-only book snapshots first so buy gates can use fresh imbalance
        // (and so thee_procedure's next cycle can ORDER BY it). Still no
        // place/cancel inside the logger itself.
        await processBookSnapshots();

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


    } catch (error) {
        console.log("main", error)
    } finally {
        //await db.end();
        console.log(`End Program ${new Date().toLocaleString()}`)
        console.log('<-------------------------------------------------------------->');
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
        const balResult = await db.executeQuery(`
            SELECT
                MAX(CASE WHEN name = 'USD' THEN available ELSE 0 END) AS usd,
                ROUND(SUM(CASE WHEN name NOT IN ('USD', 'USDC') THEN value ELSE 0 END)::numeric, 2) AS equity
            FROM vw_balance
        `)
        const usd = parseFloat(balResult[0]?.usd ?? 0).toFixed(2);
        const equity = balResult[0]?.equity ?? 0;
        console.log(`Balance: ${results.length} accounts | USD: $${usd} | Position Equity: $${equity}`)
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

async function recordEtfAttempt(row) {
    await db.query(
        `INSERT INTO etf_buy
            (ticker, chicago_date, quote_usd, filled, closed_session, coinbase_order_id, client_order_id, error_message, dip_price, fill_price)
         VALUES ($1, $2::date, $3, $4, $5, $6, $7, $8, $9, $10)`,
        [
            row.ticker,
            row.chicagoDate,
            row.quoteUsd,
            row.filled,
            row.closedSession,
            row.coinbaseOrderId || null,
            row.clientOrderId || null,
            row.errorMessage || null,
            // dip_price is the live price the rule compared, or null when
            // the rule did not need one. fill_price is the execution price.
            row.dipPrice == null ? null : row.dipPrice,
            row.fillPrice == null ? null : row.fillPrice,
        ]
    )
}

// Upsert stock.price from Alpaca IEX for every enabled etf.ticker.
// Failures log and leave prior stock.price alone; dip path may then
// still miss a price and skip rather than invent one.
async function syncEtfStockPrices() {
    try {
        await alpacaMd.syncEnabledEtfStockPrices(db)
    } catch (error) {
        console.log('syncEtfStockPrices() ERROR', error?.message || error)
    }
}

// Build this minute's ETF attempts and write config.etf_usd_reserve
// before thee_procedure. pause_buys is not read here. A failure reserves
// nothing and buys nothing, so a broken price check cannot both block
// crypto and send an ETF order.
async function reserveEtfCash() {
    etfAttemptsThisRun = []
    if (!equitySessionOpen) {
        await setEtfUsdReserve(0)
        console.log('ETF reserve $0: equity session closed')
        return
    }
    try {
        const plan = await buildEtfPlan()
        etfAttemptsThisRun = plan.attempts
        const reserved = await setEtfUsdReserve(plan.reserve)
        const names = plan.attempts.map((row) => row.ticker).join(', ')
        console.log(`ETF reserve $${reserved.toFixed(2)} for ${names || 'none'}`)
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

// Match a portfolio equity row to an etf row. Coinbase identifies the
// position by cbrn, which we have not seen populated yet (no shares held).
// Accept the ticker, the product id, or a cbrn whose last token is the ticker.
function positionFor(positions, row) {
    const ticker = String(row.ticker || '').toUpperCase()
    const productId = String(row.product_id || '')
    return (positions || []).find((pos) => {
        const id = String(pos.cbrn || '')
        if (!id) return false
        if (id === row.ticker || id === productId) return true
        const token = id.toUpperCase().split(/[^A-Z0-9.]+/).filter(Boolean).pop()
        return token === ticker
    }) || null
}

// True only when an etf_buy row may still be working. A zero fill
// ("not filled (status CANCELLED/unknown)") is done and may be retried.
// OPEN/PENDING/QUEUED may still fill. No status word and a non-empty
// error (a reject such as INSUFFICIENT_FUND) is done. An order id with
// no error at all is ambiguous, so it stays pending.
function mightStillFill(errorMessage) {
    const text = String(errorMessage || '')
    const match = text.match(/status\s+([A-Za-z0-9_]+)/)
    if (match) {
        return ['OPEN', 'PENDING', 'QUEUED', 'UNSETTLED'].includes(match[1].toUpperCase())
    }
    return text.trim() === ''
}

// fills is the source of truth for whether an ETF order actually filled.
// readFill often still sees OPEN right after place; processNewFills lands
// the trade later. Reconcile today's etf_buy from fills before dip planning.
async function reconcileEtfBuysFromFills(chicagoDate) {
    const result = await db.query(
        `UPDATE etf_buy AS e
         SET filled = true,
             fill_price = f.avg_price,
             error_message = NULL
         FROM (
             SELECT order_id,
                    AVG(price)::numeric AS avg_price
             FROM fills
             WHERE order_id IS NOT NULL
               AND price IS NOT NULL
             GROUP BY order_id
         ) AS f
         WHERE e.coinbase_order_id = f.order_id
           AND e.chicago_date = $1::date
           AND (
               e.filled IS NOT TRUE
               OR e.fill_price IS NULL
               OR e.error_message IS NOT NULL
           )
         RETURNING e.etf_buy_id, e.ticker, e.fill_price`,
        [chicagoDate]
    )
    for (const row of result?.rows || []) {
        console.log(`ETF reconcile from fills: ${row.ticker} fill_price=${row.fill_price}`)
    }
    return (result?.rows || []).length
}

// Avg fill price from fills for one Coinbase order id, or null.
async function fillPriceFromFills(orderId) {
    if (!orderId) return null
    const result = await db.query(
        `SELECT AVG(price)::numeric AS avg_price
         FROM fills
         WHERE order_id = $1 AND price IS NOT NULL`,
        [orderId]
    )
    const avg = result?.rows?.[0]?.avg_price
    return avg == null ? null : Number(avg)
}

// Still-open today's etf_buy with no fills row yet: ask Coinbase once.
// Fills already covered by reconcileEtfBuysFromFills are skipped.
async function probeOpenEtfBuys(chicagoDate) {
    const open = await db.query(
        `SELECT e.etf_buy_id, e.ticker, e.coinbase_order_id, e.error_message
         FROM etf_buy e
         WHERE e.chicago_date = $1::date
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
                 error_message = NULL
             WHERE etf_buy_id = $1`,
            [row.etf_buy_id, fillPrice]
        )
        updated += 1
        console.log(`ETF probe readFill: ${row.ticker} fill_price=${fillPrice}`)
    }
    return updated
}

async function buildEtfPlan() {
    const today = chicagoToday()
    const notes = []
    // Sync etf_buy from fills (and probe any still-open leftovers) before
    // pending / boughtToday / lastFillPrice so dips are not blocked by a
    // stale "status OPEN" row whose fill already landed.
    await reconcileEtfBuysFromFills(today)
    await probeOpenEtfBuys(today)
    const listed = await db.query(
        `SELECT ticker, product_id, quote_usd, is_special
         FROM etf
         WHERE enabled
         ORDER BY ticker`
    )
    const rows = listed?.rows || []
    const book = await equity.equitySnapshot()
    if (!book.ok) {
        notes.push(`ETF plan skipped: holdings unreadable (${book.reason})`)
        return { attempts: [], reserve: 0, notes }
    }
    const openOrders = await db.query(
        `SELECT DISTINCT product_id
         FROM bulk_open_orders
         WHERE side = 'BUY' AND status = 'OPEN' AND product_id IS NOT NULL`
    )
    const openProducts = new Set((openOrders?.rows || []).map((row) => row.product_id))
    const latest = await db.query(
        `SELECT DISTINCT ON (ticker)
                ticker, filled, closed_session, coinbase_order_id, error_message
         FROM etf_buy
         ORDER BY ticker, created_at DESC, etf_buy_id DESC`
    )
    const pendingTickers = new Set()
    for (const row of latest?.rows || []) {
        // A zero fill or a closed-market reject is terminal: filled stays
        // false so it does not count as today's buy, and it may be retried.
        // An order id that is still OPEN, or whose status was never shown
        // to be done, might still fill, so it blocks another send.
        if (row.filled || row.closed_session || !row.coinbase_order_id) continue
        if (!mightStillFill(row.error_message)) continue
        pendingTickers.add(row.ticker)
    }
    const bought = await db.query(
        `SELECT ticker
         FROM etf_buy
         WHERE chicago_date = $1::date AND filled`,
        [today]
    )
    const boughtToday = new Set((bought?.rows || []).map((row) => row.ticker))
    const lastFills = await db.query(
        `SELECT DISTINCT ON (ticker) ticker, fill_price
         FROM etf_buy
         WHERE filled AND fill_price IS NOT NULL
         ORDER BY ticker, created_at DESC, etf_buy_id DESC`
    )
    const lastFillByTicker = new Map((lastFills?.rows || []).map((row) => [row.ticker, Number(row.fill_price)]))
    const info = {}
    for (const row of rows) {
        const held = positionFor(book.positions, row)
        const sharesKnown = !held || held.shares != null
        info[row.ticker] = {
            boughtToday: boughtToday.has(row.ticker),
            pending: openProducts.has(row.product_id) || pendingTickers.has(row.ticker),
            sharesKnown,
            shares: held && held.shares != null ? held.shares : 0,
            averageEntry: held ? held.averageEntry : null,
            unrealizedPnl: held ? held.unrealizedPnl : null,
            lastFillPrice: lastFillByTicker.get(row.ticker) || null,
            price: null,
        }
    }
    const needPrice = rows.filter((row) => {
        const state = info[row.ticker]
        if (!state || state.pending || !state.sharesKnown) return false
        // First $1 with no shares does not need a price. A held position
        // or a later buy the same day does.
        return state.boughtToday || Number(state.shares) > 0
    })
    // Coinbase product price/mid/bid/ask first. When those are blank
    // (common on these ETF products), use stock.price written by the
    // Alpaca IEX sync earlier this run. Session open / not-halted is
    // already required before we get here via equitySessionOpen.
    await Promise.all(needPrice.map(async (row) => {
        const quote = await equity.equityPrice(row.product_id)
        if (quote.ok) info[row.ticker].price = quote.price
        else notes.push(`ETF Coinbase price blank ${row.ticker}: ${quote.reason}`)
    }))
    const stillNeed = needPrice.filter((row) => !(Number(info[row.ticker]?.price) > 0))
    if (stillNeed.length > 0) {
        const fromStock = await alpacaMd.readStockPrices(db, stillNeed.map((r) => r.ticker))
        for (const row of stillNeed) {
            const p = fromStock.get(String(row.ticker).toUpperCase())
            if (Number(p) > 0) {
                info[row.ticker].price = p
                notes.push(`ETF price from stock (Alpaca IEX) ${row.ticker}: ${p}`)
            } else {
                notes.push(`ETF price unavailable ${row.ticker}: Coinbase blank and no stock.price`)
            }
        }
    }
    const planned = etfPlan.planAttempts(rows, info, etfPlan.inCatchUpWindow())
    notes.push(...planned.notes)
    const funded = etfPlan.fundAttempts(planned.chosen, book.available)
    notes.push(...funded.notes)
    return { attempts: funded.attempts, reserve: funded.reserve, notes }
}

// Send the attempts reserved at the start of this run. Does not re-pick
// tickers: a dip that appears only after thee_procedure would spend cash
// the crypto plans were already allowed to use. Does not re-reserve.
// A closed-market reject or a zero fill stays filled=false. A failed
// fill GET is still recorded filled=true so the $1 is not sent twice.
async function processEquityEtfBuys() {
    if (!equitySessionOpen) return
    if (etfAttemptsThisRun.length === 0) {
        console.log('ETF buys: nothing reserved this run')
        return
    }
    let cash = 0
    try {
        const bal = await equity.defaultUsdAvailable()
        if (!bal.ok) {
            console.log(`ETF buys skipped: Default USD unreadable (${bal.reason})`)
            return
        }
        cash = bal.available
        console.log(`ETF Default USD available: $${cash.toFixed(2)}`)
        const today = chicagoToday()
        for (const row of etfAttemptsThisRun) {
            if (!equitySessionOpen) break
            const quote = Number(row.quote_usd)
            if (!(cash >= quote) || !(quote > 0)) {
                console.log(`ETF buy skipped: ${row.ticker} needs $${quote.toFixed(2)} Default USD, have $${cash.toFixed(2)}`)
                continue
            }
            console.log(`ETF buy attempt: ${row.ticker} $${quote.toFixed(2)} (${row.reason})`)
            const clientOrderId = crypto.randomUUID()
            const response = await equity.createMarketBuy(row.product_id, quote, clientOrderId)
            if (equity.isClosedMarket(response)) {
                const message = response?.error_response?.message || 'equity session closed'
                await recordEtfAttempt({
                    ticker: row.ticker,
                    chicagoDate: today,
                    quoteUsd: quote,
                    filled: false,
                    closedSession: true,
                    clientOrderId,
                    errorMessage: message,
                    dipPrice: row.dipPrice,
                })
                equitySessionOpen = false
                await db.query(
                    `UPDATE config SET value = 'false' WHERE key = 'equity_session_open'`
                )
                console.log(`ETF session closed on ${row.ticker} (${message}); not today's buy`)
                break
            }
            if (response?.success === true) {
                const orderId = response.success_response?.order_id
                // Prefer fills when a trade already landed; otherwise readFill.
                // A later minute's reconcileEtfBuysFromFills repairs OPEN rows.
                const fromFills = await fillPriceFromFills(orderId)
                let filled = false
                let fillPrice = null
                let fillStatus = null
                if (fromFills != null && Number.isFinite(fromFills)) {
                    filled = true
                    fillPrice = fromFills
                } else {
                    const fill = await equity.readFill(orderId)
                    const closedFill = equity.isClosedMarket(fill.raw || fill)
                    if (closedFill) {
                        await recordEtfAttempt({
                            ticker: row.ticker,
                            chicagoDate: today,
                            quoteUsd: quote,
                            filled: false,
                            closedSession: true,
                            coinbaseOrderId: orderId,
                            clientOrderId,
                            errorMessage: 'order viewing is not available',
                            dipPrice: row.dipPrice,
                        })
                        equitySessionOpen = false
                        await db.query(
                            `UPDATE config SET value = 'false' WHERE key = 'equity_session_open'`
                        )
                        console.log(`ETF session closed after accept ${row.ticker}; not today's buy`)
                        break
                    }
                    filled = fill.unknown || fill.filledSize > 0 || fill.filledQuote > 0
                    fillPrice = fill.filledSize > 0 && fill.filledQuote > 0
                        ? fill.filledQuote / fill.filledSize
                        : null
                    fillStatus = fill.status
                }
                await recordEtfAttempt({
                    ticker: row.ticker,
                    chicagoDate: today,
                    quoteUsd: quote,
                    filled,
                    closedSession: false,
                    coinbaseOrderId: orderId,
                    clientOrderId,
                    errorMessage: filled ? null : `not filled (status ${fillStatus || 'unknown'})`,
                    dipPrice: row.dipPrice,
                    fillPrice: filled ? fillPrice : null,
                })
                if (filled) {
                    cash -= quote
                    console.log(`ETF buy filled: ${row.ticker} $${quote.toFixed(2)}`)
                } else {
                    console.log(`ETF buy not filled, will retry: ${row.ticker} status ${fillStatus}`)
                }
            } else {
                const message = response?.error_response?.message || 'unknown'
                await recordEtfAttempt({
                    ticker: row.ticker,
                    chicagoDate: today,
                    quoteUsd: quote,
                    filled: false,
                    closedSession: false,
                    clientOrderId,
                    errorMessage: message,
                    dipPrice: row.dipPrice,
                })
                console.log(`ETF buy FAILED: ${row.ticker} ${message}`)
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
            -- 2026-09-25: never try to place on a delisted / trading-disabled coin
            AND s.trading_disabled IS NOT TRUE
            -- 2026-09-25: cooldown -- a row processFarBuyCashRelease just cancelled
            -- to free cash is not re-placed for 30 min, so the freed cash actually
            -- reaches the higher-priority row it was released for (previously the
            -- same ETC/TRB/ATOM orders were re-placed the very next minute).
            AND (p.buy_released_at IS NULL OR p.buy_released_at < NOW() - INTERVAL '30 minutes')
            -- 2026-09-27: only place a buy while price is below its trigger. A
            -- bounce-buy (stop) must sit above current price or Coinbase rejects
            -- it. When thee_procedure's add-on cap puts a trigger below the
            -- current price, the row waits here until price drops under it
            -- instead of being rejected every minute.
            AND s.price < p.buy_stop_price
            ORDER BY s.priority DESC NULLS LAST
        `)
        console.log(`Buy Orders to Process: ${orders.length}`);

        // 2026-09-27 affordability gate: the $1 check above and the cash-backlog
        // gate in thee_procedure only stop NEW planned rows from being inserted;
        // nothing checked whether each already-planned row fits in free cash, so
        // e.g. MON 1003 (234 @ ~$6.41) was sent every minute and Coinbase rejected
        // it INSUFFICIENT_FUND (~90 log lines/hour). Compare each row's cost plus
        // fee pad against AVAILABLE USD (available_balance excludes cash already
        // held by other open buy orders) and skip it this cycle if it doesn't fit.
        // The row is left as-is (not deleted, no error_message) so it places once
        // cash frees up, or expires via thee_procedure's 24h TTL. cashLeft is
        // decremented after each successful create so later rows in the same run
        // don't count the same dollars twice.
        const BUY_FEE_PAD = 1.012   // same ~1.2% taker-fee pad as processFarBuyCashRelease
        let cashLeft = available

        for (i = 0; i < orders.length; i++) {
            const element = orders[i];
            const cost = Number(element.buy_price) * Number(element.shares) * BUY_FEE_PAD
            if (cost > cashLeft) {
                console.log(`Skip buy ${element.name}: cost $${cost.toFixed(2)} > available $${cashLeft.toFixed(2)}`)
                continue
            }
            // Live L2 gate before create — skip this cycle (leave row pending,
            // no error_message) so a bad book can clear without blocking forever.
            try {
                const book = await ca.getProductBook(element.name, 20)
                const metrics = computeBookMetrics(book)
                const clipNotional = Number(element.buy_price) * Number(element.shares)
                if (metrics) {
                    if (metrics.imbalance < BOOK_SKIP_IMBALANCE) {
                        console.log(`Buy Order deferred (ask-heavy book): ${element.name} | imbalance: ${metrics.imbalance.toFixed(3)}`)
                        continue
                    }
                    if (metrics.spreadPct > BOOK_MAX_SPREAD_PCT) {
                        console.log(`Buy Order deferred (wide spread): ${element.name} | spread: ${metrics.spreadPct.toFixed(3)}%`)
                        continue
                    }
                    if (clipNotional > 0 && metrics.nearAskUsd < clipNotional * BOOK_MIN_ASK_NOTIONAL_MULT) {
                        console.log(`Buy Order deferred (thin ask): ${element.name} | nearAskUsd: ${metrics.nearAskUsd.toFixed(2)} | clip: ${clipNotional.toFixed(2)}`)
                        continue
                    }
                }
            } catch (bookErr) {
                console.log(`Buy Order book-check ERROR ${element.name}`, bookErr?.message || bookErr)
                // Fail open: still attempt place if the book call blips.
            }
            // Coinbase treats client_order_id as an idempotency key: reusing one
            // already used for a since-cancelled order returns that SAME dead
            // order back with success: true, not a genuinely new one. Confirmed
            // live 2026-09-05 -- this is why nulling buy_coinbase_order_id on a
            // failed/cancelled position and letting it retry kept resurrecting
            // the exact same dead order every time. processSellOrders() already
            // generates a fresh id per attempt; this didn't.
            const newOrderId = crypto.randomUUID()
            let response = await ca.createStopLimitOrder('buy', element.buy_price, element.shares, element.name, element.buy_stop_price, newOrderId);
            if(response?.success == true) {
                // buy_placed_at (2026-09-25): order age, so far-release won't cancel a fresh order
                await db.executeQuery(`UPDATE position SET buy_order_id = '${newOrderId}', buy_coinbase_order_id = '${response.success_response.order_id}', buy_placed_at = NOW() WHERE buy_order_id = '${element.buy_order_id}'`)
                console.log(`Buy Order Created: ${element.name} | shares: ${element.shares} | price: ${element.buy_price}`)
                // this order's hold now comes out of free USD for the rest of the loop
                cashLeft -= cost
            } else {
                const errMsg = (response?.error_response?.message || 'unknown').replace(/'/g, "''")
                await db.executeQuery(`UPDATE position SET error_message = '${errMsg}' WHERE buy_order_id = '${element.buy_order_id}'`)
                console.log(`Buy Order FAILED: ${element.name}`, response)
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
            -- latest L2 snapshot (processBookSnapshots runs just before this)
            LEFT JOIN LATERAL (
                SELECT bs.imbalance, bs.spread_pct, bs.near_ask_usd
                FROM book_snapshot bs
                WHERE bs.name = p.name AND bs.date_created > NOW() - INTERVAL '10 minutes'
                ORDER BY bs.date_created DESC
                LIMIT 1
            ) book ON TRUE
            WHERE p.buy_coinbase_order_id IS NULL
            AND p.buy_filled_price IS NULL
            AND s.trading_disabled IS NOT TRUE
            AND (p.error_message IS NULL OR p.error_message NOT IN ('Invalid product_id'))
            AND (p.buy_released_at IS NULL OR p.buy_released_at < NOW() - INTERVAL '30 minutes')
            -- 2026-09-27: same price gate as processBuyOrders -- a capped add-on
            -- buy waiting for price to drop is not a real beneficiary yet.
            AND s.price < p.buy_stop_price
            -- same book gates processBuyOrders applies before placing; a row it
            -- would just defer (e.g. DEXT's chronic wide spread) is not a real
            -- beneficiary -- releasing cash for it would hand the cash to some
            -- lower-priority row instead. No snapshot = allow (processBuyOrders
            -- also fails open).
            AND (book.imbalance  IS NULL OR book.imbalance >= ${BOOK_SKIP_IMBALANCE})
            AND (book.spread_pct IS NULL OR book.spread_pct <= ${BOOK_MAX_SPREAD_PCT})
            AND (book.near_ask_usd IS NULL OR book.near_ask_usd >= (p.shares * p.buy_price) * ${BOOK_MIN_ASK_NOTIONAL_MULT})
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
                // Leave error_message NULL so processBuyOrders can heal once cash returns.
                // buy_released_at (2026-09-25) starts the 30-min re-place cooldown.
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

// Buy gates from live L2 (same thresholds as offered in chat):
// - Skip place when imbalance < -0.4 (ask-heavy)
// - Skip place when spread is wide OR near ask notional is thin vs this clip
// Prefer (+0.2) is handled in thee_procedure ORDER BY, not here.
const BOOK_SKIP_IMBALANCE = -0.4
const BOOK_MAX_SPREAD_PCT = 0.75
const BOOK_MIN_ASK_NOTIONAL_MULT = 5 // near_ask_usd must be >= 5x clip notional

// Read-only order-book logger + food for next-cycle SQL prefer.
// Logs open fills AND pending buys. No place/cancel here.
async function processBookSnapshots () {
    try {
        const rows = await db.executeQuery(`
            SELECT DISTINCT ON (p.name) p.name, p.stock_id
            FROM position p
            WHERE p.buy_order_id IS NOT NULL
            AND p.sell_filled_price IS NULL
            ORDER BY p.name
        `)
        if (!rows?.length) {
            console.log('Book snapshots: 0 products')
            return
        }
        const MAX_PER_CYCLE = 40
        const targets = rows.slice(0, MAX_PER_CYCLE)
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
        console.log(`Book snapshots: ${logged}/${targets.length} logged (cap ${MAX_PER_CYCLE})`)
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