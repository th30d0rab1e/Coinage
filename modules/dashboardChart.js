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

// Coins the user can search: stock table ONLY — no fills join/union/fallback.
// 2026-10-11: ^[A-Z0-9]+-USD$ only (no USDC). fill_count is always 0 here;
// labels just show the symbol. All / A-Z / search stay client-side.
async function listCoins () {
    const { rows } = await db.query(`
        SELECT name,
               rsi,
               0::int AS fill_count,
               NULL::timestamptz AS last_fill
        FROM stock
        WHERE name IS NOT NULL
          AND name ~ '^[A-Z0-9]+-USD$'
        ORDER BY name ASC`)
    return rows
}

// 2026-10-11: cheapest poll for the auto-follow chart — newest SELL row only.
async function latestSell () {
    const { rows } = await db.query(`
        SELECT product_id AS coin, trade_time AS t, price AS p, size, fee, order_id, side
        FROM fills
        WHERE side = 'SELL'
          AND product_id ~ '^[A-Z0-9]+-USD$'
        ORDER BY trade_time DESC
        LIMIT 1`)
    const r = rows[0]
    if (!r) return null
    return {
        coin: r.coin,
        t: new Date(r.t).getTime(),
        p: r.p,
        size: r.size,
        fee: r.fee,
        order_id: r.order_id,
        side: r.side,
    }
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


// Wilder RSI series for the chart pane (period default 14). Input: [{t,c}, ...]
// ordered by time. First `period` changes seed SMA; then Wilder smooth.
// Returns [{t, p}] (p = RSI). Skips until enough history.
function wilderRsiSeries (closes, period = 14) {
    const out = []
    if (!closes || closes.length < period + 1) return out
    let prev = closes[0].c
    let sumGain = 0, sumLoss = 0, avgGain = 0, avgLoss = 0, n = 0
    for (let i = 1; i < closes.length; i++) {
        const change = closes[i].c - prev
        prev = closes[i].c
        n++
        const gain = Math.max(change, 0)
        const loss = Math.max(-change, 0)
        if (n <= period) {
            sumGain += gain
            sumLoss += loss
            if (n < period) continue
            avgGain = sumGain / period
            avgLoss = sumLoss / period
        } else {
            avgGain = (avgGain * (period - 1) + gain) / period
            avgLoss = (avgLoss * (period - 1) + loss) / period
        }
        let rsi
        if (avgLoss === 0 && avgGain === 0) rsi = 50
        else if (avgLoss === 0) rsi = 100
        else rsi = 100 - 100 / (1 + avgGain / avgLoss)
        out.push({ t: closes[i].t, p: Math.round(rsi * 10000) / 10000 })
    }
    return out
}

async function chartData (coin, range) {
    const [back, gran] = RANGES[range] || RANGES['7d']
    // 2026-10-11 (Theodore, voice): stock.rsi (current) + day-close RSI series for the pane.
    // Series is Wilder(14) over price_aggregate day closes — same math as fn_stock_rsi;
    // latest point should match stock.rsi when day history is what aggregate() used.
    const rsiRes = await db.query(`SELECT rsi FROM stock WHERE name = $1`, [coin])
    const coinRsi = rsiRes.rows[0] ? rsiRes.rows[0].rsi : null
    const dayCloses = await db.query(`
        SELECT pa.period_date AS d, pa.close::float8 AS c
        FROM price_aggregate pa
        JOIN stock s ON s.stock_id = pa.stock_id
        WHERE s.name = $1 AND pa.period_type = 'day' AND pa.close IS NOT NULL
        ORDER BY pa.period_date`, [coin])
    const rsiSeries = wilderRsiSeries(dayCloses.rows.map(r => ({
        t: new Date(r.d).getTime(),
        c: Number(r.c),
    })), 14)
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
        prices = rows.map(r => ({ t: new Date(r.t).getTime(), p: Number(r.p) }))
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
            prices = rows.map(r => ({ t: new Date(r.t).getTime(), p: Number(r.p) }))
            source = `price_aggregate day close (Coinbase candles failed: ${e.message})`
        }
    }

    const { rows: fills } = await db.query(`
        SELECT trade_time AS t, price AS p, size, fee, side, order_id
        FROM fills
        WHERE product_id = $1 AND trade_time >= $2
        ORDER BY trade_time`, [coin, since])

    const mapFill = f => ({ t: new Date(f.t).getTime(), p: Number(f.p), size: Number(f.size), fee: Number(f.fee), order_id: f.order_id })
    return {
        coin, range, source,
        rsi: coinRsi == null ? null : Number(coinRsi),
        rsiSeries,
        prices,
        buys: fills.filter(f => f.side === 'BUY').map(mapFill),
        sells: fills.filter(f => f.side === 'SELL').map(mapFill),
    }
}

