const ca = require('./modules/coinbaseAuth.js')
const db = require('./modules/database.js')

async function fix() {
    // Rows where either ID is still a numeric string
    const rows = await db.executeQuery(`
        SELECT profit_history_id, name, buy_fee, sell_fee, buy_fills_id, sell_fills_id
        FROM profit_history
        WHERE buy_fills_id ~ '^[0-9]+$' OR sell_fills_id ~ '^[0-9]+$'
        ORDER BY profit_history_id
    `)
    console.log(`${rows.length} rows need fixing`)

    // Fetch all fills per unique product once
    const products = [...new Set(rows.map(r => r.name))]
    const fillsByProduct = {}
    for (const product of products) {
        console.log(`Fetching fills for ${product}...`)
        fillsByProduct[product] = await ca.gatherAllFillsByProduct(product)
        console.log(`  ${fillsByProduct[product].length} fills`)
    }

    let fixed = 0, failed = 0
    for (const row of rows) {
        const fills = fillsByProduct[row.name] || []

        const newBuyId = row.buy_fills_id.match(/^[0-9a-f]{8}-/)
            ? row.buy_fills_id  // already a UUID, keep it
            : matchFill(fills, 'BUY', row.buy_fee)

        const newSellId = row.sell_fills_id.match(/^[0-9a-f]{8}-/)
            ? row.sell_fills_id
            : matchFill(fills, 'SELL', row.sell_fee)

        if (!newBuyId || !newSellId) {
            console.log(`FAILED id=${row.profit_history_id} ${row.name} buy_fee=${row.buy_fee} sell_fee=${row.sell_fee} | buy=${newBuyId || 'NOT FOUND'} sell=${newSellId || 'NOT FOUND'}`)
            failed++
            continue
        }

        await db.executeQuery(`
            UPDATE profit_history
            SET buy_fills_id = '${newBuyId}', sell_fills_id = '${newSellId}'
            WHERE profit_history_id = ${row.profit_history_id}
        `)
        console.log(`OK id=${row.profit_history_id} ${row.name} | buy=${newBuyId} sell=${newSellId}`)
        fixed++
    }

    console.log(`\nDone: ${fixed} fixed, ${failed} failed`)
    process.exit(0)
}

function matchFill(fills, side, fee) {
    const match = fills.find(f =>
        f.side === side &&
        Math.abs(parseFloat(f.commission) - fee) < 0.000001
    )
    return match ? match.order_id : null
}

fix().catch(e => { console.log(e); process.exit(1) })
