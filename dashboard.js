const http = require('http')
const db = require('./modules/database.js')

const PORT = 3000

const PROFIT_SUMMARY_QUERY = `SELECT * FROM vw_profit_summary`

const PROFIT_HISTORY_24H_QUERY = `
    SELECT ph.name, ph.period_type,
        (pa.old_value::jsonb ->> 'buy_filled_price') AS buy_price,
        (pa.old_value::jsonb ->> 'sell_filled_price') AS sell_price,
        ph.buy_fee, ph.sell_fee, ph.profit, ph.date_created
    FROM profit_history ph
    LEFT JOIN position_audit pa ON pa.operation = 'DELETE'
        AND (pa.old_value::jsonb ->> 'buy_coinbase_order_id') = ph.buy_coinbase_order_id
        AND (pa.old_value::jsonb ->> 'sell_coinbase_order_id') = ph.sell_fills_id
    WHERE ph.date_created > NOW() - INTERVAL '24 hours'
    ORDER BY ph.date_created DESC
`

const OPEN_POSITIONS_QUERY = `
    SELECT p.name, p.shares,
        p.buy_filled_price, s.price AS current_price, p.sell_price AS sell_target,
        p.sell_coinbase_order_id IS NOT NULL AND p.sell_coinbase_order_id != '' AS has_live_sell,
        p.error_message,
        (
            p.sell_price::numeric * p.shares::numeric
            * (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), 0.012))
            - (p.buy_filled_price::numeric * p.shares::numeric + COALESCE(p.buy_fee::numeric, 0))
        ) AS target_profit,
        (
            s.price::numeric * p.shares::numeric
            * (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), 0.012))
            - (p.buy_filled_price::numeric * p.shares::numeric + COALESCE(p.buy_fee::numeric, 0))
        ) AS current_profit
    FROM position p
    JOIN stock s ON s.stock_id = p.stock_id
    WHERE p.buy_filled_price IS NOT NULL AND p.sell_filled_price IS NULL
    ORDER BY has_live_sell DESC, current_profit DESC
`

const RECENT_FILLS_QUERY = `
    SELECT
        pa.position_id,
        COALESCE(cur.name, ins.new_value::jsonb ->> 'name') AS name,
        CASE pa.column_name WHEN 'buy_filled_price' THEN 'BUY' ELSE 'SELL' END AS fill_type,
        pa.new_value AS price,
        pa.changed_at
    FROM position_audit pa
    LEFT JOIN position cur ON cur.position_id = pa.position_id
    LEFT JOIN LATERAL (
        SELECT new_value FROM position_audit ins
        WHERE ins.position_id = pa.position_id AND ins.operation = 'INSERT'
        LIMIT 1
    ) ins ON true
    WHERE pa.column_name IN ('buy_filled_price', 'sell_filled_price')
    ORDER BY pa.changed_at DESC
    LIMIT 100
`

function money (value) {
    if (value === null || value === undefined || value === '') return '—'
    const n = parseFloat(value)
    if (Number.isNaN(n)) return '—'
    const cls = n > 0 ? 'pos' : n < 0 ? 'neg' : ''
    const sign = n < 0 ? '-' : ''
    return `<span class="${cls}">${sign}$${Math.abs(n).toFixed(4)}</span>`
}

function num (value, digits) {
    if (value === null || value === undefined || value === '') return '—'
    const n = parseFloat(value)
    if (Number.isNaN(n)) return '—'
    return n.toFixed(digits ?? 5)
}

function esc (value) {
    if (value === null || value === undefined) return ''
    return String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))
}