function renderSection () {
    const ranges = Object.keys(RANGES).map(r => `<option value="${r}"${r === '7d' ? ' selected' : ''}>${r}</option>`).join('')
    // 2026-10-11: auto-follow the coin of the latest SELL fill (poll /api/latest-sell).
    // Dropdown remains a manual override; a newer sell jumps the chart again.
    return `
    <style>
      .rsi-os { color: #22c55e; font-weight: 600; }
      .rsi-ob { color: #ef4444; font-weight: 600; }
      .rsi-mid { color: #9ca3af; }
    </style>
    <h2>Price &amp; Fills Chart</h2>
    <div id="pf-controls" style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:8px;font-size:13px">
        <label for="pf-coin-search" class="dim">Search</label>
        <input id="pf-coin-search" type="search" placeholder="Type to filter…" autocomplete="off"
            style="background:#1a1a1a;color:#ddd;border:1px solid #333;border-radius:6px;padding:6px 10px;min-width:140px;max-width:200px">
        <label for="pf-coin" class="dim">Coin</label>
        <select id="pf-coin" style="background:#1a1a1a;color:#ddd;border:1px solid #333;border-radius:6px;padding:6px 10px;min-width:220px;max-width:360px">
            <option value="">Loading coins…</option>
        </select>
        <label style="display:flex;align-items:center;gap:6px;cursor:pointer" title="When on, jump to whichever coin just sold">
            <input type="checkbox" id="pf-autofollow" checked>
            <span class="dim">Auto-follow latest sell</span>
        </label>
        <select id="pf-range" style="background:#1a1a1a;color:#ddd;border:1px solid #333;border-radius:6px;padding:6px">${ranges}</select>
        <button id="pf-reset" style="background:#333;color:#ddd;border:0;border-radius:6px;padding:6px 10px">Reset zoom</button>
        <span id="pf-rsi" class="dim" title="Wilder RSI(14) from stock.rsi"></span>
        <span id="pf-status" class="dim"></span>
    </div>
    <div style="position:relative;height:420px;background:#151515;border-radius:8px;padding:8px"><canvas id="pf-chart"></canvas></div>
    <div style="position:relative;height:160px;background:#151515;border-radius:8px;padding:8px;margin-top:8px">
      <canvas id="pf-rsi-chart"></canvas>
    </div>
    <div class="dim" style="font-size:12px;margin-top:2px">
      RSI(14) pane from day closes (same Wilder math as stock.rsi).
      <span class="rsi-os">● &lt;30 oversold</span>
      <span class="rsi-mid">● 30–70</span>
      <span class="rsi-ob">● &gt;70 overbought</span>
      — dashed lines at 30 / 70
    </div>
    <div class="dim" style="font-size:12px;margin-top:4px">
        Polls sells every 1 minute while this tab is open. Leave the browser window open on this machine to keep watching.
        <span class="buy-tag">● buy fill</span> <span class="sell-tag">● sell fill</span>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.4/dist/chart.umd.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3.0.0/dist/chartjs-adapter-date-fns.bundle.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/hammerjs@2.0.8/hammer.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-zoom@2.0.1/dist/chartjs-plugin-zoom.min.js"></script>
    <script>
    (function () {
        const coinSel = document.getElementById('pf-coin')
        const rangeSel = document.getElementById('pf-range')
        const autoFollow = document.getElementById('pf-autofollow')
        const status = document.getElementById('pf-status')
        const rsiBadge = document.getElementById('pf-rsi')
        function paintRsi (v) {
            if (!rsiBadge) return
            if (v == null || v === '' || !Number.isFinite(Number(v))) {
                rsiBadge.innerHTML = ''
                return
            }
            const n = Number(v)
            const cls = n < 30 ? 'rsi-os' : n > 70 ? 'rsi-ob' : 'rsi-mid'
            rsiBadge.innerHTML = 'RSI <span class="' + cls + '">' + n.toFixed(2) + '</span>'
        }
        let chart = null, rsiChart = null, current = null, lastSellKey = null, loading = false
        const POLL_MS = 60000
        // Coerce numbers: node/JSON can leave price as string; Chart.js then
        // mis-scales scatter datasets vs the time/line series (markers pin to
        // the top/bottom of the plot). Use line+showLine:false so buys/sells
        // share the same linear Y axis as the price series.
        const toXY = a => a.map(d => ({
            x: Number(d.t),
            y: Number(d.p),
            size: d.size == null ? null : Number(d.size),
            fee: d.fee == null ? null : Number(d.fee),
        })).filter(d => Number.isFinite(d.x) && Number.isFinite(d.y))

        function draw (data) {
            const ds = [
                { label: data.coin + ' price', data: toXY(data.prices), type: 'line', yAxisID: 'y', borderColor: '#60a5fa', borderWidth: 1.5, pointRadius: 0, tension: 0, order: 3 },
                { label: 'Buy fills', data: toXY(data.buys), type: 'line', yAxisID: 'y', showLine: false, backgroundColor: '#22c55e', borderColor: '#bbf7d0', pointBackgroundColor: '#22c55e', pointBorderColor: '#bbf7d0', pointRadius: 6, pointHoverRadius: 9, order: 1 },
                { label: 'Sell fills', data: toXY(data.sells), type: 'line', yAxisID: 'y', showLine: false, backgroundColor: '#ef4444', borderColor: '#fecaca', pointBackgroundColor: '#ef4444', pointBorderColor: '#fecaca', pointRadius: 6, pointHoverRadius: 9, order: 1 },
            ]
            if (chart) chart.destroy()
            chart = new Chart(document.getElementById('pf-chart'), {
                type: 'line',
                data: { datasets: ds },
                options: {
                    responsive: true, maintainAspectRatio: false, animation: false, parsing: false,
                    interaction: { mode: 'nearest', intersect: false },
                    scales: {
                        x: { type: 'time', ticks: { color: '#888' }, grid: { color: '#222' } },
                        // Explicit linear Y shared by price + fill markers (yAxisID: 'y').
                        y: { type: 'linear', position: 'left', stacked: false, ticks: { color: '#888' }, grid: { color: '#222' } },
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

        function emitFilter (coin) {
            // null/'' = All — restore full tables. Auto-follow and manual
            // picks both go through here so the rest of the page stays in sync.
            window.dispatchEvent(new CustomEvent('pf-coin-filter', { detail: { coin: coin || null } }))
            if (typeof window.applyDashboardCoinFilter === 'function') {
                window.applyDashboardCoinFilter(coin || null)
            }
        }


        function drawRsi (data) {
            const canvas = document.getElementById('pf-rsi-chart')
            if (!canvas) return
            const series = toXY(data.rsiSeries || [])
            // Color the line by last RSI zone; thresholds as dashed refs.
            const last = series.length ? series[series.length - 1].y : (data.rsi != null ? Number(data.rsi) : null)
            const lineColor = (last != null && Number.isFinite(last))
                ? (last < 30 ? '#22c55e' : last > 70 ? '#ef4444' : '#9ca3af')
                : '#9ca3af'
            const band30 = series.map(d => ({ x: d.x, y: 30 }))
            const band70 = series.map(d => ({ x: d.x, y: 70 }))
            // Flat current stock.rsi marker across the pane when we have points
            const cur = (data.rsi != null && Number.isFinite(Number(data.rsi)) && series.length)
                ? series.map(d => ({ x: d.x, y: Number(data.rsi) }))
                : []
            if (rsiChart) rsiChart.destroy()
            rsiChart = new Chart(canvas, {
                type: 'line',
                data: {
                    datasets: [
                        { label: 'RSI 70', data: band70, borderColor: 'rgba(239,68,68,0.45)', borderWidth: 1, borderDash: [4,4], pointRadius: 0, tension: 0, order: 3 },
                        { label: 'RSI 30', data: band30, borderColor: 'rgba(34,197,94,0.45)', borderWidth: 1, borderDash: [4,4], pointRadius: 0, tension: 0, order: 3 },
                        { label: 'stock.rsi', data: cur, borderColor: lineColor, borderWidth: 1, borderDash: [2,2], pointRadius: 0, tension: 0, order: 2 },
                        { label: 'RSI(14)', data: series, borderColor: lineColor, borderWidth: 1.5, pointRadius: 0, tension: 0, order: 1 },
                    ]
                },
                options: {
                    responsive: true, maintainAspectRatio: false, animation: false, parsing: false,
                    interaction: { mode: 'nearest', intersect: false },
                    plugins: {
                        legend: { display: false },
                        tooltip: {
                            callbacks: {
                                label: (ctx) => {
                                    const y = ctx.parsed.y
                                    if (y == null) return ctx.dataset.label
                                    const zone = y < 30 ? 'oversold' : y > 70 ? 'overbought' : 'neutral'
                                    return ctx.dataset.label + ': ' + Number(y).toFixed(2) + ' (' + zone + ')'
                                }
                            }
                        },
                        zoom: { pan: { enabled: true, mode: 'x' }, zoom: { wheel: { enabled: true }, pinch: { enabled: true }, mode: 'x' } },
                    },
                    scales: {
                        x: { type: 'time', time: { tooltipFormat: 'MMM d, yyyy' }, grid: { color: '#222' }, ticks: { color: '#888', maxRotation: 0 } },
                        y: { min: 0, max: 100, grid: { color: '#222' }, ticks: { color: '#888', stepSize: 10 }, title: { display: true, text: 'RSI', color: '#888' } },
                    },
                },
            })
        }

        async function load (coin, note) {
            if (!coin || loading) return
            loading = true
            current = coin
            if (coinSel.value !== coin) {
                const opt = Array.from(coinSel.options).find(o => o.value === coin)
                if (opt) coinSel.value = coin
            }
            emitFilter(coin)
            status.textContent = (note ? note + ' · ' : '') + 'Loading ' + coin + '…'
            try {
                const r = await fetch('/api/chart?coin=' + encodeURIComponent(coin) + '&range=' + rangeSel.value)
                const data = await r.json()
                if (data.error) throw new Error(data.error)
                draw(data)
                drawRsi(data)
                const coinMeta = allCoins.find(x => x.name === coin)
                const rsiVal = (coinMeta && coinMeta.rsi != null && coinMeta.rsi !== '')
                    ? Number(coinMeta.rsi)
                    : (data.rsi != null ? Number(data.rsi) : null)
                const rsiHtml = (rsiVal != null && Number.isFinite(rsiVal))
                    ? (' · RSI <span class="' + (rsiVal < 30 ? 'rsi-os' : rsiVal > 70 ? 'rsi-ob' : 'rsi-mid') + '">' + rsiVal.toFixed(2) + '</span>')
                    : ''
                paintRsi(rsiVal)
                status.innerHTML = (note ? note + ' · ' : '') + data.prices.length + ' price points · ' + data.buys.length + ' buys · ' + data.sells.length + ' sells · ' + data.source + rsiHtml
            } catch (e) { status.textContent = 'Error: ' + e.message }
            finally { loading = false }
        }

        function showAll (note) {
            current = null
            coinSel.value = ''
            if (chart) { chart.destroy(); chart = null }
            emitFilter(null)
            paintRsi(null)
            status.textContent = (note ? note + ' · ' : '') + 'All coins — tables unfiltered'
        }

        async function pollLatestSell () {
            try {
                const r = await fetch('/api/latest-sell')
                const data = await r.json()
                if (!data || !data.coin) return
                const key = String(data.order_id || '') + '|' + String(data.t || '')
                if (key === lastSellKey) return
                lastSellKey = key
                if (!autoFollow.checked) {
                    status.textContent = 'New sell on ' + data.coin + ' (auto-follow off) · ' + (status.textContent || '')
                    return
                }
                await load(data.coin, 'Latest sell ' + data.coin)
            } catch (e) { /* keep last chart; next poll retries */ }
        }

        // Manual override: All clears filter; a coin loads chart + filters tables.
        // Auto-follow still jumps on the next sell (and refilters).
        coinSel.addEventListener('change', () => {
            if (!coinSel.value) showAll('Manual')
            else load(coinSel.value, 'Manual')
        })
        rangeSel.addEventListener('change', () => { if (current) load(current) })
        autoFollow.addEventListener('change', () => { if (autoFollow.checked) pollLatestSell() })
        document.getElementById('pf-reset').addEventListener('click', () => {
            if (chart) chart.resetZoom()
            if (rsiChart) rsiChart.resetZoom()
        })

        const searchBox = document.getElementById('pf-coin-search')
        let allCoins = []

        function renderCoinOptions (filterText) {
            const q = (filterText || '').trim().toLowerCase()
            const prev = coinSel.value
            const matched = (!q ? allCoins.slice() : allCoins.filter(c => {
                const hay = (c.name + ' ' + (c.fill_count || '')).toLowerCase()
                return hay.includes(q)
            })).sort((a, b) => a.name.localeCompare(b.name))
            // All always first, then coins A-Z.
            coinSel.innerHTML = '<option value="">All</option>' + matched.map(c => {
                const rsiBit = (c.rsi == null || c.rsi === '') ? '' : (' · RSI ' + Number(c.rsi).toFixed(2))
                const label = c.name + rsiBit
                return '<option value="' + c.name + '">' + label + '</option>'
            }).join('')
            // Keep selection if still in the filtered list; else stay on All.
            if (prev && Array.from(coinSel.options).some(o => o.value === prev)) {
                coinSel.value = prev
            } else if (prev && prev !== '') {
                // Filtered out — leave All; do not auto-load.
                coinSel.value = ''
            }
        }

        searchBox.addEventListener('input', () => renderCoinOptions(searchBox.value))

        fetch('/api/coins').then(r => r.json()).then(list => {
            // 2026-10-11: leading All clears chart filter / restores full tables.
            allCoins = list || []
            renderCoinOptions('')
            // Start on the latest sell (not merely latest fill of any side).
            pollLatestSell().then(() => {
                if (!current && allCoins[0]) load(allCoins[0].name)
                else if (!current) emitFilter(null)
            })
        }).catch(e => { coinSel.innerHTML = '<option value="">All</option>'; status.textContent = 'Error: ' + e.message })

        setInterval(pollLatestSell, POLL_MS)
        document.addEventListener('visibilitychange', () => { if (!document.hidden) pollLatestSell() })
    })()
    </script>`
}

module.exports = { listCoins, latestSell, chartData, renderSection, RANGES }
