#!/usr/bin/env node
/** Build charts/coinage_interactive.html — offline Plotly + coin dropdown. */
const fs = require('fs')
const path = require('path')
const { Client } = require('pg')
const ROOT = path.join(__dirname, '..')
process.chdir(ROOT)
const ca = require(path.join(ROOT, 'modules', 'coinbaseAuth.js'))

const DAYS = 45
const MAX_PRODUCTS = 40
const OUT = path.join(__dirname, 'coinage_interactive.html')

async function main() {
  const client = new Client({ user: 'theodorecross', database: 'coinbase', host: 'localhost' })
  await client.connect()
  const { rows: products } = await client.query(`
    SELECT product_id
    FROM fills
    WHERE product_id LIKE '%-USD' AND product_id <> '00-USD'
    GROUP BY product_id
    ORDER BY MAX(trade_time) DESC NULLS LAST
    LIMIT $1
  `, [MAX_PRODUCTS])
  const productIds = products.map(r => r.product_id)

  const end0 = Math.floor(Date.now() / 1000)
  const start0 = end0 - DAYS * 24 * 3600
  const cutoff = new Date(start0 * 1000)

  // Fills from local DB (fast)
  const { rows: fillRows } = await client.query(`
    SELECT product_id, side, price, size,
           (trade_time AT TIME ZONE 'UTC') AS trade_time
    FROM fills
    WHERE product_id = ANY($1::text[])
      AND trade_time >= $2
    ORDER BY trade_time
  `, [productIds, cutoff])
  await client.end()

  const fillsBy = {}
  for (const id of productIds) fillsBy[id] = []
  for (const f of fillRows) {
    fillsBy[f.product_id].push({
      t: new Date(f.trade_time).getTime(),
      side: String(f.side || '').toUpperCase(),
      p: Number(f.price),
      s: Number(f.size),
    })
  }

  const data = {}
  const window = 3600 * 250
  for (const productId of productIds) {
    const all = []
    for (let s = start0; s < end0; s += window) {
      const e = Math.min(s + window, end0)
      const candles = await ca.yoinkPriceData(productId, String(s), String(e), 'ONE_HOUR', 300)
      if (candles?.length) all.push(...candles)
    }
    all.sort((a, b) => Number(a.start) - Number(b.start))
    const seen = new Set()
    const candles = []
    for (const c of all) {
      if (seen.has(c.start)) continue
      seen.add(c.start)
      candles.push({ t: Number(c.start) * 1000, c: Number(c.close) })
    }
    data[productId] = { candles, fills: fillsBy[productId] || [] }
    console.log(productId, 'candles', candles.length, 'fills', data[productId].fills.length)
  }

  const payload = JSON.stringify({ days: DAYS, generated_at: new Date().toISOString(), products: productIds, data })
  const html = `<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Coinage price vs fills</title>
<script src="https://cdn.plot.ly/plotly-2.35.2.min.js"></script>
<style>
:root{color-scheme:dark}
body{margin:0;font-family:-apple-system,system-ui,sans-serif;background:#0f1115;color:#e8eaed}
header{display:flex;gap:12px;align-items:center;flex-wrap:wrap;padding:14px 18px;border-bottom:1px solid #2a2f3a}
h1{font-size:16px;margin:0;font-weight:600}
select{background:#1a1f29;color:#e8eaed;border:1px solid #3a4150;border-radius:8px;padding:8px 10px}
#meta{opacity:.7;font-size:13px}
#chart{width:100%;height:calc(100vh - 70px)}
</style></head><body>
<header>
  <h1>Coinage — price vs fills</h1>
  <label>Coin <select id="coin"></select></label>
  <span id="meta"></span>
</header>
<div id="chart"></div>
<script>
const BUNDLE=${payload};
const sel=document.getElementById('coin');
const meta=document.getElementById('meta');
for(const p of BUNDLE.products){
  const o=document.createElement('option');o.value=p;o.textContent=p;
  if(p==='ALGO-USD')o.selected=true;sel.appendChild(o);
}
function render(product){
  const d=BUNDLE.data[product]||{candles:[],fills:[]};
  const buys=d.fills.filter(f=>f.side==='BUY');
  const sells=d.fills.filter(f=>f.side==='SELL');
  meta.textContent='last '+BUNDLE.days+'d · '+d.candles.length+' hourly · '+buys.length+' buys · '+sells.length+' sells';
  const traces=[{x:d.candles.map(c=>new Date(c.t)),y:d.candles.map(c=>c.c),type:'scatter',mode:'lines',name:'Hourly close',line:{color:'#5b7c99',width:1.5}}];
  if(buys.length)traces.push({x:buys.map(f=>new Date(f.t)),y:buys.map(f=>f.p),type:'scatter',mode:'markers',name:'Buys ('+buys.length+')',marker:{symbol:'triangle-up',size:11,color:'#27ae60'},text:buys.map(f=>'size '+f.s),hovertemplate:'BUY %{y}<br>%{text}<br>%{x}<extra></extra>'});
  if(sells.length)traces.push({x:sells.map(f=>new Date(f.t)),y:sells.map(f=>f.p),type:'scatter',mode:'markers',name:'Sells ('+sells.length+')',marker:{symbol:'triangle-down',size:11,color:'#c0392b'},text:sells.map(f=>'size '+f.s),hovertemplate:'SELL %{y}<br>%{text}<br>%{x}<extra></extra>'});
  Plotly.newPlot('chart',traces,{paper_bgcolor:'#0f1115',plot_bgcolor:'#0f1115',font:{color:'#e8eaed'},margin:{l:50,r:20,t:30,b:40},xaxis:{title:'Time',gridcolor:'#2a2f3a',rangeslider:{visible:true}},yaxis:{title:'USD',gridcolor:'#2a2f3a'},legend:{orientation:'h',y:1.08},hovermode:'x unified'},{responsive:true,displaylogo:false});
}
sel.addEventListener('change',()=>render(sel.value));
render(sel.value||BUNDLE.products[0]);
</script></body></html>`
  fs.writeFileSync(OUT, html)
  console.log('wrote', OUT, 'bytes', html.length)
}
main().catch(e => { console.error(e); process.exit(1) })
