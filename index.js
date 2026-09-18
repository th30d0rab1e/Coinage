var ca = require('./modules/coinbaseAuth.js')
var db = require('./modules/database.js')
const crypto = require('crypto')
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

async function processBuyOrders () {
    try {
        // bulk_currency is already truncated by the time this runs (thee_procedure()
        // truncates it at the end, and that runs before this), so check live rather
        // than via vw_balance. If there isn't at least $1 free, don't even look at
        // the pending-buy backlog -- every one of them would just fail anyway.
        //
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
            ORDER BY s.priority DESC NULLS LAST
        `)
        console.log(`Buy Orders to Process: ${orders.length}`);

        for (i = 0; i < orders.length; i++) {
            const element = orders[i];
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
                await db.executeQuery(`UPDATE position SET buy_order_id = '${newOrderId}', buy_coinbase_order_id = '${response.success_response.order_id}' WHERE buy_order_id = '${element.buy_order_id}'`)
                console.log(`Buy Order Created: ${element.name} | shares: ${element.shares} | price: ${element.buy_price}`)
            } else {
                const errMsg = (response?.error_response?.message || 'unknown').replace(/'/g, "''")
                await db.executeQuery(`UPDATE position SET error_message = '${errMsg}' WHERE buy_order_id = '${element.buy_order_id}'`)
                console.log(`Buy Order FAILED: ${element.name}`, response)
            }
        }

    } catch (error) {
        console.log("processBuyOrders() ERROR", error)
    }
}

async function processSellOrders () {
    try {
        const orders = await db.executeQuery(`SELECT p.*, s.price AS current_price, s.price_rounding FROM position p JOIN stock s ON p.stock_id = s.stock_id WHERE p.buy_filled_price IS NOT NULL AND p.sell_coinbase_order_id IS NULL AND p.sell_price IS NOT NULL;`)
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
        const orders = await db.executeQuery(`
            SELECT p.buy_order_id, p.name, p.buy_coinbase_order_id, p.buy_stop_price, s.price AS market,
                (p.buy_stop_price::numeric - s.price::numeric) / NULLIF(s.price::numeric, 0) AS gap_pct
            FROM position p
            JOIN stock s ON s.stock_id = p.stock_id
            WHERE p.buy_coinbase_order_id IS NOT NULL
            AND p.buy_filled_price IS NULL
            AND p.buy_stop_price > s.price
            ORDER BY gap_pct DESC NULLS LAST
            LIMIT ${FAR_BUY_CANCEL_LIMIT}
        `)
        if (!orders.length) {
            console.log(`processFarBuyCashRelease() skipped: only $${available.toFixed(2)} free but no far buy stops`)
            return
        }
        console.log(`processFarBuyCashRelease(): $${available.toFixed(2)} free — canceling ${orders.length} farthest buy stop(s)`)
        for (let i = 0; i < orders.length; i++) {
            const element = orders[i]
            const cancelResponse = await ca.cancelOrder(element.buy_coinbase_order_id)
            if (cancelResponse == true) {
                // Leave error_message NULL so processBuyOrders can heal once cash returns.
                await db.executeQuery(`UPDATE position SET buy_coinbase_order_id = NULL, error_message = NULL WHERE buy_order_id = '${element.buy_order_id}'`)
                console.log(`Far Buy Cancelled: ${element.name} | gap: ${(Number(element.gap_pct)*100).toFixed(1)}% | stop: ${element.buy_stop_price} | mkt: ${element.market}`)
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
                        await db.executeQuery(`UPDATE position SET buy_order_id = '${newOrderId}', buy_coinbase_order_id = '${reMakeResponse.success_response.order_id}', buy_stop_price = ${element.new_stop_price}, buy_price = ${element.order_price}, buy_counter = buy_counter + 1, last_remade_at = NOW(), error_message = NULL WHERE buy_order_id = '${element.buy_order_id}'`)
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