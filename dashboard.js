const http = require('http')
const db = require('./modules/database.js')
// 2026-10-11: new searchable Price & Fills chart (separate section + JSON API)
const pfChart = require('./modules/dashboardChart.js')

const PORT = 3000

// 2026-10-11: live cash above the chart (vw_balance totals = available + hold).
// profit_history.usd_balance/usdc_balance are snapshots at close only — not for this.
const BALANCE_QUERY = `
    SELECT
        MAX(balance::numeric) FILTER (WHERE name = 'USD')  AS usd,
        MAX(available::numeric) FILTER (WHERE name = 'USD') AS usd_available,
        MAX(hold::numeric) FILTER (WHERE name = 'USD') AS usd_hold,
        MAX(balance::numeric) FILTER (WHERE name = 'USDC') AS usdc,
        MAX(available::numeric) FILTER (WHERE name = 'USDC') AS usdc_available,
        MAX(hold::numeric) FILTER (WHERE name = 'USDC') AS usdc_hold
    FROM vw_balance
    WHERE name IN ('USD', 'USDC')
`

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

const OPEN_BUY_ORDERS_QUERY = `
    SELECT p.name, p.shares, p.buy_price, p.buy_stop_price, s.price AS current_price,
        ROUND(((p.buy_stop_price - s.price) / NULLIF(s.price, 0) * 100)::numeric, 4) AS pct_to_trigger,
        p.error_message, p.date_created
    FROM position p
    JOIN stock s ON s.stock_id = p.stock_id
    WHERE p.buy_coinbase_order_id IS NOT NULL AND p.buy_coinbase_order_id != ''
    AND p.buy_filled_price IS NULL
    ORDER BY pct_to_trigger ASC
`

const OPEN_POSITIONS_QUERY = `
    SELECT p.name, p.shares,
        p.buy_filled_price, s.price AS current_price, p.sell_price AS sell_target,
        p.sell_stop_price,
        ROUND(((p.sell_stop_price::numeric - s.price::numeric) / NULLIF(s.price::numeric, 0) * 100)::numeric, 4) AS sell_pct_to_trigger,
        p.sell_coinbase_order_id IS NOT NULL AND p.sell_coinbase_order_id != '' AS has_live_sell,
        p.error_message,
        (
            p.sell_price::numeric * p.shares::numeric
            * (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100))
            - (p.buy_filled_price::numeric * p.shares::numeric + COALESCE(p.buy_fee::numeric, 0))
        ) AS target_profit,
        (
            s.price::numeric * p.shares::numeric
            * (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100))
            - (p.buy_filled_price::numeric * p.shares::numeric + COALESCE(p.buy_fee::numeric, 0))
        ) AS current_profit
    FROM position p
    JOIN stock s ON s.stock_id = p.stock_id
    WHERE p.buy_filled_price IS NOT NULL AND p.sell_filled_price IS NULL
    ORDER BY has_live_sell DESC, current_profit DESC
`

