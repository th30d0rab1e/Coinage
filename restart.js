const ca = require('./modules/coinbaseAuth.js')
const db = require('./modules/database.js')

const STABLE_CURRENCIES = new Set(['USD', 'USDC', 'USDT', 'DAI'])

async function restart() {
    try {
        // Step 1: Cancel all open orders
        console.log('Fetching open orders from Coinbase...')
        const orders = await ca.gatherOrders()
        console.log(`Found ${orders.length} open orders`)
        for (const order of orders) {
            const result = await ca.cancelOrder(order.order_id)
            console.log(`Cancel ${order.product_id} ${order.side} ${order.order_id}: ${result ? 'OK' : 'FAILED'}`)
        }

        // Step 2: Market sell all non-stable balances
        console.log('Fetching account balances...')
        const accounts = await ca.gatherBalance()
        for (const account of accounts) {
            const currency = account.currency
            const available = parseFloat(account.available_balance.value)
            if (STABLE_CURRENCIES.has(currency) || available <= 0) continue

            const productId = `${currency}-USD`
            console.log(`Selling ${available} ${currency} (${productId})...`)
            const result = await ca.createMarketSellOrder(productId, available)
            if (result?.success) {
                console.log(`Sold ${currency}: OK`)
            } else {
                console.log(`Sell ${currency} failed:`, result?.error_response?.message)
            }
        }

        // Step 3: Truncate position table
        console.log('Truncating position table...')
        await db.executeQuery('TRUNCATE TABLE position;')
        console.log('Done. Position table cleared.')

    } catch (error) {
        console.log('restart()', error)
    } finally {
        process.exit(0)
    }
}

restart()
