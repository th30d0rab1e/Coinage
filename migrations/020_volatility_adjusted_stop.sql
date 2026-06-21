-- Volatility-adjusted sell stops using std_dev from price_aggregate_total.
-- Stop distance = std_dev / 2, capped per period:
--   day:   1% min, 10% max
--   month: 3% min, 25% max
--   year:  5% min, 40% max
-- Replaces flat 3%/10%/25% stops. Higher-volatility assets get more room;
-- lower-volatility assets get a tighter stop.

CREATE OR REPLACE PROCEDURE thee_procedure()
LANGUAGE sql
AS $$

INSERT INTO stock (name, date_created)
SELECT bs.id, NOW()
FROM bulk_stock bs
LEFT JOIN stock s ON bs.id = s.name
WHERE s.stock_id IS NULL
AND bs.id LIKE '%-USD';

UPDATE stock
SET price = bs.price::DOUBLE PRECISION,
    share_rounding = CASE
        WHEN (bs.json->>'base_increment') LIKE '%.%'
        THEN length(bs.json->>'base_increment') - position('.' IN bs.json->>'base_increment')
        ELSE 0
    END,
    price_rounding = CASE
        WHEN (bs.json->>'quote_increment') LIKE '%.%'
        THEN length(bs.json->>'quote_increment') - position('.' IN bs.json->>'quote_increment')
        ELSE 0
    END,
    max_shares = (bs.json->>'base_max_size')::double precision,
    min_shares = (bs.json->>'base_min_size')::double precision,
    max_price = (bs.json->>'quote_max_size')::double precision,
    min_price = (bs.json->>'quote_min_size')::double precision
FROM bulk_stock bs
WHERE stock.name = bs.id
AND bs.id LIKE '%-USD'
AND bs.price != '';

INSERT INTO position (stock_id, name, buy_price, buy_stop_price, shares, date_created, buy_order_id, period_type)
SELECT s.stock_id, s.name,
    TRUNC((s.close::numeric * bal.stop_mult * 1.01), stock.price_rounding::integer) AS buy_price,
    TRUNC((s.close::numeric * bal.stop_mult),        stock.price_rounding::integer) AS buy_stop_price,
    CASE
        WHEN s.period_type = 'day'   THEN TRUNC((1.00   / s.close)::numeric, stock.share_rounding::integer)
        WHEN s.period_type = 'month' THEN TRUNC((10.00  / s.close)::numeric, stock.share_rounding::integer)
        WHEN s.period_type = 'year'  THEN TRUNC((100.00 / s.close)::numeric, stock.share_rounding::integer)
        ELSE 0
    END AS shares,
    NOW() AS date_created,
    gen_random_uuid(),
    s.period_type
FROM vw_signal s
JOIN stock ON s.stock_id = stock.stock_id
CROSS JOIN vw_balance b
CROSS JOIN LATERAL (
    SELECT GREATEST(1.01::numeric, LEAST(1.05::numeric,
        1.01 + 0.04 * (1.0 -
            b.available::numeric /
            NULLIF(
                b.available::numeric + COALESCE((
                    SELECT SUM(p2.buy_price * p2.shares)
                    FROM position p2
                    WHERE p2.buy_coinbase_order_id IS NOT NULL
                    AND p2.buy_filled_price IS NULL
                ), 0)::numeric,
                0
            )
        )
    )) AS stop_mult
) bal
LEFT JOIN vw_position p ON s.stock_id = p.stock_id AND s.period_type = p.period_type
WHERE b.name = 'USD'
AND (SELECT value FROM config WHERE key = 'pause_buys') = 'false'
AND (
    (b.available > 1.00  AND s.period_type = 'day')
    OR (b.available > 10.00 AND s.period_type = 'month')
    OR (b.available > 100.00 AND s.period_type = 'year')
)
AND (s.close < p.min_buy_filled_price OR p.max_buy_coinbase_order_id IS NULL)
AND recommendation = 'BUY'
AND current_change_percent < historical_avg_change_percent
AND historical_avg_change_percent > 0
AND s.score > 5
AND COALESCE(p.cnt, 0) < 10
LIMIT 1;

