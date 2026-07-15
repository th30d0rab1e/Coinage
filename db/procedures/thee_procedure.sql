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

-- Mark the pending buy order whose coin currently has the highest vw_signal
-- priority as daily_buy. Re-evaluated every cycle (not a once-per-day pick),
-- so exactly one row is true at a time and it tracks priority as it shifts.
WITH ranked AS (
    SELECT p.buy_order_id,
        ROW_NUMBER() OVER (ORDER BY vw.priority DESC NULLS LAST) AS rn
    FROM position p
    JOIN vw_signal vw ON vw.stock_id = p.stock_id AND vw.period_type = p.period_type
    WHERE p.buy_coinbase_order_id IS NOT NULL
    AND p.buy_filled_price IS NULL
)
UPDATE position
SET daily_buy = (position.buy_order_id IN (SELECT buy_order_id FROM ranked WHERE rn = 1))
WHERE position.buy_coinbase_order_id IS NOT NULL
AND position.buy_filled_price IS NULL
AND position.daily_buy != (position.buy_order_id IN (SELECT buy_order_id FROM ranked WHERE rn = 1));

-- Reconcile cancelled sell orders: in DB but gone from Coinbase.
UPDATE position
SET sell_coinbase_order_id = NULL, error_message = NULL
WHERE sell_filled_price IS NULL
AND sell_coinbase_order_id IS NOT NULL
AND NOT EXISTS (
    SELECT 1 FROM bulk_open_orders o WHERE o.order_id = position.sell_coinbase_order_id
);

-- Orphan sell recovery: re-link any Coinbase SELL order to a position that lost its sell_coinbase_order_id.
-- Uses DISTINCT ON (o.order_id) so each Coinbase order is only matched to one position row.
WITH orphan_match AS (
    SELECT DISTINCT ON (o.order_id) p.buy_order_id AS pos_key, o.order_id
    FROM position p
    JOIN bulk_open_orders o ON o.side = 'SELL'
        AND o.product_id = p.name
        AND ABS((o.order_configuration->'stop_limit_stop_limit_gtc'->>'base_size')::numeric - p.shares::numeric) < 0.0001
        AND NOT EXISTS (SELECT 1 FROM position p2 WHERE p2.sell_coinbase_order_id = o.order_id)
    WHERE p.buy_filled_price IS NOT NULL
    AND p.sell_filled_price IS NULL
    AND p.sell_coinbase_order_id IS NULL
    ORDER BY o.order_id
)
UPDATE position p
SET sell_coinbase_order_id = om.order_id
FROM orphan_match om
WHERE p.buy_order_id = om.pos_key;

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
AND (
    NOT EXISTS (
        SELECT 1 FROM position existing
        WHERE existing.stock_id = s.stock_id
        AND existing.period_type = s.period_type
        AND existing.buy_filled_price IS NOT NULL
        AND existing.sell_filled_price IS NULL
    )
    OR s.close < (
        SELECT MIN(existing.buy_filled_price)
        FROM position existing
        WHERE existing.stock_id = s.stock_id
        AND existing.period_type = s.period_type
        AND existing.buy_filled_price IS NOT NULL
        AND existing.sell_filled_price IS NULL
    )
)
LIMIT 1;

-- Initial sell stop, floored at a breakeven price unconditionally — a
-- position must never be sold at a net loss, underwater or not. The floor
-- is NOT raw buy_filled_price: profit is (sell_price*shares - sell_fee) -
-- (buy_price*shares + buy_fee), so selling at exactly buy_filled_price
-- still loses both fees. This expression solves for the sell price where
-- post-fee proceeds exactly cover total cost, using this position's own
-- realized buy-side fee rate as the estimate for the sell-side fee
-- (falling back to 1.2% if the buy fee is unknown). LATERAL can't be used
-- here since UPDATE's target table isn't a FROM-list item it can see, so
-- the formula is inlined directly instead of computed once via a join.
-- When underwater this floor makes the stop land above current market,
-- which Coinbase will reject at placement time; processSellOrders() must
-- not respond to that rejection by substituting a lower (loss-making)
-- price — it should leave the position unprotected and retry with fresh
-- preview data next cycle until price recovers enough for this floor to
-- clear.
UPDATE position
SET sell_stop_price = GREATEST(
        CEIL(
            (position.buy_filled_price::numeric
                * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012))
                / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012)))
            * POWER(10::numeric, stock.price_rounding::int)
        ) / POWER(10::numeric, stock.price_rounding::int),
        TRUNC(stock.price::numeric * CASE position.period_type
            WHEN 'day'   THEN LEAST(0.99, GREATEST(0.90, 1 - pat.std_dev::numeric / 200))
            WHEN 'month' THEN LEAST(0.97, GREATEST(0.75, 1 - pat.std_dev::numeric / 200))
            WHEN 'year'  THEN LEAST(0.95, GREATEST(0.60, 1 - pat.std_dev::numeric / 200))
        END, stock.price_rounding::int)
    ),
    sell_price = GREATEST(
        CEIL(
            (position.buy_filled_price::numeric
                * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012))
                / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012)))
            * POWER(10::numeric, stock.price_rounding::int)
        ) / POWER(10::numeric, stock.price_rounding::int),
        TRUNC(stock.price::numeric * (CASE position.period_type
            WHEN 'day'   THEN LEAST(0.99, GREATEST(0.90, 1 - pat.std_dev::numeric / 200))
            WHEN 'month' THEN LEAST(0.97, GREATEST(0.75, 1 - pat.std_dev::numeric / 200))
            WHEN 'year'  THEN LEAST(0.95, GREATEST(0.60, 1 - pat.std_dev::numeric / 200))
        END - 0.01), stock.price_rounding::int)
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

