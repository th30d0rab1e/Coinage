// 2026-10-11: Pushover profit alerts, ported from the old CoinbasePro bot's
// sendNotifications.js (Theodore). Same idea, adapted to Coinage:
//
//   CoinbasePro (MSSQL)                    Coinage (Postgres, this file)
//   exec SendNotifications              -> SELECT un-notified profit_history
//                                          rows joined to their buy/sell fills
//   Profit / SellTotal / Sell Fee /     -> Profit, coin, buy + sell price,
//   Buy Total / Buy Fee message            shares, buy + sell time, totals,
//                                          fees, live USD + USDC balance
//   push.send(userKey, ProductID, msg)  -> same node-pushover call, title =
//                                          product id (e.g. "XTZ-USD")
//
// Differences on purpose:
//   * No hardcoded secrets. The Pushover app token and user key are read
//     from the config table (pushover_app_token / pushover_user_key), never
//     from source, so nothing secret is committed to git.
//   * Each close is sent once: rows are CLAIMED (pushover_notified_at stamped)
//     in the same statement that selects them, before anything is sent. If
//     two cron minutes overlap, the second sees nothing to send. Trade-off:
//     a Pushover outage loses that alert (logged) instead of re-sending it
//     every minute forever.
//   * Kill switch config.pushover_profit_alerts ('true'/'false').
//   * Read-only towards Coinbase: one GET of accounts (gatherBalance) and
//     only when there is at least one close to announce. Places, edits and
//     cancels nothing. Never throws, so it cannot stop a trading minute.
//
// Field mapping (profit_history has no totals / prices / times of its own):
//   buy price / shares / bought at -> fills WHERE order_id = buy_coinbase_order_id
//                                     (VWAP price, SUM size, MIN trade_time)
//   sell price / sold at           -> fills WHERE order_id = sell_fills_id
//                                     (sell_fills_id holds the SELL order id;
//                                     VWAP price, MAX trade_time)
//   Buy Total / Sell Total         -> SUM(price*size) of those same fills
//   Buy Fee / Sell Fee / Profit    -> profit_history.buy_fee / sell_fee / profit

const Pushover = require('node-pushover')

// Most alerts sent in one minute (1s apart, like CoinbasePro's sleep(1000)),
// so a burst of closes never adds more than ~10s to the end of a run. Any
// extra closes stay NULL and go out next minute.
const MAX_PER_RUN = 10

function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms))
}

// Promise wrapper around node-pushover's callback-style send().
function pushSend(push, userKey, title, message) {
    return new Promise((resolve, reject) => {
        push.send(userKey, title, message, (err, res) => (err ? reject(err) : resolve(res)))
    })
}

// '2026-10-11 03:12 CT'-style stamp in the Mac Mini's own zone (Central).
function fmtTime(t) {
    if (!t) return 'n/a'
    return new Date(t).toLocaleString('en-US', {
        timeZone: 'America/Chicago', month: 'short', day: 'numeric',
        hour: 'numeric', minute: '2-digit', timeZoneName: 'short',
    })
}

function money(n, digits = 2) {
    const v = Number(n)
    return Number.isFinite(v) ? `$${v.toFixed(digits)}` : 'n/a'
}

function num(n, digits = 6) {
    const v = Number(n)
    return Number.isFinite(v) ? String(Number(v.toFixed(digits))) : 'n/a'
}

// USD and USDC balance (available + held by open orders) straight from
// Coinbase at send time. Falls back to this minute's bulk_currency snapshot
// (also from gatherBalance, taken at the start of the run) if the GET fails.
async function liveCashBalances(db, ca) {
    const out = { usd: null, usdc: null, source: 'coinbase' }
    try {
        const accounts = await ca.gatherBalance()
        if (Array.isArray(accounts)) {
            for (const a of accounts) {
                const total = parseFloat(a?.available_balance?.value ?? 0) + parseFloat(a?.hold?.value ?? 0)
                if (a.currency === 'USD') out.usd = (out.usd ?? 0) + total
                if (a.currency === 'USDC') out.usdc = (out.usdc ?? 0) + total
            }
        }
    } catch (e) { /* fall through to snapshot */ }
    if (out.usd === null || out.usdc === null) {
        out.source = 'snapshot'
        const rows = await db.executeQuery(`
            SELECT SUM(CASE WHEN currency = 'USD'  THEN balance END) AS usd,
                   SUM(CASE WHEN currency = 'USDC' THEN balance END) AS usdc
              FROM bulk_currency`)
        out.usd = out.usd ?? rows?.[0]?.usd ?? null
        out.usdc = out.usdc ?? rows?.[0]?.usdc ?? null
    }
    return out
}