UPDATE position
SET buy_filled_price = bf.price,
    buy_fee = bf.fee
FROM bulk_fills bf
WHERE position.buy_coinbase_order_id = bf.order_id
AND position.buy_filled_price IS NULL;

WITH sell_fills AS (
    UPDATE position
    SET sell_filled_price = bf.price,
        sell_fee = bf.fee,
        profit = TRUNC(((bf.price * position.shares - bf.fee) - (position.buy_filled_price * position.shares + position.buy_fee))::numeric, 2)
    FROM bulk_fills bf
    WHERE position.sell_coinbase_order_id = bf.order_id
    AND position.sell_filled_price IS NULL
    RETURNING position.stock_id, position.name, position.period_type,
              position.buy_coinbase_order_id, bf.order_id AS sell_fills_id,
              TRUNC(position.buy_fee::numeric, 2) AS buy_fee,
              TRUNC(bf.fee::numeric, 2) AS sell_fee,
              TRUNC(((bf.price * position.shares - bf.fee) - (position.buy_filled_price * position.shares + position.buy_fee))::numeric, 2) AS profit
),
insert_history AS (
    INSERT INTO profit_history (stock_id, name, period_type, buy_coinbase_order_id, sell_fills_id, buy_fee, sell_fee, profit)
    SELECT stock_id, name, period_type, buy_coinbase_order_id, sell_fills_id, buy_fee, sell_fee, profit
    FROM sell_fills
)
DELETE FROM position
WHERE buy_order_id IN (
    SELECT p.buy_order_id
    FROM position p
    JOIN bulk_fills bf ON p.sell_coinbase_order_id = bf.order_id
    WHERE p.sell_filled_price IS NOT NULL
    AND p.profit IS NOT NULL
);

-- Volatility-adjusted initial sell stop: std_dev/2 of the asset's historical
-- price variation, capped to reasonable bounds per period type.
UPDATE position
SET sell_stop_price = TRUNC(
        stock.price::numeric * CASE position.period_type
            WHEN 'day'   THEN LEAST(0.99, GREATEST(0.90, 1 - pat.std_dev::numeric / 200))
            WHEN 'month' THEN LEAST(0.97, GREATEST(0.75, 1 - pat.std_dev::numeric / 200))
            WHEN 'year'  THEN LEAST(0.95, GREATEST(0.60, 1 - pat.std_dev::numeric / 200))
        END,
        stock.price_rounding::int),
    sell_price = TRUNC(
        stock.price::numeric * (CASE position.period_type
            WHEN 'day'   THEN LEAST(0.99, GREATEST(0.90, 1 - pat.std_dev::numeric / 200))
            WHEN 'month' THEN LEAST(0.97, GREATEST(0.75, 1 - pat.std_dev::numeric / 200))
            WHEN 'year'  THEN LEAST(0.95, GREATEST(0.60, 1 - pat.std_dev::numeric / 200))
        END - 0.01),
        stock.price_rounding::int)
FROM stock
JOIN price_aggregate_total pat ON stock.stock_id = pat.stock_id
WHERE position.stock_id = stock.stock_id
AND pat.period_type = position.period_type
AND position.buy_filled_price IS NOT NULL
AND position.sell_price IS NULL;

--Delete bad records
DELETE FROM position WHERE error_message IS NOT NULL AND buy_coinbase_order_id IS NULL;

TRUNCATE TABLE bulk_stock;
TRUNCATE TABLE bulk_fills;
TRUNCATE TABLE bulk_currency;
TRUNCATE TABLE bulk_open_orders;

$$;


