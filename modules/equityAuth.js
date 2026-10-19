// Default (Primary) portfolio key. Ed25519, stored outside the repo (mode 600)
// so the secret is never committed. Crypto (coinbaseAuth via signRequest) and
// equity ETFs both sign with this key. The tedTosterone portfolio is going
// away; modules/config.js still holds that old ES256 key and is not used here.
// Default path is the mini user's home: ~/.coinage-equity-key.json
// (on this machine that is /Volumes/2TBSSD/theodorecrossX, not /Users/theodorecross).
// EQUITY_KEY_PATH overrides that path.
const fs = require('fs')
const os = require('os')
const path = require('path')
const crypto = require('crypto')
const axios = require('axios')

const KEY_PATH = process.env.EQUITY_KEY_PATH || path.join(os.homedir(), '.coinage-equity-key.json')
// BLOX, used only to read equity_product_details (session / full-close). Not an order.
const SESSION_PRODUCT_ID = 'b00c6138f30e9f64073251d311d38324de73a36acfd22867427b293adc143d3c'

// Default (Primary) portfolio. This Ed25519 key is bound to this uuid, so
// crypto requests signed with signRequest see Default, not tedTosterone.
// Equity code passes this id when it reads that portfolio's breakdown.
const DEFAULT_PORTFOLIO_ID = '54a3cffc-9b34-5ee3-973a-5dc323f6bb1d'

let cachedKey

function loadKey() {
    if (cachedKey) return cachedKey
    const parsed = JSON.parse(fs.readFileSync(KEY_PATH, 'utf8'))
    if (!parsed.name || !parsed.privateKey) {
        throw new Error('equity key JSON missing name or privateKey')
    }
    // CDP Ed25519 secret is 64 bytes: 32-byte seed || public key.
    const raw = Buffer.from(parsed.privateKey, 'base64')
    const seed = raw.length === 64 ? raw.subarray(0, 32) : raw
    const pkcs8 = Buffer.concat([
        Buffer.from('302e020100300506032b657004220420', 'hex'),
        seed,
    ])
    cachedKey = {
        name: parsed.name,
        privateKey: crypto.createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' }),
    }
    return cachedKey
}

// jsonwebtoken 9.0.3 rejects algorithm "EdDSA", so sign the JWT with node crypto.
// Claims match the crypto key's tokenate(): iss coinbase-cloud, aud advanced-trade.
function signJwt(method, requestPath) {
    const key = loadKey()
    const now = Math.floor(Date.now() / 1000)
    const b64url = (buf) => Buffer.from(buf).toString('base64url')
    const header = {
        alg: 'EdDSA',
        kid: key.name,
        nonce: crypto.randomBytes(16).toString('hex'),
        typ: 'JWT',
    }
    const payload = {
        iss: 'coinbase-cloud',
        nbf: now,
        exp: now + 120,
        sub: key.name,
        aud: ['advanced-trade'],
        uri: `${method} api.coinbase.com${requestPath}`,
    }
    const input = b64url(JSON.stringify(header)) + '.' + b64url(JSON.stringify(payload))
    const sig = crypto.sign(null, Buffer.from(input), key.privateKey)
    return input + '.' + b64url(sig)
}

async function equityRequest(method, requestPath, query, data) {
    const token = signJwt(method, requestPath)
    const response = await axios.request({
        method,
        url: `https://api.coinbase.com${requestPath}${query || ''}`,
        headers: {
            Authorization: `Bearer ${token}`,
            'Content-Type': 'application/json',
        },
        data: data || undefined,
        timeout: 30000,
        // Callers inspect status themselves. Never throw the axios error:
        // its config carries the bearer token.
        validateStatus: () => true,
    })
    return response
}

