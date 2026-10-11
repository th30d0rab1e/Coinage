// 2026-10-11: Searchable "Price & Fills" chart for dashboard.js.
// Brand-new section; the existing dashboard tables are untouched.
// Data sources (checked against the live DB before writing this):
//   - price_history keeps only ~25h of 1-minute prices, so it is used for the 24h range.
//   - Longer ranges use Coinbase's public candles endpoint (no auth, read-only),
//     falling back to price_aggregate day closes if that request fails.
//   - Fills come from the fills table (one row per Coinbase trade, side BUY/SELL).
const db = require('./database.js')

// range -> [seconds back, candle granularity seconds]. Coinbase returns max 300 candles per call.
const RANGES = {
    '24h': [86400, null],
    '7d': [7 * 86400, 3600],
    '30d': [30 * 86400, 21600],
    '90d': [90 * 86400, 86400],
    '1y': [365 * 86400, 86400],
    'all': [5 * 365 * 86400, 86400],
}

// Coins the user can search: every stock row plus any product that has fills
// (27 filled products are no longer in stock, e.g. delisted coins).
async function listCoins () {
    const { rows } = await db.query(`
        SELECT name, SUM(fill_count)::int AS fill_count, MAX(last_fill) AS last_fill
        FROM (
            SELECT name, 0 AS fill_count, NULL::timestamptz AS last_fill FROM stock
            UNION ALL
            SELECT product_id, COUNT(*), MAX(trade_time) FROM fills GROUP BY product_id
        ) x
        WHERE name IS NOT NULL
        GROUP BY name
        ORDER BY MAX(last_fill) DESC NULLS LAST, name`)
    return rows
}

async function coinbaseCandles (coin, startSec, endSec, gran) {
    const out = []
    // Page backwards in 300-candle windows (Coinbase limit).
    for (let end = endSec; end > startSec; end -= gran * 300) {
        const start = Math.max(startSec, end - gran * 300)
        const url = `https://api.exchange.coinbase.com/products/${encodeURIComponent(coin)}/candles` +
            `?granularity=${gran}&start=${new Date(start * 1000).toISOString()}&end=${new Date(end * 1000).toISOString()}`
        const r = await fetch(url, { headers: { 'User-Agent': 'coinage-dashboard' }, signal: AbortSignal.timeout(8000) })
        if (!r.ok) throw new Error(`candles ${r.status}`)
        const rows = await r.json()
        if (!Array.isArray(rows) || rows.length === 0) break // before listing date
        // [time, low, high, open, close, volume] -> plot the close
        for (const c of rows) out.push({ t: c[0] * 1000, p: c[4] })
    }
    return out.sort((a, b) => a.t - b.t)
}

async function chartData (coin, range) {
    const [back, gran] = RANGES[range] || RANGES['7d']
    const nowSec = Math.floor(Date.now() / 1000)
    const since = new Date((nowSec - back) * 1000)
    let prices = []
    let source = ''

    if (!gran) {
        const { rows } = await db.query(`
            SELECT ph.date_created AS t, ph.price AS p
            FROM price_history ph JOIN stock s ON s.stock_id = ph.stock_id
            WHERE s.name = $1 AND ph.date_created >= $2
            ORDER BY ph.date_created`, [coin, since])
        prices = rows.map(r => ({ t: new Date(r.t).getTime(), p: r.p }))
        source = 'price_history (1-min, bot DB)'
    } else {
        try {
            prices = await coinbaseCandles(coin, nowSec - back, nowSec, gran)
            source = `Coinbase candles (${gran / 3600}h close)`
        } catch (e) {
            const { rows } = await db.query(`
                SELECT pa.period_date AS t, pa.close AS p
                FROM price_aggregate pa JOIN stock s ON s.stock_id = pa.stock_id
                WHERE s.name = $1 AND pa.period_type = 'day' AND pa.period_date >= $2::date
                ORDER BY pa.period_date`, [coin, since])
            prices = rows.map(r => ({ t: new Date(r.t).getTime(), p: r.p }))
            source = `price_aggregate day close (Coinbase candles failed: ${e.message})`
        }
    }

    const { rows: fills } = await db.query(`
        SELECT trade_time AS t, price AS p, size, fee, side, order_id
        FROM fills
        WHERE product_id = $1 AND trade_time >= $2
        ORDER BY trade_time`, [coin, since])

    const mapFill = f => ({ t: new Date(f.t).getTime(), p: f.p, size: f.size, fee: f.fee, order_id: f.order_id })
    return {
        coin, range, source,
        prices,
        buys: fills.filter(f => f.side === 'BUY').map(mapFill),
        sells: fills.filter(f => f.side === 'SELL').map(mapFill),
    }
}