-- Volatility-adjusted trailing stops in vw_edit_orders.
-- Each sell branch computes stop_ratio from price_aggregate_total std_dev.

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
    ), 0)), 4) AS estimated_profit,
    p.buy_counter AS counter
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

-- SELL daily_sell: tight 1% trail to lock in the daily profit-taking position
SELECT p.name, p.period_type,
    TRUNC(s.price::numeric * (0.99 + p.sell_counter::numeric * 0.001) * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now, p.buy_order_id, p.sell_coinbase_order_id AS coinbase_order_id, p.shares,
    TRUNC(s.price::numeric * (0.99 + p.sell_counter::numeric * 0.001), s.price_rounding) AS new_stop_price, 'sell'::text AS order_type,
    TRUNC(((s.price::numeric * (0.99 + p.sell_counter::numeric * 0.001)) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit,
    p.sell_counter AS counter
FROM position p JOIN stock s ON p.stock_id = s.stock_id
WHERE p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL
  AND p.daily_sell = true
  AND p.sell_stop_price < TRUNC(s.price::numeric * (0.99 + p.sell_counter::numeric * 0.001), s.price_rounding)::double precision

UNION ALL

-- SELL trailing up: stop is below the vol-adjusted target, move it up
SELECT p.name, p.period_type,
    TRUNC(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.001) * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now, p.buy_order_id, p.sell_coinbase_order_id AS coinbase_order_id, p.shares,
    TRUNC(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.001), s.price_rounding) AS new_stop_price, 'sell'::text AS order_type,
    TRUNC(((s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.001)) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit,
    p.sell_counter AS counter
FROM position p
JOIN stock s ON p.stock_id = s.stock_id
JOIN price_aggregate_total pat ON p.stock_id = pat.stock_id AND p.period_type = pat.period_type
CROSS JOIN LATERAL (
    SELECT CASE p.period_type
        WHEN 'day'   THEN LEAST(0.99, GREATEST(0.90, 1 - pat.std_dev::numeric / 200))
        WHEN 'month' THEN LEAST(0.97, GREATEST(0.75, 1 - pat.std_dev::numeric / 200))
        WHEN 'year'  THEN LEAST(0.95, GREATEST(0.60, 1 - pat.std_dev::numeric / 200))
    END AS stop_ratio
) vol
WHERE p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL
  AND p.daily_sell = false
  AND p.sell_stop_price < TRUNC(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.001), s.price_rounding)::double precision

UNION ALL

-- SELL too tight: stop is above vol-adjusted target + 1%, pull it back down
SELECT p.name, p.period_type,
    TRUNC(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.001) * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now, p.buy_order_id, p.sell_coinbase_order_id AS coinbase_order_id, p.shares,
    TRUNC(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.001), s.price_rounding) AS new_stop_price, 'sell'::text AS order_type,
    TRUNC(((s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.001)) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit,
    p.sell_counter AS counter
FROM position p
JOIN stock s ON p.stock_id = s.stock_id
JOIN price_aggregate_total pat ON p.stock_id = pat.stock_id AND p.period_type = pat.period_type
CROSS JOIN LATERAL (
    SELECT CASE p.period_type
        WHEN 'day'   THEN LEAST(0.99, GREATEST(0.90, 1 - pat.std_dev::numeric / 200))
        WHEN 'month' THEN LEAST(0.97, GREATEST(0.75, 1 - pat.std_dev::numeric / 200))
        WHEN 'year'  THEN LEAST(0.95, GREATEST(0.60, 1 - pat.std_dev::numeric / 200))
    END AS stop_ratio
) vol
WHERE p.sell_coinbase_order_id IS NOT NULL AND p.sell_filled_price IS NULL
  AND p.daily_sell = false
  AND p.sell_stop_price > TRUNC(s.price::numeric * (vol.stop_ratio + 0.01 + p.sell_counter::numeric * 0.001), s.price_rounding)::double precision

ORDER BY estimated_profit DESC;
