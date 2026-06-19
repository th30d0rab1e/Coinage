-- Add sell_counter and buy_counter to position.
-- Each successful cancel+recreate increments the counter by 1.
-- Each count tightens the stop by 0.10% of current price (closer to market).

ALTER TABLE position ADD COLUMN sell_counter INTEGER NOT NULL DEFAULT 0;
ALTER TABLE position ADD COLUMN buy_counter  INTEGER NOT NULL DEFAULT 0;

CREATE OR REPLACE VIEW vw_edit_orders AS

-- BUY remakes: balance-aware stop, tightened by buy_counter * 0.1%
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
    SELECT GREATEST(1.001::numeric, LEAST(1.05::numeric,
        1.01 + 0.04 * (1.0 -
            COALESCE((SELECT b.available::numeric FROM vw_balance b WHERE b.name = 'USD'), 0) /
            NULLIF(
                COALESCE((SELECT b.available::numeric FROM vw_balance b WHERE b.name = 'USD'), 0) +
                COALESCE((SELECT SUM(p2.buy_price * p2.shares)::numeric FROM position p2
                          WHERE p2.buy_coinbase_order_id IS NOT NULL AND p2.buy_filled_price IS NULL), 0),
                0
            )
        ) - p.buy_counter::numeric * 0.001
    )) AS stop_mult
) bal
WHERE p.buy_coinbase_order_id IS NOT NULL
  AND p.buy_filled_price IS NULL
  AND p.buy_stop_price > TRUNC((s.price::numeric * bal.stop_mult), s.price_rounding)::double precision

UNION ALL

