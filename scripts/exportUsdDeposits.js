// exportUsdDeposits.js -- READ-ONLY export of every USD (fiat) deposit, or
// with --withdrawals every USD (fiat) withdrawal, ever made on this Coinbase
// account, written to a CSV.
//
// Why: Coinbase's Advanced Trade API (/api/v3/brokerage/...) has no deposit
// or withdrawal history endpoint, and the in-app statements are awkward to
// total. The older Coinbase App "v2" API still exposes both and accepts the
// same CDP JWT the bot already signs, so this script reuses that auth instead
// of adding a new key. Withdrawals are a flag on this same script (not a
// sibling file) because the v2 /deposits and /withdrawals endpoints return
// identically shaped records and the matching ledger types (fiat_deposit /
// fiat_withdrawal) differ only by sign -- one code path keeps both exports
// consistent, which matters when you net deposits minus withdrawals.
//
// What it does (GET requests only -- it never places orders, moves funds, or
// touches the DB):
//   1. GET /v2/accounts (paged) and keep every fiat USD account ("Cash (USD)").
//      There can be more than one: each portfolio has its own USD wallet.
//   2. For each USD account, GET /v2/accounts/{id}/deposits (or /withdrawals),
//      paged. This is the primary source: it includes non-completed records
//      (canceled etc.), the fee, the payment method id, and Coinbase's
//      user_reference code.
//   3. GET /v2/accounts/{id}/transactions (paged) and keep type=fiat_deposit
//      (or fiat_withdrawal) as a cross-check. The ledger transaction id there
//      differs from the record's own transaction id, so the two are matched by
//      absolute amount + time (within 5 minutes; withdrawals are negative in
//      the ledger). Any ledger row with no matching record is still exported
//      (type "fiat_deposit (ledger only)" / "fiat_withdrawal (ledger only)").
//      Skip this step with --skip-transactions (it pages through every
//      advanced_trade_fill in the USD wallet, so it is the slow part).
//   4. GET /api/v3/brokerage/payment_methods to turn payment method ids into
//      names (e.g. "ACH | Bank ... ****1234"); ids not in that list (bank
//      since unlinked) get a per-id lookup, else show as "<id> (no longer
//      linked)". Older records (pre-2023) come back with no payment method id;
//      those show as "(not returned by API)".
//
// Amounts in both CSVs are positive dollars (money in for deposits, money out
// for withdrawals).
//
// Not included: crypto sends/receives, USDC conversions, internal
// portfolio-to-portfolio "tx" transfers, and the old Coinbase Pro
// exchange_deposit/exchange_withdrawal/pro_withdrawal moves -- those are not
// money entering or leaving Coinbase.
//
// Auth: signs with modules/equityAuth.js signRequest(), the same signer
// modules/coinbaseAuth.js tokenate() uses (Default / Primary portfolio
// Ed25519 key, stored outside the repo). Key needs the "view" permission.
// No secret is printed.
//
// Usage:
//   node scripts/exportUsdDeposits.js [--withdrawals] [--out /path/file.csv] [--skip-transactions]
// Default output: ~/Downloads/coinbase_usd_deposits.csv
//             or  ~/Downloads/coinbase_usd_withdrawals.csv with --withdrawals
// Dates in the CSV are America/Chicago.

const fs = require('fs')
const os = require('os')
const path = require('path')
const axios = require('axios')
const { signRequest } = require('../modules/equityAuth.js')

const args = process.argv.slice(2)
// KIND picks the v2 endpoint (/deposits or /withdrawals) and the ledger type.
const KIND = args.includes('--withdrawals') ? 'withdrawal' : 'deposit'
const ENDPOINT = `${KIND}s`
const LEDGER_TYPE = `fiat_${KIND}`
const outIdx = args.indexOf('--out')
const OUT = outIdx >= 0 ? args[outIdx + 1] : path.join(os.homedir(), 'Downloads', `coinbase_usd_${KIND}s.csv`)
const SKIP_TX = args.includes('--skip-transactions')
const MATCH_WINDOW_MS = 5 * 60 * 1000

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// GET only. The JWT "uri" claim must be the path WITHOUT the query string.
// validateStatus keeps axios from throwing an error object that carries the
// bearer token in its config.
async function get(pathAndQuery) {
    const pathOnly = pathAndQuery.split('?')[0]
    await sleep(110) // stay well under Coinbase's 10-15 req/sec limit
    const res = await axios.get(`https://api.coinbase.com${pathAndQuery}`, {
        headers: {
            Authorization: `Bearer ${signRequest('GET', pathOnly)}`,
            'CB-VERSION': '2024-01-01',
        },
        timeout: 30000,
        validateStatus: () => true,
    })
    if (res.status !== 200) {
        const body = typeof res.data === 'string' ? res.data.slice(0, 300) : JSON.stringify(res.data).slice(0, 300)
        throw new Error(`GET ${pathOnly} -> HTTP ${res.status}: ${body}`)
    }
    return res.data
}

// v2 pagination: follow pagination.next_uri until it is null.
async function getAllV2(firstUri) {
    const rows = []
    let next = firstUri
    while (next) {
        const page = await get(next)
        rows.push(...(page.data || []))
        next = page.pagination?.next_uri || null
    }
    return rows
}

function toCentral(iso) {
    if (!iso) return ''
    const d = new Date(iso)
    const parts = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
        timeZone: 'America/Chicago', hourCycle: 'h23',
        year: 'numeric', month: '2-digit', day: '2-digit',
        hour: '2-digit', minute: '2-digit', second: '2-digit', timeZoneName: 'short',
    }).formatToParts(d).map((p) => [p.type, p.value]))
    return `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}:${parts.second} ${parts.timeZoneName}`
}