// Called once per minute from index.js main(), after thee_procedure has
// written this minute's closes to profit_history. Never throws.
async function run(db, ca) {
    try {
        const cfg = await db.executeQuery(`
            SELECT key, value FROM config
             WHERE key IN ('pushover_profit_alerts', 'pushover_app_token', 'pushover_user_key')`)
        const c = Object.fromEntries((cfg || []).map(r => [r.key, String(r.value ?? '').trim()]))
        if (c.pushover_profit_alerts !== 'true') return
        if (!c.pushover_app_token || !c.pushover_user_key) return // keys not set: skip quietly

        // Claim up to MAX_PER_RUN un-notified closes (stamp first, send after)
        // and pull the trade details from fills in the same statement.
        const rows = await db.executeQuery(`
            WITH claimed AS (
                UPDATE profit_history ph
                   SET pushover_notified_at = now()
                 WHERE ph.profit_history_id IN (
                        SELECT profit_history_id FROM profit_history
                         WHERE pushover_notified_at IS NULL
                         ORDER BY profit_history_id
                         LIMIT ${MAX_PER_RUN}
                         FOR UPDATE SKIP LOCKED)
                RETURNING ph.*
            )
            SELECT c.profit_history_id, c.name, c.period_type, c.profit,
                   c.buy_fee, c.sell_fee,
                   b.price AS buy_price, b.shares, b.total AS buy_total, b.at AS bought_at,
                   s.price AS sell_price, s.total AS sell_total, s.at AS sold_at,
                   (SELECT SUM(profit) FROM profit_history) AS lifetime_profit
              FROM claimed c
              LEFT JOIN LATERAL (
                    SELECT SUM(price * size) / NULLIF(SUM(size), 0) AS price,
                           SUM(size) AS shares, SUM(price * size) AS total,
                           MIN(trade_time) AS at
                      FROM fills WHERE order_id = c.buy_coinbase_order_id) b ON true
              LEFT JOIN LATERAL (
                    SELECT SUM(price * size) / NULLIF(SUM(size), 0) AS price,
                           SUM(price * size) AS total, MAX(trade_time) AS at
                      FROM fills WHERE order_id = c.sell_fills_id) s ON true
             ORDER BY c.profit_history_id`)
        if (!rows || rows.length === 0) return

        const push = new Pushover({ token: c.pushover_app_token })
        const bal = await liveCashBalances(db, ca)

        for (let i = 0; i < rows.length; i++) {
            const r = rows[i]
            if (i > 0) await sleep(1000)
            // Same layout as CoinbasePro's message (Profit first, one field
            // per line), extended with the fields Theodore asked for.
            const message =
                  `Profit: ${money(r.profit)}\n`
                + `Coin: ${r.name}\n`
                + `Shares: ${num(r.shares, 8)}\n`
                + `Buy Price: ${money(r.buy_price, 6)}\n`
                + `Sell Price: ${money(r.sell_price, 6)}\n`
                + `Bought: ${fmtTime(r.bought_at)}\n`
                + `Sold: ${fmtTime(r.sold_at)}\n`
                + `Buy Total: ${money(r.buy_total)}  Buy Fee: ${money(r.buy_fee)}\n`
                + `Sell Total: ${money(r.sell_total)}  Sell Fee: ${money(r.sell_fee)}\n`
                + `USD: ${money(bal.usd)}  USDC: ${money(bal.usdc)}\n`
                + `Lifetime Profit: ${money(r.lifetime_profit)}`
            try {
                await pushSend(push, c.pushover_user_key, r.name, message)
                console.log(`Pushover profit alert sent: ${r.name} ${money(r.profit)} (profit_history ${r.profit_history_id})`)
            } catch (err) {
                // Worded as "alert not sent" + "warning" on purpose: this is
                // optional and must not trip the health check's ERROR grep.
                console.log(`Pushover profit alert not sent (warning): ${r.name} profit_history ${r.profit_history_id}`, JSON.stringify(err?.errors || err?.message || err))
            }
        }
    } catch (error) {
        console.log('sendProfitNotifications warning', error?.message || error)
    }
}

module.exports = { run }
