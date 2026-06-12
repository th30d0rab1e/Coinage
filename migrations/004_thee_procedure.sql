-- thee_procedure: balance-aware buy stops, tiered sell stops, UUID fills IDs, TRUNC fees/profit
CREATE OR REPLACE PROCEDURE public.thee_procedure()
 LANGUAGE sql
AS $procedure$

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
AND COALESCE(p.cnt, 0) < 10
LIMIT 1;

UPDATE position
SET buy_filled_price = bf.price,
    buy_fee = bf.fee,
    buy_fills_id = bf.order_id
FROM bulk_fills bf
WHERE position.buy_coinbase_order_id = bf.order_id
AND position.buy_filled_price IS NULL;

WITH sell_fills AS (
    UPDATE position
    SET sell_filled_price = bf.price,
        sell_fee = bf.fee,
        profit = TRUNC(((bf.price * position.shares - bf.fee) - (position.buy_filled_price * position.shares + position.buy_fee))::numeric, 2),
        transfer_amount = GREATEST(0, TRUNC((TRUNC(((bf.price * position.shares - bf.fee) - (position.buy_filled_price * position.shares + position.buy_fee))::numeric, 2) * 0.30)::numeric, 2))
    FROM bulk_fills bf
    WHERE position.sell_coinbase_order_id = bf.order_id
    AND position.sell_filled_price IS NULL
    RETURNING position.stock_id, position.name, position.period_type,
              position.buy_fills_id, bf.order_id AS sell_fills_id,
              TRUNC(position.buy_fee::numeric, 2) AS buy_fee,
              TRUNC(bf.fee::numeric, 2) AS sell_fee,
              TRUNC(((bf.price * position.shares - bf.fee) - (position.buy_filled_price * position.shares + position.buy_fee))::numeric, 2) AS profit
),
insert_history AS (
    INSERT INTO profit_history (stock_id, name, period_type, buy_fills_id, sell_fills_id, buy_fee, sell_fee, profit)
    SELECT stock_id, name, period_type, buy_fills_id, sell_fills_id, buy_fee, sell_fee, profit
    FROM sell_fills
)
DELETE FROM position
WHERE buy_order_id IN (
    SELECT p.buy_order_id
    FROM position p
    JOIN bulk_fills bf ON p.sell_coinbase_order_id = bf.order_id
    WHERE p.sell_filled_price IS NOT NULL
    AND p.profit IS NOT NULL
    AND (p.transfer_complete = TRUE OR COALESCE(p.transfer_amount, 0) <= 0)
);

UPDATE position
SET sell_stop_price = CASE position.period_type
        WHEN 'day'   THEN TRUNC(stock.price::numeric * 0.97, stock.price_rounding::int)
        WHEN 'month' THEN TRUNC(stock.price::numeric * 0.90, stock.price_rounding::int)
        WHEN 'year'  THEN TRUNC(stock.price::numeric * 0.75, stock.price_rounding::int)
    END,
    sell_price = CASE position.period_type
        WHEN 'day'   THEN TRUNC(stock.price::numeric * 0.96, stock.price_rounding::int)
        WHEN 'month' THEN TRUNC(stock.price::numeric * 0.89, stock.price_rounding::int)
        WHEN 'year'  THEN TRUNC(stock.price::numeric * 0.74, stock.price_rounding::int)
    END
FROM stock
WHERE position.stock_id = stock.stock_id
AND position.buy_filled_price IS NOT NULL
AND position.sell_price IS NULL;

TRUNCATE TABLE bulk_stock;
TRUNCATE TABLE bulk_fills;
TRUNCATE TABLE bulk_currency;
TRUNCATE TABLE bulk_open_orders;

$procedure$;
