-- Add daily_sell flag to position.
-- Positions marked daily_sell = true have a tight (1% below current price) stop-limit
-- placed by processDailyProfit() and must be excluded from vw_edit_orders so that
-- processRemakeOrders() does not overwrite the tight stop back to the normal trailing stop.

ALTER TABLE position ADD COLUMN daily_sell boolean NOT NULL DEFAULT false;

CREATE OR REPLACE VIEW vw_edit_orders AS

-- BUY remakes: balance-aware stop
SELECT
    p.name, p.period_type,
    TRUNC((s.price::numeric * bal.stop_mult * 1.01), s.price_rounding) AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.buy_coinbase_order_id AS coinbase_order_id,
    p.shares,
    TRUNC((s.price::numeric * bal.stop_mult), s.price_rounding) AS new_stop_price,
    'buy'::text AS order_type,
    TRUNC((1.0 - s.price::numeric / NULLIF((
        SELECT MIN(pa.low)::numeric FROM price_aggregate pa
        WHERE pa.stock_id = p.stock_id AND pa.period_type = p.period_type
    ), 0)), 4) AS estimated_profit
FROM position p
JOIN stock s ON p.stock_id = s.stock_id
CROSS JOIN LATERAL (
    SELECT GREATEST(1.01::numeric, LEAST(1.05::numeric,
        1.01 + 0.04 * (1.0 -
            COALESCE((SELECT b.available::numeric FROM vw_balance b WHERE b.name = 'USD'), 0) /
            NULLIF(
                COALESCE((SELECT b.available::numeric FROM vw_balance b WHERE b.name = 'USD'), 0) +
                COALESCE((SELECT SUM(p2.buy_price * p2.shares)::numeric FROM position p2
                          WHERE p2.buy_coinbase_order_id IS NOT NULL AND p2.buy_filled_price IS NULL), 0),
                0
            )
        )
    )) AS stop_mult
) bal
WHERE p.buy_coinbase_order_id IS NOT NULL
  AND p.buy_filled_price IS NULL
  AND p.buy_stop_price > TRUNC((s.price::numeric * bal.stop_mult), s.price_rounding)::double precision

UNION ALL

-- SELL day: trailing up
SELECT p.name, p.period_type,
    TRUNC(s.price::numeric * 0.97 * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now, p.buy_order_id, p.sell_coinbase_order_id AS coinbase_order_id, p.shares,
    TRUNC(s.price::numeric * 0.97, s.price_rounding) AS new_stop_price, 'sell'::text AS order_type,
    TRUNC(((s.price::numeric * 0.97) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit
FROM position p JOIN stock s ON p.stock_id = s.stock_id
WHERE p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL AND p.period_type = 'day'
  AND p.daily_sell = false
  AND p.sell_stop_price < TRUNC(s.price::numeric * 0.97, s.price_rounding)::double precision

UNION ALL

-- SELL day: too tight (stop within 2% of price, target is 3%)
SELECT p.name, p.period_type,
    TRUNC(s.price::numeric * 0.97 * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now, p.buy_order_id, p.sell_coinbase_order_id AS coinbase_order_id, p.shares,
    TRUNC(s.price::numeric * 0.97, s.price_rounding) AS new_stop_price, 'sell'::text AS order_type,
    TRUNC(((s.price::numeric * 0.97) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit
FROM position p JOIN stock s ON p.stock_id = s.stock_id
WHERE p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL AND p.period_type = 'day'
  AND p.daily_sell = false
  AND p.sell_stop_price > TRUNC(s.price::numeric * 0.98, s.price_rounding)::double precision

UNION ALL

-- SELL month: trailing up
SELECT p.name, p.period_type,
    TRUNC(s.price::numeric * 0.90 * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now, p.buy_order_id, p.sell_coinbase_order_id AS coinbase_order_id, p.shares,
    TRUNC(s.price::numeric * 0.90, s.price_rounding) AS new_stop_price, 'sell'::text AS order_type,
    TRUNC(((s.price::numeric * 0.90) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit
FROM position p JOIN stock s ON p.stock_id = s.stock_id
WHERE p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL AND p.period_type = 'month'
  AND p.daily_sell = false
  AND p.sell_stop_price < TRUNC(s.price::numeric * 0.90, s.price_rounding)::double precision

UNION ALL

-- SELL month: too tight (stop within 9.1% of price, target is 10%)
SELECT p.name, p.period_type,
    TRUNC(s.price::numeric * 0.90 * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now, p.buy_order_id, p.sell_coinbase_order_id AS coinbase_order_id, p.shares,
    TRUNC(s.price::numeric * 0.90, s.price_rounding) AS new_stop_price, 'sell'::text AS order_type,
    TRUNC(((s.price::numeric * 0.90) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit
FROM position p JOIN stock s ON p.stock_id = s.stock_id
WHERE p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL AND p.period_type = 'month'
  AND p.daily_sell = false
  AND p.sell_stop_price > TRUNC(s.price::numeric * 0.91, s.price_rounding)::double precision

UNION ALL

-- SELL year: trailing up
SELECT p.name, p.period_type,
    TRUNC(s.price::numeric * 0.75 * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now, p.buy_order_id, p.sell_coinbase_order_id AS coinbase_order_id, p.shares,
    TRUNC(s.price::numeric * 0.75, s.price_rounding) AS new_stop_price, 'sell'::text AS order_type,
    TRUNC(((s.price::numeric * 0.75) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit
FROM position p JOIN stock s ON p.stock_id = s.stock_id
WHERE p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL AND p.period_type = 'year'
  AND p.daily_sell = false
  AND p.sell_stop_price < TRUNC(s.price::numeric * 0.75, s.price_rounding)::double precision

UNION ALL

-- SELL year: too tight (stop within 24.25% of price, target is 25%)
SELECT p.name, p.period_type,
    TRUNC(s.price::numeric * 0.75 * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now, p.buy_order_id, p.sell_coinbase_order_id AS coinbase_order_id, p.shares,
    TRUNC(s.price::numeric * 0.75, s.price_rounding) AS new_stop_price, 'sell'::text AS order_type,
    TRUNC(((s.price::numeric * 0.75) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit
FROM position p JOIN stock s ON p.stock_id = s.stock_id
WHERE p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL AND p.period_type = 'year'
  AND p.daily_sell = false
  AND p.sell_stop_price > TRUNC(s.price::numeric * 0.76, s.price_rounding)::double precision

ORDER BY estimated_profit DESC;
