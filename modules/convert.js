// modules/convert.js -- USD <-> USDC convert helper (Advanced Trade "Convert").
//
// 2026-10-07: built on request, BUILD ONLY. Nothing in the bot calls this:
// index.js (the every-minute cron) does NOT require this file, so it never
// runs on its own. The only way to use it is by hand through
// scripts/convert.js, and money only moves when that script is given
// --commit.
//
// How a Coinbase convert works (checked against docs.cdp.coinbase.com,
// Advanced Trade REST API > Converts, 2026-10-07):
//   1. POST /api/v3/brokerage/convert/quote           -> creates a quote.
//      It only prices the convert: the docs describe the commit call, not
//      the quote, as the step that executes the trade. An uncommitted quote
//      just expires. Live test 2026-10-07: a $0.25 USD->USDC quote came back
//      rate 1, fee 0, status TRADE_STATUS_UNSPECIFIED, and 20 s later the
//      USD and USDC balances were unchanged and the trade was still
//      UNSPECIFIED (never committed, nothing moved).
//   2. POST /api/v3/brokerage/convert/trade/{trade_id} -> commits the quote.
//      THIS is the call that actually moves money.
//   3. GET  /api/v3/brokerage/convert/trade/{trade_id}?from_account=&to_account=
//      -> reads the trade back (status CREATED / STARTED / COMPLETED /
//      CANCELED).
// Per Coinbase, convert is supported for USDC-USD (both ways), PYUSD-USD,
// EURC-EUR and PYUSD-USDC. USD <-> USDC is 1:1 with no fee.
//
// from_account / to_account: per the docs these are the CURRENCY of each
// account ("USD", "USDC"), not account uuids. Tested live 2026-10-07:
// passing the Default portfolio's USD / USDC account uuids (what the bot's
// old, never-called createTransfer() in coinbaseAuth.js does) is rejected
// with 400 "Unsupported account in this conversion"; passing "USD" /
// "USDC" is accepted. The API key is bound to the Default portfolio, so the
// convert runs against Default's USD / USDC wallets (the live test's
// "$0.29 available" matched Default's free USD). getAccountUuid() is kept
// as a read-only pre-check that both wallets exist in Default and so the
// CLI can show which accounts are involved.
//
// Signing: reuses the exact signer coinbaseAuth.js uses for createLimitOrder
// / cancelOrder (equityAuth.signRequest -> Ed25519 JWT for the Default /
// Primary portfolio key, kept outside the repo). This file has its own tiny
// request wrapper instead of editing coinbaseAuth.js, so the file the live
// cron loads every minute is left untouched.

const axios = require('axios')
const equityAuth = require('./equityAuth.js')

const API = 'https://api.coinbase.com'

// Refuse a convert if we would get back less than this share of what we
// send (USD <-> USDC should be exactly 1:1, so 99.5% leaves room only for
// rounding, never for a real fee or a bad rate).
const MIN_RECEIVE_RATIO = 0.995

// How long to keep checking a committed trade before giving up and
// reporting it as still pending (it may still finish; check it by id).
const POLL_EVERY_MS = 2000
const POLL_MAX_TRIES = 30 // ~60 seconds

function sleep (ms) {
    return new Promise(resolve => setTimeout(resolve, ms))
}

// One signed Advanced Trade request. Same headers and signer as
// coinbaseAuth.js getApiCall(). The JWT is signed over the path WITHOUT the
// query string (that is how getApiCall signs GETs too). Throws on any HTTP
// error with Coinbase's error body attached, so callers can print it.
async function apiRequest (method, path, query = '', body = null) {
    const token = equityAuth.signRequest(method, path)
    try {
        const response = await axios.request({
            method,
            url: `${API}${path}${query}`,
            headers: {
                'Authorization': `Bearer ${token}`,
                'Content-Type': 'application/json',
                'User-Agent': 'Node.js Coinbase Client'
            },
            maxBodyLength: Infinity,
            data: body ? JSON.stringify(body) : undefined
        })
        return response.data
    } catch (error) {
        const detail = error?.response?.data ? JSON.stringify(error.response.data) : error.message
        const err = new Error(`${method} ${path} failed (${error?.response?.status || 'no response'}): ${detail}`)
        err.status = error?.response?.status
        err.body = error?.response?.data
        throw err
    }
}

