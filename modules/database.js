const { Pool } = require('pg');

// Configure the connection
const con = new Pool({
  user: 'theodorecross', // Homebrew default: your macOS username (run `whoami`)
  host: 'localhost',
  database: 'coinbase',      // Default database, or use one you created (e.g., 'mydb')
  password: '',              // Homebrew default: blank; EDB: your set password
  port: 5432,                // Default PostgreSQL port
});

// Test the connection
async function testConnection() {
  try {
    const client = await con.connect();
    console.log('Connected to PostgreSQL!');
    
    // Run a simple query
    const res = await client.query('SELECT NOW()');
    console.log('Current time from database:', res.rows[0]);
    
    // Release the client back to the pool
    client.release();
  } catch (err) {
    console.error('Connection error:', err.stack);
  } finally {
    await con.end(); // Close the pool
  }
}

con.executeQuery = async function (query) {
    try {
        //console.log(query);
        let result = await con.query(query);
        //console.log(result.rows);
        return result.rows;
    } catch (err) {
        console.log("executeQuery()", query, err);
    }
}

con.downloadStocks = async function (data) {
    try {
        //console.log(data);

        const id = data.map(obj => obj.product_id);
        const quote_increment = data.map(obj => obj.quote_increment);
        const base_increment = data.map(obj => obj.base_increment);
        const min_market_funds = data.map(obj => obj.min_market_funds)
        const trading_disabled = data.map(obj => obj.trading_disabled)
        const post_only = data.map(obj => obj.post_only)
        const cancel_only = data.map(obj => obj.cancel_only)
        const system = data.map(obj => obj.system)
        const price = data.map(obj => obj.price);
        const json = data.map(obj => JSON.stringify(obj))
        
        const query = `INSERT INTO bulk_stock 
        (id, quote_increment, base_increment, min_market_funds,
        trading_disabled, post_only, cancel_only, System, price, json)
        SELECT * FROM UNNEST ($1::TEXT[], $2::TEXT[],
        $3::TEXT[], $4::TEXT[], $5::TEXT[], $6::TEXT[]
        , $7::TEXT[], $8::TEXT[], $9::TEXT[], $10::json[])`;

        const values = [id, quote_increment, base_increment, min_market_funds, trading_disabled, 
        post_only, cancel_only, system, price, json]

        await con.query(query, values);
  
    } catch (error) {
        console.log("downloadStocks()", error);
    }
}

con.insertCurrency = async function (data) {
  try {
      //console.log(data);
      if(data.length > 0) {
          const id = data.map(obj => obj.uuid)
          const currency = data.map(obj => obj.currency)
          const balance = data.map(obj => parseFloat(obj.available_balance.value))
          const hold = data.map(obj => parseFloat(obj.hold.value))
          const available = data.map(obj => parseFloat(obj.available_balance.value))
          const profile_id = data.map(obj => obj.retail_portfolio_id)
          const trading_enabled = data.map(obj => obj.active.toString())
          const AccountID = data.map(obj => obj.uuid)

          const query = `INSERT INTO BULK_Currency
          (id, currency, balance, hold, available, profile_id, trading_enabled)
          SELECT * FROM UNNEST ($1::TEXT[], $2::TEXT[], $3::DOUBLE PRECISION[], $4::DOUBLE PRECISION[]
            , $5::DOUBLE PRECISION[], $6::TEXT[], $7::TEXT[])`

          const values = [id, currency, balance, hold, available, profile_id, trading_enabled]

          await con.query(query, values)
      }
      //console.log(array);
     // await connection.awaitQuery('INSERT INTO BULK_Currency (id, currency, balance, hold, available, profile_id, trading_enabled, UserID) VALUES ?', [array]);
  } catch (error) {
      console.log("insertCurrency", error)
  }
}

