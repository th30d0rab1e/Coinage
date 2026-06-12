var ca = require('./modules/coinbaseAuth.js')
var db = require('./modules/database.js')
const crypto = require('crypto')
main()

///Users/theodorecross/Library/Mobile Documents/com~apple~CloudDocs/Coinbase tedTosterone/

async function main () {
    try {

        //call thee procedure
        await db.executeQuery('Call thee_procedure();');
        //call aggregation
        await db.executeQuery('CALL aggregate();')
        //call aggregate comparison

        //call aggregate totals

        //process historical data
        await processHistoricalPrices();

         //process new coins
        const pnc = processNewCoins();
        //get balance
        const pnb = processNewBalance();
        //get fills
        const pnf = processNewFills();
        //get Open Orders
        const poo = processOpenOrders();
        //get Price Datacan 
        const ppd = processPriceData();

        const [pncR, pnbR, pnfR, pooR, ppdR] = await Promise.all([pnc, pnb, pnf, poo, ppd]);

        //cancel buy orders 
        //await processBuyOrdersOutOfRange(pnfR)

        //make buy orders
        await processBuyOrders();

        //make sell orders
        await processSellOrders();

        //Remake Orders
        await processRemakeOrders();

        //Transfer 20% profit to USDC for taxes
        await processTransfers();
        
    } catch (error) {
        console.log("main", error)
    } finally {
        //await db.end();
        console.log(`End Program ${new Date().toLocaleString()}`)
        console.log('<-------------------------------------------------------------->');
    }
}

async function processNewCoins() {
    try {
        let results = await ca.fetchProducts('')
        console.log(`New Coins: ${results.length}`)
        await db.downloadStocks(results);
        return results;
    } catch (error) {
        console.log("processNewCoins() ERROR", error)
    }
}

async function processNewFills () {
    try {
        let results = await ca.gatherFills()
        console.log(`Fills: ${results.length}`)
        await db.insertFills(results)
    } catch (error) {
        console.log("processNewFills() ERROR", error)
    }
}

async function processOpenOrders () {
    try {
        let results = await ca.gatherOrders();
        let buyCount = 0, sellCount = 0, buyAmount = 0, sellAmount = 0;
        for (let i = 0; i < results.length; i++) {
            const element = results[i];
            if(element.side == 'BUY'){
                buyCount++
                buyAmount = buyAmount + Number(element.total_value_after_fees)
            } else if(element.side == 'SELL') {
                sellCount++;
                sellAmount = sellAmount + Number(element.total_value_after_fees);
            }
        };
        console.log(`Open Orders — Buy: ${buyCount} ($${buyAmount.toFixed(2)}) | Sell: ${sellCount} ($${sellAmount.toFixed(2)})`)
        await db.insertOpenOrders(results);
    } catch (error) {
        console.log("processOpenOrders() ERROR", error)
    }
}

async function processNewBalance () {
    try {
        let results = await ca.gatherBalance();
        console.log(`Balance: ${results.length} accounts`)
        await db.insertCurrency(results);
    } catch (error) {
        console.log("processNewBalance() ERROR", error);
    }
}

async function processBuyOrders () {
    try {
        const orders = await db.executeQuery(`SELECT * FROM position WHERE buy_coinbase_order_id IS NULL AND error_message IS NULL;`)
        console.log(`Buy Orders to Process: ${orders.length}`);

        for (i = 0; i < orders.length; i++) {
            const element = orders[i];
            let response = await ca.createStopLimitOrder('buy', element.buy_price, element.shares, element.name, element.buy_stop_price, element.buy_order_id);
            if(response.success == true) {
                await db.executeQuery(`UPDATE position SET buy_coinbase_order_id = '${response.success_response.order_id}' WHERE buy_order_id = '${element.buy_order_id}'`)
                console.log(`Buy Order Created: ${element.name} | shares: ${element.shares} | price: ${element.buy_price}`)
            } else {
                await db.executeQuery(`UPDATE position SET error_message = '${response.error_response.message}' WHERE buy_order_id = '${element.buy_order_id}'`)
                console.log(`Buy Order FAILED: ${element.name}`, response)
            }
        }

    } catch (error) {
        console.log("processBuyOrders() ERROR", error)
    }
}