// 2026-10-11 (all-session trading): the equity session is OPEN in ANY
// session Coinbase reports as tradable -- PRE_MARKET, NORMAL, AFTER_HOURS,
// OVERNIGHT, MULTI_SESSION -- not only NORMAL. The user wants ETF orders
// going out as often as Coinbase allows.
//
// Hours are 100% API-driven. Nothing here hard-codes a clock or a weekday:
// current_session says which session Coinbase is in right now, and
// trading_day_info.trading_sessions gives that day's windows
// (session_start_time / session_end_time, plus support_fractional and
// limit_only per window). When the US 23/5 schedule goes live (target
// Dec 6, 2026) the new/longer OVERNIGHT windows simply show up in this
// same response and the bot trades them with no code change.
//
// Why the old Chicago weekday check is gone: Coinbase's OVERNIGHT session
// for Monday's trade date already starts Sunday ~7 PM CT (00:00Z Monday),
// which a "Sat/Sun = closed" rule would block. Weekends / holidays are
// still closed via trade_date_type FULL_CLOSE (holiday_name "WEEKEND") and
// current_session UNKNOWN.
//
// Order rules (Coinbase): only NORMAL takes market / fractional / notional
// orders. Every other session takes whole-share LIMIT orders only. The
// window's own limit_only / support_fractional flags are used when present.
// A closed result must not place an order and must not reserve USD.
const OPEN_SESSIONS = new Set([
    'EQUITY_TRADING_SESSION_PRE_MARKET',
    'EQUITY_TRADING_SESSION_NORMAL',
    'EQUITY_TRADING_SESSION_AFTER_HOURS',
    'EQUITY_TRADING_SESSION_OVERNIGHT',
    'EQUITY_TRADING_SESSION_MULTI_SESSION',
])
const NORMAL_SESSION = 'EQUITY_TRADING_SESSION_NORMAL'

function inWindow(w, now) {
    const start = Date.parse(w?.session_start_time)
    const end = Date.parse(w?.session_end_time)
    return Number.isFinite(start) && Number.isFinite(end) && now >= start && now < end
}

function interpretEquitySession(product, nowMs) {
    const details = product?.equity_product_details || {}
    const day = details.trading_day_info || {}
    const now = Number.isFinite(nowMs) ? nowMs : Date.now()
    const session = details.current_session || null
    const fullClose = day.trade_date_type === 'TRADE_DATE_TYPE_FULL_CLOSE'
    const halted = details.trading_halted === true
    const disabled = product?.trading_disabled === true
    const knownSession = OPEN_SESSIONS.has(session)
    const windows = day.trading_sessions || []
    // The window for the session Coinbase says we are in. MULTI_SESSION (or
    // any session with no same-named window) falls back to whichever
    // window contains now. No windows at all (field missing) = trust
    // current_session alone.
    const window = windows.find((w) => w.session_type === session && inWindow(w, now))
        || windows.find((w) => inWindow(w, now))
        || null
    const insideWindow = windows.length === 0 ? true : window != null
    const open = !fullClose && !halted && !disabled && knownSession && insideWindow
    // Market / fractional only when the live session is NORMAL and the
    // window (if any) allows it; everything else is whole-share limit only.
    const isNormal = session === NORMAL_SESSION
    const limitOnly = !isNormal || window?.limit_only === true
    const fractional = isNormal && window?.support_fractional !== false
    let reason = `open (${session}${window ? ` until ${window.session_end_time}` : ''}${limitOnly ? ', whole-share limits only' : ''})`
    if (fullClose) reason = `full close${day.holiday_name ? ` (${day.holiday_name})` : ''}`
    else if (halted) reason = 'trading halted'
    else if (disabled) reason = 'trading disabled'
    else if (!knownSession) reason = `session ${session || 'unknown'}`
    else if (!insideWindow) reason = `outside ${session} window`
    return {
        open,
        reason,
        tradeDateType: day.trade_date_type || null,
        // Passed straight into equity_order_metadata.equity_trading_session.
        currentSession: open ? session : null,
        rawSession: session,
        isNormal: open && isNormal,
        limitOnly,
        fractional: open && fractional,
        sessionEnd: window?.session_end_time || null,
    }
}

