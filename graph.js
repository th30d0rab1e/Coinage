const { Pool } = require('pg');
const fs = require('fs');
const path = require('path');

const con = new Pool({
    user: 'theodorecross',
    host: 'localhost',
    database: 'coinbase',
    password: '',
    port: 5432,
});

// If aggregate table uses different column names, adjust these:
const AGG_DATE_COL  = 'date';
const AGG_PRICE_COL = 'close';
const AGG_NAME_COL  = 'name';

async function main() {
    try {
        const coin = process.argv[2];

        if (!coin) {
            const result = await con.query(`SELECT DISTINCT product_id FROM bulk_fills ORDER BY product_id`);
            console.log('Usage: node graph.js <COIN-USD>\n');
            console.log('Available coins:');
            result.rows.forEach(r => console.log(' ', r.product_id));
            return;
        }

        console.log(`Fetching data for ${coin}...`);

        const [aggResult, fillResult] = await Promise.all([
            con.query(
                `SELECT ${AGG_DATE_COL} as date, ${AGG_PRICE_COL} as price
                 FROM aggregate
                 WHERE period_type = 'day' AND ${AGG_NAME_COL} = $1
                 ORDER BY ${AGG_DATE_COL} ASC`,
                [coin]
            ),
            con.query(
                `SELECT created_at, price, size, side
                 FROM bulk_fills
                 WHERE product_id = $1
                 ORDER BY created_at ASC`,
                [coin]
            )
        ]);

        console.log(`Aggregate rows: ${aggResult.rows.length}`);
        console.log(`Fill rows:      ${fillResult.rows.length}`);

        const sizes = fillResult.rows.map(r => parseFloat(r.size)).filter(s => !isNaN(s));
        const minSize = Math.min(...sizes);
        const maxSize = Math.max(...sizes);
        const toRadius = s => maxSize === minSize ? 8 : 3 + ((s - minSize) / (maxSize - minSize)) * 17;

        const lineData = aggResult.rows.map(r => ({
            x: new Date(r.date).getTime(),
            y: parseFloat(r.price)
        }));

        const buyData = fillResult.rows
            .filter(r => r.side === 'BUY')
            .map(r => ({
                x: new Date(r.created_at).getTime(),
                y: parseFloat(r.price),
                r: toRadius(parseFloat(r.size)),
                size: parseFloat(r.size)
            }));

        const sellData = fillResult.rows
            .filter(r => r.side === 'SELL')
            .map(r => ({
                x: new Date(r.created_at).getTime(),
                y: parseFloat(r.price),
                r: toRadius(parseFloat(r.size)),
                size: parseFloat(r.size)
            }));

        const html = buildHTML(coin, lineData, buyData, sellData);
        const outPath = path.join(__dirname, 'graph.html');
        fs.writeFileSync(outPath, html);
        console.log(`\nDone. Open: ${outPath}`);

    } catch (error) {
        console.error('Error:', error.message);
    } finally {
        await con.end();
    }
}

function buildHTML(coin, lineData, buyData, sellData) {
    return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>${coin} Chart</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { background: #0f0f1a; color: #e0e0e0; font-family: -apple-system, sans-serif; padding: 24px; }
    h1 { font-size: 1.4rem; font-weight: 600; margin-bottom: 16px; color: #fff; }
    .stats { display: flex; gap: 24px; margin-bottom: 20px; }
    .stat { background: #1a1a2e; border-radius: 6px; padding: 12px 18px; }
    .stat-label { font-size: 0.7rem; color: #888; text-transform: uppercase; letter-spacing: 0.05em; }
    .stat-value { font-size: 1.1rem; font-weight: 600; margin-top: 2px; }
    .buy  { color: #22c55e; }
    .sell { color: #ef4444; }
    .chart-wrap { background: #1a1a2e; border-radius: 8px; padding: 20px; }
  </style>
</head>
<body>
  <h1>${coin}</h1>

  <div class="stats">
    <div class="stat">
      <div class="stat-label">Buys</div>
      <div class="stat-value buy">${buyData.length}</div>
    </div>
    <div class="stat">
      <div class="stat-label">Sells</div>
      <div class="stat-value sell">${sellData.length}</div>
    </div>
    <div class="stat">
      <div class="stat-label">Price Points</div>
      <div class="stat-value">${lineData.length}</div>
    </div>
  </div>

  <div class="chart-wrap">
    <canvas id="chart"></canvas>
  </div>

  <script src="https://cdn.jsdelivr.net/npm/luxon@3/build/global/luxon.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-luxon@1/dist/chartjs-adapter-luxon.umd.min.js"></script>
  <script>
    const lineData = ${JSON.stringify(lineData)};
    const buyData  = ${JSON.stringify(buyData)};
    const sellData = ${JSON.stringify(sellData)};

    new Chart(document.getElementById('chart'), {
      data: {
        datasets: [
          {
            type: 'line',
            label: 'Price',
            data: lineData,
            borderColor: '#3b82f6',
            backgroundColor: 'rgba(59,130,246,0.08)',
            borderWidth: 1.5,
            pointRadius: 0,
            fill: true,
            tension: 0.2,
            order: 2
          },
          {
            type: 'bubble',
            label: 'Buy',
            data: buyData,
            backgroundColor: 'rgba(34,197,94,0.55)',
            borderColor: 'rgba(34,197,94,0.9)',
            borderWidth: 1,
            order: 0
          },
          {
            type: 'bubble',
            label: 'Sell',
            data: sellData,
            backgroundColor: 'rgba(239,68,68,0.55)',
            borderColor: 'rgba(239,68,68,0.9)',
            borderWidth: 1,
            order: 1
          }
        ]
      },
      options: {
        responsive: true,
        interaction: { mode: 'nearest', intersect: true },
        plugins: {
          legend: {
            labels: { color: '#ccc', usePointStyle: true, padding: 20 }
          },
          tooltip: {
            backgroundColor: '#1e1e3a',
            titleColor: '#fff',
            bodyColor: '#ccc',
            callbacks: {
              title: items => {
                const ms = items[0].parsed.x;
                return new Date(ms).toLocaleDateString('en-US', { year:'numeric', month:'short', day:'numeric' });
              },
              label: ctx => {
                const price = ctx.parsed.y;
                const prefix = price < 0.01 ? price.toFixed(6) : price < 1 ? price.toFixed(4) : price.toFixed(2);
                if (ctx.dataset.type === 'bubble') {
                  const size = ctx.raw.size;
                  return \` \${ctx.dataset.label}  $\${prefix}  (\${size} units)\`;
                }
                return \` Price  $\${prefix}\`;
              }
            }
          }
        },
        scales: {
          x: {
            type: 'time',
            time: {
              unit: 'month',
              displayFormats: { day: 'MMM d', month: 'MMM yyyy' }
            },
            ticks: { color: '#888', maxTicksLimit: 10 },
            grid: { color: '#252540' }
          },
          y: {
            ticks: {
              color: '#888',
              callback: v => {
                if (v < 0.01) return '$' + v.toFixed(6);
                if (v < 1)    return '$' + v.toFixed(4);
                if (v < 1000) return '$' + v.toFixed(2);
                return '$' + v.toLocaleString();
              }
            },
            grid: { color: '#252540' }
          }
        }
      }
    });
  </script>
</body>
</html>`;
}

main();
