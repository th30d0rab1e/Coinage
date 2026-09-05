//const db = require('/Users/theodorecross/Coinbase tedTosterone/modules/database.js')
const config = require('./config.js')
const { sign } = require('jsonwebtoken');
const crypto = require('crypto');
const axios = require('axios');
let ca = {};
const startProgram = new Date();

function sleep (ms) {
    return new Promise(resolve => setTimeout(resolve, ms))
}

// Coinbase's private-endpoint limit is 15 req/sec per API key. Capped at 10
// here (not 15) to leave margin for manual out-of-band calls against the
// same key (live status checks run alongside the cron) and for imprecision
// at the edge of the rolling window. Tracks real elapsed time via Date.now(),
// unlike the previous version of this function, which counted by clock-
// second (0-59) with no reset -- once any second-slot passed 9 lifetime
// calls it stayed over the threshold forever, throttling every future call
// through it. That version was also unreachable dead code: it called a
// sleep() that was never defined anywhere in this file.
let requestTimestamps = []
async function determineWait () {
    const now = Date.now()
    requestTimestamps = requestTimestamps.filter(t => now - t < 1000)
    if (requestTimestamps.length >= 10) {
        await sleep(1000 - (now - requestTimestamps[0]))
    }
    requestTimestamps.push(Date.now())
}

async function tokenate(method, path) {
    try {
        //console.log(method, path)
       // Your credentials
        const key_name = config.key_name;
        const key_secret = config.key_secret

        // Request details
        const request_method = method;
        const request_path = path;
        const algorithm = 'ES256';

        // Construct the URI for the JWT (method + path)
        const uri = `${request_method} api.coinbase.com${request_path}`;
        //console.log(uri)

        // Generate the JWT
        const token = sign(
        {
            iss: 'coinbase-cloud', // Correct issuer for Coinbase Cloud
            nbf: Math.floor(Date.now() / 1000), // Not before
            exp: Math.floor(Date.now() / 1000) + 60, // Expires in 2 minutes
            sub: key_name, // Subject (your API key name)
            aud: ['advanced-trade'], // Audience for Advanced Trade
            uri: uri // URI for the request
        },
        key_secret,
        {
            algorithm: algorithm,
            header: {
            kid: key_name, // Key ID
            nonce: crypto.randomBytes(16).toString('hex') // Random nonce
            }
        }
        );

        //console.log('JWT:', token);
        return token;
    } catch (error) {
        console.log("tokenate()", error)
    }
}

async function getApiCall(method, address, query, data) {
    try {
        await determineWait();
        const token = await tokenate(method, address);
        //console.log(token);
        let config

        if(method == 'GET'){
            // Axios request with the JWT in the Authorization header
            config = {
                method: method,
                url: `https://api.coinbase.com${address}${query}`,
                headers: {
                'Authorization': `Bearer ${token}`, // Include the JWT here
                'Content-Type': 'application/json',
                'User-Agent': 'Node.js Coinbase Client' // Optional but good practice
                },
                maxBodyLength: Infinity
            };
        } else if (method == 'POST'){
            config = {
                method: method,
                url: `https://api.coinbase.com${address}${query}`,
                headers: {
                'Authorization': `Bearer ${token}`, // Include the JWT here
                'Content-Type': 'application/json',
                'User-Agent': 'Node.js Coinbase Client' // Optional but good practice
                },
                maxBodyLength: Infinity,
                data: data
            };
        }
        
        return axios.request(config);
     
    } catch(error) {
        console.log("apiCall()", error)
    }
}



ca.fetchProducts = async function (coinName) {
    try {
       let response = await getApiCall('GET', '/api/v3/brokerage/products', `${coinName}`);

       const data = response.data.products;

        return response.data.products;

    } catch (error) {
        console.log("fetchProducts", error);
    }
}

ca.gatherBalance = async function (dbOrders) {
    try {
        const accounts = []
        let cursor = ''
        do {
            const query = `?limit=250${cursor ? `&cursor=${cursor}` : ''}`
            const response = await getApiCall('GET', '/api/v3/brokerage/accounts', query);
            accounts.push(...(response.data.accounts || []))
            cursor = response.data.has_next ? response.data.cursor : ''
        } while (cursor)
        return accounts;

    } catch (error) {
        console.log("gatherBalance()", error);
    }
}

ca.gatherFills = async function () {
    try {
        const response = await getApiCall('GET', '/api/v3/brokerage/orders/historical/fills', '');
        return response.data.fills;
    } catch (error) {
        console.log("gatherFills()", error);
    }
}

