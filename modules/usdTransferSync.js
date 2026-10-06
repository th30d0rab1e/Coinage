// usdTransferSync.js -- keeps the usd_transfer table current with every
// COMPLETED USD (fiat) deposit/withdrawal between the bank and Coinbase.
//
// Why: usd_transfer answers "how much real money have I put in / taken out"
// (net invested capital) inside the DB. index.js calls syncRecent() once per
// run (cron starts a fresh `node index.js` every minute), so a new deposit
// or withdrawal lands in the table within about a minute.
// scripts/exportUsdDeposits.js --load-db uses insertTransfers() from here
// for the one-off full-history backfill, so both writers share one insert.
//
// READ-ONLY against Coinbase: GET requests only. Signs with the same
// Default / Primary portfolio key as the rest of the bot
// (equityAuth.signRequest). Never places orders or moves funds. Only
// writes to usd_transfer.
//
// How each run works (~8 GET calls, a second or two):
//   1. GET /v2/accounts (paged, limit 300) -> every fiat USD account
//      ("Cash (USD)"; one per portfolio, currently two).
//   2. Per USD account:
//      a. GET /v2/accounts/{id}/deposits and /withdrawals, newest first,
//         one page of 100. These records carry the canonical created_at.
//      b. GET /v2/accounts/{id}/transactions, newest first, paging only
//         until created_at is older than LEDGER_WINDOW_MS (2 minutes).
//         Keep type fiat_deposit / fiat_withdrawal with status completed.
//   3. Insert candidates with ON CONFLICT (type, amount, date) DO NOTHING.
//
// Window choice:
//   * Ledger (2b): 2-minute window as requested. Each run overlaps the
//     previous one by a minute, and duplicates are harmless (see dedupe).
//   * A transfer can be CREATED earlier and COMPLETE later (ACH holds,
//     risk review). Its ledger row keeps the old created_at, so a
//     created_at window alone would never see it complete. So the
//     deposit/withdrawal records (2a) are also checked: any record with
//     status completed whose updated_at (or created_at) is within
//     RECORD_WINDOW_MS (24 hours) is inserted. 24h rather than 2 minutes
//     because it costs nothing extra (the page is already fetched, at most
//     a handful of rows qualify) and it also self-heals short bot outages
//     or a failed minute. Longer outages: re-run
//     `node scripts/exportUsdDeposits.js --load-db`.
//
// Dedupe: UNIQUE (type, amount, date) on usd_transfer + ON CONFLICT DO
// NOTHING. date must be identical for the same transfer from every path,
// so it is ALWAYS the deposit/withdrawal record's created_at. A ledger row
// is mapped to its record by type + amount + created_at within 5 minutes
// (the ledger transaction id differs from the record's, and its timestamp
// is a few seconds later). Only if no record matches is the ledger
// created_at used (logged as a warning; never seen in this account's
// full history, where all 28 + 5 ledger rows matched a record).
// date is stored as America/Chicago local time in a timestamp without
// time zone column, the same convention as date_created / created_at.
//
// Errors: syncRecent() catches everything and only logs, so a Coinbase or
// DB problem can never break the bot's main loop.

const axios = require('axios')
const { signRequest } = require('./equityAuth.js')

const LEDGER_WINDOW_MS = 2 * 60 * 1000
const RECORD_WINDOW_MS = 24 * 60 * 60 * 1000
const MATCH_WINDOW_MS = 5 * 60 * 1000
const KINDS = [
    { kind: 'deposit', endpoint: 'deposits', ledgerType: 'fiat_deposit' },
    { kind: 'withdrawal', endpoint: 'withdrawals', ledgerType: 'fiat_withdrawal' },
]

// GET only. JWT uri claim is the path without the query string.
// validateStatus: never throw an axios error (its config holds the token).
async function v2Get(pathAndQuery) {
    const pathOnly = pathAndQuery.split('?')[0]
    const res = await axios.get(`https://api.coinbase.com${pathAndQuery}`, {
        headers: {
            Authorization: `Bearer ${signRequest('GET', pathOnly)}`,
            'CB-VERSION': '2024-01-01',
        },
        timeout: 15000,
        validateStatus: () => true,
    })
    if (res.status !== 200) {
        const body = typeof res.data === 'string' ? res.data.slice(0, 200) : JSON.stringify(res.data).slice(0, 200)
        throw new Error(`GET ${pathOnly} -> HTTP ${res.status}: ${body}`)
    }
    return res.data
}

