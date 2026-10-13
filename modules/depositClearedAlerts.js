// 2026-10-12 (Theodore): Pushover alert when a USD deposit's money is
// actually usable. Why: a bank deposit shows up in usd_transfer (Coinbase
// "completed") hours/days before Coinbase releases it to available_balance,
// so the bot logs "processBuyOrders() skipped: only $0.81 available" while
// the deposit sits on hold. This tells Theodore when the bot can spend it.
//
// Rule (kept simple): for each deposit with cleared_notified_at NULL from
// the last 14 days, if Coinbase USD available >= that deposit's amount, the
// hold is over -> send one alert and stamp cleared_notified_at.
// Checked at the START of the minute (index.js starts this before any buy
// is placed), so the bot cannot spend the cleared cash before we look.
//
// Recipient: Theodore's pushover_user_key ONLY (dad's pushover_user_key_2
// gets trade-close alerts only). Switch: config.pushover_deposit_alerts.
// One Coinbase GET, and only when a pending deposit exists. Never throws.

const { loadPushover, pushSendAll, fmtTime, money } = require('./sendProfitNotifications.js')

async function run(db, ca) {
    try {
        const pending = (await db.query(`
            SELECT id, amount, date FROM usd_transfer
             WHERE type = 'deposit' AND cleared_notified_at IS NULL
               AND date > now() - interval '14 days'
             ORDER BY date`))?.rows || []
        if (pending.length === 0) return

        const accounts = await ca.gatherBalance()
        if (!Array.isArray(accounts)) return
        const usd = accounts.find(a => a.currency === 'USD')
        const available = usd ? parseFloat(usd.available_balance.value) : 0

        for (const d of pending) {
            if (!(available >= Number(d.amount))) {
                console.log(`depositClearedAlerts: deposit ${d.id} ${money(d.amount)} still on hold ($${available.toFixed(2)} available)`)
                continue
            }
            // Claim first (only if still unclaimed) so overlapping cron minutes can't double-send.
            const claim = await db.query(`UPDATE usd_transfer SET cleared_notified_at = now()
                                           WHERE id = $1 AND cleared_notified_at IS NULL RETURNING id`, [d.id])
            if (!(claim?.rows?.length > 0)) continue
            const msg = `Deposit ${money(d.amount)} cleared — ${money(available)} now available to trade (deposited ${fmtTime(d.date)})`
            console.log(`depositClearedAlerts: ${msg}`)
            try {
                const p = await loadPushover(db, 'pushover_deposit_alerts')
                if (!p) continue
                // Theodore's key only: the first entry of pushover_user_key.
                const cfg = await db.query(`SELECT value FROM config WHERE key = 'pushover_user_key'`)
                const mine = String(cfg?.rows?.[0]?.value ?? '').split(/[,\s]+/).filter(Boolean)
                if (mine.length === 0) continue
                await pushSendAll({ push: p.push, userKeys: mine }, 'Deposit cleared', msg)
            } catch (e) {
                console.log(`depositClearedAlerts: Pushover not sent (warning) ${e?.message || e}`)
            }
        }
    } catch (e) {
        console.log(`depositClearedAlerts ERROR ${e?.message || e}`)
    }
}

module.exports = { run }