async function equitySession() {
    const response = await equityRequest(
        'GET',
        `/api/v3/brokerage/products/${SESSION_PRODUCT_ID}`,
        ''
    )
    if (response.status !== 200) {
        const message = typeof response.data === 'string'
            ? response.data.slice(0, 200)
            : (response.data?.message || response.data?.error || `HTTP ${response.status}`)
        return { open: false, reason: `session check failed: ${message}` }
    }
    const product = response.data?.product || response.data
    return interpretEquitySession(product)
}

// Closed-market rejects must not count as today's buy (Monday still buys).
function isClosedMarket(payload) {
    const blob = JSON.stringify(payload || {}).toLowerCase()
    return blob.includes('order queueing is not available')
        || blob.includes('untradable_product')
        || blob.includes('untradable product')
}

// 2026-10-06: KEPT for the once-per-Chicago-day morning $1 market buy of
// each enabled ETF (index.js buildEtfPlan). The per-minute market dip
// re-buys and the 2:45 PM market catch-up that also used it are retired.
// Market buy for exactly quoteUsd. No retail_portfolio_id: the equity key's
// default portfolio is implicit, and setting it is not part of this order.
// Market orders are only valid in NORMAL (Coinbase rule), so the session
// is always NORMAL here; index.js only sends market buys in NORMAL.
async function createMarketBuy(productId, quoteUsd, clientOrderId) {
    const quote = Number(quoteUsd).toFixed(2)
    const body = {
        client_order_id: clientOrderId,
        product_id: productId,
        side: 'BUY',
        order_configuration: {
            market_market_ioc: {
                quote_size: quote,
            },
        },
        equity_order_metadata: {
            equity_trading_session: NORMAL_SESSION,
            displayed_order_config: 'MARKET_GFD',
        },
    }
    const response = await equityRequest('POST', '/api/v3/brokerage/orders', '', body)
    const data = response.data
    if (response.status === 200 && data?.success) return data
    const message = data?.error_response?.message
        || data?.message
        || (typeof data === 'string' ? data.slice(0, 300) : `HTTP ${response.status}`)
    return {
        success: false,
        error_response: {
            message,
            error: data?.error_response?.error || data?.error,
            preview_failure_reason: data?.error_response?.preview_failure_reason,
            error_details: data?.error_response?.error_details,
        },
    }
}

// Confirm the $1 actually filled. Unknown (GET failed) is treated as filled
// by the caller so we never send a second quote_usd the same day.
async function readFill(orderId) {
    const response = await equityRequest('GET', `/api/v3/brokerage/orders/historical/${orderId}`, '')
    if (response.status !== 200) return { unknown: true }
    const order = response.data?.order || response.data
    return {
        unknown: false,
        status: order?.status || null,
        filledSize: parseFloat(order?.filled_size || 0) || 0,
        filledQuote: parseFloat(order?.filled_value || order?.total_value_after_fees || 0) || 0,
        raw: {
            status: order?.status,
            filled_size: order?.filled_size,
            filled_value: order?.filled_value,
        },
    }
}