function renderSection () {
    const ranges = Object.keys(RANGES).map(r => `<option value="${r}"${r === '7d' ? ' selected' : ''}>${r}</option>`).join('')
    return `
    <h2>Price &amp; Fills Chart</h2>
    <div id="pf-controls" style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:8px;font-size:13px">
        <input id="pf-search" list="pf-coins" placeholder="Search coin (e.g. RLC)" autocomplete="off"
            style="background:#1a1a1a;color:#ddd;border:1px solid #333;border-radius:6px;padding:6px 10px;width:220px">
        <datalist id="pf-coins"></datalist>
        <select id="pf-range" style="background:#1a1a1a;color:#ddd;border:1px solid #333;border-radius:6px;padding:6px">${ranges}</select>
        <button id="pf-reset" style="background:#333;color:#ddd;border:0;border-radius:6px;padding:6px 10px">Reset zoom</button>
        <span id="pf-status" class="dim"></span>
    </div>
    <div style="position:relative;height:420px;background:#151515;border-radius:8px;padding:8px"><canvas id="pf-chart"></canvas></div>
    <div class="dim" style="font-size:12px;margin-top:4px">Scroll / pinch to zoom, drag to pan, hover a point for details. <span class="buy-tag">● buy fill</span> <span class="sell-tag">● sell fill</span></div>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.4/dist/chart.umd.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3.0.0/dist/chartjs-adapter-date-fns.bundle.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/hammerjs@2.0.8/hammer.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-zoom@2.0.1/dist/chartjs-plugin-zoom.min.js"></script>
    <script>
    (function () {
        const search = document.getElementById('pf-search')
        const rangeSel = document.getElementById('pf-range')
        const status = document.getElementById('pf-status')
        let coins = [], chart = null, current = null
        const toXY = a => a.map(d => ({ x: d.t, y: d.p, size: d.size, fee: d.fee }))

        function draw (data) {
            const ds = [
                { label: data.coin + ' price', data: toXY(data.prices), type: 'line', borderColor: '#60a5fa', borderWidth: 1.5, pointRadius: 0, tension: 0, order: 3 },
                { label: 'Buy fills', data: toXY(data.buys), type: 'scatter', backgroundColor: '#22c55e', borderColor: '#bbf7d0', pointRadius: 6, pointHoverRadius: 9, order: 1 },
                { label: 'Sell fills', data: toXY(data.sells), type: 'scatter', backgroundColor: '#ef4444', borderColor: '#fecaca', pointRadius: 6, pointHoverRadius: 9, order: 1 },
            ]
            if (chart) chart.destroy()
            chart = new Chart(document.getElementById('pf-chart'), {
                data: { datasets: ds },
                options: {
                    responsive: true, maintainAspectRatio: false, animation: false, parsing: false,
                    interaction: { mode: 'nearest', intersect: false },
                    scales: {
                        x: { type: 'time', ticks: { color: '#888' }, grid: { color: '#222' } },
                        y: { ticks: { color: '#888' }, grid: { color: '#222' } },
                    },
                    plugins: {
                        legend: { labels: { color: '#ccc' } },
                        tooltip: { callbacks: { label: c => {
                            const d = c.raw, base = c.dataset.label + ': $' + d.y
                            return d.size != null ? base + '  size ' + d.size + '  fee $' + Number(d.fee).toFixed(4) : base
                        } } },
                        zoom: { pan: { enabled: true, mode: 'x' }, zoom: { wheel: { enabled: true }, pinch: { enabled: true }, mode: 'x' } },
                    },
                },
            })
        }

        async function load (coin) {
            if (!coin) return
            current = coin
            status.textContent = 'Loading ' + coin + '…'
            try {
                const r = await fetch('/api/chart?coin=' + encodeURIComponent(coin) + '&range=' + rangeSel.value)
                const data = await r.json()
                if (data.error) throw new Error(data.error)
                draw(data)
                status.textContent = data.prices.length + ' price points · ' + data.buys.length + ' buys · ' + data.sells.length + ' sells · ' + data.source
            } catch (e) { status.textContent = 'Error: ' + e.message }
        }

        // Accept exact names, or a bare ticker like "rlc" -> RLC-USD.
        function resolve (q) {
            q = q.trim().toUpperCase()
            if (!q) return null
            return coins.find(c => c.name === q) || coins.find(c => c.name === q + '-USD') || coins.find(c => c.name.startsWith(q)) || null
        }

        search.addEventListener('change', () => { const c = resolve(search.value); if (c) { search.value = c.name; load(c.name) } else status.textContent = 'No coin matches "' + search.value + '"' })
        search.addEventListener('keydown', e => { if (e.key === 'Enter') search.dispatchEvent(new Event('change')) })
        rangeSel.addEventListener('change', () => load(current))
        document.getElementById('pf-reset').addEventListener('click', () => chart && chart.resetZoom())

        fetch('/api/coins').then(r => r.json()).then(list => {
            coins = list
            document.getElementById('pf-coins').innerHTML = list.map(c => '<option value="' + c.name + '">' + (c.fill_count ? c.fill_count + ' fills' : 'no fills') + '</option>').join('')
            // Default: the coin with the most recent fill.
            if (list[0]) { search.value = list[0].name; load(list[0].name) }
        })
    })()
    </script>`
}

module.exports = { listCoins, chartData, renderSection, RANGES }