async function processSellOrders () {
    try {
        const orders = await db.executeQuery(`SELECT * FROM position WHERE buy_filled_price IS NOT NULL AND sell_coinbase_order_id IS NULL AND sell_price IS NOT NULL AND error_message IS NULL;`)
        console.log(`Sell Orders to Process: ${orders.length}`);
        for(let i = 0; i < orders.length; i++) {
            let element = orders[i];
            const newSellOrderId = crypto.randomUUID()
            let response = await ca.createStopLimitOrder('sell', element.sell_price, element.shares, element.name, element.sell_stop_price, newSellOrderId)
            if(response?.success == true) {
                await db.executeQuery(`UPDATE position SET sell_coinbase_order_id = '${response.success_response.order_id}', sell_order_id = '${newSellOrderId}' WHERE buy_order_id = '${element.buy_order_id}'`)
                console.log(`Sell Order Created: ${element.name} | shares: ${element.shares} | price: ${element.sell_price}`)
            } else {
                await db.executeQuery(`UPDATE position SET error_message = '${response.error_response.message}' WHERE buy_order_id = '${element.buy_order_id}'`)
                console.log(`Sell Order FAILED: ${element.name}`, response)
            }
        }
    } catch (error) {
        console.log("processSellOrders() ERROR", error)
    }
}

async function processRemakeOrders () {
    try {
        const orders = await db.executeQuery(`SELECT * FROM vw_edit_orders ORDER BY estimated_profit DESC LIMIT 1;`)
        for(let i = 0; i < orders.length; i++){
            let element = orders[i];
            const previewOk = await ca.previewStopLimitOrder(element.order_type, element.order_price, element.shares, element.name, element.new_stop_price)
            if(!previewOk) {
                console.log(`Remake Preview FAILED: ${element.name} ${element.order_type}, skipping`)
                continue
            }
            let cancelResponse = await ca.cancelOrder(element.coinbase_order_id)
            if(cancelResponse == true) {
                const newOrderId = crypto.randomUUID()
                let reMakeResponse = await ca.createStopLimitOrder(element.order_type, element.order_price, element.shares, element.name, element.new_stop_price, newOrderId)
                if(reMakeResponse?.success == true) {
                    if(element.order_type === 'buy') {
                        await db.executeQuery(`UPDATE position SET buy_order_id = '${newOrderId}', buy_coinbase_order_id = '${reMakeResponse.success_response.order_id}', buy_stop_price = ${element.new_stop_price}, buy_price = ${element.order_price} WHERE buy_order_id = '${element.buy_order_id}'`)
                    } else {
                        await db.executeQuery(`UPDATE position SET sell_order_id = '${newOrderId}', sell_coinbase_order_id = '${reMakeResponse.success_response.order_id}', sell_stop_price = ${element.new_stop_price}, sell_price = ${element.order_price} WHERE buy_order_id = '${element.buy_order_id}'`)
                    }
                    console.log(`Remake OK: ${element.name} ${element.order_type} | shares: ${element.shares} | new stop: ${element.new_stop_price} | est profit: ${element.estimated_profit}`)
                } else {
                    await db.executeQuery(`UPDATE position SET error_message = '${reMakeResponse.error_response.message}' WHERE buy_order_id = '${element.buy_order_id}'`)
                    console.log(`Remake Create FAILED: ${element.name} ${element.order_type}`, reMakeResponse)
                }
            } else {
                console.log(`Remake Cancel FAILED: ${element.name} ${element.order_type}`, cancelResponse)
            }
        }
    } catch (error) {
        console.log("processRemakeOrders() ERROR", error)
    }
}

async function processPriceData () {
    try{
       // Current time in seconds
        const nowUnixSeconds = Math.floor(Date.now() / 1000); // Divide by 1000 to convert milliseconds to seconds

        // Subtract 24 hours (24 hours * 60 minutes * 60 seconds)
        const oneDayAgoUnixSeconds = nowUnixSeconds - 48 * 60 * 60;

        const priceData = await ca.yoinkPriceData('BTC-USD', oneDayAgoUnixSeconds, nowUnixSeconds, 'ONE_DAY');
        
        let highest = -Infinity; // Start with lowest possible number
        let lowest = Infinity; // Start with highest possible number

        for (let i = 0; i < priceData.length; i++) {
            const high = Number(priceData[i].high); // Convert to number
            const low = Number(priceData[i].low); // Convert to number

            if (high > highest) {
                highest = high;
                //console.log(`New highest: ${high}`);
            }
            if (low < lowest) {
                lowest = low;
                //console.log(`New lowest: ${low}`);
            }
        }
        const spread = ((highest - lowest) / lowest) * 100
        //console.log(spread, highest, lowest, priceData)
        console.log(`spread:  ${spread} ${highest} ${lowest} ${priceData}`)
        return spread;
    } catch (error) {
        console.log('processPriceData()', error)
    }
}