// Amount helpers. Coinbase returns money as { value: "1.00", currency: "USD" }.
function amt (a) {
    return a && a.value !== undefined ? Number(a.value) : null
}
function fmt (a) {
    return a && a.value !== undefined ? `${a.value} ${a.currency || ''}`.trim() : 'n/a'
}

// getAccountUuid('USD' | 'USDC')
// Lists every account the API key can see (GET /api/v3/brokerage/accounts,
// 250 per page, following the cursor) and returns the uuid of the account
// for that currency in the bot's Default portfolio. The key is bound to
// Default, so it normally only sees Default's accounts; we still match on
// retail_portfolio_id when Coinbase includes it, as a second guard against
// ever picking another portfolio's wallet. Read-only. Throws if not found.
async function getAccountUuid (currency) {
    const want = String(currency).toUpperCase()
    const matches = []
    let cursor = ''
    do {
        const query = `?limit=250${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`
        const data = await apiRequest('GET', '/api/v3/brokerage/accounts', query)
        for (const acct of data.accounts || []) {
            if (acct.currency === want) matches.push(acct)
        }
        cursor = data.has_next ? data.cursor : ''
    } while (cursor)

    const inDefault = matches.filter(a =>
        !a.retail_portfolio_id || a.retail_portfolio_id === equityAuth.DEFAULT_PORTFOLIO_ID)
    if (inDefault.length === 0) {
        throw new Error(`getAccountUuid(${want}): no ${want} account in the Default portfolio`)
    }
    if (inDefault.length > 1) {
        throw new Error(`getAccountUuid(${want}): ${inDefault.length} ${want} accounts found, refusing to guess`)
    }
    return inDefault[0].uuid
}

// Pulls the parts of a convert trade we care about into a flat object.
// sent     = what leaves the from account (trade.total, incl. any fee)
// received = what lands in the to account (trade.amount, in to-currency)
// rate     = received / sent, so 1.0 means a perfect 1:1 convert
function summarizeTrade (trade) {
    const sent = amt(trade.total) ?? amt(trade.user_entered_amount)
    const received = amt(trade.amount)
    return {
        tradeId: trade.id,
        status: trade.status,
        from: trade.source_currency || trade.user_entered_amount?.currency,
        to: trade.target_currency || trade.amount?.currency,
        entered: fmt(trade.user_entered_amount),
        sent: fmt(trade.total),
        received: fmt(trade.amount),
        subtotal: fmt(trade.subtotal),
        totalFee: fmt(trade.total_fee?.amount),
        totalFeeValue: amt(trade.total_fee?.amount) || 0,
        fees: (trade.fees || []).map(f => `${f.title || f.label || 'fee'}: ${fmt(f.amount)}`),
        exchangeRate: fmt(trade.exchange_rate),
        effectiveRate: sent && received ? received / sent : null,
        sentValue: sent,
        receivedValue: received,
        cancellationReason: trade.cancellation_reason?.message || null
    }
}

// createConvertQuote('USD', 'USDC', 5)
// Asks Coinbase for a quote (POST /api/v3/brokerage/convert/quote, body
// {from_account: 'USD', to_account: 'USDC', amount: '5.00'}). amount is in
// the FROM currency. First confirms both wallets exist in Default
// (getAccountUuid). Returns the summary above plus fromAccount / toAccount
// (the currency codes the commit and status calls must repeat) and the
// wallet uuids for display. Creating a quote does NOT move money; only
// commitConvertTrade does.
// Coinbase can answer HTTP 200 with an EMPTY trade id and a
// cancellation_reason instead of an error (e.g. "$0.29 available" when the
// USD wallet's free balance is too small); that is thrown as an error here.
async function createConvertQuote (fromCurrency, toCurrency, amount) {
    const n = Number(amount)
    if (!Number.isFinite(n) || n <= 0) throw new Error(`createConvertQuote: bad amount "${amount}"`)
    const fromAccount = String(fromCurrency).toUpperCase()
    const toAccount = String(toCurrency).toUpperCase()
    const fromUuid = await getAccountUuid(fromAccount)
    const toUuid = await getAccountUuid(toAccount)
    const data = await apiRequest('POST', '/api/v3/brokerage/convert/quote', '', {
        from_account: fromAccount,
        to_account: toAccount,
        amount: n.toFixed(2)
    })
    const trade = data?.trade || {}
    if (!trade.id) {
        const why = trade.cancellation_reason?.message || JSON.stringify(data)
        const err = new Error(`createConvertQuote: Coinbase refused the quote: ${why}`)
        err.cancellationReason = trade.cancellation_reason || null
        throw err
    }
    return { ...summarizeTrade(trade), fromAccount, toAccount, fromUuid, toUuid, raw: trade }
}

