// Alpaca IEX market data for Coinage ETF dip checks.
//
// Why this exists: Coinbase Advanced Trade often returns blank price / mid /
// bid / ask on equity ETF products even during NORMAL session. Dip rules
// still need a live number, so each bot run (cron: node index.js every
// minute) pulls IEX snapshots for every enabled etf.ticker and upserts
// stock.price under the bare ticker (BLOX, not BLOX-USD). buildEtfPlan
// then falls back to that stock.price when equityPrice() has nothing.
//
// Secrets stay OUT of this repo. Keys are loaded from the Alpaca bot's
// modules/config.js (sibling project on this machine), or from
// APCA_API_KEY_ID / APCA_API_SECRET_KEY env, or ALPACA_CONFIG_PATH.
// Never log key material.

const fs = require('fs')
const os = require('os')
const path = require('path')
const axios = require('axios')

// Same IEX feed the Alpaca politic bot uses. SIP returns 403 on this account.
const DATA_URL = 'https://data.alpaca.markets/v2'
const FEED = 'iex'
// If the last trade is older than this AND there is no usable bid/ask mid,
// treat the price as unavailable rather than inventing one from a stale print.
const STALE_TRADE_MS = 10 * 60 * 1000

// Default: Alpaca politic bot config on this mini. Override with env.
const DEFAULT_ALPACA_CONFIG = path.join(
    '/Volumes/2TBSSD/theodorecrossX',
    'Alpaca Trader',
    'alpaca_trader_politic',
    'modules',
    'config.js'
)

let cachedKeys = null

function loadAlpacaKeys() {
    if (cachedKeys) return cachedKeys

    const envKey = process.env.APCA_API_KEY_ID || process.env.ALPACA_KEY
    const envSecret = process.env.APCA_API_SECRET_KEY || process.env.ALPACA_SECRET
    if (envKey && envSecret) {
        cachedKeys = { key: envKey, secret: envSecret, source: 'env' }
        return cachedKeys
    }

    const configPath = process.env.ALPACA_CONFIG_PATH || DEFAULT_ALPACA_CONFIG
    if (!fs.existsSync(configPath)) {
        throw new Error(
            `Alpaca keys not found (no APCA_API_KEY_ID/APCA_API_SECRET_KEY env, ` +
            `and config missing at ${configPath}). Set ALPACA_CONFIG_PATH or env.`
        )
    }
    // require() the sibling bot's config; do not copy secrets into Coinage.
    // Clear cache so a rotated key file is picked up on the next process
    // (cron starts a fresh node each minute anyway).
    delete require.cache[require.resolve(configPath)]
    const cfg = require(configPath)
    if (!cfg.alpaca_key || !cfg.alpaca_secret) {
        throw new Error(`Alpaca config at ${configPath} missing alpaca_key / alpaca_secret`)
    }
    cachedKeys = { key: cfg.alpaca_key, secret: cfg.alpaca_secret, source: configPath }
    return cachedKeys
}

function authHeaders() {
    const keys = loadAlpacaKeys()
    return {
        'APCA-API-KEY-ID': keys.key,
        'APCA-API-SECRET-KEY': keys.secret,
    }
}

// Prefer mid when both sides of the quote are present and positive.
// Otherwise use the last trade only if it is fresh enough. Never invent.
function pickLivePrice(snapshot, nowMs = Date.now()) {
    const quote = snapshot?.latestQuote || null
    const trade = snapshot?.latestTrade || null
    const bid = Number(quote?.bp)
    const ask = Number(quote?.ap)
    if (Number.isFinite(bid) && Number.isFinite(ask) && bid > 0 && ask > 0) {
        return {
            ok: true,
            price: (bid + ask) / 2,
            source: 'iex_mid',
            tradeAgeMs: trade?.t ? nowMs - Date.parse(trade.t) : null,
        }
    }
    const tradePrice = Number(trade?.p)
    if (!(Number.isFinite(tradePrice) && tradePrice > 0) || !trade?.t) {
        return { ok: false, price: null, source: null, reason: 'no usable quote or trade' }
    }
    const ageMs = nowMs - Date.parse(trade.t)
    if (!Number.isFinite(ageMs) || ageMs > STALE_TRADE_MS) {
        const ageMin = Number.isFinite(ageMs) ? (ageMs / 60000).toFixed(1) : '?'
        return {
            ok: false,
            price: null,
            source: null,
            reason: `stale last trade (${ageMin} min old) and no bid/ask mid`,
        }
    }
    return { ok: true, price: tradePrice, source: 'iex_trade', tradeAgeMs: ageMs }
}

