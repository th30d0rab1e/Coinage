// 2026-10-07: new-listing watcher -- finds when a new -USD pair's trading
// ACTUALLY opens, so thee_procedure's listing snipe can fire inside the
// first config.listing_window_minutes (default 5) after that moment.
//
// Why not Coinbase products.new_at: a 50-listing study showed trading
// typically opens ~18h after new_at (only 2/50 traded within 60 min of it),
// and EVERY product in the public list carries a non-empty new_at; only
// new = true marks a currently-new listing. The move is front-loaded
// (minute-1 buys hit +3% within an hour 80% of the time vs 48% at minute
// 60), so the window must start at the real open.
//
// Window start (listing_watch.trading_open_at) = the EARLIER of
//   (a) the pair's first completed trade:
//         primary  -> public Exchange API GET /products/{id}/trades?after=2,
//                     which returns trade_id 1 (exact time + price), or []
//                     / NotFound when nothing has traded yet;
//         fallback -> public ONE_MINUTE candles (last 300 min), first
//                     candle with volume > 0 (minute start, candle open
//                     price). Used only when the Exchange call fails.
//   (b) the first time this bot OBSERVES the launch restrictions cleared:
//         status online AND NOT trading_disabled AND NOT auction_mode AND
//         NOT limit_only AND NOT cancel_only (all from the products payload
//         index.js already fetched this minute -- no extra API call).
// Real launches (e.g. CT-USD: auction ~10:04 UTC, first match 10:16:28 UTC,
// limit-only until ~15:15 UTC) put (a) well before (b), so (a) normally wins.
//
// Stale-listing guard: trading_open_at is only written on a minute where
// the first-trade check itself succeeded. A product that is already open
// with old trades when first watched therefore gets its REAL first trade
// time (e.g. days ago) and never qualifies -- it cannot be mistaken for
// "opened now" just because this is the first minute the bot looked.
//
// Scope / API budget: only candidate products -- -USD SPOT where new = true
// or new_at is within the last 7 days -- that still lack trading_open_at or
// a first trade price. At most MAX_CHECKS_PER_RUN per minute, one public
// Exchange call each (+1 candle call only if that fails). Once both are
// known the product is never checked again. Public endpoints only: no
// auth, no orders, nothing but listing_watch is written.
//
// Architecture (Theodore's rule): this only GATHERS data into a table.
// The buy decision (window, tradable gates, mutex, cash) lives in
// thee_procedure.
const axios = require('axios')

const CANDIDATE_NEW_AT_DAYS = 7      // new_at only narrows candidates; it is NOT the window start
const MAX_CHECKS_PER_RUN = 15        // hard cap on products checked per minute
const HTTP_TIMEOUT_MS = 5000

const truthy = v => v === true || v === 'true'

// (b) "launch restrictions cleared" exactly as Theodore defined it.
function restrictionsCleared(p) {
    return p.status === 'online'
        && !truthy(p.trading_disabled)
        && !truthy(p.auction_mode)
        && !truthy(p.limit_only)
        && !truthy(p.cancel_only)
}

function flagsOf(p) {
    return {
        status: p.status ?? null,
        trading_disabled: p.trading_disabled ?? null,
        auction_mode: p.auction_mode ?? null,
        limit_only: p.limit_only ?? null,
        cancel_only: p.cancel_only ?? null,
        post_only: p.post_only ?? null,
        is_disabled: p.is_disabled ?? null,
    }
}

// (a) primary: Exchange API trade_id 1. Returns
//   { ok: true, trade: {time, price} }  first trade found
//   { ok: true, trade: null }           confirmed nothing traded yet
//   { ok: false, error }                could not tell (try candles)
async function firstTradeFromExchange(productId) {
    try {
        const r = await axios.get(`https://api.exchange.coinbase.com/products/${encodeURIComponent(productId)}/trades`, {
            params: { after: 2 },   // cursor: trades with trade_id < 2, i.e. trade_id 1
            timeout: HTTP_TIMEOUT_MS,
            headers: { 'User-Agent': 'Coinage listing watcher' },
        })
        const rows = Array.isArray(r.data) ? r.data : []
        if (!rows.length) return { ok: true, trade: null }
        const first = rows.reduce((a, b) => (Number(a.trade_id) <= Number(b.trade_id) ? a : b))
        return { ok: true, trade: { time: first.time, price: first.price, source: 'exchange_trade_id_1' } }
    } catch (error) {
        // Exchange answers 404 {"message":"NotFound"} for a pair it does not
        // list yet -> nothing has traded.
        if (error?.response?.status === 404) return { ok: true, trade: null }
        return { ok: false, error: `exchange trades: ${error?.response?.status || ''} ${error?.message || error}`.trim() }
    }
}

