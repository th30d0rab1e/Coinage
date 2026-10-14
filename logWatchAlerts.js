// 2026-10-14 (Theodore): Pushover EMERGENCY alert (priority 2) when the bot
// crashes or stops running. Runs from its own cron line every minute, NOT
// from index.js, so it still fires if index.js itself is dead.
//
// What alerts (Theodore's pushover_user_key ONLY, not dad's key_2):
//   1. Crash lines in NEW outputLog.txt text since the last check: JS
//      exceptions (TypeError, ReferenceError, ...), unhandled rejections,
//      stack frames, DB/network failures (ECONNREFUSED, ETIMEDOUT, pg
//      "error: ..."). Normal Coinbase order rejections (INSUFFICIENT_FUND,
//      preview_failure_reason, error_response, ...) are ignored on purpose:
//      they happen every day and are not a bot problem.
//   2. Stale log: no "End Program" line for 5+ minutes = bot not running.
//
// Spam guard: the same alert signature fires at most once per hour.
// Emergency priority repeats every 60s for up to 30 min until acknowledged.
// State (byte offset, last-alert times, cached Pushover keys so a DB outage
// can still be reported) lives in logWatchState.json next to this file.
const fs = require('fs')
const path = require('path')
const db = require('./modules/database.js')

const LOG = path.join(__dirname, 'outputLog.txt')
const STATE = path.join(__dirname, 'logWatchState.json')
const STALE_MIN = 5
const REPEAT_MS = 60 * 60 * 1000

const CRASH = /(TypeError|ReferenceError|SyntaxError|RangeError|Unhandled|uncaught|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|^\s*error: [^']|^Error: |^\s+at .+\.js:\d+:\d+)/i
const IGNORE = /(INSUFFICIENT_FUND|preview_failure_reason|error_response|error_details|UNKNOWN_FAILURE_REASON|PREVIEW_|FAILED: )/

function loadState () { try { return JSON.parse(fs.readFileSync(STATE, 'utf8')) } catch { return { offset: null, sent: {} } } }
function saveState (s) { fs.writeFileSync(STATE, JSON.stringify(s, null, 2)) }

async function keys (state) {
    try {
        const r = await db.query(`SELECT MAX(value) FILTER (WHERE key = 'pushover_app_token') AS token,
                                         MAX(value) FILTER (WHERE key = 'pushover_user_key')  AS user
                                  FROM config`)
        const token = r.rows[0].token, user = (r.rows[0].user || '').split(',')[0].trim()
        if (token && user) state.keys = { token, user }
    } catch (e) { /* DB down: fall back to cached keys and report it below */ state.dbError = String(e.message || e) }
    return state.keys
}

async function emergency (k, title, message) {
    const body = new URLSearchParams({ token: k.token, user: k.user, title, message: message.slice(0, 1000),
        priority: '2', retry: '60', expire: '1800', sound: 'siren' })
    const res = await fetch('https://api.pushover.net/1/messages.json', { method: 'POST', body })
    return res.json()
}

async function main () {
    const state = loadState()
    state.sent = state.sent || {}
    const alerts = []

    const st = fs.statSync(LOG)
    // Midnight cron truncates the log; first run starts at the end.
    if (state.offset == null || state.offset > st.size) state.offset = state.offset == null ? st.size : 0
    if (st.size > state.offset) {
        const fd = fs.openSync(LOG, 'r'); const buf = Buffer.alloc(st.size - state.offset)
        fs.readSync(fd, buf, 0, buf.length, state.offset); fs.closeSync(fd)
        const hits = buf.toString('utf8').split('\n').filter(l => CRASH.test(l) && !IGNORE.test(l))
        if (hits.length) alerts.push({ sig: 'crash:' + hits[0].replace(/[0-9a-f-]{8,}|\d+/gi, '#').slice(0, 80),
            title: 'Coinage bot ERROR', msg: `${hits.length} error line(s):\n` + hits.slice(0, 5).join('\n') })
        state.offset = st.size
    }

    const tail = fs.readFileSync(LOG, 'utf8').slice(-200000)
    const m = [...tail.matchAll(/End Program (.+)/g)].pop()
    const lastEnd = m ? new Date(m[1]) : null
    const ageMin = lastEnd ? (Date.now() - lastEnd) / 60000 : (Date.now() - st.mtimeMs) / 60000
    if (ageMin >= STALE_MIN) alerts.push({ sig: 'stale', title: 'Coinage bot NOT RUNNING',
        msg: `No "End Program" in ${Math.round(ageMin)} min (last: ${lastEnd ? lastEnd.toLocaleString('en-US', { timeZone: 'America/Chicago' }) + ' CT' : 'none'}).` })

    const k = await keys(state)
    if (state.dbError) alerts.push({ sig: 'db', title: 'Coinage DB unreachable', msg: state.dbError })
    delete state.dbError

    for (const a of alerts) {
        if (Date.now() - (state.sent[a.sig] || 0) < REPEAT_MS) continue
        if (!k) { console.log('logWatch: no Pushover keys cached; cannot alert:', a.title); continue }
        const r = await emergency(k, a.title, a.msg)
        console.log('logWatch alert', a.title, JSON.stringify(r))
        if (r.status === 1) state.sent[a.sig] = Date.now()
    }
    saveState(state)
}

if (require.main === module) {
    main().catch(e => console.error('logWatch failed:', e)).finally(() => process.exit(0))
}
module.exports = { emergency, keys, loadState }
