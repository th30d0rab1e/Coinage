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

-- Snapshot each stock's year-basis signal score onto the stock row itself, as
-- a priority marker for what to buy -- vw_signal's score isn't otherwise
-- persisted anywhere outside the view.
UPDATE stock
SET score = vw.score
FROM vw_signal vw
WHERE stock.stock_id = vw.stock_id
AND vw.period_type = 'year';

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

-- New position: $1 into the highest year-basis-score coin not already held,
-- gated only on the coin's year-basis trend being positive -- no day-timing
-- signal (recommendation / current-vs-average dip) and no score floor, since
-- the goal is broad $1 exposure across every coin trending up over the
-- year, ranked by score, not picking entries by short-term dip timing.
-- Always recorded as period_type 'day' (the existing $1-size bucket), even
-- though the signal driving the pick is the year row. One new position per
-- cycle.
INSERT INTO position (stock_id, name, buy_price, buy_stop_price, shares, date_created, buy_order_id, period_type)
SELECT s.stock_id, s.name,
    TRUNC((s.close::numeric * 1.05 * 1.01), stock.price_rounding::integer) AS buy_price,
    TRUNC((s.close::numeric * 1.05),        stock.price_rounding::integer) AS buy_stop_price,
    TRUNC((1.00 / s.close)::numeric, stock.share_rounding::integer) AS shares,
    NOW() AS date_created,
    gen_random_uuid(),
    'day'
FROM vw_signal s
JOIN stock ON s.stock_id = stock.stock_id
CROSS JOIN vw_balance b
LEFT JOIN position p ON p.stock_id = s.stock_id
    AND p.period_type = 'day'
    AND p.buy_order_id IS NOT NULL
    AND p.buy_filled_price IS NULL
WHERE b.name = 'USD'
AND (SELECT value FROM config WHERE key = 'pause_buys') = 'false'
AND b.available > 1.00
AND s.period_type = 'year'
AND p.buy_order_id IS NULL
AND historical_avg_change_percent > 0
AND (
    NOT EXISTS (
        SELECT 1 FROM position existing
        WHERE existing.stock_id = s.stock_id
        AND existing.period_type = 'day'
        AND existing.buy_filled_price IS NOT NULL
        AND existing.sell_filled_price IS NULL
    )
    OR s.close < (
        SELECT MIN(existing.buy_filled_price)
        FROM position existing
        WHERE existing.stock_id = s.stock_id
        AND existing.period_type = 'day'
        AND existing.buy_filled_price IS NOT NULL
        AND existing.sell_filled_price IS NULL
    )
)
ORDER BY s.score DESC NULLS LAST
LIMIT 1;

-- Buy again (always $1) if current price has dropped below the MOST
-- RECENT already-filled price for a stock+period (not the lowest ever --
-- anchored on whichever fill actually happened last, so this can
-- re-trigger even after a good fill if price has since moved against
-- the latest one). Anchored on position itself, not vw_signal — purely
-- "average down further," no score/recommendation conditions involved.
-- Only triggers off a coin whose buy is actually filled, and only if
-- there's no other buy order currently open/pending for that same
-- stock+period. When multiple held coins qualify in the same cycle,
-- ranked by stock.score descending (same year-basis priority marker the
-- new-position buy uses) so the highest-priority coin gets the
-- average-down dollar first. One new position per cycle.
WITH held AS (
    SELECT DISTINCT ON (stock_id, period_type)
        stock_id, period_type, buy_filled_price AS last_filled_price
    FROM position
    WHERE buy_filled_price IS NOT NULL
    ORDER BY stock_id, period_type, buy_filled_date DESC
)
INSERT INTO position (stock_id, name, buy_price, buy_stop_price, shares, date_created, buy_order_id, period_type)
SELECT
    s.stock_id,
    s.name,
    TRUNC(s.price::numeric * 1.011, s.price_rounding::integer) AS buy_price,
    TRUNC(s.price::numeric * 1.01,  s.price_rounding::integer) AS buy_stop_price,
    TRUNC((1.00 / s.price)::numeric, s.share_rounding::integer) AS shares,
    NOW() AS date_created,
    gen_random_uuid(),
    held.period_type