ca.gatherAllFills = async function () {
    try {
        const fills = []
        let cursor = ''
        do {
            const query = `?limit=250${cursor ? `&cursor=${cursor}` : ''}`
            const response = await getApiCall('GET', '/api/v3/brokerage/orders/historical/fills', query)
            const page = response.data.fills || []
            fills.push(...page)
            cursor = page.length === 250 ? response.data.cursor : ''
        } while (cursor)
        return fills
    } catch (error) {
        console.log(`gatherAllFills()`, error?.response?.data || error)
        return []
    }
}

ca.gatherAllFillsByProduct = async function (productId) {
    try {
        const fills = []
        let cursor = ''
        do {
            const query = `?product_id=${productId}&limit=250${cursor ? `&cursor=${cursor}` : ''}`
            const response = await getApiCall('GET', '/api/v3/brokerage/orders/historical/fills', query)
            const page = response.data.fills || []
            fills.push(...page)
            cursor = page.length === 250 ? response.data.cursor : ''
        } while (cursor)
        return fills
    } catch (error) {
        console.log(`gatherAllFillsByProduct(${productId})`, error?.response?.data || error)
        return []
    }
}

ca.gatherOrders = async function () {
    try {
        const response = await getApiCall('GET', '/api/v3/brokerage/orders/historical/batch', '?order_status=OPEN')
        return response.data.orders;
    } catch (error) {
        console.log("gatherOrders()", error);
    }
}

ca.getOrderById = async function (orderId) {
    try {
        const response = await getApiCall('GET', `/api/v3/brokerage/orders/historical/${orderId}`, '')
        return response.data.order;
    } catch (error) {
        console.log("getOrderById()", error?.response?.data || error);
    }
}

// Coinbase's documented client_order_id lookup params (both the deprecated
// query param on get-order-by-id, and a filter on the list-orders/batch
// endpoint) don't actually filter anything -- confirmed 2026-08-31, both
// silently returned an unrelated order instead of erroring. This lists open
// orders for the product and matches client_order_id client-side instead,
// which does work. Only checks OPEN orders since this is meant to verify a
// just-attempted create within the same cycle, well before a fresh stop
// order could plausibly have already triggered and filled.
ca.findOpenOrderByClientId = async function (productId, clientOrderId) {
    try {
        const response = await getApiCall('GET', '/api/v3/brokerage/orders/historical/batch', `?order_status=OPEN&product_id=${productId}`)
        const orders = response.data.orders || []
        return orders.find(o => o.client_order_id === clientOrderId)
    } catch (error) {
        console.log("findOpenOrderByClientId()", error?.response?.data || error);
    }
}

ca.createLimitOrder = async function (side, price, shares, name, orderID) {
    try {
        let data = JSON.stringify({
            "client_order_id": orderID,
            "product_id": name,
            "side": side,
            "order_configuration": {
              "limit_limit_gtc": {
                //"quote_size": USD,
                "base_size": shares.toString(),
                "post_only": false,
                "limit_price": price.toString()
              }
            }
          });

        const result = await getApiCall('POST', '/api/v3/brokerage/orders', '', data);

        console.log('Order created!', result.data)
        
        return result.data;

    } catch (error) {
        if (error?.response?.data){
            console.log("createBuyOrder() ERROR response.data", error.response.data, side, price, shares, name, orderID);
        } else if (error?.data) {
            console.log("createBuyOrder() ERROR data", error.data, side, price, shares, name, orderID);
        } else {
            console.log("createBuyOrder() ERROR else", error, side, price, shares, name, orderID)
        }
        
    }
} 

ca.createBracketOrder = async function (side, price, shares, name, expireDate, stopPrice) {
    try {
        let data = JSON.stringify({
            "client_order_id": crypto.randomUUID(),
            "product_id": name,
            "side": side,
            "order_configuration": {
              "trigger_bracket_gtd": {
                //"quote_size": USD,
                "base_size": shares,
                //"post_only": true,
                "limit_price": price,
                "end_time": expireDate,
                "stop_trigger_price": stopPrice
              }
            }
          });

        const result = await getApiCall('POST', '/api/v3/brokerage/orders', '', data);

        console.log('Order created!', result.data)
    } catch (error) {
        console.log("createSellOrder()", error)
    }
} 

