// 2026-10-11: record dividends Coinbase actually paid into cash, and send a
// Pushover alert for each one (Theodore: "any dividends received I want an
// alert"). Same app token + recipients as the profit-close alerts.
//
// WHERE DIVIDENDS SHOW UP (found 2026-10-11 by reading the live ledger):
//   Coinbase has no dividend endpoint and no "dividend" transaction type on
//   this account. A paid ETF distribution lands in the Cash (USD) v2 ledger
//   as a POSITIVE `simple_equity_settlement` transaction around 6 AM CT on
//   the payable date, with no ticker on it (details = {}). ETF buys are the
//   NEGATIVE simple_equity_settlement rows. Examples:
//     2026-10-08 06:12 CT  +$0.57  = CHPY ($0.5847/sh, payable 10/08)
//     2026-10-09 06:02 CT  +$0.03  = XDTE (payable 10/09)
//   So the RECEIPT (amount + time) is real Coinbase data; the TICKER is
//   inferred by matching it to Alpaca's corporate-actions calendar
//   (cash_dividend, payable_date within 3 days before the credit) for an
//   etf ticker we actually held on the ex-date (BUY fills before ex_date).
//   When several held tickers pay the same day, the one whose
//   rate x shares is closest to the credit wins and the alert says so.
//   No match -> the credit is still recorded and alerted, labelled
//   "Equity cash credit (no dividend match)", never dressed up as a dividend.
//   A future ledger type containing "dividend" is taken as a dividend as-is.
//
// Storage: dividend_receipt (one row per Coinbase ledger transaction id,
// UNIQUE, so the same receipt is never stored or alerted twice). Alert
// dedup is dividend_receipt.pushover_notified_at, claimed before sending
// (same pattern as profit_history / etf_buy). Receipts older than
// config.dividend_alerts_since (set by the migration) are stored already
// stamped, so the first run records history silently.
//
// Cost: runs every DIVIDEND_SYNC_EVERY_MIN minutes (not every minute):
// GET /v2/accounts (2 pages) + one ledger page (newest 100) per USD/USDC
// account, plus ONE Alpaca corporate-actions GET only when a new credit
// needs a ticker. GET-only, never places/cancels anything, never throws.
//
// Kill switch: config.pushover_dividend_alerts ('true'/'false') controls
// the alert only; receipts are recorded either way.

const axios = require('axios')
const { signRequest } = require('./equityAuth.js')
const alpacaMd = require('./alpacaMarketData.js')
const { loadPushover, pushSendAll, liveCashBalances, fmtTime, money, num, sleep } = require('./sendProfitNotifications.js')

const DIVIDEND_SYNC_EVERY_MIN = 5
const MAX_PER_RUN = 10

// GET only; JWT uri claim is the path without the query string. Never let
// axios throw (its error config would carry the token).
async function v2Get(pathAndQuery) {
    const pathOnly = pathAndQuery.split('?')[0]
    const res = await axios.get(`https://api.coinbase.com${pathAndQuery}`, {
        headers: { Authorization: `Bearer ${signRequest('GET', pathOnly)}`, 'CB-VERSION': '2024-01-01' },
        timeout: 15000,
        validateStatus: () => true,
    })
    if (res.status !== 200) throw new Error(`GET ${pathOnly} -> HTTP ${res.status}`)
    return res.data
}

// Cash (USD) and USDC wallets in every portfolio.
async function listCashAccounts() {
    const out = []
    let next = '/v2/accounts?limit=300'
    while (next) {
        const page = await v2Get(next)
        out.push(...(page.data || []))
        next = page.pagination?.next_uri || null
    }
    return out.filter((a) => ['USD', 'USDC'].includes(a.currency?.code || a.currency))
}

// Positive equity cash credits in the newest 100 ledger rows of an account.
function isCandidate(t) {
    const amt = Number(t.amount?.amount)
    if (!(amt > 0) || t.status !== 'completed') return false
    return t.type === 'simple_equity_settlement' || /divid/i.test(String(t.type))
}

async function fetchCorporateDividends(tickers, start, end) {
    const k = alpacaMd.loadAlpacaKeys()
    const res = await axios.get('https://data.alpaca.markets/v1/corporate-actions', {
        params: { symbols: tickers.join(','), types: 'cash_dividend', start, end, limit: 1000 },
        headers: { 'APCA-API-KEY-ID': k.key, 'APCA-API-SECRET-KEY': k.secret },
        timeout: 15000,
        validateStatus: () => true,
    })
    if (res.status !== 200) throw new Error(`Alpaca corporate-actions HTTP ${res.status}`)
    return res.data?.corporate_actions?.cash_dividends || []
}

function isoDate(d) { return d.toISOString().slice(0, 10) }