const RECENT_FILLS_QUERY = `
    -- 2026-10-11: use fills (not position_audit). Audit rows are deleted
    -- when a position closes, so closed coins like ABT-USD vanished from
    -- "Last 100 Fills" even though the trades still exist in fills.
    -- 2026-10-11: also show size (shares) and fee — both live on fills.
    SELECT product_id AS name,
           side AS fill_type,
           price,
           size,
           fee,
           trade_time AS changed_at
    FROM fills
    ORDER BY trade_time DESC
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

function renderPage (balances, profitSummary, profitHistory24h, openBuyOrders, openPositions, recentFills) {
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

    // 2026-10-11: data-coin on each row so the Price & Fills dropdown can
    // filter these tables client-side (see applyCoinFilter script below).
    const historyRows = profitHistory24h.map(r => `
        <tr data-coin="${esc(r.name)}">
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

    // 2026-10-11: Position columns grouped buy-side then sell-side.
    // Buy: Kind, Coin, Shares, Bought @, Buy Limit, Buy Stop, Buy %.
    // Then Current. Sell: Limit, Stop, Sell %, Sell Order, Current Profit,
    // Target Profit. Then Error / Placed.
    const heldRows = openPositions.map(r => `
        <tr data-coin="${esc(r.name)}">
            <td><span class="pos">Held</span></td>
            <td>${esc(r.name)}</td>
            <td>${num(r.shares)}</td>
            <td>${num(r.buy_filled_price)}</td>
            <td class="dim">—</td>
            <td class="dim">—</td>
            <td class="dim">—</td>
            <td>${num(r.current_price)}</td>
            <td>${num(r.sell_target)}</td>
            <td>${num(r.sell_stop_price)}</td>
            <td>${r.sell_pct_to_trigger == null ? '—' : (r.sell_pct_to_trigger + '%')}</td>
            <td>${r.has_live_sell ? '<span class="pos">live</span>' : '<span class="dim">none</span>'}</td>
            <td>${money(r.current_profit)}</td>
            <td>${money(r.target_profit)}</td>
            <td class="dim">${esc(r.error_message)}</td>
            <td class="dim">—</td>
        </tr>
    `).join('')
    const pendingBuyRows = openBuyOrders.map(r => `
        <tr data-coin="${esc(r.name)}">
            <td><span class="buy-tag">Buy</span></td>
            <td>${esc(r.name)}</td>
            <td>${num(r.shares)}</td>
            <td class="dim">—</td>
            <td>${num(r.buy_price)}</td>
            <td>${num(r.buy_stop_price)}</td>
            <td>${r.pct_to_trigger}%</td>
            <td>${num(r.current_price)}</td>
            <td class="dim">—</td>
            <td class="dim">—</td>
            <td class="dim">—</td>
            <td class="dim">—</td>
            <td class="dim">—</td>
            <td class="dim">—</td>
            <td class="dim">${esc(r.error_message)}</td>
            <td class="dim">${new Date(r.date_created).toLocaleString()}</td>
        </tr>
    `).join('')
    const positionRows = heldRows + pendingBuyRows
    const positionTotal = openPositions.length + openBuyOrders.length

    const fillRows = recentFills.map(r => `
        <tr data-coin="${esc(r.name)}">
            <td>${esc(r.name)}</td>
            <td class="${r.fill_type === 'BUY' ? 'buy-tag' : 'sell-tag'}">${r.fill_type}</td>
            <td>${num(r.price)}</td>
            <td>${num(r.size)}</td>
            <td>${money(r.fee)}</td>
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
    tr.coin-filter-empty td { color: #666; }
    .coin-filter-note { font-size: 12px; color: #888; margin: -24px 0 8px; }
    .cash-bar { display:flex; gap:24px; flex-wrap:wrap; align-items:baseline; margin: 12px 0 8px;
                padding: 12px 16px; background:#151515; border:1px solid #2a2a2a; border-radius:8px; }
    .cash-bar .amt { font-size: 22px; font-weight: 600; color: #f5f5f5; }
    .cash-bar .lbl { font-size: 13px; color: #999; text-transform: uppercase; letter-spacing: 0.06em; margin-right: 8px; }
    .cash-bar .split { font-size: 12px; color: #777; margin-left: 8px; }
</style>
</head>
<body>
    <h1>Coinbase Bot Dashboard</h1>
    <div class="meta">Generated ${new Date().toLocaleString()}</div>
    <a class="refresh" href="/">Refresh</a>

    <div class="cash-bar">
        <div>
            <span class="lbl">USD</span>
            <span class="amt">${money(balances && balances.usd)}</span>
            <span class="split">total · ${money(balances && balances.usd_available)} available · ${money(balances && balances.usd_hold)} held</span>
        </div>
        <div>
            <span class="lbl">USDC</span>
            <span class="amt">${money(balances && balances.usdc)}</span>
            <span class="split">total · ${money(balances && balances.usdc_available)} available · ${money(balances && balances.usdc_hold)} held</span>
        </div>
    </div>

    ${pfChart.renderSection()}

    <h2 id="h-positions">Position (${positionTotal})</h2>
    <table class="coin-filter" data-title="Position" data-total="${positionTotal}" data-colspan="16">
        <tr>
            <th>Kind</th><th>Coin</th><th>Shares</th><th>Bought @</th><th>Buy Limit</th><th>Buy Stop</th><th>Buy % to Trigger</th>
            <th>Current</th>
            <th>Limit Price</th><th>Stop Price</th><th>Sell % to Trigger</th><th>Sell Order</th><th>Current Profit</th><th>Target Profit</th>
            <th>Error</th><th>Placed</th>
        </tr>
        ${positionRows || '<tr class="coin-filter-empty"><td class="empty" colspan="16">No open positions or buy orders</td></tr>'}
    </table>

    <h2 id="h-fills">Last 100 Fills</h2>
    <table class="coin-filter" data-title="Last 100 Fills" data-total="${recentFills.length}" data-colspan="6">
        <tr><th>Coin</th><th>Type</th><th>Price</th><th>Shares</th><th>Fee</th><th>When</th></tr>
        ${fillRows || '<tr class="coin-filter-empty"><td class="empty" colspan="6">No fills recorded</td></tr>'}
    </table>

    <h2>Profit Summary</h2>
    <p class="coin-filter-note">Portfolio-wide by period type — not filtered by the chart coin (no per-coin summary query yet).</p>
    <table>
        <tr>
            <th>Period</th><th>Total Trades</th><th>All-Time Profit</th><th>All-Time Avg</th>
            <th>Today Trades</th><th>Today Profit</th><th>Today Avg</th>
            <th>Month Trades</th><th>Month Profit</th><th>Month Avg</th>
        </tr>
        ${summaryRows || '<tr><td class="empty" colspan="10">No data</td></tr>'}
    </table>

    <h2 id="h-history">Profit History — Last 24 Hours (${profitHistory24h.length})</h2>
    <table class="coin-filter" data-title="Profit History — Last 24 Hours" data-total="${profitHistory24h.length}" data-colspan="8">
        <tr>
            <th>Coin</th><th>Period</th><th>Buy Price</th><th>Sell Price</th>
            <th>Buy Fee</th><th>Sell Fee</th><th>Profit</th><th>When</th>
        </tr>
        ${historyRows || '<tr class="coin-filter-empty"><td class="empty" colspan="8">No trades in the last 24 hours</td></tr>'}
    </table>
    <script>
    // 2026-10-11: filter coin-tagged tables from the Price & Fills dropdown
    // (CustomEvent pf-coin-filter from modules/dashboardChart.js).
    (function () {
        const headingFor = {
            'Position': 'h-positions',
            'Last 100 Fills': 'h-fills',
            'Profit History — Last 24 Hours': 'h-history',
        }
        function applyCoinFilter (coin) {
            document.querySelectorAll('table.coin-filter').forEach(table => {
                const total = Number(table.dataset.total || 0)
                const title = table.dataset.title || ''
                const colspan = table.dataset.colspan || '4'
                let shown = 0
                table.querySelectorAll('tr[data-coin]').forEach(tr => {
                    const match = !coin || tr.getAttribute('data-coin') === coin
                    tr.style.display = match ? '' : 'none'
                    if (match) shown++
                })
                let empty = table.querySelector('tr.coin-filter-empty')
                if (!empty) {
                    empty = document.createElement('tr')
                    empty.className = 'coin-filter-empty'
                    empty.innerHTML = '<td class="empty" colspan="' + colspan + '"></td>'
                    table.appendChild(empty)
                }
                const cell = empty.querySelector('td')
                if (coin && shown === 0) {
                    empty.style.display = ''
                    cell.textContent = 'No rows for ' + coin
                } else if (!coin && total === 0) {
                    empty.style.display = ''
                    // keep server-rendered empty copy if present
                    if (!cell.textContent) cell.textContent = 'No data'
                } else if (shown > 0) {
                    empty.style.display = 'none'
                }
                const hid = headingFor[title]
                const h = hid && document.getElementById(hid)
                if (h) {
                    if (title === 'Last 100 Fills') {
                        h.textContent = coin
                            ? ('Last 100 Fills (' + shown + ' of ' + total + ' · ' + coin + ')')
                            : ('Last 100 Fills')
                    } else {
                        h.textContent = coin
                            ? (title + ' (' + shown + ' of ' + total + ' · ' + coin + ')')
                            : (title + ' (' + total + ')')
                    }
                }
            })
        }
        window.applyDashboardCoinFilter = applyCoinFilter
        window.addEventListener('pf-coin-filter', e => applyCoinFilter(e.detail && e.detail.coin))
    })()
    </script>
</body>
</html>`
}