async function listUsdAccounts() {
    const accounts = []
    let next = '/v2/accounts?limit=300'
    while (next) {
        const page = await v2Get(next)
        accounts.push(...(page.data || []))
        next = page.pagination?.next_uri || null
    }
    return accounts.filter((a) => a.type === 'fiat' && (a.currency?.code || a.currency) === 'USD')
}

// rows: [{ type: 'deposit'|'withdrawal', amount: Number|String, createdAt: ISO string }]
// createdAt is converted to Chicago local time in SQL, so every writer
// stores the exact same value for the same Coinbase timestamp.
// Returns the rows actually inserted (conflicts are skipped silently).
async function insertTransfers(db, rows) {
    const inserted = []
    for (const r of rows) {
        // WHERE NOT EXISTS skips the row before an id is drawn (a bare
        // ON CONFLICT would burn an identity value every minute for every
        // recent transfer). ON CONFLICT DO NOTHING still covers the race of
        // two overlapping runs inserting the same row at once.
        const res = await db.query(
            `INSERT INTO usd_transfer (type, amount, date)
             SELECT v.type, v.amount, v.date
             FROM (SELECT $1::text AS type,
                          round($2::numeric, 2) AS amount,
                          ($3::timestamptz AT TIME ZONE 'America/Chicago') AS date) v
             WHERE NOT EXISTS (SELECT 1 FROM usd_transfer u
                               WHERE u.type = v.type AND u.amount = v.amount AND u.date = v.date)
             ON CONFLICT (type, amount, date) DO NOTHING
             RETURNING id, type, amount, date`,
            [r.type, String(r.amount), r.createdAt]
        )
        if (res.rows[0]) inserted.push(res.rows[0])
    }
    return inserted
}

// Newest-first ledger rows created within LEDGER_WINDOW_MS. Stops paging
// at the first row older than the window.
async function recentLedger(accountId, now) {
    const out = []
    let next = `/v2/accounts/${accountId}/transactions?limit=25&order=desc`
    while (next) {
        const page = await v2Get(next)
        let reachedOld = false
        for (const t of page.data || []) {
            if (now - Date.parse(t.created_at) > LEDGER_WINDOW_MS) { reachedOld = true; break }
            out.push(t)
        }
        next = reachedOld ? null : (page.pagination?.next_uri || null)
    }
    return out
}

async function collectRecent(accountId, now) {
    const candidates = []
    const ledger = await recentLedger(accountId, now)
    for (const { kind, endpoint, ledgerType } of KINDS) {
        const page = await v2Get(`/v2/accounts/${accountId}/${endpoint}?limit=100&order=desc`)
        const records = page.data || []

        // Records that completed (or were created) inside the record window.
        // This is what catches "created earlier, completed later".
        for (const r of records) {
            if (r.status !== 'completed') continue
            const touched = Math.max(Date.parse(r.updated_at || 0) || 0, Date.parse(r.created_at) || 0)
            if (now - touched <= RECORD_WINDOW_MS) {
                candidates.push({ type: kind, amount: Math.abs(Number(r.amount?.amount)), createdAt: r.created_at })
            }
        }

        // Ledger rows in the 2-minute window, mapped to their record's created_at.
        for (const t of ledger) {
            if (t.type !== ledgerType || t.status !== 'completed') continue
            const amt = Math.abs(Number(t.amount?.amount))
            const tAt = Date.parse(t.created_at)
            const rec = records.find((r) => r.status === 'completed'
                && Math.abs(Math.abs(Number(r.amount?.amount)) - amt) < 0.005
                && Math.abs(Date.parse(r.created_at) - tAt) <= MATCH_WINDOW_MS)
            if (!rec) {
                console.log(`usdTransferSync WARNING: ${ledgerType} ${t.id} $${amt} has no matching ${kind} record; using ledger created_at`)
            }
            candidates.push({ type: kind, amount: amt, createdAt: rec ? rec.created_at : t.created_at })
        }
    }
    return candidates
}

// Called once per bot run from index.js. Never throws.
async function syncRecent(db) {
    try {
        const now = Date.now()
        const accounts = await listUsdAccounts()
        let candidates = []
        for (const acct of accounts) {
            candidates = candidates.concat(await collectRecent(acct.id, now))
        }
        const inserted = await insertTransfers(db, candidates)
        for (const r of inserted) {
            console.log(`USD transfer recorded: ${r.type} $${r.amount} (usd_transfer id ${r.id})`)
        }
        return inserted
    } catch (error) {
        console.log('usdTransferSync.syncRecent() ERROR', error?.message || error)
        return []
    }
}

module.exports = { syncRecent, insertTransfers, listUsdAccounts }
