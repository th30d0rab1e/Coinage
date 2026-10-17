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
               0::int AS fill_count,
               NULL::timestamptz AS last_fill
        FROM stock
        WHERE name IS NOT NULL
          AND name ~ '^[A-Z0-9]+-USD$'
          -- 2026-10-17 (Theodore): open-order filter (b5e5414) removed — the
          -- dropdown/search lists ANY coin again. Auto-follow/cycling uses
          -- OPEN_ORDER_COINS_SQL instead.
        ORDER BY name ASC`)
    return rows
}

// 2026-10-17 (Theodore): coins with an open order on Coinbase (unfilled buy or
// unfilled sell). Auto-follow and cycling only ever jump to these.
const OPEN_ORDER_COINS_SQL = `
    SELECT s.name FROM position p JOIN stock s ON s.stock_id = p.stock_id
     WHERE (p.buy_coinbase_order_id IS NOT NULL AND p.buy_filled_price IS NULL)
        OR (p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL)`
async function openOrderCoins () {
    const { rows } = await db.query(`SELECT DISTINCT name FROM (${OPEN_ORDER_COINS_SQL}) o WHERE name IS NOT NULL ORDER BY name`)
    return rows.map(r => r.name)
}

// 2026-10-11: cheapest poll for the auto-follow chart — newest SELL row only.
async function latestSell (openOnly) {
    const { rows } = await db.query(`
        SELECT product_id AS coin, trade_time AS t, price AS p, size, fee, order_id, side
        FROM fills
        WHERE side = 'SELL'
          AND product_id ~ '^[A-Z0-9]+-USD$'
          ${openOnly ? `AND product_id IN (${OPEN_ORDER_COINS_SQL})` : ''} -- 2026-10-17 (Theodore)
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

// 2026-10-11: newest BUY fill (auto-follow buys too).
async function latestBuy (openOnly) {
    const { rows } = await db.query(`
        SELECT product_id AS coin, trade_time AS t, price AS p, size, fee, order_id, side
        FROM fills
        WHERE side = 'BUY'
          AND product_id ~ '^[A-Z0-9]+-USD$'
          ${openOnly ? `AND product_id IN (${OPEN_ORDER_COINS_SQL})` : ''} -- 2026-10-17 (Theodore)
        ORDER BY trade_time DESC
        LIMIT 1`)
    const r = rows[0]
    if (!r) return null
    return { coin: r.coin, t: new Date(r.t).getTime(), p: r.p, size: r.size, fee: r.fee, order_id: r.order_id, side: r.side }
}

// 2026-10-11: newest order remake from position_audit (buy_remade_price /
// sell_remade_price UPDATE). p = new stop/trigger from the same audit moment
// (matches the chart X), market = remade market price.
async function latestRemake (openOnly) {
    const { rows } = await db.query(`
        SELECT pa.audit_id, pa.position_id, pa.changed_at AS t, pa.column_name,
               pa.new_value AS market,
               (SELECT a.new_value
                  FROM position_audit a
                 WHERE a.position_id = pa.position_id
                   AND a.operation = 'UPDATE'
                   AND a.changed_at = pa.changed_at
                   AND a.column_name = CASE WHEN pa.column_name = 'buy_remade_price'
                                            THEN 'buy_stop_price' ELSE 'sell_stop_price' END
                   AND a.new_value ~ '^[0-9.]+$'
                 ORDER BY a.audit_id LIMIT 1) AS stop,
               COALESCE(p.name,
                   (SELECT i.new_value::jsonb->>'name'
                      FROM position_audit i
                     WHERE i.position_id = pa.position_id AND i.operation = 'INSERT'
                     ORDER BY i.audit_id LIMIT 1)) AS coin
        FROM position_audit pa
        LEFT JOIN position p ON p.position_id = pa.position_id
        WHERE pa.column_name IN ('buy_remade_price', 'sell_remade_price')
          AND pa.operation = 'UPDATE'
          AND pa.new_value ~ '^[0-9.]+$'
          ${openOnly ? `AND p.name IN (${OPEN_ORDER_COINS_SQL})` : ''} -- 2026-10-17 (Theodore)
        ORDER BY pa.changed_at DESC, pa.audit_id DESC
        LIMIT 1`)
    const r = rows[0]
    if (!r || !r.coin) return null
    return {
        coin: r.coin,
        t: new Date(r.t).getTime(),
        p: r.stop != null ? Number(r.stop) : Number(r.market),
        stop: r.stop != null ? Number(r.stop) : null,
        market: Number(r.market),
        side: r.column_name === 'sell_remade_price' ? 'sell_remake' : 'buy_remake',
        position_id: r.position_id,
        audit_id: r.audit_id,
    }
}