// 2026-10-06 limit ladder: one resting LIMIT buy per enabled ticker,
// alongside the morning market buy above.
//
// Why GTC and not GTD: the spec asked for limit_limit_gtd with end_time =
// now + 12h, but Coinbase rejects GTD for equities ("only market and limit
// orders are supported for CCM", HTTP 400, tested 2026-10-06 on BLOX).
// The equity API only takes limit_limit_gtc with displayed_order_config
// LIMIT_GFD or LIMIT_GTC. So we place LIMIT_GTC and the bot emulates the
// expiry: etf_buy.expires_at = placed + config.etf_limit_ttl_hours, and
// index.js syncEtfLimitOrders cancels the order once that time passes.
// 2026-10-11: session = the LIVE current_session from equitySession()
// (PRE_MARKET / NORMAL / AFTER_HOURS / OVERNIGHT / MULTI_SESSION), not a
// hard-coded NORMAL. Outside NORMAL Coinbase only accepts whole-share
// base_size, so a fractional size is refused here before it is sent
// (index.js sizes non-NORMAL limits to whole shares).
async function createLimitBuy(productId, baseSize, limitPrice, clientOrderId, session) {
    const tradingSession = OPEN_SESSIONS.has(session) ? session : NORMAL_SESSION
    if (tradingSession !== NORMAL_SESSION && !Number.isInteger(Number(baseSize))) {
        return {
            success: false,
            error_response: { message: `fractional base_size ${baseSize} not allowed in ${tradingSession} (whole shares only)` },
        }
    }
    const body = {
        client_order_id: clientOrderId,
        product_id: productId,
        side: 'BUY',
        order_configuration: {
            limit_limit_gtc: {
                base_size: String(baseSize),
                limit_price: String(limitPrice),
                // Not post-only: if the price already fell through the
                // limit, fill now (at or under the limit) instead of being
                // rejected and re-placed every minute.
                post_only: false,
            },
        },
        equity_order_metadata: {
            equity_trading_session: tradingSession,
            displayed_order_config: 'LIMIT_GTC',
        },
    }
    const response = await equityRequest('POST', '/api/v3/brokerage/orders', '', body)
    const data = response.data
    if (response.status === 200 && data?.success) return data
    const message = data?.error_response?.message
        || data?.message
        || (typeof data === 'string' ? data.slice(0, 300) : `HTTP ${response.status}`)
    return {
        success: false,
        error_response: {
            message,
            error: data?.error_response?.error || data?.error,
            preview_failure_reason: data?.error_response?.preview_failure_reason,
            error_details: data?.error_response?.error_details,
            // 2026-10-19 (Theodore): pass through the other reason fields too.
            new_order_failure_reason: data?.error_response?.new_order_failure_reason,
        },
        failure_reason: data?.failure_reason || data?.success_response?.failure_reason,
    }
}

// One order's live state. ok=false (HTTP error) means "unknown": callers
// must treat the order as still open so a second limit is never stacked.
// avgFilledPrice is Coinbase's own VWAP, used only when the fills table
// has not caught up yet (fills.price is preferred).
async function readOrder(orderId) {
    const response = await equityRequest('GET', `/api/v3/brokerage/orders/historical/${orderId}`, '')
    if (response.status !== 200) return { ok: false, reason: `HTTP ${response.status}` }
    const order = response.data?.order || response.data || {}
    return {
        ok: true,
        status: order.status || null,
        filledSize: parseFloat(order.filled_size || 0) || 0,
        filledValue: parseFloat(order.filled_value || 0) || 0,
        avgFilledPrice: parseFloat(order.average_filled_price || 0) || null,
    }
}

// Cancel one order. ok=true only when Coinbase confirms the cancel.
async function cancelOrder(orderId) {
    const response = await equityRequest('POST', '/api/v3/brokerage/orders/batch_cancel', '', { order_ids: [orderId] })
    const result = response.data?.results?.[0]
    if (response.status === 200 && result?.success === true) return { ok: true, reason: null }
    return { ok: false, reason: result?.failure_reason || response.data?.message || `HTTP ${response.status}` }
}

// Spendable USD in the Default portfolio only. That breakdown lists more
// than one USD row (fiat, derivatives cash, prediction-markets cash). The
// first row is not the trading wallet, so sum available_to_trade_fiat on
// every USD row. Cash on hold and cash that cannot trade (available 0)
// stays out. A non-200 does not fall back to the crypto key: if Default
// cannot be read, the caller skips the ETF buy.
function amountValue(value) {
    if (value == null || value === '') return null
    if (typeof value === 'number') return Number.isFinite(value) ? value : null
    if (typeof value === 'string') {
        const n = Number(value)
        return Number.isFinite(n) ? n : null
    }
    if (typeof value === 'object') return amountValue(value.value)
    return null
}