function csvCell(v) {
    const s = v == null ? '' : String(v)
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
}

async function main() {
    // 1. USD fiat accounts
    const accounts = await getAllV2('/v2/accounts?limit=100')
    const usdAccounts = accounts.filter((a) => a.type === 'fiat' && (a.currency?.code || a.currency) === 'USD')
    console.log(`Exporting USD ${KIND}s. v2 accounts: ${accounts.length}, USD fiat accounts: ${usdAccounts.length}`)

    // 4. payment method names (Advanced Trade endpoint; v2 /payment-methods is gone)
    const pmNames = {}
    try {
        const pm = await get('/api/v3/brokerage/payment_methods')
        for (const m of pm.payment_methods || []) pmNames[m.id] = `${m.type} | ${m.name}`
    } catch (e) {
        console.log(`payment_methods lookup failed (names will be ids): ${e.message}`)
    }
    async function pmName(pmId) {
        if (!pmId) return '(not returned by API)'
        if (!(pmId in pmNames)) {
            try {
                const one = await get(`/api/v3/brokerage/payment_methods/${pmId}`)
                const m = one.payment_method || one
                pmNames[pmId] = m?.type ? `${m.type} | ${m.name}` : `${pmId} (no longer linked)`
            } catch {
                pmNames[pmId] = `${pmId} (no longer linked)`
            }
        }
        return pmNames[pmId]
    }

    const rows = []
    for (const acct of usdAccounts) {
        // 2. deposit / withdrawal records
        const records = await getAllV2(`/v2/accounts/${acct.id}/${ENDPOINT}?limit=100`)
        // 3. ledger fiat_deposit / fiat_withdrawal rows (cross-check)
        let ledger = []
        if (!SKIP_TX) {
            const tx = await getAllV2(`/v2/accounts/${acct.id}/transactions?limit=100`)
            ledger = tx.filter((t) => t.type === LEDGER_TYPE)
        }
        console.log(`  ${acct.name} ${acct.id}: ${records.length} ${KIND} records, ${SKIP_TX ? 'skipped' : ledger.length} ${LEDGER_TYPE} ledger rows`)

        const usedLedger = new Set()
        for (const d of records) {
            const amt = Math.abs(Number(d.amount?.amount))
            const t = Date.parse(d.created_at)
            const match = ledger.find((l) => !usedLedger.has(l.id)
                && Math.abs(Math.abs(Number(l.amount?.amount)) - amt) < 0.005
                && Math.abs(Date.parse(l.created_at) - t) <= MATCH_WINDOW_MS)
            if (match) usedLedger.add(match.id)
            rows.push({
                created_at: d.created_at,
                date_ct: toCentral(d.created_at),
                amount_usd: amt.toFixed(2),
                fee_usd: d.fee?.amount ?? '',
                status: d.status,
                type: LEDGER_TYPE,
                payment_method: await pmName(d.payment_method?.id || ''),
                transaction_id: match?.id || '',
                record_id: d.id,
                record_transaction_id: d.transaction?.transaction_id || '',
                user_reference: d.user_reference || '',
                cancel_reason: d.cancel_reason?.message || '',
                account_id: acct.id,
            })
        }
        for (const l of ledger.filter((l) => !usedLedger.has(l.id))) {
            rows.push({
                created_at: l.created_at,
                date_ct: toCentral(l.created_at),
                amount_usd: Math.abs(Number(l.amount?.amount)).toFixed(2),
                fee_usd: '',
                status: l.status,
                type: `${LEDGER_TYPE} (ledger only)`,
                payment_method: `(no ${KIND} record)`,
                transaction_id: l.id,
                record_id: '', record_transaction_id: '', user_reference: '', cancel_reason: '',
                account_id: acct.id,
            })
        }
    }

    rows.sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at))
    // Header names keep the kind in them (deposit_id / withdrawal_id) so each
    // CSV reads naturally on its own.
    const cols = ['date_ct', 'amount_usd', 'fee_usd', 'status', 'type', 'payment_method', 'transaction_id',
        'record_id', 'record_transaction_id', 'user_reference', 'cancel_reason', 'account_id', 'created_at']
    const header = cols.map((c) => c.replace('record', KIND))
    const csv = [header.join(','), ...rows.map((r) => cols.map((c) => csvCell(r[c])).join(','))].join('\n') + '\n'
    fs.mkdirSync(path.dirname(OUT), { recursive: true })
    fs.writeFileSync(OUT, csv)

    // Summary
    const done = rows.filter((r) => r.status === 'completed')
    const other = rows.filter((r) => r.status !== 'completed')
    const total = done.reduce((s, r) => s + Number(r.amount_usd), 0)
    console.log(`\nWrote ${rows.length} rows -> ${OUT}`)
    console.log(`Completed ${KIND}s: ${done.length}, total $${total.toFixed(2)}`)
    if (done.length) console.log(`Earliest: ${done[0].date_ct}  Latest: ${done[done.length - 1].date_ct}`)
    console.log(`Not completed: ${other.length}`)
    for (const r of other) console.log(`  ${r.date_ct} $${r.amount_usd} ${r.status} ${r.cancel_reason}`)
}

main().catch((e) => {
    console.error(`exportUsdDeposits (${KIND}s) failed: ${e.message}`)
    process.exit(1)
})