function renderPage (profitSummary, profitHistory24h, openPositions, recentFills) {
    const summaryRows = profitSummary.map(r => `
        <tr>
            <td>${esc(r.period_type)}</td>
            <td>${r.total_trades}</td>
            <td>${money(r.all_time_profit)}</td>
            <td>${money(r.all_time_avg)}</td>
            <td>${r.today_trades}</td>
            <td>${money(r.today_profit)}</td>
            <td>${money(r.today_avg)}</td>
            <td>${r.month_trades}</td>
            <td>${money(r.month_profit)}</td>
            <td>${money(r.month_avg)}</td>
        </tr>
    `).join('')

    const historyRows = profitHistory24h.map(r => `
        <tr>
            <td>${esc(r.name)}</td>
            <td>${esc(r.period_type)}</td>
            <td>${num(r.buy_price)}</td>
            <td>${num(r.sell_price)}</td>
            <td>${money(r.buy_fee)}</td>
            <td>${money(r.sell_fee)}</td>
            <td>${money(r.profit)}</td>
            <td class="dim">${new Date(r.date_created).toLocaleString()}</td>
        </tr>
    `).join('')

    const positionRows = openPositions.map(r => `
        <tr>
            <td>${esc(r.name)}</td>
            <td>${num(r.shares)}</td>
            <td>${num(r.buy_filled_price)}</td>
            <td>${num(r.current_price)}</td>
            <td>${num(r.sell_target)}</td>
            <td>${r.has_live_sell ? '<span class="pos">live</span>' : '<span class="dim">none</span>'}</td>
            <td>${money(r.target_profit)}</td>
            <td>${money(r.current_profit)}</td>
            <td class="dim">${esc(r.error_message)}</td>
        </tr>
    `).join('')

    const fillRows = recentFills.map(r => `
        <tr>
            <td>${esc(r.name)}</td>
            <td class="${r.fill_type === 'BUY' ? 'buy-tag' : 'sell-tag'}">${r.fill_type}</td>
            <td>${num(r.price)}</td>
            <td class="dim">${new Date(r.changed_at).toLocaleString()}</td>
        </tr>
    `).join('')

    return `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Coinbase Bot Dashboard</title>
<style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #111; color: #ddd; margin: 0; padding: 24px; }
    h1 { font-size: 20px; margin: 0 0 4px; }
    h2 { font-size: 15px; color: #999; margin: 32px 0 8px; text-transform: uppercase; letter-spacing: 0.05em; }
    .meta { color: #888; font-size: 13px; margin-bottom: 16px; }
    a.refresh { display: inline-block; background: #2563eb; color: white; text-decoration: none; padding: 6px 14px; border-radius: 6px; font-size: 13px; }
    a.refresh:hover { background: #1d4ed8; }
    table { border-collapse: collapse; width: 100%; font-size: 13px; }
    th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid #2a2a2a; }
    th { color: #999; font-weight: 600; }
    tr:hover { background: #1a1a1a; }
    .pos { color: #4ade80; }
    .neg { color: #f87171; }
    .dim { color: #777; }
    .buy-tag { color: #4ade80; }
    .sell-tag { color: #f87171; }
    .empty { color: #666; padding: 12px 0; }
</style>
</head>
<body>
    <h1>Coinbase Bot Dashboard</h1>
    <div class="meta">Generated ${new Date().toLocaleString()}</div>
    <a class="refresh" href="/">Refresh</a>

    <h2>Profit Summary</h2>
    <table>
        <tr>
            <th>Period</th><th>Total Trades</th><th>All-Time Profit</th><th>All-Time Avg</th>
            <th>Today Trades</th><th>Today Profit</th><th>Today Avg</th>
            <th>Month Trades</th><th>Month Profit</th><th>Month Avg</th>
        </tr>
        ${summaryRows || '<tr><td class="empty" colspan="10">No data</td></tr>'}
    </table>

    <h2>Profit History — Last 24 Hours (${profitHistory24h.length})</h2>
    <table>
        <tr>
            <th>Coin</th><th>Period</th><th>Buy Price</th><th>Sell Price</th>
            <th>Buy Fee</th><th>Sell Fee</th><th>Profit</th><th>When</th>
        </tr>
        ${historyRows || '<tr><td class="empty" colspan="8">No trades in the last 24 hours</td></tr>'}
    </table>

    <h2>Open Positions &amp; Estimated Profit (${openPositions.length})</h2>
    <table>
        <tr>
            <th>Coin</th><th>Shares</th><th>Bought @</th><th>Current</th><th>Sell Target</th>
            <th>Sell Order</th><th>Target Profit</th><th>Current Profit</th><th>Error</th>
        </tr>
        ${positionRows || '<tr><td class="empty" colspan="9">No open positions</td></tr>'}
    </table>

    <h2>Last 100 Fills</h2>
    <table>
        <tr><th>Coin</th><th>Type</th><th>Price</th><th>When</th></tr>
        ${fillRows || '<tr><td class="empty" colspan="4">No fills recorded</td></tr>'}
    </table>
</body>
</html>`
}

const server = http.createServer(async (req, res) => {
    try {
        const [profitSummary, profitHistory24h, openPositions, recentFills] = await Promise.all([
            db.executeQuery(PROFIT_SUMMARY_QUERY),
            db.executeQuery(PROFIT_HISTORY_24H_QUERY),
            db.executeQuery(OPEN_POSITIONS_QUERY),
            db.executeQuery(RECENT_FILLS_QUERY),
        ])
        res.writeHead(200, { 'Content-Type': 'text/html' })
        res.end(renderPage(profitSummary, profitHistory24h, openPositions, recentFills))
    } catch (error) {
        console.log('dashboard request error', error)
        res.writeHead(500, { 'Content-Type': 'text/plain' })
        res.end('Dashboard error: ' + error.message)
    }
})

server.listen(PORT, () => {
    console.log(`Dashboard running at http://localhost:${PORT}`)
})