// Shares of a ticker held at the start of its ex-date (BUY fills only; the
// bot never sells ETFs). Market fills are quote $ (size / price = shares).
async function sharesHeldBefore(db, ticker, exDate) {
    const r = await db.query(
        `SELECT SUM(CASE WHEN eb.order_type = 'market' THEN f.size / NULLIF(f.price, 0) ELSE f.size END) AS shares
           FROM fills f
           JOIN etf t ON t.ticker = $1
           LEFT JOIN etf_buy eb ON eb.coinbase_order_id = f.order_id
          WHERE f.side = 'BUY' AND f.price > 0
            AND f.product_id IN (t.product_id, t.usdc_product_id)
            AND f.trade_time < ($2::date::timestamp AT TIME ZONE 'America/New_York')`,
        [ticker, exDate])
    return Number(r?.rows?.[0]?.shares) || 0
}

// Best guess of which ticker(s) paid this credit. Returns fields for
// dividend_receipt (kind 'dividend' when matched, else 'equity_credit').
//
// Seen on this account: Coinbase pays ONE lump credit per day covering
// every ETF whose distribution is payable that day (2026-10-08: CHPY +
// YBTC + TOPW -> one +$0.57). So: take every held ETF with payable_date =
// the credit's Chicago date; if none, fall back to the previous 3 days
// (a late post). One candidate -> that ticker; several -> all of them,
// ticker = "CHPY, YBTC, TOPW" and the per-ticker estimate in match_note.
async function attribute(db, credit, corpActions) {
    if (/divid/i.test(credit.ledgerType)) {
        return { kind: 'dividend', ticker: null, matchNote: `Coinbase type ${credit.ledgerType}` }
    }
    const day = credit.chicagoDate
    const lo = isoDate(new Date(Date.parse(day) - 3 * 86400000))
    const held = async (list) => {
        const out = []
        for (const ca of list) {
            const shares = await sharesHeldBefore(db, ca.symbol, ca.ex_date)
            if (shares > 0) out.push({ ...ca, shares, expected: shares * Number(ca.rate) })
        }
        return out
    }
    let candidates = await held(corpActions.filter((ca) => ca.payable_date === day))
    if (candidates.length === 0) {
        candidates = await held(corpActions.filter((ca) => ca.payable_date >= lo && ca.payable_date < day))
    }
    if (candidates.length === 0) {
        return { kind: 'equity_credit', ticker: null, matchNote: 'no held ETF had a dividend payable in the last 3 days' }
    }
    candidates.sort((a, b) => b.expected - a.expected)
    const total = candidates.reduce((sum, c) => sum + c.expected, 0)
    const parts = candidates.map((c) => `${c.symbol} $${Number(c.rate)}/sh x ${num(c.shares, 5)} sh = ~${money(c.expected)}`)
    const one = candidates.length === 1 ? candidates[0] : null
    return {
        kind: 'dividend',
        ticker: candidates.map((c) => c.symbol).join(', '),
        rate: one ? Number(one.rate) : null,
        estShares: one ? one.shares : null,
        exDate: one ? one.ex_date : null,
        payDate: candidates[0].payable_date,
        matchNote: parts.join('; ') + (one ? '' : ` (est. total ~${money(total)})`),
    }
}

// Pull new credits from Coinbase into dividend_receipt. maxPages = how many
// 100-row ledger pages per account to read (1 every 5 minutes is ~2-3 days
// of ledger; pass more for a one-off history backfill, e.g.
//   node -e "require('./modules/dividendAlerts.js').syncReceipts(require('./modules/database.js'), {maxPages: 20})"
async function syncReceipts(db, { maxPages = 1 } = {}) {
    const accounts = await listCashAccounts()
    const fresh = []
    for (const a of accounts) {
        let next = `/v2/accounts/${a.id}/transactions?limit=100&order=desc`
        const txns = []
        for (let p = 0; next && p < maxPages; p++) {
            const page = await v2Get(next)
            txns.push(...(page.data || []))
            next = page.pagination?.next_uri || null
        }
        for (const t of txns) {
            if (!isCandidate(t)) continue
            fresh.push({
                txnId: t.id,
                currency: a.currency?.code || a.currency,
                ledgerType: t.type,
                amount: Number(t.amount.amount),
                createdAt: t.created_at,
                chicagoDate: new Date(t.created_at).toLocaleDateString('en-CA', { timeZone: 'America/Chicago' }),
            })
        }
    }
    if (fresh.length === 0) return 0
    const known = await db.query(`SELECT coinbase_txn_id FROM dividend_receipt WHERE coinbase_txn_id = ANY($1::text[])`,
        [fresh.map((f) => f.txnId)])
    const knownIds = new Set((known?.rows || []).map((r) => r.coinbase_txn_id))
    const todo = fresh.filter((f) => !knownIds.has(f.txnId))
    if (todo.length === 0) return 0

    // One Alpaca call covers every new credit.
    let corp = []
    let corpError = null
    try {
        const tick = await db.query(`SELECT ticker FROM etf`)
        const tickers = (tick?.rows || []).map((r) => r.ticker)
        const dates = todo.map((t) => t.chicagoDate).sort()
        const start = isoDate(new Date(Date.parse(dates[0]) - 4 * 86400000))
        corp = await fetchCorporateDividends(tickers, start, dates[dates.length - 1])
    } catch (e) {
        corpError = e?.message || String(e)
    }

    let inserted = 0
    for (const c of todo) {
        const m = corpError
            ? { kind: 'equity_credit', ticker: null, matchNote: `ticker lookup failed (${corpError})` }
            : await attribute(db, c, corp)
        // Older than dividend_alerts_since -> stored already "notified".
        const r = await db.query(
            `INSERT INTO dividend_receipt
                (coinbase_txn_id, currency, ledger_type, amount, received_at, kind, ticker,
                 rate, est_shares, ex_date, pay_date, match_note, pushover_notified_at)
             SELECT $1, $2, $3, $4, $5::timestamptz, $6, $7, $8, $9, $10::date, $11::date, $12,
                    CASE WHEN $5::timestamptz < COALESCE(
                        (SELECT NULLIF(value, '')::timestamptz FROM config WHERE key = 'dividend_alerts_since'),
                        '-infinity'::timestamptz) THEN now() END
             ON CONFLICT (coinbase_txn_id) DO NOTHING
             RETURNING dividend_receipt_id`,
            [c.txnId, c.currency, c.ledgerType, c.amount, c.createdAt, m.kind, m.ticker,
                m.rate ?? null, m.estShares ?? null, m.exDate ?? null, m.payDate ?? null, m.matchNote])
        if (r?.rows?.[0]) {
            inserted++
            console.log(`Dividend receipt recorded: ${m.kind} ${m.ticker || '?'} $${c.amount} ${c.currency} (${m.matchNote})`)
        }
    }
    return inserted
}