// 2026-10-11: newest of latest sell fill, buy fill, and remake — one poll
// target for chart auto-follow. kind = 'sell' | 'buy' | 'remake'; key is a
// stable id the client compares to detect a new event.
async function latestEvent () {
    // 2026-10-17 (Theodore): only events on coins that still have an open
    // buy/sell order — never follow a coin with nothing open.
    const [sell, buy, remake] = await Promise.all([latestSell(true), latestBuy(true), latestRemake(true)])
    const ev = []
    if (sell) ev.push({ ...sell, kind: 'sell', key: 'sell|' + sell.order_id + '|' + sell.t })
    if (buy) ev.push({ ...buy, kind: 'buy', key: 'buy|' + buy.order_id + '|' + buy.t })
    if (remake) ev.push({ ...remake, kind: 'remake', key: 'remake|' + remake.audit_id + '|' + remake.t })
    if (!ev.length) return null
    ev.sort((a, b) => b.t - a.t)
    // 2026-10-12 (Theodore): sells win. A buy or remake only takes the chart
    // if it is more than SELL_HOLD_MS after the latest sell; otherwise the
    // chart stays on (or jumps to) the latest sell.
    const SELL_HOLD_MS = 5 * 60 * 1000
    const sellEv = ev.find(e => e.kind === 'sell')
    const pick = (sellEv && ev[0].kind !== 'sell' && ev[0].t - sellEv.t <= SELL_HOLD_MS) ? sellEv : ev[0]
    return { ...pick, latest: { sell, buy, remake } }
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
    // Cancelled remake orders: stamp buy_remade_price / sell_remade_price at
    // remake time (market). Chart Y is the NEW stop/trigger from the same
    // audit moment (buy_stop_price / sell_stop_price) — Theodore 2026-10-11
    // voice: green/red X at stop, not market.
    const remakeRes = await db.query(`
        SELECT pa.changed_at AS t,
               pa.column_name,
               (
                   SELECT a.new_value::numeric
                   FROM position_audit a
                   WHERE a.position_id = pa.position_id
                     AND a.operation = 'UPDATE'
                     AND a.changed_at = pa.changed_at
                     AND a.column_name = CASE
                         WHEN pa.column_name = 'buy_remade_price' THEN 'buy_stop_price'
                         ELSE 'sell_stop_price'
                     END
                     AND a.new_value ~ '^[0-9.]+$'
                   ORDER BY a.audit_id
                   LIMIT 1
               ) AS p,
               COALESCE(
                   p.name,
                   (SELECT i.new_value::jsonb->>'name'
                    FROM position_audit i
                    WHERE i.position_id = pa.position_id
                      AND i.operation = 'INSERT'
                    ORDER BY i.audit_id
                    LIMIT 1)
               ) AS name
        FROM position_audit pa
        LEFT JOIN position p ON p.position_id = pa.position_id
        WHERE pa.column_name IN ('buy_remade_price', 'sell_remade_price')
          AND pa.operation = 'UPDATE'
          AND pa.changed_at >= $2
          AND pa.new_value ~ '^[0-9.]+$'
          AND COALESCE(
                  p.name,
                  (SELECT i.new_value::jsonb->>'name'
                   FROM position_audit i
                   WHERE i.position_id = pa.position_id
                     AND i.operation = 'INSERT'
                   ORDER BY i.audit_id
                   LIMIT 1)
              ) = $1
        ORDER BY pa.changed_at`, [coin, since])
    const remakes = remakeRes.rows.map(r => ({
        t: new Date(r.t).getTime(),
        p: Number(r.p),
        side: r.column_name === 'sell_remade_price' ? 'sell_remake' : 'buy_remake',
    })).filter(d => Number.isFinite(d.t) && Number.isFinite(d.p))

    // 2026-10-11 (Theodore, voice): RSI line from rsi_history (5-min snapshots).
    // Buy logic does not read this; chart-only. Aligned to the selected range.
    const rsiRes = await db.query(`
        SELECT rh.captured_at AS t, rh.rsi AS p
        FROM rsi_history rh
        JOIN stock s ON s.stock_id = rh.stock_id
        WHERE s.name = $1
          AND rh.captured_at >= $2
        ORDER BY rh.captured_at`, [coin, since])
    const rsiSeries = rsiRes.rows.map(r => ({
        t: new Date(r.t).getTime(),
        p: Number(r.p),
    })).filter(d => Number.isFinite(d.t) && Number.isFinite(d.p))

    // 2026-10-12: open (resting) orders as hollow circles. Y = stop/trigger
    // (same convention as remake X), falling back to limit. Chart-only.
    // 2026-10-13 (Theodore): X = when the order was actually placed on
    // Coinbase (bulk_open_orders.created_time, stored as UTC), not the buy
    // fill / remake time. Joined on the live Coinbase order id, so only orders
    // really resting on Coinbase are drawn (priced-but-unplaced sells have no
    // placement time and are no longer shown as open).
    const openRes = await db.query(`
        SELECT p.position_id,
               CASE WHEN p.buy_filled_price IS NULL THEN 'buy' ELSE 'sell' END AS side,
               CASE WHEN p.buy_filled_price IS NULL THEN COALESCE(p.buy_stop_price, p.buy_price)
                    ELSE COALESCE(p.sell_stop_price, p.sell_price) END AS p,
               CASE WHEN p.buy_filled_price IS NULL THEN COALESCE(p.buy_price, p.buy_stop_price)
                    ELSE COALESCE(p.sell_price, p.sell_stop_price) END AS lim,
               o.created_time AT TIME ZONE 'UTC' AS t
        FROM position p
        JOIN bulk_open_orders o
          ON o.order_id = CASE WHEN p.buy_filled_price IS NULL
                               THEN p.buy_coinbase_order_id
                               ELSE p.sell_coinbase_order_id END
        WHERE p.name = $1
          AND p.sell_filled_price IS NULL`, [coin])
    const openOrders = openRes.rows.map(r => ({
        t: Math.max(new Date(r.t).getTime(), since.getTime()),
        p: Number(r.p), limit: Number(r.lim), side: r.side, position_id: r.position_id,
    })).filter(d => Number.isFinite(d.t) && Number.isFinite(d.p) && d.p > 0)

    // 2026-10-13 (Theodore): buy->sell pairs for the dotted pairing lines.
    // Closed trades: profit_history links buy_coinbase_order_id -> sell_fills_id
    // (both are fills.order_id). Positions still on the table with a filled sell
    // link buy_coinbase_order_id -> sell_coinbase_order_id. Each end = that order's
    // FIRST fill (same dot plotted on the chart). Both ends must be inside the range.
    const pairRes = await db.query(`
        WITH links AS (
            SELECT buy_coinbase_order_id AS buy_oid, sell_fills_id AS sell_oid
            FROM profit_history WHERE name = $1
            UNION
            SELECT buy_coinbase_order_id, sell_coinbase_order_id
            FROM position WHERE name = $1 AND sell_filled_price IS NOT NULL
        ),
        first_fill AS (   -- earliest fill per order in range
            SELECT DISTINCT ON (order_id) order_id, trade_time AS t, price AS p
            FROM fills WHERE product_id = $1 AND trade_time >= $2
            ORDER BY order_id, trade_time
        )
        SELECT b.t AS bt, b.p AS bp, s.t AS st, s.p AS sp
        FROM links l
        JOIN first_fill b ON b.order_id = l.buy_oid
        JOIN first_fill s ON s.order_id = l.sell_oid`, [coin, since])
    // Open bags: filled buy -> its resting sell order (the hollow red circle).
    const openPairRes = await db.query(`
        SELECT DISTINCT ON (p.position_id) p.position_id, f.trade_time AS bt, f.price AS bp
        FROM position p
        JOIN fills f ON f.order_id = p.buy_coinbase_order_id AND f.trade_time >= $2
        WHERE p.name = $1 AND p.buy_filled_price IS NOT NULL AND p.sell_filled_price IS NULL
        ORDER BY p.position_id, f.trade_time`, [coin, since])
    const pairs = pairRes.rows.map(r => ({ bt: new Date(r.bt).getTime(), bp: Number(r.bp), st: new Date(r.st).getTime(), sp: Number(r.sp), open: false }))
    for (const r of openPairRes.rows) {
        const o = openOrders.find(x => x.side === 'sell' && x.position_id === r.position_id)
        if (o) pairs.push({ bt: new Date(r.bt).getTime(), bp: Number(r.bp), st: o.t, sp: o.p, open: true })
    }

    return {
        coin, range, source,
        pairs: pairs.filter(x => [x.bt, x.bp, x.st, x.sp].every(Number.isFinite)),
        prices,
        buys: fills.filter(f => f.side === 'BUY').map(mapFill),
        sells: fills.filter(f => f.side === 'SELL').map(mapFill),
        // Split by side so the chart can color buy remakes green and sell remakes red.
        remakes,
        buy_remakes: remakes.filter(r => r.side === 'buy_remake'),
        sell_remakes: remakes.filter(r => r.side === 'sell_remake'),
        rsiSeries,
        open_buys: openOrders.filter(o => o.side === 'buy'),
        open_sells: openOrders.filter(o => o.side === 'sell'),
    }
}

