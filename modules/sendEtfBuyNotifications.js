// 2026-10-11: Pushover alert for every CONFIRMED ETF buy fill (Theodore:
// "any ETFs bought I want a pushover alert"). Same app token + recipients
// as the profit-close alerts (config pushover_app_token / pushover_user_key
// / pushover_user_key_2); see sendProfitNotifications.loadPushover().
//
// What counts as "bought" (not just "order placed"):
//   an etf_buy row with filled = true AND real evidence of a fill:
//     * at least one row in fills for its coinbase_order_id (fills is the
//       source of truth: thee_procedure copies this minute's bulk_fills
//       there, and this runs at the very end of main(), after it), or
//     * fill_price set (limit sync / readFill computed a real price).
//   placeEtfMarket() records filled = true even when its fill GET failed
//   (so the $1 is never sent twice); such a row has no fills and no
//   fill_price, so it waits here until fills land instead of alerting a
//   guess. Partial fills of a limit that was then cancelled/expired are
//   filled = true too and DO alert (with the partial share count).
//
// Dedup: etf_buy.pushover_notified_at. Rows are CLAIMED (stamped) in the
// same UPDATE that selects them, before anything is sent, exactly like the
// profit alerts: overlapping cron minutes cannot double-send; a Pushover
// outage loses that one alert (logged as a warning) instead of retrying
// every minute. Rows older than 3 days are never picked up (and every row
// that existed before this feature was stamped by the migration), so
// turning this on does not flood the phone with history.
//
// Fields (all from the DB, no extra Coinbase calls except the one balance
// GET shared with profit alerts, and only when there is something to send):
//   shares   = limit: SUM(fills.size)          (size is shares)
//              market: SUM(size / price)        (size is quote $ on the
//                                                 $1/$2 notional market buy)
//   notional = limit: SUM(price * size); market: SUM(size)
//   price    = notional / shares (VWAP); falls back to etf_buy.fill_price
//   session  = etf_buy.equity_session (written at placement since
//              2026-10-11); market buys are NORMAL-only by design
//   holding  = all BUY fills on the ticker's USD + USDC products (the bot
//              never sells ETFs; a manual sell elsewhere is not subtracted)
//
// Kill switch: config.pushover_etf_buy_alerts ('true' / 'false').
// Never throws, so it can never stop a trading minute.

const { loadPushover, pushSendAll, liveCashBalances, fmtTime, money, num, sleep } = require('./sendProfitNotifications.js')

const MAX_PER_RUN = 10

const SESSION_LABEL = {
    EQUITY_TRADING_SESSION_PRE_MARKET: 'Pre-market',
    EQUITY_TRADING_SESSION_NORMAL: 'Regular',
    EQUITY_TRADING_SESSION_AFTER_HOURS: 'After-hours',
    EQUITY_TRADING_SESSION_OVERNIGHT: 'Overnight',
    EQUITY_TRADING_SESSION_MULTI_SESSION: 'Multi-session',
}

function sessionLabel(s) {
    if (!s) return 'n/a'
    return SESSION_LABEL[s] || String(s).replace(/^EQUITY_TRADING_SESSION_/, '')
}

