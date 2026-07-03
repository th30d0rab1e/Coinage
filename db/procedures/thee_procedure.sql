CREATE OR REPLACE PROCEDURE public.thee_procedure()
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

-- Delete unfilled buy positions that have no active order on Coinbase.
-- A row is only removed if neither its buy nor sell order_id appears in
-- bulk_open_orders, meaning Coinbase has no open order associated with it.
DELETE FROM position
WHERE buy_filled_price IS NULL
AND NOT EXISTS (
    SELECT 1 FROM bulk_open_orders o WHERE o.order_id = position.buy_coinbase_order_id
)
AND NOT EXISTS (
    SELECT 1 FROM bulk_open_orders o WHERE o.order_id = position.sell_coinbase_order_id
);

-- Recover orphaned buy orders: open on Coinbase but missing from position table.
-- Skip if an unfilled buy position already exists for that coin + period_type.
INSERT INTO position (stock_id, name, buy_price, buy_stop_price, shares, date_created, buy_order_id, buy_coinbase_order_id, period_type)
SELECT
    s.stock_id,
    o.product_id,
    (o.order_configuration->'stop_limit_stop_limit_gtc'->>'limit_price')::double precision,
    (o.order_configuration->'stop_limit_stop_limit_gtc'->>'stop_price')::double precision,
    (o.order_configuration->'stop_limit_stop_limit_gtc'->>'base_size')::double precision,
    o.created_time,
    o.client_order_id,
    o.order_id,
    CASE
        WHEN ((o.order_configuration->'stop_limit_stop_limit_gtc'->>'limit_price')::numeric *
              (o.order_configuration->'stop_limit_stop_limit_gtc'->>'base_size')::numeric) < 5   THEN 'day'
        WHEN ((o.order_configuration->'stop_limit_stop_limit_gtc'->>'limit_price')::numeric *
              (o.order_configuration->'stop_limit_stop_limit_gtc'->>'base_size')::numeric) < 50  THEN 'month'
        ELSE 'year'
    END
FROM bulk_open_orders o
JOIN stock s ON s.name = o.product_id
LEFT JOIN position p ON p.buy_coinbase_order_id = o.order_id
WHERE o.side = 'BUY'
AND p.buy_coinbase_order_id IS NULL
AND o.order_configuration::text LIKE '%stop_limit_stop_limit_gtc%'
AND NOT EXISTS (
    SELECT 1 FROM position existing
    WHERE existing.stock_id = s.stock_id
    AND existing.buy_filled_price IS NULL
    AND existing.buy_order_id IS NOT NULL
    AND existing.period_type = CASE
        WHEN ((o.order_configuration->'stop_limit_stop_limit_gtc'->>'limit_price')::numeric *
              (o.order_configuration->'stop_limit_stop_limit_gtc'->>'base_size')::numeric) < 5   THEN 'day'
        WHEN ((o.order_configuration->'stop_limit_stop_limit_gtc'->>'limit_price')::numeric *
              (o.order_configuration->'stop_limit_stop_limit_gtc'->>'base_size')::numeric) < 50  THEN 'month'
        ELSE 'year'
    END
);

-- Reconcile cancelled buy orders: in DB but gone from Coinbase.
UPDATE position
SET buy_coinbase_order_id = NULL, error_message = NULL
WHERE buy_filled_price IS NULL
AND buy_coinbase_order_id IS NOT NULL
AND NOT EXISTS (
    SELECT 1 FROM bulk_open_orders o WHERE o.order_id = position.buy_coinbase_order_id
);

-- Reconcile cancelled sell orders: in DB but gone from Coinbase.
UPDATE position
SET sell_coinbase_order_id = NULL, error_message = NULL
WHERE sell_filled_price IS NULL
AND sell_coinbase_order_id IS NOT NULL
AND NOT EXISTS (
    SELECT 1 FROM bulk_open_orders o WHERE o.order_id = position.sell_coinbase_order_id
);

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
LEFT JOIN position p ON p.stock_id = s.stock_id
    AND p.period_type = s.period_type
    AND p.buy_order_id IS NOT NULL
    AND p.buy_filled_price IS NULL
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
WHERE b.name = 'USD'
AND (SELECT value FROM config WHERE key = 'pause_buys') = 'false'
AND (
    (b.available > 1.00  AND s.period_type = 'day')
    OR (b.available > 10.00 AND s.period_type = 'month')
    OR (b.available > 100.00 AND s.period_type = 'year')
)
AND p.buy_order_id IS NULL
AND recommendation = 'BUY'
AND current_change_percent < historical_avg_change_percent
AND historical_avg_change_percent > 0
AND s.score > 5
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

-- Initial sell stop floored at buy_filled_price so we never lock in a loss.
UPDATE position
SET sell_stop_price = GREATEST(
        position.buy_filled_price::numeric,
        TRUNC(
            stock.price::numeric * CASE position.period_type
                WHEN 'day'   THEN LEAST(0.99, GREATEST(0.90, 1 - pat.std_dev::numeric / 200))
                WHEN 'month' THEN LEAST(0.97, GREATEST(0.75, 1 - pat.std_dev::numeric / 200))
                WHEN 'year'  THEN LEAST(0.95, GREATEST(0.60, 1 - pat.std_dev::numeric / 200))
            END,
            stock.price_rounding::int)
    ),
    sell_price = GREATEST(
        position.buy_filled_price::numeric,
        TRUNC(
            stock.price::numeric * (CASE position.period_type
                WHEN 'day'   THEN LEAST(0.99, GREATEST(0.90, 1 - pat.std_dev::numeric / 200))
                WHEN 'month' THEN LEAST(0.97, GREATEST(0.75, 1 - pat.std_dev::numeric / 200))
                WHEN 'year'  THEN LEAST(0.95, GREATEST(0.60, 1 - pat.std_dev::numeric / 200))
            END - 0.01),
            stock.price_rounding::int)
    )
FROM stock
JOIN price_aggregate_total pat ON stock.stock_id = pat.stock_id
WHERE position.stock_id = stock.stock_id
AND pat.period_type = position.period_type
AND position.buy_filled_price IS NOT NULL
AND position.sell_price IS NULL;

-- Clear error_message on unfilled buy positions instead of deleting them.
UPDATE position SET error_message = NULL
WHERE error_message IS NOT NULL
AND buy_coinbase_order_id IS NULL
AND buy_filled_price IS NULL;

TRUNCATE TABLE bulk_stock;
TRUNCATE TABLE bulk_fills;
TRUNCATE TABLE bulk_currency;
TRUNCATE TABLE bulk_open_orders;

$$;