function renderSection () {
    const ranges = Object.keys(RANGES).map(r => `<option value="${r}"${r === '7d' ? ' selected' : ''}>${r}</option>`).join('')
    // 2026-10-11: auto-follow the coin of the newest event — buy fill, sell fill,
    // or order remake (poll /api/latest-event). Dropdown is a manual override;
    // a newer event jumps the chart again.
    return `
    <h2>Price &amp; Fills Chart</h2>
    <div id="pf-controls" style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:8px;font-size:13px">
        <label for="pf-coin-search" class="dim">Search</label>
        <input id="pf-coin-search" type="search" placeholder="Type to filter…" autocomplete="off"
            style="background:#1a1a1a;color:#ddd;border:1px solid #333;border-radius:6px;padding:6px 10px;min-width:140px;max-width:200px">
        <label for="pf-coin" class="dim">Coin</label>
        <select id="pf-coin" style="background:#1a1a1a;color:#ddd;border:1px solid #333;border-radius:6px;padding:6px 10px;min-width:220px;max-width:360px">
            <option value="">Loading coins…</option>
        </select>
        <label style="display:flex;align-items:center;gap:6px;cursor:pointer" title="When on, jump to whichever coin had the newest buy fill, sell fill, or order remake">
            <input type="checkbox" id="pf-autofollow" checked>
            <span class="dim">Auto-follow latest buy/sell/remake</span>
        </label>
        <select id="pf-range" style="background:#1a1a1a;color:#ddd;border:1px solid #333;border-radius:6px;padding:6px">${ranges}</select>
        <button id="pf-reset" style="background:#333;color:#ddd;border:0;border-radius:6px;padding:6px 10px">Reset zoom</button>
        <!-- 2026-10-12 (Theodore): shown while rotation is paused by a manual pick -->
        <button id="pf-resume" style="display:none;background:#2563eb;color:#fff;border:0;border-radius:6px;padding:6px 10px">Resume cycling</button>
        <span id="pf-status" class="dim"></span>
    </div>
    <div style="position:relative;height:420px;background:#151515;border-radius:8px;padding:8px"><canvas id="pf-chart"></canvas></div>
    <div class="dim" style="font-size:12px;margin-top:4px">
        Polls buys, sells and remakes every 1 minute while this tab is open. Leave the browser window open on this machine to keep watching.
        <span class="buy-tag">● buy fill</span> <span class="sell-tag">● sell fill</span>
        <span style="color:#22c55e">✕ buy remake</span> <span style="color:#ef4444">✕ sell remake</span>
        <span style="color:#22c55e">○ open buy</span> <span style="color:#ef4444">○ open sell</span>
        <span style="color:#22c55e">··· RSI&lt;50</span> <span style="color:#ef4444">··· RSI&gt;50</span>
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
        let chart = null, current = null, lastEventKey = null, loading = false
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
            // 2026-10-11 (Theodore, voice): one RSI series on right y1 (0–100),
            // segment.borderColor green under 50 / red above (0bf8564 pattern).
            // Single dataset — split series hid short runs. Points show 1-sample buckets.
            const rsiRaw = toXY(data.rsiSeries || [])
            // Green under 50 / red at or above 50. Always draw points so a short
            // rsi_history window is still visible on a multi-day price chart.
            const rsiColor = (y) => (y < 50 ? '#22c55e' : '#ef4444')
            const rsiY = (ctx) => {
                const p = ctx && ctx.p1
                if (!p) return null
                if (p.parsed && Number.isFinite(p.parsed.y)) return p.parsed.y
                if (p.raw && Number.isFinite(p.raw.y)) return p.raw.y
                return null
            }
            const ds = [
                { label: data.coin + ' price', data: toXY(data.prices), type: 'line', yAxisID: 'y', borderColor: '#60a5fa', borderWidth: 1.5, pointRadius: 0, tension: 0, order: 3 },
                {
                    label: 'RSI(7)',
                    data: rsiRaw,
                    type: 'line',
                    yAxisID: 'y1',
                    borderColor: rsiRaw.length ? rsiColor(rsiRaw[rsiRaw.length - 1].y) : '#9ca3af',
                    borderWidth: 2.5,
                    // 2026-10-11 (Theodore, voice): no point markers — red dots
                    // looked like sell fills. Line + segment colors only.
                    pointRadius: 0,
                    pointHoverRadius: 4,
                    pointHitRadius: 8,
                    tension: 0,
                    spanGaps: false,
                    order: 2,
                    segment: {
                        borderColor: (ctx) => {
                            const y = rsiY(ctx)
                            return y == null ? '#9ca3af' : rsiColor(y)
                        },
                    },
                },
                { label: 'Buy fills', data: toXY(data.buys), type: 'line', yAxisID: 'y', showLine: false, backgroundColor: '#22c55e', borderColor: '#bbf7d0', pointBackgroundColor: '#22c55e', pointBorderColor: '#bbf7d0', pointRadius: 6, pointHoverRadius: 9, order: 1 },
                { label: 'Sell fills', data: toXY(data.sells), type: 'line', yAxisID: 'y', showLine: false, backgroundColor: '#ef4444', borderColor: '#fecaca', pointBackgroundColor: '#ef4444', pointBorderColor: '#fecaca', pointRadius: 6, pointHoverRadius: 9, order: 1 },
                // 2026-10-11 (Theodore, voice): remake cancels as X by side —
                // green X = buy remake, red X = sell remake (fills stay solid dots).
                { label: 'Buy remake', data: toXY(data.buy_remakes || (data.remakes || []).filter(r => r.side === 'buy_remake')), type: 'scatter', yAxisID: 'y', backgroundColor: '#22c55e', borderColor: '#bbf7d0', pointBackgroundColor: '#22c55e', pointBorderColor: '#86efac', pointStyle: 'crossRot', radius: 8, hoverRadius: 11, borderWidth: 2, order: 10 },
                { label: 'Sell remake', data: toXY(data.sell_remakes || (data.remakes || []).filter(r => r.side === 'sell_remake')), type: 'scatter', yAxisID: 'y', backgroundColor: '#ef4444', borderColor: '#fecaca', pointBackgroundColor: '#ef4444', pointBorderColor: '#fca5a5', pointStyle: 'crossRot', radius: 8, hoverRadius: 11, borderWidth: 2, order: 10 },
                { label: 'Open buy', data: toXY(data.open_buys || []), type: 'scatter', yAxisID: 'y', pointStyle: 'circle', backgroundColor: 'rgba(0,0,0,0)', pointBackgroundColor: 'rgba(0,0,0,0)', borderColor: '#22c55e', pointBorderColor: '#22c55e', pointBorderWidth: 2, borderWidth: 2, radius: 6, hoverRadius: 9, order: 9 },
                { label: 'Open sell', data: toXY(data.open_sells || []), type: 'scatter', yAxisID: 'y', pointStyle: 'circle', backgroundColor: 'rgba(0,0,0,0)', pointBackgroundColor: 'rgba(0,0,0,0)', borderColor: '#ef4444', pointBorderColor: '#ef4444', pointBorderWidth: 2, borderWidth: 2, radius: 6, hoverRadius: 9, order: 9 },
            ]
            // 2026-10-13 (Theodore): dotted gray line from each buy fill to its paired
            // sell (filled sell dot, or resting sell = hollow red circle). Drawn by a
            // tiny per-chart plugin under the markers: no datasets, legend or tooltips.
            const pairs = data.pairs || []
            const pairLines = {
                id: 'pairLines',
                beforeDatasetsDraw (c) {
                    const { ctx, chartArea: a, scales: { x, y } } = c
                    ctx.save()
                    ctx.beginPath(); ctx.rect(a.left, a.top, a.right - a.left, a.bottom - a.top); ctx.clip()
                    ctx.setLineDash([4, 4]); ctx.lineWidth = 1; ctx.strokeStyle = 'rgba(200,200,200,0.55)'
                    let drawn = 0
                    for (const pr of pairs) {
                        ctx.beginPath()
                        ctx.moveTo(x.getPixelForValue(pr.bt), y.getPixelForValue(pr.bp))
                        ctx.lineTo(x.getPixelForValue(pr.st), y.getPixelForValue(pr.sp))
                        ctx.stroke(); drawn++
                    }
                    ctx.restore()
                    c.$pairLinesDrawn = drawn   // exposed for testing
                },
            }
            if (chart) chart.destroy()
            chart = new Chart(document.getElementById('pf-chart'), {
                type: 'line',
                plugins: [pairLines],
                data: { datasets: ds },
                options: {
                    responsive: true, maintainAspectRatio: false, animation: false, parsing: false,
                    interaction: { mode: 'nearest', intersect: false },
                    scales: {
                        x: { type: 'time', ticks: { color: '#888' }, grid: { color: '#222' } },
                        y: { type: 'linear', position: 'left', ticks: { color: '#888' }, grid: { color: '#222' } },
                        y1: {
                            type: 'linear', position: 'right', min: 0, max: 100,
                            grid: { drawOnChartArea: false },
                            ticks: { color: '#9ca3af', callback: v => v },
                            title: { display: true, text: 'RSI', color: '#9ca3af' },
                        },
                    },
                    elements: { point: { pointStyle: 'circle' } },
                    plugins: {
                        legend: { labels: { color: '#ccc', usePointStyle: true } },
                        tooltip: { callbacks: { label: c => {
                            const d = c.raw
                            if (c.dataset.yAxisID === 'y1') return c.dataset.label + ': ' + Number(d.y).toFixed(2)
                            const base = c.dataset.label + ': $' + d.y
                            return d.size != null ? base + '  size ' + d.size + '  fee $' + Number(d.fee).toFixed(4) : base
                        } } },
                        // 2026-10-13 (Theodore): no scroll/pinch zoom on the chart (drag-pan kept)
                        zoom: { pan: { enabled: true, mode: 'x' }, zoom: { wheel: { enabled: false }, pinch: { enabled: false }, mode: 'x' } },
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
                const nBuyRem = (data.buy_remakes && data.buy_remakes.length) || ((data.remakes || []).filter(r => r.side === 'buy_remake').length)
                const nSellRem = (data.sell_remakes && data.sell_remakes.length) || ((data.remakes || []).filter(r => r.side === 'sell_remake').length)
                const nRsi = (data.rsiSeries && data.rsiSeries.length) || 0
                status.textContent = (note ? note + ' · ' : '') + data.prices.length + ' price points · ' + data.buys.length + ' buys · ' + data.sells.length + ' sells · ' + nBuyRem + ' buy remakes · ' + nSellRem + ' sell remakes · ' + nRsi + ' RSI · ' + data.source
            } catch (e) { status.textContent = 'Error: ' + e.message }
            finally { loading = false }
        }

        function showAll (note) {
            current = null
            coinSel.value = ''
            if (chart) { chart.destroy(); chart = null }
            emitFilter(null)
            status.textContent = (note ? note + ' · ' : '') + 'All coins — tables unfiltered'
        }

        // Newest of buy fill / sell fill / remake (server picks by timestamp),
        // so buys, sells and remakes never fight — the latest one wins.
        const KIND_LABEL = { sell: 'Latest sell', buy: 'Latest buy', remake: 'Latest remake' }
        async function pollLatestEvent () {
            try {
                const r = await fetch('/api/latest-event', { cache: 'no-store' })
                const data = await r.json()
                if (!data || !data.coin || !data.key) return
                if (data.key === lastEventKey) return
                lastEventKey = data.key
                let label = KIND_LABEL[data.kind] || 'Latest'
                if (data.kind === 'remake') label = data.side === 'sell_remake' ? 'Latest sell remake' : 'Latest buy remake'
                if (!autoFollow.checked) {
                    status.textContent = label + ' on ' + data.coin + ' (auto-follow off) · ' + (status.textContent || '')
                    return
                }
                await load(data.coin, label + ' ' + data.coin)
                // Trade event interrupts rotation: hold this coin one full slot, then resume.
                scheduleRotate(ROTATE_MS)
            } catch (e) { /* keep last chart; next poll retries */ }
        }

        // Manual override: All clears filter; a coin loads chart + filters tables.
        // Auto-follow still jumps on the next sell (and refilters).
        // 2026-10-12: only real user picks (and coin-link clicks, which dispatch
        // 'change') land here — rotation calls load() directly and setting
        // coinSel.value in code never fires 'change' — so this = manual pause.
        coinSel.addEventListener('change', () => {
            pauseRotation()
            if (!coinSel.value) showAll('Manual')
            else load(coinSel.value, 'Manual')
        })
        rangeSel.addEventListener('change', () => { if (current) load(current) })
        autoFollow.addEventListener('change', () => { if (autoFollow.checked) pollLatestEvent() })
        document.getElementById('pf-reset').addEventListener('click', () => chart && chart.resetZoom())

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
                const label = c.name
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
            // Start on the newest buy/sell/remake.
            pollLatestEvent().then(() => {
                if (!current && allCoins[0]) load(allCoins[0].name)
                else if (!current) emitFilter(null)
            })
        }).catch(e => { coinSel.innerHTML = '<option value="">All</option>'; status.textContent = 'Error: ' + e.message })

        // 2026-10-12 (Theodore): rotate through the Positions coins every 20s.
        // List = buying/bought/selling rows (sold skipped), deduped, in the table's
        // CURRENT DOM order (re-read every step, so re-sorting changes the order).
        const ROTATE_MS = window.PF_ROTATE_MS || 20000
        const resumeBtn = document.getElementById('pf-resume')
        let rotateTimer = null, paused = false, lastRotCoin = null
        // 2026-10-17 (Theodore): cycle only coins with an open buy/sell order
        // (refreshed from /api/open-order-coins each poll).
        let openCoins = null
        function refreshOpenCoins () {
            return fetch('/api/open-order-coins', { cache: 'no-store' }).then(r => r.json())
                .then(l => { if (Array.isArray(l)) openCoins = l }).catch(() => {})
        }
        refreshOpenCoins()
        setInterval(refreshOpenCoins, POLL_MS)
        function rotationCoins () {
            const out = []
            document.querySelectorAll('#positions-table tbody tr[data-coin]').forEach(tr => {
                if (tr.querySelector('.kind-sold')) return
                const c = tr.getAttribute('data-coin')
                if (c && !out.includes(c)) out.push(c)
            })
            if (!openCoins) return out
            // Positions-table order first, then any other open-order coins.
            const list = out.filter(c => openCoins.includes(c))
            openCoins.forEach(c => { if (!list.includes(c)) list.push(c) })
            return list
        }
        function scheduleRotate (ms) {
            clearTimeout(rotateTimer)
            if (!paused) rotateTimer = setTimeout(rotateStep, ms)
        }
        function rotateStep () {
            const list = rotationCoins()
            if (list.length) {
                // Continue after the last coin rotation showed (wraps around).
                const next = list[(list.indexOf(lastRotCoin) + 1) % list.length]
                lastRotCoin = next
                load(next, 'Cycling ' + (list.indexOf(next) + 1) + '/' + list.length)
            }
            scheduleRotate(ROTATE_MS)
        }
        function pauseRotation () {
            paused = true
            clearTimeout(rotateTimer)
            resumeBtn.style.display = ''
        }
        resumeBtn.addEventListener('click', () => {
            paused = false
            resumeBtn.style.display = 'none'
            rotateStep()   // pick up right where rotation left off
        })
        scheduleRotate(ROTATE_MS)

        setInterval(pollLatestEvent, POLL_MS)
        document.addEventListener('visibilitychange', () => { if (!document.hidden) pollLatestEvent() })
    })()
    </script>`
}

module.exports = { listCoins, openOrderCoins, latestSell, latestBuy, latestRemake, latestEvent, chartData, renderSection, RANGES }