FROM held
JOIN stock s ON s.stock_id = held.stock_id
CROSS JOIN vw_balance b
WHERE b.name = 'USD'
AND b.available > 1.00
AND (SELECT value FROM config WHERE key = 'pause_buys') = 'false'
AND TRUNC(s.price::numeric * 1.011, s.price_rounding::integer) < held.last_filled_price
AND NOT EXISTS (
    SELECT 1 FROM position existing
    WHERE existing.stock_id = held.stock_id
    AND existing.period_type = held.period_type
    AND existing.buy_order_id IS NOT NULL
    AND existing.buy_filled_price IS NULL
)
ORDER BY s.score DESC NULLS LAST
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
--
-- sell_stop_price's floor branch carries an extra 1.01 multiplier that
-- sell_price's floor branch does not: when the floor is the binding
-- constraint (GREATEST picks it over the volatility-discount branch,
-- which is most underwater positions), the two branches would otherwise
-- compute to the exact same price, leaving zero gap between trigger and
-- fill. A sell stop-limit order triggers at stop_price and then only
-- fills at limit_price or better; with no gap, price crosses the trigger
-- and keeps falling before the now-working limit order ever gets a
-- chance to execute against it, stranding it above the market
-- indefinitely (confirmed on two LSETH-USD orders: both showed
-- trigger_status STOP_TRIGGERED but sat unfilled since stop_price and
-- limit_price were identical). The 1% buffer only raises the trigger
-- threshold; sell_price's floor is untouched, so the guaranteed-minimum
-- fill price is unchanged and the no-loss floor still holds exactly.
UPDATE position
SET sell_stop_price = GREATEST(
        CEIL(
            (position.buy_filled_price::numeric
                * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012))
                / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012)))
                * 1.01
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
AND position.sell_price IS NULL
-- Estimated profit, from buy_filled_price and buy_fee alone: at the
-- fee-adjusted floor price (same CEIL(...) breakeven formula as above),
-- proceeds after an estimated sell fee (same buy-side fee rate, falling
-- back to 1.2%) must exceed total cost (buy_filled_price * shares +
-- buy_fee). Uses only known buy-side values, not current market price.
AND (
    (CEIL(
        (position.buy_filled_price::numeric
            * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012))
            / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012)))
        * POWER(10::numeric, stock.price_rounding::int)
    ) / POWER(10::numeric, stock.price_rounding::int))
    * position.shares::numeric
    * (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012))
    - (position.buy_filled_price::numeric * position.shares::numeric + COALESCE(position.buy_fee::numeric, 0))
) > 0
-- Also must exceed this period_type's historical average profit, same gate
-- already applied to vw_edit_orders' sell-remake branches.
AND (
    (CEIL(
        (position.buy_filled_price::numeric
            * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012))
            / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012)))
        * POWER(10::numeric, stock.price_rounding::int)
    ) / POWER(10::numeric, stock.price_rounding::int))
    * position.shares::numeric
    * (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012))
    - (position.buy_filled_price::numeric * position.shares::numeric + COALESCE(position.buy_fee::numeric, 0))
) > (SELECT COALESCE(AVG(profit), 0) FROM profit_history WHERE period_type = position.period_type);

-- Refresh stale buy candidates: a pending buy that has never gotten a
-- Coinbase order ID keeps its original buy_stop_price forever, since
-- nothing else ever touches it (the remake logic in vw_edit_orders only
-- applies once a position has SOME coinbase_order_id, pending or filled).
-- If the market moves up past that stop before the order is ever
-- successfully placed, every attempt fails with
-- PREVIEW_STOP_PRICE_BELOW_LAST_TRADE_PRICE (the stop needs room above
-- current price to trigger) -- and since the "clear error_message" step
-- below resets it every cycle, it just retries the same doomed price
-- forever (confirmed stuck this way on OCEAN-USD for 4 days). Recompute
-- using the same flat 5% rule a fresh pick uses, off current price
-- instead of the stale signal-time price.
UPDATE position
SET buy_stop_price = TRUNC(stock.price::numeric * 1.05, stock.price_rounding::integer),
    buy_price = TRUNC(stock.price::numeric * 1.05 * 1.01, stock.price_rounding::integer)
FROM stock
WHERE position.stock_id = stock.stock_id
AND position.buy_coinbase_order_id IS NULL
AND position.buy_filled_price IS NULL
AND stock.price::numeric >= position.buy_stop_price::numeric;

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
    buy_fee            = CASE WHEN position.buy_fee IS NULL AND bf.order_id = position.buy_coinbase_order_id AND bf.fee > 0 THEN bf.fee ELSE position.buy_fee END,
    buy_filled_date    = CASE WHEN position.buy_filled_price IS NULL AND bf.order_id = position.buy_coinbase_order_id THEN NOW() ELSE position.buy_filled_date END,
    sell_filled_price  = CASE WHEN position.sell_filled_price IS NULL AND bf.order_id = position.sell_coinbase_order_id THEN bf.price ELSE position.sell_filled_price END,
    sell_fee           = CASE WHEN position.sell_fee IS NULL AND bf.order_id = position.sell_coinbase_order_id AND bf.fee > 0 THEN bf.fee ELSE position.sell_fee END
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

-- Prune position_audit records older than a month.
DELETE FROM position_audit WHERE changed_at < NOW() - INTERVAL '1 month';

TRUNCATE TABLE bulk_stock;
TRUNCATE TABLE bulk_fills;
TRUNCATE TABLE bulk_currency;
TRUNCATE TABLE bulk_open_orders;

$$;