ca.previewStopLimitOrder = async function (side, price, shares, name, stop_price) {
    try {
        const direction = side == 'sell' ? 'STOP_DIRECTION_STOP_DOWN' : 'STOP_DIRECTION_STOP_UP'
        const data = JSON.stringify({
            "product_id": name,
            "side": side.toUpperCase(),
            "order_configuration": {
                "stop_limit_stop_limit_gtc": {
                    "base_size": shares.toString(),
                    "limit_price": price.toString(),
                    "stop_price": stop_price.toString(),
                    "stop_direction": direction
                }
            }
        })
        const result = await getApiCall('POST', '/api/v3/brokerage/orders/preview', '', data)
        const errs = result.data?.errs
        if (errs && errs.length > 0) {
            const realErrors = errs.filter(e => e !== 'PREVIEW_INSUFFICIENT_FUND' && e?.error !== 'PREVIEW_INSUFFICIENT_FUND')
            if (realErrors.length > 0) {
                console.log(`previewStopLimitOrder() failed for ${name}:`, realErrors)
                return { ok: false, errors: realErrors }
            }
        }
        return { ok: true }
    } catch (error) {
        const errors = error?.response?.data || error?.data || error
        console.log('previewStopLimitOrder()', errors)
        return { ok: false, errors }
    }
}

ca.createStopLimitOrder = async function (side, price, shares, name, stop_price, order_id) {
    try {
        let direction;
        if(side == 'sell') 
        {
            direction = 'STOP_DIRECTION_STOP_DOWN'
        }
        else if(side == 'buy') 
        {
            direction = 'STOP_DIRECTION_STOP_UP'
        }
        let data = JSON.stringify({
            "client_order_id": order_id,
            "product_id": name,
            "side": side.toUpperCase(),
            "order_configuration": {
              "stop_limit_stop_limit_gtc": {
                //"quote_size": USD,
                "base_size": shares.toString(),
                //"post_only": true,
                "limit_price": price.toString(),
               // "end_time": expireDate,
                "stop_price": stop_price.toString(),
                "stop_direction": direction
              }
            }
          });

          //console.log("Order To Make", data);

        const result = await getApiCall('POST', '/api/v3/brokerage/orders', '', data);
        if (result.data?.success) return result.data;

        // A reported failure can still mean Coinbase received and created the
        // order -- confirmed 2026-08-31 on MORPHO-USD, which sat as a real open
        // order for 4 days and eventually filled while completely untracked,
        // because a prior call here discarded the attempt as failed and never
        // checked. Before trusting the failure, verify no open order actually
        // exists under this client_order_id.
        console.log(`createStopLimitOrder() FAILED: ${name}`, result.data, `-- verifying via open orders`)
        const existing = await ca.findOpenOrderByClientId(name, order_id)
        if (existing) {
            console.log(`createStopLimitOrder() verified order actually exists: ${name} ${existing.order_id}`)
            return { success: true, success_response: { order_id: existing.order_id } }
        }
        return result.data;

    } catch (error) {
        const errData = error?.response?.data || error?.data || error
        console.log(`createStopLimitOrder() ERROR: ${name}`, errData, `-- verifying via open orders`)
        const existing = await ca.findOpenOrderByClientId(name, order_id)
        if (existing) {
            console.log(`createStopLimitOrder() verified order actually exists despite error: ${name} ${existing.order_id}`)
            return { success: true, success_response: { order_id: existing.order_id } }
        }
        return { success: false, error_response: { message: errData?.message || errData?.error_details || String(errData) } }
    }
}

ca.editStopLimitOrder = async function(order_id, price, shares, stop_price, side, name, coinbase_order_id) {
    try {
        // 1. Cancel existing order
        const cancelData = JSON.stringify({ order_ids: [coinbase_order_id] });
        const cancelResult = await getApiCall('POST', '/api/v3/brokerage/orders/batch_cancel', '', cancelData);
        console.log(`Cancel result for ${name}:`, cancelResult.data);

        if (!cancelResult.data?.results?.[0]?.success) {
            console.log(`Failed to cancel order ${coinbase_order_id} for ${name}`, cancelResult.data?.results?.[0]?.failure_reason);
            //return null;
        }

        // 2. Create new order with updated prices
        const newOrder = await ca.createStopLimitOrder(side, price, shares, name, stop_price, order_id);
        console.log(`Replaced order for ${name}:`, newOrder);
        return newOrder;

    } catch (error) {
        if (error?.response?.data) {
            console.log("editStopLimitOrder() ERROR response.data", error.response.data, side, price, shares, name);
        } else if (error?.data) {
            console.log("editStopLimitOrder() ERROR data", error.data, side, price, shares, name);
        } else {
            console.log("editStopLimitOrder() ERROR else", error, side, price, shares, name);
        }
    }
}