const server = http.createServer(async (req, res) => {
    try {
        // 2026-10-11: JSON routes for the Price & Fills chart, fetched client-side
        // so the main page doesn't embed thousands of price points on every load.
        const url = new URL(req.url, 'http://localhost')
        if (url.pathname === '/api/coins') {
            res.writeHead(200, { 'Content-Type': 'application/json' })
            return res.end(JSON.stringify(await pfChart.listCoins()))
        }
        // 2026-10-11: poll target for auto-follow — newest SELL in fills.
        if (url.pathname === '/api/latest-sell') {
            res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' })
            return res.end(JSON.stringify(await pfChart.latestSell()))
        }
        if (url.pathname === '/api/chart') {
            const coin = (url.searchParams.get('coin') || '').toUpperCase()
            if (!coin) { res.writeHead(400, { 'Content-Type': 'application/json' }); return res.end('{"error":"coin required"}') }
            res.writeHead(200, { 'Content-Type': 'application/json' })
            return res.end(JSON.stringify(await pfChart.chartData(coin, url.searchParams.get('range') || '7d')))
        }
        if (url.pathname !== '/') { res.writeHead(404); return res.end('not found') }
        const [balanceRows, profitSummary, profitHistory24h, openBuyOrders, openPositions, recentFills] = await Promise.all([
            db.executeQuery(BALANCE_QUERY),
            db.executeQuery(PROFIT_SUMMARY_QUERY),
            db.executeQuery(PROFIT_HISTORY_24H_QUERY),
            db.executeQuery(OPEN_BUY_ORDERS_QUERY),
            db.executeQuery(OPEN_POSITIONS_QUERY),
            db.executeQuery(RECENT_FILLS_QUERY),
        ])
        const balances = balanceRows[0] || {}
        // 2026-10-11: no-store so a hard-refresh isn't required to see chart updates
        res.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' })
        res.end(renderPage(balances, profitSummary, profitHistory24h, openBuyOrders, openPositions, recentFills))
    } catch (error) {
        console.log('dashboard request error', error)
        res.writeHead(500, { 'Content-Type': 'text/plain' })
        res.end('Dashboard error: ' + error.message)
    }
})

server.listen(PORT, () => {
    console.log(`Dashboard running at http://localhost:${PORT}`)
})