async function processBuyOrdersOutOfRange (fills) {
    try{
        let sellDate = new Date(fills[0].trade_time)
        console.log(`Latest Order ${fills[0].side} ${sellDate}`)
        
        if(fills[0].side == 'SELL'){
            let openOrders = await ca.gatherOrders();
            for(i=0;i<openOrders.length; i++){
                let element = openOrders[i]
                //console.log(element.created_time)
                let buyDate = new Date(element.created_time)
                if(element.side == 'BUY' && sellDate > buyDate){
                    
                    //cancel it
                    await ca.cancelOrder(element.order_id)
                    console.log(`Cancel: ${element.order_id}`)
                }
            }
        }
        
    } catch (error) {
        console.log("processBuyOrdersOutOfRange()", error)
    }
}

async function processHistoricalPrices () {
    try {
        //get next stock
        let results = await db.fetchNextHistorical();
        let coin = results[0].name;
        let start_date = results[0].start_date;
        let end_date = results[0].end_date;
        let stockID = results[0].stock_id

        //Math.floor(new Date(yourDate).getTime() / 1000)
        let unixStartDate = Math.floor(new Date(start_date).getTime() / 1000)
        let unixEndDate = Math.floor(new Date(end_date).getTime() / 1000)

       
        //fetch from api
        let prices;
        console.log(`Next historical is`, stockID, coin, start_date, unixStartDate, end_date, unixEndDate);
        
        try {
            prices = await ca.yoinkPriceData(coin, unixStartDate, unixEndDate, 'ONE_DAY')
            console.log(prices.length, 'remaining historical');

            //download it to table
            await db.downloadHistoricalPrices(stockID, prices);

            //execute procedure
            await db.executeQuery(
                `Update stock s
                SET historical_last_date = x.earliest_date
                FROM (
                    SELECT stock_id, MIN(TO_TIMESTAMP(start)::DATE) as earliest_date
                    FROM bulk_historical
                    group by stock_id
                    ) x
                WHERE s.stock_id = x.stock_id;`
                )

            
        } catch (error)
        {
            await db.executeQuery(`UPDATE stock SET historical_finished = 1::bit WHERE stock_id = ` + stockID)
            await db.executeQuery('CALL insert_aggregate();')
        }

        if(prices.length == 0 || !prices) {
            await db.executeQuery(`UPDATE stock SET historical_finished = 1::bit WHERE stock_id = ` + stockID)
            await db.executeQuery('CALL insert_aggregate();')
        }

    } catch (error) {
        console.log('processHistoricalPrices()', error?.response);

        await db.executeQuery('CALL insert_aggregate();')
       // await db.executeQuery(`UPDATE stock set historical_finished = 1 WHERE stock_id = ${stockID}`
        
    }
}

async function processTransfers () {
    try {
        const pending = await db.executeQuery(`
            SELECT buy_order_id, name, transfer_amount
            FROM position
            WHERE sell_filled_price IS NOT NULL
            AND transfer_amount > 0
            AND transfer_complete = false
        `)
        if (pending.length === 0) return

        const accounts = await ca.gatherBalance()
        let usdId, usdcId
        for (const account of accounts) {
            if (account.currency === 'USD')  usdId  = account.uuid
            if (account.currency === 'USDC') usdcId = account.uuid
            if (usdId && usdcId) break
        }

        if (!usdId || !usdcId) {
            console.log('processTransfers() ERROR: could not find USD or USDC account')
            return
        }

        for (const pos of pending) {
            const result = await ca.createTransfer('USD', 'USDC', pos.transfer_amount, usdId, usdcId)
            if (result !== false) {
                await db.executeQuery(`UPDATE position SET transfer_complete = true WHERE buy_order_id = '${pos.buy_order_id}'`)
                console.log(`Transfer OK: ${pos.name} $${pos.transfer_amount} USD → USDC`)
            } else {
                console.log(`Transfer FAILED: ${pos.name} $${pos.transfer_amount}`)
            }
        }
    } catch (error) {
        console.log('processTransfers() ERROR', error)
    }
}

async function transferProfit (accounts, fills) {
    try {
        //if(fills[0].side == 'SELL'){

            let usdc, usd, sellShares = fills[0].size, sellPrice = fills[0].price, sellFee = fills[0].commission;
            for(i = 0; i < accounts.length; i++){
                if(accounts[i].currency == 'USDC'){
                    usdc = accounts[i].uuid
                } else if(accounts[i].currency == 'USD'){
                    usd = accounts[i].uuid
                }

                if(usdc && usd){
                    break;
                }
            }

            if(!usdc && usd){
                //transfer a penny
                let response = await ca.createTransfer('USD', 'USDC', 0.01, usd, usdc)
                console.log("Transfer Success?", response)
            }

            //console.log(usd, usdc)
            // for(i=0;i<fills.length;i++){
            //     let element = fills[i];

            // }
          
        //}
    } catch (error) {
        console.log('transferProfit()', error)
    }
}