ca.createMarketSellOrder = async function (name, shares) {
    try {
        const data = JSON.stringify({
            "client_order_id": crypto.randomUUID(),
            "product_id": name,
            "side": "SELL",
            "order_configuration": {
                "market_market_ioc": {
                    "base_size": shares.toString()
                }
            }
        })
        const result = await getApiCall('POST', '/api/v3/brokerage/orders', '', data)
        if (!result.data?.success) console.log(`createMarketSellOrder() FAILED: ${name}`, result.data)
        return result.data
    } catch (error) {
        console.log(`createMarketSellOrder() ERROR: ${name}`, error?.response?.data || error)
    }
}

ca.cancelOrder = async function (coinbase_order_id) {
    try {
        const cancelData = JSON.stringify({ order_ids: [coinbase_order_id] });
        let response = await getApiCall('POST', '/api/v3/brokerage/orders/batch_cancel', '', cancelData);
        const result = response.data?.results?.[0];
        if (result?.success) return true;

        // batch_cancel can report failure (e.g. UNKNOWN_CANCEL_ORDER) even when the
        // cancel actually took effect -- confirmed 2026-07-23 on JUPITER-USD and
        // LIGHTER-USD, both left permanently stuck retrying a cancel every cycle on
        // an order Coinbase's own order history showed as already CANCELLED with
        // zero fill. Before treating this as a real failure -- which could mean the
        // order already filled, the genuinely dangerous case a caller must not
        // paper over -- check the order's actual terminal state directly.
        console.log(`cancelOrder() reported FAILED: ${result?.failure_reason} | ${coinbase_order_id} -- verifying actual order status`)
        const order = await ca.getOrderById(coinbase_order_id)
        // FAILED is just as safe as CANCELLED here: it means the order was
        // rejected and never went live, so there's nothing resting on the book
        // to accidentally leave open. Confirmed 2026-08-30/31 on AGLD-USD, stuck
        // retrying a cancel every cycle for 24+ hours on an order Coinbase's own
        // order history showed as status FAILED with zero fill the entire time.
        if ((order?.status === 'CANCELLED' || order?.status === 'FAILED') && parseFloat(order.filled_size || 0) === 0) {
            console.log(`cancelOrder() verified safe to proceed (status: ${order?.status}, no fill): ${coinbase_order_id}`)
            return true
        }
        console.log(`cancelOrder() confirmed still unsafe (status: ${order?.status}, filled_size: ${order?.filled_size}): ${coinbase_order_id}`)
        return false;
    } catch (error) {
        console.log(`cancelOrder() ERROR`, error)
        return false
    }
}


ca.yoinkPriceData = async function (coin, start, end, granularity, limit) {
    try {
        const response = await getApiCall('GET', `/api/v3/brokerage/products/${coin}/candles`, `?start=${start}&end=${end}&granularity=${granularity}&limit=300`)
        return response.data.candles;
    } catch (error) {
        console.log('yoinkPriceData()', error?.response?.data)
    }
}

ca.yoinkTransfers = async function (coin) {
    try {
        const response = await getApiCall('GET', '/api/v3/brokerage/transaction_summary', '')
        return response.data;
    } catch (error) {
        console.log(error);
    }
}

ca.createTransfer = async function (amount, fromAccountId, toAccountId) {
    try {
        const quoteData = JSON.stringify({
            'from_account': fromAccountId,
            'to_account': toAccountId,
            'amount': amount.toString()
        })
        const quote = await getApiCall('POST', '/api/v3/brokerage/convert/quote', '', quoteData)
        const tradeId = quote.data?.trade?.id
        if (!tradeId) {
            console.log('createTransfer() no trade_id in quote response', JSON.stringify(quote.data))
            return false;
        }

        const commitData = JSON.stringify({
            'from_account': fromAccountId,
            'to_account': toAccountId
        })
        const commit = await getApiCall('POST', `/api/v3/brokerage/convert/trade/${tradeId}`, '', commitData)
        console.log('createTransfer()', JSON.stringify(commit.data))
        return commit.data;
    } catch (error) {
        console.log('createTransfer()', error?.response?.status, JSON.stringify(error?.response?.data) || error)
        return false;
    }
}

// ca.cancelOrder = async function (orderID) {
//     try{
//         let data = JSON.stringify({
//             order_ids: [orderID]
//         })
//         await getApiCall('POST', '/api/v3/brokerage/orders/batch_cancel', '', data)
//     } catch (error) {
//         console.log('cancelOrder()', error)
//     }
// }



module.exports = ca;