function sumUsdAvailable(positions) {
    let available = 0
    for (const pos of positions || []) {
        if (pos.asset !== 'USD') continue
        const n = Number(pos.available_to_trade_fiat)
        if (!Number.isFinite(n)) {
            return { ok: false, available: 0, reason: 'USD available missing' }
        }
        available += n
    }
    return { ok: true, available }
}

// 2026-10-07: spendable USDC in the Default portfolio, for ETFs bought on
// their USDC-quoted product (etf.usdc_product_id). Same breakdown as USD
// above; USDC is one ACCOUNT_TYPE_WALLET row (asset 'USDC'). Uses
// available_to_trade_crypto (USDC units, which is what a USDC order spends)
// and falls back to available_to_trade_fiat (1:1). Held USDC stays out.
// No USDC row = 0 spendable, not an error. Kept separate from
// sumUsdAvailable on purpose: USD and USDC are budgeted as two pots, and
// nothing that reads USD (crypto buy gates, the USD sweep reserve) sees USDC.
function sumUsdcAvailable(positions) {
    let available = 0
    for (const pos of positions || []) {
        if (pos.asset !== 'USDC') continue
        let n = Number(pos.available_to_trade_crypto)
        if (!Number.isFinite(n)) n = Number(pos.available_to_trade_fiat)
        if (!Number.isFinite(n)) {
            return { ok: false, available: 0, reason: 'USDC available missing' }
        }
        available += n
    }
    return { ok: true, available }
}

// One portfolio read for the reserve. USD is the same sum defaultUsdAvailable
// uses. equity_positions is where Coinbase reports stock/ETF shares,
// average entry, and unrealized_pnl. An empty list means no equity shares,
// which is what lets a never-held ticker (XDTE) buy its first $1.
async function equitySnapshot() {
    try {
        const response = await equityRequest(
            'GET',
            `/api/v3/brokerage/portfolios/${DEFAULT_PORTFOLIO_ID}`,
            '?currency=USD'
        )
        if (response.status !== 200) {
            return { ok: false, available: 0, usdcAvailable: 0, positions: [], reason: `HTTP ${response.status}` }
        }
        const breakdown = response.data?.breakdown || {}
        const usd = sumUsdAvailable(breakdown.spot_positions)
        if (!usd.ok) {
            return { ok: false, available: 0, usdcAvailable: 0, positions: [], reason: usd.reason }
        }
        const positions = (breakdown.equity_positions || []).map((pos) => ({
            cbrn: pos.cbrn || null,
            shares: amountValue(pos.total_balance_equity),
            // 2026-10-17 (Theodore): dollar value; index.js matches ETF by fiat/shares price.
            fiat: amountValue(pos.total_balance_fiat),
            averageEntry: amountValue(pos.average_entry_price),
            unrealizedPnl: amountValue(pos.unrealized_pnl),
        }))
        // 2026-10-07: USDC pot for USDC-quoted ETF buys. An unreadable USDC
        // row does not fail the snapshot (USD buys keep working); it reads
        // as 0 USDC, so USDC-capable ETFs fall back to USD or skip.
        const usdc = sumUsdcAvailable(breakdown.spot_positions)
        return {
            ok: true,
            available: usd.available,
            usdcAvailable: usdc.ok ? usdc.available : 0,
            usdcReason: usdc.ok ? null : usdc.reason,
            positions,
            reason: null,
        }
    } catch (error) {
        return { ok: false, available: 0, usdcAvailable: 0, positions: [], reason: error?.message || 'request failed' }
    }
}

