//const db = require('/Users/theodorecross/Coinbase tedTosterone/modules/database.js')
const config = require('/Users/theodorecross/Coinbase tedTosterone/modules/config.js')
const { sign } = require('jsonwebtoken');
const crypto = require('crypto');
const axios = require('axios');
let ca = {};
ca.timeArray = [];
const startProgram = new Date();

ca.makeTimeArray = function () {

    //create time array for seconds in minute
    for(let index = 0; index < 60; index++) {
        ca.timeArray.push({second: index, count: 0})
    }
}

async function determineWait () {
    let secondNow = new Date().getSeconds();
    let count = 0
    for (let index = 0; index < ca.timeArray.length; index++) {
        const element = ca.timeArray[index];
        //console.log("timeArray", element)
        if(element.second == secondNow) {
            element.count++;
            count = element.count;
        }
    }
    if(count > 9) {
       await sleep(100)
    }
    //console.log(secondNow, count);
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

        const response = await getApiCall('GET', '/api/v3/brokerage/accounts', '');

        return response.data.accounts;

    } catch (error) {
        console.log("gatherBalance()", error);
    }
}

ca.gatherFills = async function (coinName) {
    try {
        const response = await getApiCall('GET', '/api/v3/brokerage/orders/historical/fills', `${coinName}`);
       
        return response.data.fills;
        
    } catch (error) {
        console.log("gatherFills()", error);
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

ca.createLimitOrder = async function (side, price, shares, name, expireDate) {
    try {
        let data = JSON.stringify({
            "client_order_id": crypto.randomUUID(),
            "product_id": name,
            "side": side,
            "order_configuration": {
              "limit_limit_gtd": {
                //"quote_size": USD,
                "base_size": shares,
                "post_only": true,
                "limit_price": price,
                "end_time": expireDate
              }
            }
          });

        const result = await getApiCall('POST', '/api/v3/brokerage/orders', '', data);

        console.log('Order created!', result.data)
    } catch (error) {
        console.log("createBuyOrder()", error.data)
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

ca.editStopLimitOrder = async function(orderId, price, size, newStopPrice) {
    const data = JSON.stringify({
        order_id: orderId,
        price: price.toString(),
        size: size.toString(),
        stop_price: newStopPrice.toString()
    });

    const result = await getApiCall('POST', '/api/v3/brokerage/orders/edit', '', data);
    console.log('Order edited!', result.data);
    return result.data;
}

ca.yoinkPriceData = async function (coin, start, end, granularity, limit) {
    try {
        const response = await getApiCall('GET', `/api/v3/brokerage/products/${coin}/candles`, `?start=${start}&end=${end}&granularity=${granularity}`)
        return response.data.candles;
    } catch (error) {
        console.log('yoinkPriceData()', error)
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

ca.createTransfer = async function (from, to, amount) {
    try {
        let data = JSON.stringify({
            'from_currency': from,
            'to_currency': to,
            'amount': amount
        })
        await getApiCall('POST', '/api/v3/brokerage/conversions', '', data)
        return true;
    } catch (error) {
        console.log('createTransfer()', error)
        return false;
    }
}

ca.cancelOrder = async function (orderID) {
    try{
        let data = JSON.stringify({
            order_ids: [orderID]
        })
        await getApiCall('POST', '/api/v3/brokerage/orders/batch_cancel', '', data)
    } catch (error) {
        console.log('cancelOrder()', error)
    }
}



module.exports = ca;