-- SELL daily_sell: trail at 1% below current price, tightened by sell_counter * 0.1%
SELECT p.name, p.period_type,
    TRUNC(s.price::numeric * (0.99 + p.sell_counter::numeric * 0.001) * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now, p.buy_order_id, p.sell_coinbase_order_id AS coinbase_order_id, p.shares,
    TRUNC(s.price::numeric * (0.99 + p.sell_counter::numeric * 0.001), s.price_rounding) AS new_stop_price, 'sell'::text AS order_type,
    TRUNC(((s.price::numeric * (0.99 + p.sell_counter::numeric * 0.001)) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit
FROM position p JOIN stock s ON p.stock_id = s.stock_id
WHERE p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL
  AND p.daily_sell = true
  AND p.sell_stop_price < TRUNC(s.price::numeric * (0.99 + p.sell_counter::numeric * 0.001), s.price_rounding)::double precision

UNION ALL

-- SELL day: trailing up
SELECT p.name, p.period_type,
    TRUNC(s.price::numeric * (0.97 + p.sell_counter::numeric * 0.001) * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now, p.buy_order_id, p.sell_coinbase_order_id AS coinbase_order_id, p.shares,
    TRUNC(s.price::numeric * (0.97 + p.sell_counter::numeric * 0.001), s.price_rounding) AS new_stop_price, 'sell'::text AS order_type,
    TRUNC(((s.price::numeric * (0.97 + p.sell_counter::numeric * 0.001)) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit
FROM position p JOIN stock s ON p.stock_id = s.stock_id
WHERE p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL AND p.period_type = 'day'
  AND p.daily_sell = false
  AND p.sell_stop_price < TRUNC(s.price::numeric * (0.97 + p.sell_counter::numeric * 0.001), s.price_rounding)::double precision

UNION ALL

-- SELL day: too tight (stop within 1% above target)
SELECT p.name, p.period_type,
    TRUNC(s.price::numeric * (0.97 + p.sell_counter::numeric * 0.001) * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now, p.buy_order_id, p.sell_coinbase_order_id AS coinbase_order_id, p.shares,
    TRUNC(s.price::numeric * (0.97 + p.sell_counter::numeric * 0.001), s.price_rounding) AS new_stop_price, 'sell'::text AS order_type,
    TRUNC(((s.price::numeric * (0.97 + p.sell_counter::numeric * 0.001)) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit
FROM position p JOIN stock s ON p.stock_id = s.stock_id
WHERE p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL AND p.period_type = 'day'
  AND p.daily_sell = false
  AND p.sell_stop_price > TRUNC(s.price::numeric * (0.98 + p.sell_counter::numeric * 0.001), s.price_rounding)::double precision

UNION ALL

-- SELL month: trailing up
SELECT p.name, p.period_type,
    TRUNC(s.price::numeric * (0.90 + p.sell_counter::numeric * 0.001) * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now, p.buy_order_id, p.sell_coinbase_order_id AS coinbase_order_id, p.shares,
    TRUNC(s.price::numeric * (0.90 + p.sell_counter::numeric * 0.001), s.price_rounding) AS new_stop_price, 'sell'::text AS order_type,
    TRUNC(((s.price::numeric * (0.90 + p.sell_counter::numeric * 0.001)) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit
FROM position p JOIN stock s ON p.stock_id = s.stock_id
WHERE p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL AND p.period_type = 'month'
  AND p.daily_sell = false
  AND p.sell_stop_price < TRUNC(s.price::numeric * (0.90 + p.sell_counter::numeric * 0.001), s.price_rounding)::double precision

UNION ALL

-- SELL month: too tight (stop within 1% above target)
SELECT p.name, p.period_type,
    TRUNC(s.price::numeric * (0.90 + p.sell_counter::numeric * 0.001) * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now, p.buy_order_id, p.sell_coinbase_order_id AS coinbase_order_id, p.shares,
    TRUNC(s.price::numeric * (0.90 + p.sell_counter::numeric * 0.001), s.price_rounding) AS new_stop_price, 'sell'::text AS order_type,
    TRUNC(((s.price::numeric * (0.90 + p.sell_counter::numeric * 0.001)) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit
FROM position p JOIN stock s ON p.stock_id = s.stock_id
WHERE p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL AND p.period_type = 'month'
  AND p.daily_sell = false
  AND p.sell_stop_price > TRUNC(s.price::numeric * (0.91 + p.sell_counter::numeric * 0.001), s.price_rounding)::double precision

UNION ALL

-- SELL year: trailing up
SELECT p.name, p.period_type,
    TRUNC(s.price::numeric * (0.75 + p.sell_counter::numeric * 0.001) * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now, p.buy_order_id, p.sell_coinbase_order_id AS coinbase_order_id, p.shares,
    TRUNC(s.price::numeric * (0.75 + p.sell_counter::numeric * 0.001), s.price_rounding) AS new_stop_price, 'sell'::text AS order_type,
    TRUNC(((s.price::numeric * (0.75 + p.sell_counter::numeric * 0.001)) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit
FROM position p JOIN stock s ON p.stock_id = s.stock_id
WHERE p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL AND p.period_type = 'year'
  AND p.daily_sell = false
  AND p.sell_stop_price < TRUNC(s.price::numeric * (0.75 + p.sell_counter::numeric * 0.001), s.price_rounding)::double precision

UNION ALL

-- SELL year: too tight (stop within 1% above target)
SELECT p.name, p.period_type,
    TRUNC(s.price::numeric * (0.75 + p.sell_counter::numeric * 0.001) * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now, p.buy_order_id, p.sell_coinbase_order_id AS coinbase_order_id, p.shares,
    TRUNC(s.price::numeric * (0.75 + p.sell_counter::numeric * 0.001), s.price_rounding) AS new_stop_price, 'sell'::text AS order_type,
    TRUNC(((s.price::numeric * (0.75 + p.sell_counter::numeric * 0.001)) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit
FROM position p JOIN stock s ON p.stock_id = s.stock_id
WHERE p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL AND p.period_type = 'year'
  AND p.daily_sell = false
  AND p.sell_stop_price > TRUNC(s.price::numeric * (0.76 + p.sell_counter::numeric * 0.001), s.price_rounding)::double precision

ORDER BY estimated_profit DESC;
