#!/usr/bin/env node
/**
 * CLI helper for the Streamlit coin chart.
 * Usage:
 *   node charts/fetch_chart_data.js list
 *   node charts/fetch_chart_data.js data ALGO-USD [days]
 *
 * Prints JSON to stdout. Uses the same Coinbase auth as the trading bot.
 * list prefers distinct products from local fills, then falls back to API fills.
 */
const path = require('path')
const { Client } = require('pg')

// Resolve bot modules from project root (this file lives in charts/)
const ROOT = path.join(__dirname, '..')
process.chdir(ROOT)
const ca = require(path.join(ROOT, 'modules', 'coinbaseAuth.js'))

async function dbProducts() {
  const client = new Client({
    user: 'theodorecross',
    database: 'coinbase',
    host: 'localhost',
  })
  try {
    await client.connect()
    const r = await client.query(`
      SELECT product_id, COUNT(*)::int AS fill_count,
             MAX(trade_time) AS last_fill
      FROM fills
      WHERE product_id IS NOT NULL AND product_id LIKE '%-USD'
      GROUP BY product_id
      ORDER BY MAX(trade_time) DESC NULLS LAST, product_id
    `)
    return r.rows.map(row => ({
      product_id: row.product_id,
      fill_count: row.fill_count,
      last_fill: row.last_fill,
    }))
  } catch (e) {
    return null
  } finally {
    try { await client.end() } catch (_) {}
  }
}

async function listProducts() {
  const fromDb = await dbProducts()
  if (fromDb && fromDb.length) {
    return { products: fromDb.map(p => p.product_id), detail: fromDb }
  }
  // Fallback: page recent API fills and collect product ids
  const fills = await ca.gatherAllFills()
  const set = new Set()
  for (const f of fills || []) {
    if (f.product_id) set.add(f.product_id)
  }
  const products = [...set].sort()
  return { products, detail: products.map(p => ({ product_id: p })) }
}

async function fetchCandles(productId, days) {
  const end0 = Math.floor(Date.now() / 1000)
  const start0 = end0 - days * 24 * 3600
  const gran = 'ONE_HOUR'
  const window = 3600 * 250
  const all = []
  for (let s = start0; s < end0; s += window) {
    const e = Math.min(s + window, end0)
    const candles = await ca.yoinkPriceData(productId, String(s), String(e), gran, 300)
    if (candles?.length) all.push(...candles)
  }
  all.sort((a, b) => Number(a.start) - Number(b.start))
  const seen = new Set()
  const uniq = []
  for (const c of all) {
    if (seen.has(c.start)) continue
    seen.add(c.start)
    uniq.push({
      start: Number(c.start),
      open: Number(c.open),
      high: Number(c.high),
      low: Number(c.low),
      close: Number(c.close),
    })
  }
  return uniq
}

async function fetchFills(productId, days) {
  const fills = await ca.gatherAllFillsByProduct(productId)
  const cutoff = Date.now() - days * 24 * 3600 * 1000
  return (fills || [])
    .filter(f => new Date(f.trade_time).getTime() >= cutoff)
    .map(f => ({
      trade_time: f.trade_time,
      side: String(f.side || '').toUpperCase(),
      price: Number(f.price),
      size: Number(f.size),
      fee: Number(f.commission || f.fee || 0),
      order_id: f.order_id,
    }))
    .sort((a, b) => new Date(a.trade_time) - new Date(b.trade_time))
}

async function main() {
  const [cmd, productId, daysArg] = process.argv.slice(2)
  const days = Math.max(1, Math.min(180, Number(daysArg) || 45))

  if (cmd === 'list') {
    process.stdout.write(JSON.stringify(await listProducts()) + '\n')
    return
  }
  if (cmd === 'data' && productId) {
    const [candles, fills] = await Promise.all([
      fetchCandles(productId, days),
      fetchFills(productId, days),
    ])
    process.stdout.write(JSON.stringify({
      product_id: productId,
      days,
      candles,
      fills,
      generated_at: new Date().toISOString(),
    }) + '\n')
    return
  }
  console.error('Usage: node charts/fetch_chart_data.js list | data PRODUCT [days]')
  process.exit(1)
}

main().catch(e => {
  console.error(e)
  process.exit(1)
})