// commitConvertTrade(tradeId, fromAccount, toAccount)
// Executes a quote (POST /api/v3/brokerage/convert/trade/{trade_id}, body
// {from_account, to_account} = the same currency codes used for the quote). THIS MOVES MONEY. Only the convertXxx
// wrappers below call it, and only after the quote passes the sanity check.
async function commitConvertTrade (tradeId, fromAccount, toAccount) {
    const data = await apiRequest('POST', `/api/v3/brokerage/convert/trade/${encodeURIComponent(tradeId)}`, '', {
        from_account: fromAccount,
        to_account: toAccount
    })
    return summarizeTrade(data.trade || {})
}

// getConvertTrade(tradeId, fromAccount, toAccount)
// Reads a convert trade back to check its status
// (GET /api/v3/brokerage/convert/trade/{trade_id}?from_account=&to_account=,
// both required, same currency codes as the quote). Read-only.
async function getConvertTrade (tradeId, fromAccount, toAccount) {
    const query = `?from_account=${encodeURIComponent(fromAccount)}&to_account=${encodeURIComponent(toAccount)}`
    const data = await apiRequest('GET', `/api/v3/brokerage/convert/trade/${encodeURIComponent(tradeId)}`, query)
    return summarizeTrade(data.trade || {})
}

// Sanity check a quote before committing it. Returns a list of problems
// (empty = OK). We refuse if we'd receive < 99.5% of what we send, if the
// currencies are not the ones we asked for, or if any fee is charged.
function checkQuote (q, fromCurrency, toCurrency) {
    const problems = []
    if (q.from && q.from !== fromCurrency) problems.push(`quote is from ${q.from}, expected ${fromCurrency}`)
    if (q.to && q.to !== toCurrency) problems.push(`quote is to ${q.to}, expected ${toCurrency}`)
    if (!q.sentValue || !q.receivedValue) problems.push('quote is missing the sent or received amount')
    else if (q.receivedValue < q.sentValue * MIN_RECEIVE_RATIO) {
        problems.push(`would receive ${q.received} for ${q.sent} (${(q.effectiveRate * 100).toFixed(3)}%, need >= ${MIN_RECEIVE_RATIO * 100}%)`)
    }
    if (q.totalFeeValue > 0.01) problems.push(`quote charges a fee of ${q.totalFee}`)
    return problems
}

// convert(from, to, amount, { commit })
// The full flow: quote -> sanity check -> (only if commit === true) commit
// -> poll status until COMPLETED or CANCELED (or ~60 s). Without
// commit:true it stops after the quote and moves nothing.
async function convert (fromCurrency, toCurrency, amount, { commit = false } = {}) {
    const quote = await createConvertQuote(fromCurrency, toCurrency, amount)
    const problems = checkQuote(quote, fromCurrency, toCurrency)
    const result = { quote, problems, committed: false, final: null }
    if (problems.length) return result          // never commit a bad quote
    if (commit !== true) return result          // quote only, nothing moved

    result.committed = true
    let status = await commitConvertTrade(quote.tradeId, quote.fromAccount, quote.toAccount)
    for (let i = 0; i < POLL_MAX_TRIES; i++) {
        if (status.status === 'TRADE_STATUS_COMPLETED' || status.status === 'TRADE_STATUS_CANCELED') break
        await sleep(POLL_EVERY_MS)
        status = await getConvertTrade(quote.tradeId, quote.fromAccount, quote.toAccount)
    }
    result.final = status
    return result
}

// Convenience wrappers for the two directions the bot cares about.
function convertUsdToUsdc (amount, opts) { return convert('USD', 'USDC', amount, opts) }
function convertUsdcToUsd (amount, opts) { return convert('USDC', 'USD', amount, opts) }

module.exports = {
    getAccountUuid,
    createConvertQuote,
    commitConvertTrade,
    getConvertTrade,
    checkQuote,
    convert,
    convertUsdToUsdc,
    convertUsdcToUsd,
    MIN_RECEIVE_RATIO
}