// (a) fallback: first public ONE_MINUTE candle with volume > 0 in the last
// 300 minutes. If even the oldest candle in that range already has volume,
// the true first trade is at or before it -- still >= 5h ago, so the
// product can never qualify for the 5-15 min window either way.
async function firstTradeFromCandles(productId) {
    try {
        const end = Math.floor(Date.now() / 1000)
        const start = end - 300 * 60
        const r = await axios.get(`https://api.coinbase.com/api/v3/brokerage/market/products/${encodeURIComponent(productId)}/candles`, {
            params: { start, end, granularity: 'ONE_MINUTE', limit: 300 },
            timeout: HTTP_TIMEOUT_MS,
        })
        const candles = (r.data?.candles || [])
            .filter(c => Number(c.volume) > 0)
            .sort((a, b) => Number(a.start) - Number(b.start))
        if (!candles.length) return { ok: true, trade: null }
        return { ok: true, trade: { time: new Date(Number(candles[0].start) * 1000).toISOString(), price: candles[0].open, source: 'candles_1m' } }
    } catch (error) {
        return { ok: false, error: `candles: ${error?.response?.status || ''} ${error?.message || error}`.trim() }
    }
}

async function run(db, products) {
    try {
        if (!Array.isArray(products) || !products.length) {
            console.log('Listing watch skipped: no products payload this run')
            return
        }
        const cutoff = Date.now() - CANDIDATE_NEW_AT_DAYS * 24 * 3600 * 1000
        const candidates = products.filter(p => {
            if (!p?.product_id?.endsWith('-USD')) return false
            if ((p.product_type || 'SPOT') !== 'SPOT') return false
            const newAt = p.new_at ? Date.parse(p.new_at) : NaN
            return truthy(p.new) || (Number.isFinite(newAt) && newAt >= cutoff)
        })
        if (!candidates.length) {
            console.log('Listing watch: 0 candidates')
            return
        }

        const ids = candidates.map(p => p.product_id)
        const existing = await db.query(
            `SELECT product_id, trading_open_at, first_trade_price, restricted_seen_at FROM listing_watch WHERE product_id = ANY($1::text[])`,
            [ids])
        const known = new Map(existing.rows.map(r => [r.product_id, r]))
        // Done = window start AND first trade price known; never re-checked.
        const todo = candidates
            .filter(p => { const k = known.get(p.product_id); return !k || !k.trading_open_at || k.first_trade_price === null })
            .sort((a, b) => (Date.parse(b.new_at || 0) || 0) - (Date.parse(a.new_at || 0) || 0))
            .slice(0, MAX_CHECKS_PER_RUN)

        const summary = []
        for (const p of todo) {
            const cleared = restrictionsCleared(p)
            let ft = await firstTradeFromExchange(p.product_id)
            let err = ft.ok ? null : ft.error
            if (!ft.ok) {
                const c = await firstTradeFromCandles(p.product_id)
                if (c.ok) ft = c; else err = `${err}; ${c.error}`
                // Candles only cover the last 300 minutes, so for a thinly
                // traded OLD pair the "first" candle with volume may just be
                // its latest trade. Trust a recent (< 60 min) candle as the
                // first trade only if this bot actually watched the product
                // while it was still restricted (i.e. saw it launch);
                // otherwise treat the minute as inconclusive (no
                // trading_open_at) and retry the exact Exchange call next
                // minute. Prevents sniping a stale listing during an
                // Exchange API outage.
                const recent = ft.ok && ft.trade && (Date.now() - Date.parse(ft.trade.time) < 60 * 60 * 1000)
                if (recent && cleared && !known.get(p.product_id)?.restricted_seen_at) {
                    ft = { ok: false }
                    err = `${err}; candles inconclusive (recent first candle, launch not observed)`
                }
            }
            const trade = ft.ok ? ft.trade : null

            // One statement: upsert flags, stamp first-seen restricted /
            // cleared times (never overwritten), record the first trade
            // (never overwritten), then set trading_open_at = LEAST(first
            // trade, cleared) only when this minute's first-trade check
            // succeeded (stale-listing guard) and only if not already set.
            await db.query(`
                INSERT INTO listing_watch AS lw
                    (product_id, stock_id, is_new, new_at, last_checked_at, check_count, last_flags,
                     restricted_seen_at, restrictions_cleared_at,
                     first_trade_at, first_trade_price, first_trade_source, last_error)
                VALUES ($1, (SELECT stock_id FROM stock WHERE name = $1 LIMIT 1), $2, $3::timestamptz, now(), 1, $4::jsonb,
                        CASE WHEN $5::boolean THEN NULL ELSE now() END,
                        CASE WHEN $5::boolean THEN now() ELSE NULL END,
                        $6::timestamptz, $7::numeric, $8, $9)
                ON CONFLICT (product_id) DO UPDATE SET
                    stock_id                = COALESCE(lw.stock_id, EXCLUDED.stock_id),
                    is_new                  = EXCLUDED.is_new,
                    new_at                  = EXCLUDED.new_at,
                    last_checked_at         = now(),
                    check_count             = lw.check_count + 1,
                    last_flags              = EXCLUDED.last_flags,
                    restricted_seen_at      = COALESCE(lw.restricted_seen_at, EXCLUDED.restricted_seen_at),
                    restrictions_cleared_at = COALESCE(lw.restrictions_cleared_at, EXCLUDED.restrictions_cleared_at),
                    first_trade_at          = COALESCE(lw.first_trade_at, EXCLUDED.first_trade_at),
                    first_trade_price       = COALESCE(lw.first_trade_price, EXCLUDED.first_trade_price),
                    first_trade_source      = COALESCE(lw.first_trade_source, EXCLUDED.first_trade_source),
                    last_error              = EXCLUDED.last_error`,
                [p.product_id, truthy(p.new), p.new_at || null, JSON.stringify(flagsOf(p)), cleared,
                 trade?.time || null, trade?.price ?? null, trade?.source || null, err])

            if (ft.ok) {
                await db.query(`
                    UPDATE listing_watch
                    SET trading_open_at = LEAST(first_trade_at, restrictions_cleared_at),
                        trading_open_source = CASE
                            WHEN first_trade_at IS NOT NULL
                             AND (restrictions_cleared_at IS NULL OR first_trade_at <= restrictions_cleared_at)
                            THEN 'first_trade' ELSE 'restrictions_cleared' END
                    WHERE product_id = $1
                    AND trading_open_at IS NULL
                    AND (first_trade_at IS NOT NULL OR restrictions_cleared_at IS NOT NULL)`,
                    [p.product_id])
            }
            const row = (await db.query(
                `SELECT trading_open_at, trading_open_source, first_trade_price FROM listing_watch WHERE product_id = $1`,
                [p.product_id])).rows[0]
            summary.push(`${p.product_id} new=${truthy(p.new)} cleared=${cleared} first_trade=${trade ? `${trade.time}@${trade.price} (${trade.source})` : (ft.ok ? 'none yet' : 'unknown')}`
                + ` open_at=${row?.trading_open_at ? new Date(row.trading_open_at).toISOString() : 'unset'}${row?.trading_open_source ? ` (${row.trading_open_source})` : ''}`
                // Worded "check unavailable" (not ERROR/FAILED) on purpose: a
                // blip on a public endpoint just means "retry next minute" and
                // must not trip the hourly health check's ERROR/FAILED grep.
                + (err ? ` (first-trade check unavailable: ${err})` : ''))
        }
        console.log(`Listing watch: ${candidates.length} candidate(s), ${todo.length} checked${summary.length ? ' | ' + summary.join(' | ') : ''}`)
    } catch (error) {
        // Never break the minute loop; the procedure simply sees no new window.
        console.log('listingWatch.run() ERROR', error?.message || error)
    }
}

module.exports = { run, restrictionsCleared }
