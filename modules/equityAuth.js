// Equity ETFs use a separate Coinbase API key from crypto.
// modules/config.js stays the ES256 key that trades spot. This key is Ed25519
// and lives outside the repo (mode 600) so it is never committed.
// Default path is the mini user's home: ~/.coinage-equity-key.json
// (on this machine that is /Volumes/2TBSSD/theodorecrossX, not /Users/theodorecross).
const fs = require('fs')
const os = require('os')
const path = require('path')
const crypto = require('crypto')
const axios = require('axios')

const KEY_PATH = process.env.EQUITY_KEY_PATH || path.join(os.homedir(), '.coinage-equity-key.json')
// BLOX, used only to read equity_product_details (session / full-close). Not an order.
const SESSION_PRODUCT_ID = 'b00c6138f30e9f64073251d311d38324de73a36acfd22867427b293adc143d3c'

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

// Weekend full close, holiday full close, or anything that is not the
// regular session. Market orders are only valid in EQUITY_TRADING_SESSION_NORMAL.
// A closed result must not place an order and must not reserve USD.
function interpretEquitySession(product) {
    const details = product?.equity_product_details || {}
    const day = details.trading_day_info || {}
    const weekday = new Intl.DateTimeFormat('en-US', {
        timeZone: 'America/Chicago',
        weekday: 'short',
    }).format(new Date())
    const weekend = weekday === 'Sat' || weekday === 'Sun'
    const fullClose = day.trade_date_type === 'TRADE_DATE_TYPE_FULL_CLOSE'
    const normal = details.current_session === 'EQUITY_TRADING_SESSION_NORMAL'
    const windows = day.trading_sessions || []
    const normalWindow = windows.find((w) => w.session_type === 'EQUITY_TRADING_SESSION_NORMAL')
    let inWindow = true
    if (normalWindow?.session_start_time && normalWindow?.session_end_time) {
        const now = Date.now()
        inWindow = now >= Date.parse(normalWindow.session_start_time)
            && now < Date.parse(normalWindow.session_end_time)
    }
    const halted = details.trading_halted === true
    const open = !weekend && !fullClose && normal && inWindow && !halted
    let reason = 'open'
    if (weekend) reason = 'weekend full close'
    else if (fullClose) reason = `full close${day.holiday_name ? ` (${day.holiday_name})` : ''}`
    else if (halted) reason = 'trading halted'
    else if (!normal) reason = `session ${details.current_session || 'unknown'}`
    else if (!inWindow) reason = 'outside NORMAL window'
    return {
        open,
        reason,
        tradeDateType: day.trade_date_type || null,
        currentSession: details.current_session || null,
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

// Market buy for exactly quoteUsd. No retail_portfolio_id: the equity key's
// default portfolio is implicit, and setting it is not part of this order.
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
            equity_trading_session: 'EQUITY_TRADING_SESSION_NORMAL',
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

module.exports = {
    KEY_PATH,
    interpretEquitySession,
    equitySession,
    isClosedMarket,
    createMarketBuy,
    readFill,
}