// Batch snapshot for the given symbols. One HTTP call; IEX feed only.
async function fetchIexSnapshots(symbols) {
    const list = [...new Set((symbols || []).map((s) => String(s || '').trim().toUpperCase()).filter(Boolean))]
    if (list.length === 0) return { ok: true, bySymbol: {}, reason: null }
    const url = `${DATA_URL}/stocks/snapshots`
    const response = await axios.get(url, {
        params: { symbols: list.join(','), feed: FEED },
        headers: authHeaders(),
        timeout: 30000,
        validateStatus: () => true,
    })
    if (response.status !== 200) {
        const message = typeof response.data === 'string'
            ? response.data.slice(0, 200)
            : (response.data?.message || response.data?.error || `HTTP ${response.status}`)
        return { ok: false, bySymbol: {}, reason: message }
    }
    return { ok: true, bySymbol: response.data || {}, reason: null }
}

// Insert if the bare ticker is missing; always UPDATE price when a live
// figure was chosen. trading_disabled / historical_finished keep these
// rows out of crypto buy + Coinbase candle historical paths (those join
// %-USD products only for price refresh, but historical picks any
// trading_disabled IS NOT TRUE row).
async function upsertStockPrice(db, ticker, price) {
    const name = String(ticker).toUpperCase()
    const updated = await db.query(
        `UPDATE stock SET price = $2 WHERE name = $1`,
        [name, price]
    )
    if ((updated.rowCount || 0) > 0) return { inserted: false }
    await db.query(
        `INSERT INTO stock (
            name, date_created, price,
            trading_disabled, historical_finished
         ) VALUES (
            $1, CURRENT_DATE, $2,
            TRUE, B'1'
         )`,
        [name, price]
    )
    return { inserted: true }
}

// Drive the whole sync: enabled etf rows → IEX snapshots → stock upsert.
// Adding a new etf row with enabled=true is enough; no code list to edit.
async function syncEnabledEtfStockPrices(db) {
    const listed = await db.query(
        `SELECT ticker FROM etf WHERE enabled ORDER BY ticker`
    )
    const tickers = (listed?.rows || []).map((r) => String(r.ticker).toUpperCase())
    if (tickers.length === 0) {
        console.log('ETF Alpaca sync: no enabled etf rows')
        return { updated: [], skipped: [], error: null }
    }

    let snap
    try {
        snap = await fetchIexSnapshots(tickers)
    } catch (error) {
        const reason = error?.message || 'snapshot request failed'
        console.log(`ETF Alpaca sync ERROR: ${reason}`)
        return { updated: [], skipped: tickers.map((t) => ({ ticker: t, reason })), error: reason }
    }
    if (!snap.ok) {
        console.log(`ETF Alpaca sync ERROR: ${snap.reason}`)
        return {
            updated: [],
            skipped: tickers.map((t) => ({ ticker: t, reason: snap.reason })),
            error: snap.reason,
        }
    }

    const updated = []
    const skipped = []
    const nowMs = Date.now()
    for (const ticker of tickers) {
        const shot = snap.bySymbol[ticker]
        if (!shot) {
            skipped.push({ ticker, reason: 'symbol missing from IEX snapshot response' })
            console.log(`ETF Alpaca sync skip ${ticker}: missing from snapshot`)
            continue
        }
        const picked = pickLivePrice(shot, nowMs)
        if (!picked.ok) {
            skipped.push({ ticker, reason: picked.reason })
            console.log(`ETF Alpaca sync skip ${ticker}: ${picked.reason}`)
            continue
        }
        try {
            const result = await upsertStockPrice(db, ticker, picked.price)
            updated.push({
                ticker,
                price: picked.price,
                source: picked.source,
                inserted: result.inserted,
            })
            console.log(
                `ETF Alpaca sync ${result.inserted ? 'INSERT' : 'UPDATE'} ${ticker} ` +
                `price=${picked.price} source=${picked.source}`
            )
        } catch (error) {
            const reason = error?.message || 'upsert failed'
            skipped.push({ ticker, reason })
            console.log(`ETF Alpaca sync upsert ERROR ${ticker}: ${reason}`)
        }
    }
    return { updated, skipped, error: null }
}

// One-shot read of stock.price for dip fallback (after sync).
async function readStockPrices(db, tickers) {
    const list = [...new Set((tickers || []).map((t) => String(t).toUpperCase()))]
    if (list.length === 0) return new Map()
    const result = await db.query(
        `SELECT name, price FROM stock WHERE name = ANY($1::text[])`,
        [list]
    )
    const map = new Map()
    for (const row of result?.rows || []) {
        const n = Number(row.price)
        if (Number.isFinite(n) && n > 0) map.set(String(row.name).toUpperCase(), n)
    }
    return map
}

module.exports = {
    STALE_TRADE_MS,
    FEED,
    loadAlpacaKeys,
    pickLivePrice,
    fetchIexSnapshots,
    syncEnabledEtfStockPrices,
    readStockPrices,
}