con.insertOpenOrders = async function (data) {
    try {
        if (data.length > 0) {
            const order_id = data.map(obj => obj.order_id)
            const product_id = data.map(obj => obj.product_id)
            const user_id = data.map(obj => obj.user_id)
            const order_configuration = data.map(obj => JSON.stringify(obj.order_configuration))
            const side = data.map(obj => obj.side)
            const client_order_id = data.map(obj => obj.client_order_id)
            const status = data.map(obj => obj.status)
            const time_in_force = data.map(obj => obj.time_in_force)
            const created_time = data.map(obj => obj.created_time)
            const completion_percentage = data.map(obj => parseFloat(obj.completion_percentage))
            const filled_size = data.map(obj => parseFloat(obj.filled_size))
            const average_filled_price = data.map(obj => parseFloat(obj.average_filled_price))
            const fee = data.map(obj => obj.fee)
            const number_of_fills = data.map(obj => parseInt(obj.number_of_fills))
            const filled_value = data.map(obj => parseFloat(obj.filled_value))
            const pending_cancel = data.map(obj => obj.pending_cancel)
            const size_in_quote = data.map(obj => obj.size_in_quote)
            const total_fees = data.map(obj => parseFloat(obj.total_fees))
            const size_inclusive_of_fees = data.map(obj => obj.size_inclusive_of_fees)
            const total_value_after_fees = data.map(obj => parseFloat(obj.total_value_after_fees))
            const trigger_status = data.map(obj => obj.trigger_status)
            const order_type = data.map(obj => obj.order_type)
            const reject_reason = data.map(obj => obj.reject_reason)
            const settled = data.map(obj => obj.settled)
            const product_type = data.map(obj => obj.product_type)
            const reject_message = data.map(obj => obj.reject_message)
            const cancel_message = data.map(obj => obj.cancel_message)
            const order_placement_source = data.map(obj => obj.order_placement_source)
            const outstanding_hold_amount = data.map(obj => parseFloat(obj.outstanding_hold_amount))
            const is_liquidation = data.map(obj => obj.is_liquidation)
            const last_fill_time = data.map(obj => obj.last_fill_time)
            const edit_history = data.map(obj => JSON.stringify(obj.edit_history))
            const leverage = data.map(obj => obj.leverage)
            const margin_type = data.map(obj => obj.margin_type)
            const retail_portfolio_id = data.map(obj => obj.retail_portfolio_id)
            const originating_order_id = data.map(obj => obj.originating_order_id)
            const attached_order_id = data.map(obj => obj.attached_order_id)
            const attached_order_configuration = data.map(obj => JSON.stringify(obj.attached_order_configuration))
            const current_pending_replace = data.map(obj => JSON.stringify(obj.current_pending_replace))
            const commission_detail_total = data.map(obj => JSON.stringify(obj.commission_detail_total))
            const workable_size = data.map(obj => obj.workable_size)
            const workable_size_completion_pct = data.map(obj => obj.workable_size_completion_pct)
            const product_details = data.map(obj => JSON.stringify(obj.product_details))
            const cost_basis_method = data.map(obj => obj.cost_basis_method)
            const displayed_order_config = data.map(obj => obj.displayed_order_config)
            const equity_trading_session = data.map(obj => obj.equity_trading_session)
            const prediction_side = data.map(obj => obj.prediction_side)
            const last_update_time = data.map(obj => obj.last_update_time)

            const query = `INSERT INTO bulk_open_orders
            (order_id, product_id, user_id, order_configuration, side, client_order_id, status,
            time_in_force, created_time, completion_percentage, filled_size, average_filled_price,
            fee, number_of_fills, filled_value, pending_cancel, size_in_quote, total_fees,
            size_inclusive_of_fees, total_value_after_fees, trigger_status, order_type, reject_reason,
            settled, product_type, reject_message, cancel_message, order_placement_source,
            outstanding_hold_amount, is_liquidation, last_fill_time, edit_history, leverage,
            margin_type, retail_portfolio_id, originating_order_id, attached_order_id,
            attached_order_configuration, current_pending_replace, commission_detail_total,
            workable_size, workable_size_completion_pct, product_details, cost_basis_method,
            displayed_order_config, equity_trading_session, prediction_side, last_update_time)
            SELECT * FROM UNNEST (
            $1::TEXT[], $2::TEXT[], $3::TEXT[], $4::JSON[], $5::TEXT[], $6::TEXT[], $7::TEXT[],
            $8::TEXT[], $9::TIMESTAMP[], $10::DOUBLE PRECISION[], $11::DOUBLE PRECISION[], $12::DOUBLE PRECISION[],
            $13::TEXT[], $14::INT[], $15::DOUBLE PRECISION[], $16::BOOLEAN[], $17::BOOLEAN[], $18::DOUBLE PRECISION[],
            $19::BOOLEAN[], $20::DOUBLE PRECISION[], $21::TEXT[], $22::TEXT[], $23::TEXT[],
            $24::BOOLEAN[], $25::TEXT[], $26::TEXT[], $27::TEXT[], $28::TEXT[],
            $29::DOUBLE PRECISION[], $30::BOOLEAN[], $31::TIMESTAMP[], $32::JSON[], $33::TEXT[],
            $34::TEXT[], $35::TEXT[], $36::TEXT[], $37::TEXT[],
            $38::JSON[], $39::JSON[], $40::JSON[],
            $41::TEXT[], $42::TEXT[], $43::JSON[], $44::TEXT[],
            $45::TEXT[], $46::TEXT[], $47::TEXT[], $48::TIMESTAMP[])`

            const values = [
                order_id, product_id, user_id, order_configuration, side, client_order_id, status,
                time_in_force, created_time, completion_percentage, filled_size, average_filled_price,
                fee, number_of_fills, filled_value, pending_cancel, size_in_quote, total_fees,
                size_inclusive_of_fees, total_value_after_fees, trigger_status, order_type, reject_reason,
                settled, product_type, reject_message, cancel_message, order_placement_source,
                outstanding_hold_amount, is_liquidation, last_fill_time, edit_history, leverage,
                margin_type, retail_portfolio_id, originating_order_id, attached_order_id,
                attached_order_configuration, current_pending_replace, commission_detail_total,
                workable_size, workable_size_completion_pct, product_details, cost_basis_method,
                displayed_order_config, equity_trading_session, prediction_side, last_update_time
            ]

            await con.query(query, values)
        }
    } catch (error) {
        console.log("insertOpenOrders", error)
    }
}