-- Step 1: match fills for either side of a position (buy or sell) against
-- this cycle's bulk_fills. Deliberately does not compute profit here — that
-- happens fresh in Step 2 from position's own stored columns, decoupled
-- from this statement, so a NULL fee here can never silently block the
-- close-out the way it used to (buy_fee NULL -> profit NULL -> position
-- stuck forever with no way back in).
-- Also retries fee alone even after the price is already filled in: Coinbase
-- can return a fill with price known but commission not yet settled, and
-- without this the fee would stay NULL forever since nothing else ever
-- rechecks a row once buy_filled_price/sell_filled_price is no longer NULL.
UPDATE position
SET buy_filled_price  = CASE WHEN position.buy_filled_price IS NULL AND bf.order_id = position.buy_coinbase_order_id THEN bf.price ELSE position.buy_filled_price END,
    buy_fee            = CASE WHEN position.buy_fee IS NULL AND bf.order_id = position.buy_coinbase_order_id THEN bf.fee ELSE position.buy_fee END,
    buy_filled_date    = CASE WHEN position.buy_filled_price IS NULL AND bf.order_id = position.buy_coinbase_order_id THEN NOW() ELSE position.buy_filled_date END,
    sell_filled_price  = CASE WHEN position.sell_filled_price IS NULL AND bf.order_id = position.sell_coinbase_order_id THEN bf.price ELSE position.sell_filled_price END,
    sell_fee           = CASE WHEN position.sell_fee IS NULL AND bf.order_id = position.sell_coinbase_order_id THEN bf.fee ELSE position.sell_fee END
FROM bulk_fills bf
WHERE (bf.order_id = position.buy_coinbase_order_id AND (position.buy_filled_price IS NULL OR position.buy_fee IS NULL))
   OR (bf.order_id = position.sell_coinbase_order_id AND (position.sell_filled_price IS NULL OR position.sell_fee IS NULL));

-- Step 2: record any fully bought-and-sold position into profit_history,
-- computing profit fresh from position's current buy/sell price and fee
-- columns. Requires every one of buy/sell order_id, buy/sell filled price,
-- and buy/sell fee to actually be populated -- no COALESCE fallback, so a
-- still-missing fee (e.g. not yet settled by Coinbase) correctly holds this
-- position back rather than recording a wrong, understated profit. It'll
-- pick it up automatically once Step 1 finishes backfilling it. Skips
-- anything already recorded, matched on both the buy and sell order_id
-- together.
INSERT INTO profit_history (stock_id, name, period_type, buy_coinbase_order_id, sell_fills_id, buy_fee, sell_fee, profit)
SELECT
    p.stock_id, p.name, p.period_type, p.buy_coinbase_order_id, p.sell_coinbase_order_id AS sell_fills_id,
    TRUNC(p.buy_fee::numeric, 2) AS buy_fee,
    TRUNC(p.sell_fee::numeric, 2) AS sell_fee,
    TRUNC(((p.sell_filled_price::numeric * p.shares::numeric - p.sell_fee::numeric)
         - (p.buy_filled_price::numeric * p.shares::numeric + p.buy_fee::numeric))::numeric, 2) AS profit
FROM position p
WHERE p.buy_coinbase_order_id IS NOT NULL
AND p.sell_coinbase_order_id IS NOT NULL
AND p.buy_filled_price IS NOT NULL
AND p.sell_filled_price IS NOT NULL
AND p.buy_fee IS NOT NULL
AND p.sell_fee IS NOT NULL
AND NOT EXISTS (
    SELECT 1 FROM profit_history ph
    WHERE ph.buy_coinbase_order_id = p.buy_coinbase_order_id AND ph.sell_fills_id = p.sell_coinbase_order_id
);

-- Step 3: delete the position row, but only once it's confirmed recorded in
-- profit_history — never delete on the strength of this statement's own
-- assumptions the way the old combined version did.
DELETE FROM position p
WHERE p.buy_filled_price IS NOT NULL AND p.sell_filled_price IS NOT NULL
AND EXISTS (
    SELECT 1 FROM profit_history ph
    WHERE ph.buy_coinbase_order_id = p.buy_coinbase_order_id AND ph.sell_fills_id = p.sell_coinbase_order_id
);

TRUNCATE TABLE bulk_stock;
TRUNCATE TABLE bulk_fills;
TRUNCATE TABLE bulk_currency;
TRUNCATE TABLE bulk_open_orders;

$$;