async function sendAlerts(db, ca) {
    const pushover = await loadPushover(db, 'pushover_dividend_alerts')
    if (!pushover) return
    const res = await db.query(`
        WITH claimed AS (
            UPDATE dividend_receipt d
               SET pushover_notified_at = now()
             WHERE d.dividend_receipt_id IN (
                    SELECT dividend_receipt_id FROM dividend_receipt
                     WHERE pushover_notified_at IS NULL
                     ORDER BY dividend_receipt_id
                     LIMIT ${MAX_PER_RUN}
                     FOR UPDATE SKIP LOCKED)
            RETURNING d.*
        )
        SELECT c.*, c.ex_date::text AS ex_txt, c.pay_date::text AS pay_txt,
               (SELECT SUM(amount) FROM dividend_receipt WHERE kind = 'dividend') AS lifetime,
               (SELECT COALESCE(SUM(amount), 0) FROM dividend_receipt
                 WHERE kind = 'dividend'
                   AND (received_at AT TIME ZONE 'America/Chicago')::date
                       >= date_trunc('month', now() AT TIME ZONE 'America/Chicago')::date) AS month
          FROM claimed c ORDER BY c.dividend_receipt_id`)
    const rows = res?.rows || []
    if (rows.length === 0) return
    const bal = await liveCashBalances(db, ca)
    for (let i = 0; i < rows.length; i++) {
        const r = rows[i]
        if (i > 0) await sleep(1000)
        const isDiv = r.kind === 'dividend'
        const title = isDiv ? `Dividend ${r.ticker || ''}`.trim() : 'Equity cash credit'
        const message =
              (isDiv ? `Dividend: ${money(r.amount)} ${r.currency}\n` : `Credit: ${money(r.amount)} ${r.currency} (no dividend match)\n`)
            + `Ticker: ${r.ticker || 'unknown'}${r.ticker ? ' (matched by pay date)' : ''}\n`
            + (r.pay_txt ? `${r.ex_txt ? `Ex: ${r.ex_txt}  ` : ''}Pay date: ${r.pay_txt}\n` : '')
            + `Match: ${r.match_note || 'n/a'}\n`
            + `Received: ${fmtTime(r.received_at)}\n`
            + `Month Dividends: ${money(r.month)}  Lifetime: ${money(r.lifetime)}\n`
            + `USD: ${money(bal.usd)} (avail ${money(bal.usd_available)} / hold ${money(bal.usd_hold)})  USDC: ${money(bal.usdc)}`
        try {
            await pushSendAll(pushover, title, message)
            console.log(`Pushover dividend alert sent: ${r.ticker || r.kind} ${money(r.amount)} to ${pushover.userKeys.length} recipient(s) (dividend_receipt ${r.dividend_receipt_id})`)
        } catch (err) {
            console.log(`Pushover dividend alert not sent (warning): dividend_receipt ${r.dividend_receipt_id}`, JSON.stringify(err?.errors || err?.message || err))
        }
    }
}

// Called once per minute from index.js (at the end of main()). Syncs only
// every DIVIDEND_SYNC_EVERY_MIN minutes (force = true for manual runs);
// alerts anything unsent every call. Never throws.
async function run(db, ca, { force = false } = {}) {
    try {
        if (force || new Date().getMinutes() % DIVIDEND_SYNC_EVERY_MIN === 0) {
            await syncReceipts(db)
        }
    } catch (error) {
        console.log('dividendAlerts sync warning', error?.message || error)
    }
    try {
        await sendAlerts(db, ca)
    } catch (error) {
        console.log('dividendAlerts alert warning', error?.message || error)
    }
}

module.exports = { run, syncReceipts }