con.fetchRSI = async function () {
  try {
    let query = 'SELECT RSI();'
    let result = await con.query(query);
    console.log(`RSI: ${result.rows[0].rsi}`);
  } catch (error) {
    console.log(error)
  }
}

con.insertFills = async function (data) {
  try {
  
      if(data.length > 0) {
                  //console.log(data);

          const created_at = data.map(obj => obj.trade_time)
          const trade_id = data.map(obj => obj.trade_id)
          const product_id = data.map(obj => obj.product_id)
          const order_id = data.map(obj => obj.order_id)
          const user_id = data.map(obj => obj.user_id)
          const profile_id = data.map(obj => obj.profile_id)
          const liquidity = data.map(obj => obj.liquidity)
          const price = data.map(obj => obj.price)
          const size = data.map(obj => obj.size)
          const fee = data.map(obj => obj.commission)
          const side = data.map(obj => obj.side)
          const settled = data.map(obj => obj.settled)
         // const usd_volume = data.map(obj => obj.usd)
          const AccountID = data.map(obj => obj.AccountID)
          const StockID = data.map(obj => obj.StockID)

          
         const query = `INSERT INTO bulk_fills
         (created_at        
          , trade_id
          , product_id
          , order_id
          , profile_id
          , liquidity
          , price
          , size
          , fee
          , side
          , settled)
          SELECT * FROM UNNEST (
            $1::timestamp[]
            , $2::text[]
            , $3::text[]
            , $4::text[]
            , $5::text[]
            , $6::text[]
            , $7::double precision[]
            , $8::double precision[]
            , $9::double precision[]
            , $10::text[]
            , $11::text[])`

          const values = [created_at, trade_id, product_id, order_id, profile_id, liquidity, price, size,
          fee, side, settled]
          
          await con.query(query, values);

      }
      //console.log(array);
     // await connection.awaitQuery('INSERT INTO BULK_Currency (id, currency, balance, hold, available, profile_id, trading_enabled, UserID) VALUES ?', [array]);
  } catch (error) {
      console.log("insertFills", error)
  }
}

con.fetchNextHistorical = async function () {
  try {
    let query = `SELECT stock_id, name, COALESCE(historical_last_date, NOW()::DATE) as end_date, COALESCE(historical_last_date, NOW()::DATE) - INTERVAL '350 days' AS start_date FROM stock order by historical_finished, RANDOM() limit 1;`
    let results = await con.query(query);
    return results.rows;
    console.log(results)
  } catch (error) {
      console.log('fetchNextHistorical()', error);
  }
}

con.downloadHistoricalPrices = async function (stockID, prices) {
  try {
    if(prices.length > 0) {
     

      const stock_id = Array(prices.length).fill(stockID)
      const start = prices.map(obj => obj.start)
      const low = prices.map(obj => obj.low)
      const high = prices.map(obj => obj.high)
      const open = prices.map(obj => obj.open)
      const close = prices.map(obj => obj.close)
      const volume = prices.map(obj => obj.volume)

      const query = 
      `insert into bulk_historical
      (stock_id
      , start
      , low
      , high
      , open
      , close
      , volume)
      SELECT * FROM UNNEST (
      $1::INT[]
      , $2::INT[]
      , $3::DOUBLE PRECISION[]
      , $4::DOUBLE PRECISION[]
      , $5::DOUBLE PRECISION[]
      , $6::DOUBLE PRECISION[]
      , $7::DOUBLE PRECISION[])`

      const values = [stock_id, start, low, high, open, close, volume]

      await con.query(query, values)
    } 
  } catch (error) {
    console.log('downloadHistoricalPrices()', error)
  }
}



module.exports = con;