async function defaultUsdAvailable() {
    try {
        const snap = await equitySnapshot()
        if (!snap.ok) return { ok: false, available: 0, usdcAvailable: 0, reason: snap.reason }
        // available stays USD only (unchanged meaning); usdcAvailable is the
        // separate USDC pot (2026-10-07).
        return { ok: true, available: snap.available, usdcAvailable: snap.usdcAvailable, usdcReason: snap.usdcReason }
    } catch (error) {
        return { ok: false, available: 0, usdcAvailable: 0, reason: error?.message || 'request failed' }
    }
}

// Product rules for sizing a limit: increments, the $1 fractional notional
// minimum, and whether a fractional buy is allowed at all. A product that
// is liquidate_only (sell-only, e.g. YETH on 2026-10-06), not fractionable,
// halted, or has buy_fractional_shares=false is reported as not buyable so
// the caller skips and logs it instead of sending an order that must fail.
async function equityProduct(productId) {
    try {
        const response = await equityRequest('GET', `/api/v3/brokerage/products/${productId}`, '')
        if (response.status !== 200) return { ok: false, reason: `HTTP ${response.status}` }
        const p = response.data?.product || response.data || {}
        const d = p.equity_product_details || {}
        const flags = p.equity_trading_flags || {}
        let blocked = null
        if (p.trading_disabled || p.is_disabled || p.cancel_only || p.view_only) blocked = 'product disabled / cancel-only / view-only'
        else if (d.liquidate_only === true) blocked = 'liquidate_only (sell-only)'
        else if (flags.buy_enabled === false) blocked = 'buy disabled'
        else if (d.trading_halted === true) blocked = 'trading halted'
        // 2026-10-11: fractional is only needed for NORMAL-session fractional
        // limits. Outside NORMAL every limit is whole shares, so index.js
        // ignores this block there (wholeBlocked = can't even buy whole).
        const fractionalBlocked = (d.fractionable === false || flags.buy_fractional_shares === false)
            ? 'whole shares only (not fractionable)' : null
        const wholeBlocked = blocked || (flags.buy_whole_shares === false ? 'whole-share buys disabled' : null)
        return {
            ok: true,
            blocked: blocked || fractionalBlocked,
            wholeBlocked,
            baseIncrement: p.base_increment || '0.00001',
            priceIncrement: p.price_increment || p.quote_increment || '0.01',
            quoteMinSize: Number(p.quote_min_size) || 0,
            notionalMin: Number(d.fractional_notional_min_size) || 0,
            bestBid: amountValue(p.best_bid_price),
        }
    } catch (error) {
        return { ok: false, reason: error?.message || 'request failed' }
    }
}

// Coinbase top-of-book bid for one product, or null. On these equity
// products it is usually blank (same as product.best_bid_price), in which
// case the caller falls back to the Alpaca IEX bid.
async function bestBid(productId) {
    try {
        const response = await equityRequest('GET', '/api/v3/brokerage/best_bid_ask', `?product_ids=${productId}`)
        if (response.status !== 200) return null
        const book = (response.data?.pricebooks || []).find((b) => b.product_id === productId)
        const bid = amountValue(book?.bids?.[0]?.price)
        return bid != null && bid > 0 ? bid : null
    } catch (error) {
        return null
    }
}

module.exports = {
    KEY_PATH,
    DEFAULT_PORTFOLIO_ID,
    // coinbaseAuth.tokenate calls this so crypto signs as Default / Primary
    // (Ed25519) instead of the tedTosterone ES256 key in config.js.
    signRequest: signJwt,
    interpretEquitySession,
    equitySession,
    OPEN_SESSIONS,
    NORMAL_SESSION,
    isClosedMarket,
    // Morning $1 market buy (kept 2026-10-06).
    createMarketBuy,
    readFill,
    // 2026-10-06 limit ladder. equityPrice (the dip check's Coinbase quote)
    // was removed with the market dip re-buys.
    createLimitBuy,
    readOrder,
    cancelOrder,
    equityProduct,
    bestBid,
    defaultUsdAvailable,
    equitySnapshot,
}