// Called once per minute from index.js main(), after the profit alerts.
async function run(db, ca) {
    try {
        const pushover = await loadPushover(db, 'pushover_etf_buy_alerts')
        if (!pushover) return

        const res = await db.query(`
            WITH claimed AS (
                UPDATE etf_buy e
                   SET pushover_notified_at = now()
                 WHERE e.etf_buy_id IN (
                        SELECT x.etf_buy_id FROM etf_buy x
                         WHERE x.pushover_notified_at IS NULL
                           AND x.filled = true
                           AND x.coinbase_order_id IS NOT NULL
                           AND x.created_at > now() - interval '3 days'
                           AND (x.fill_price IS NOT NULL
                                OR EXISTS (SELECT 1 FROM fills f WHERE f.order_id = x.coinbase_order_id))
                         ORDER BY x.etf_buy_id
                         LIMIT ${MAX_PER_RUN}
                         FOR UPDATE SKIP LOCKED)
                RETURNING e.*
            )
            SELECT c.etf_buy_id, c.ticker, c.order_type, c.status, c.quote_usd,
                   c.fill_price, c.limit_price, c.base_size, c.equity_session,
                   COALESCE(c.quote_currency, 'USD') AS quote_currency,
                   f.shares, f.notional, f.fee, f.filled_at,
                   h.held_shares
              FROM claimed c
              LEFT JOIN LATERAL (
                    SELECT SUM(CASE WHEN c.order_type = 'limit' THEN size ELSE size / NULLIF(price, 0) END) AS shares,
                           SUM(CASE WHEN c.order_type = 'limit' THEN price * size ELSE size END) AS notional,
                           SUM(fee) AS fee,
                           MAX(trade_time) AS filled_at
                      FROM fills WHERE order_id = c.coinbase_order_id AND price > 0) f ON true
              LEFT JOIN LATERAL (
                    -- Total shares of this ticker bought so far (USD + USDC
                    -- products). Market fills are quote $, limit fills shares.
                    SELECT SUM(CASE WHEN eb.order_type = 'market' THEN fl.size / NULLIF(fl.price, 0)
                                    ELSE fl.size END) AS held_shares
                      FROM fills fl
                      JOIN etf t ON t.ticker = c.ticker
                      LEFT JOIN etf_buy eb ON eb.coinbase_order_id = fl.order_id
                     WHERE fl.side = 'BUY' AND fl.price > 0
                       AND fl.product_id IN (t.product_id, t.usdc_product_id)) h ON true
             ORDER BY c.etf_buy_id`)
        const rows = res?.rows || []
        if (rows.length === 0) return

        const bal = await liveCashBalances(db, ca)

        for (let i = 0; i < rows.length; i++) {
            const r = rows[i]
            if (i > 0) await sleep(1000)
            const shares = Number(r.shares)
            const notional = Number(r.notional)
            // VWAP from fills; etf_buy.fill_price when fills have not landed.
            const price = shares > 0 && notional > 0 ? notional / shares : Number(r.fill_price)
            const sharesOut = shares > 0 ? shares
                : (r.order_type === 'limit' ? Number(r.base_size) : Number(r.quote_usd) / price)
            const notionalOut = notional > 0 ? notional
                : (r.order_type === 'limit' ? Number(r.base_size) * price : Number(r.quote_usd))
            const partial = r.order_type === 'limit' && r.status !== 'FILLED' ? ' (partial)' : ''
            const heldValue = Number(r.held_shares) * price
            const message =
                  `Bought: ${num(sharesOut, 5)} sh ${r.ticker}${partial}\n`
                + `Price: ${money(price, 4)}\n`
                + `Cost: ${money(notionalOut)} ${r.quote_currency}  Fee: ${money(r.fee ?? 0)}\n`
                + `Order: ${r.order_type || 'n/a'}${r.order_type === 'limit' ? ` @ ${money(r.limit_price, 4)}` : ''}\n`
                + `Session: ${sessionLabel(r.equity_session)}\n`
                + `Filled: ${fmtTime(r.filled_at)}\n`
                + `Holding: ${num(r.held_shares, 5)} sh (~${money(heldValue)})\n`
                + `USD: ${money(bal.usd)} (avail ${money(bal.usd_available)} / hold ${money(bal.usd_hold)})  USDC: ${money(bal.usdc)}`
            try {
                await pushSendAll(pushover, `ETF Buy ${r.ticker}`, message)
                console.log(`Pushover ETF buy alert sent: ${r.ticker} ${num(sharesOut, 5)} sh @ ${money(price, 4)} to ${pushover.userKeys.length} recipient(s) (etf_buy ${r.etf_buy_id})`)
            } catch (err) {
                // "not sent (warning)": never trips the health check's ERROR grep.
                console.log(`Pushover ETF buy alert not sent (warning): ${r.ticker} etf_buy ${r.etf_buy_id}`, JSON.stringify(err?.errors || err?.message || err))
            }
        }
    } catch (error) {
        console.log('sendEtfBuyNotifications warning', error?.message || error)
    }
}

module.exports = { run, sessionLabel }
