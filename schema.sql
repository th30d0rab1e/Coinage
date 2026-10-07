--
-- PostgreSQL database dump
--

\restrict HRelLC2K2SyCeAgn8Z6IwrLZs8sfQxkIPF1O1XCc5Dh5Ew0LqeHdWcza7T4E6Jc

-- Dumped from database version 17.9 (Homebrew)
-- Dumped by pg_dump version 17.9 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: aggregate(); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.aggregate()
    LANGUAGE sql
    AS $$

DELETE FROM price_history
WHERE date_created < NOW() - INTERVAL '25 hours';

DELETE FROM price_aggregate
WHERE period_date < NOW() - INTERVAL '31 days'
AND period_type = 'day';

DELETE FROM price_aggregate
WHERE period_date < NOW() - INTERVAL '13 months'
AND period_type = 'month';

INSERT INTO price_history(stock_id, price, date_created)
SELECT stock_id, price, now()
FROM stock;

INSERT INTO price_aggregate (stock_id, period_type, period_date, open, close, high, low, avg_price)
SELECT stock_id, 'day', DATE_TRUNC('day', NOW())::DATE,
    MIN(price), MAX(price), MAX(price), MIN(price), AVG(price)
FROM stock
WHERE NOT EXISTS (
    SELECT 1 FROM price_aggregate pa
    WHERE pa.stock_id = stock.stock_id
    AND pa.period_type = 'day'
    AND pa.period_date = DATE_TRUNC('day', NOW())::DATE
)
GROUP BY stock_id

UNION ALL

SELECT stock_id, 'month', DATE_TRUNC('month', NOW())::DATE,
    MIN(open), MAX(close), MAX(high), MIN(low), AVG(avg_price)
FROM price_aggregate
WHERE period_type = 'day'
AND period_date >= NOW() - INTERVAL '30 days'
AND NOT EXISTS (
    SELECT 1 FROM price_aggregate pa
    WHERE pa.stock_id = price_aggregate.stock_id
    AND pa.period_type = 'month'
    AND pa.period_date = DATE_TRUNC('month', NOW())::DATE
)
GROUP BY stock_id

UNION ALL

SELECT stock_id, 'year', DATE_TRUNC('year', NOW())::DATE,
    MIN(open), MAX(close), MAX(high), MIN(low), AVG(avg_price)
FROM price_aggregate
WHERE period_type = 'month'
AND period_date >= NOW() - INTERVAL '12 months'
AND NOT EXISTS (
    SELECT 1 FROM price_aggregate pa
    WHERE pa.stock_id = price_aggregate.stock_id
    AND pa.period_type = 'year'
    AND pa.period_date = DATE_TRUNC('year', NOW())::DATE
)
GROUP BY stock_id;

UPDATE price_aggregate pa
SET
    open = s.open,
    close = s.close,
    high = s.max_price,
    low = s.min_price,
    avg_price = s.avg_price
FROM (
    SELECT DISTINCT ON (stock_id)
        stock_id,
        FIRST_VALUE(price) OVER (PARTITION BY stock_id ORDER BY price_history_id ASC) AS open,
        LAST_VALUE(price) OVER (PARTITION BY stock_id ORDER BY price_history_id ASC ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS close,
        MIN(price) OVER (PARTITION BY stock_id) AS min_price,
        MAX(price) OVER (PARTITION BY stock_id) AS max_price,
        AVG(price) OVER (PARTITION BY stock_id) AS avg_price
    FROM price_history
    WHERE date_created::date = DATE_TRUNC('day', NOW())::DATE
    ORDER BY stock_id
) s
WHERE pa.stock_id = s.stock_id
AND pa.period_type = 'day'
AND pa.period_date = DATE_TRUNC('day', NOW())::DATE;

UPDATE price_aggregate pa
SET
    open = s.open,
    close = s.close,
    high = s.high,
    low = s.low,
    avg_price = s.avg_price
FROM (
    SELECT stock_id,
        (ARRAY_AGG(open ORDER BY period_date ASC))[1] AS open,
        (ARRAY_AGG(close ORDER BY period_date DESC))[1] AS close,
        MAX(high) AS high,
        MIN(low) AS low,
        AVG(avg_price) AS avg_price
    FROM price_aggregate
    WHERE period_type = 'day'
    AND period_date >= NOW() - INTERVAL '30 days'
    GROUP BY stock_id
) s
WHERE pa.stock_id = s.stock_id
AND pa.period_type = 'month'
AND pa.period_date = DATE_TRUNC('month', NOW())::DATE;

UPDATE price_aggregate pa
SET
    open = s.open,
    close = s.close,
    high = s.high,
    low = s.low,
    avg_price = s.avg_price
FROM (
    SELECT stock_id,
        (ARRAY_AGG(open ORDER BY period_date ASC))[1] AS open,
        (ARRAY_AGG(close ORDER BY period_date DESC))[1] AS close,
        MAX(high) AS high,
        MIN(low) AS low,
        AVG(avg_price) AS avg_price
    FROM price_aggregate
    WHERE period_type = 'month'
    AND period_date >= NOW() - INTERVAL '12 months'
    GROUP BY stock_id
) s
WHERE pa.stock_id = s.stock_id
AND pa.period_type = 'year'
AND pa.period_date = DATE_TRUNC('year', NOW())::DATE;

INSERT INTO price_aggregate_comparison (before_id, after_id, change_percent)
SELECT
    pa_before.price_aggregate_id AS before_id,
    pa_after.price_aggregate_id AS after_id,
    ((pa_after.close - pa_before.close) / pa_before.close) * 100 AS change_percent
FROM price_aggregate pa_before
JOIN price_aggregate pa_after
    ON pa_before.stock_id = pa_after.stock_id
    AND pa_before.period_type = pa_after.period_type
    AND (
        (pa_before.period_type = 'day' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 day')
        OR (pa_before.period_type = 'year' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 year')
        OR (pa_before.period_type = 'month' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 month')
    )
LEFT JOIN price_aggregate_comparison pac
    ON pa_before.price_aggregate_id = pac.before_id
    AND pa_after.price_aggregate_id = pac.after_id
WHERE pac.price_aggregate_comparison_id IS NULL;

UPDATE price_aggregate_comparison pac
SET change_percent = ((pa_after.close - pa_before.close) / pa_before.close) * 100
FROM price_aggregate pa_before
JOIN price_aggregate pa_after
    ON pa_before.stock_id = pa_after.stock_id
    AND pa_before.period_type = pa_after.period_type
    AND (
        (pa_before.period_type = 'day' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 day')
        OR (pa_before.period_type = 'year' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 year')
        OR (pa_before.period_type = 'month' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 month')
    )
WHERE pac.before_id = pa_before.price_aggregate_id
AND pac.after_id = pa_after.price_aggregate_id;

INSERT INTO price_aggregate_total (stock_id, period_type, avg_change_percent)
SELECT
    pa.stock_id,
    pa.period_type,
    AVG(pac.change_percent) AS avg_change_percent
FROM price_aggregate_comparison pac
JOIN price_aggregate pa ON pa.price_aggregate_id = pac.before_id
LEFT JOIN price_aggregate_total pat
    ON pa.stock_id = pat.stock_id
    AND pa.period_type = pat.period_type
WHERE pat.price_aggregate_total_id IS NULL
GROUP BY pa.stock_id, pa.period_type;

UPDATE price_aggregate_total pat
SET
    avg_change_percent = x.avg_change_percent,
    std_dev = x.std_dev,
    std_dev_upper_bound = x.avg_change_percent + (2 * x.std_dev),
    std_dev_lower_bound = x.avg_change_percent - (2 * x.std_dev)
FROM (
    SELECT
        pa.stock_id,
        pa.period_type,
        AVG(pac.change_percent) AS avg_change_percent,
        STDDEV(pac.change_percent) AS std_dev
    FROM price_aggregate_comparison pac
    JOIN price_aggregate pa ON pa.price_aggregate_id = pac.before_id
    GROUP BY pa.stock_id, pa.period_type
) x
WHERE pat.stock_id = x.stock_id
AND pat.period_type = x.period_type;

$$;


--
-- Name: insert_aggregate(); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.insert_aggregate()
    LANGUAGE sql
    AS $$
INSERT INTO price_aggregate (stock_id, period_type, period_date, low, high, open, close, avg_price)
SELECT 
    bs.stock_id,
    'year' AS period_type,
    DATE_TRUNC('year', TO_TIMESTAMP(bs.start))::DATE AS period_date,
    MIN(bs.low) AS low,
    MAX(bs.high) AS high,
    (ARRAY_AGG(bs.open ORDER BY start ASC))[1] AS open,
    (ARRAY_AGG(bs.close ORDER BY start DESC))[1] AS close,
    AVG(bs.close) AS avg_price
FROM bulk_historical bs
LEFT JOIN price_aggregate pa
     ON bs.stock_id = pa.stock_id
     AND pa.period_type = 'year'
     AND pa.period_date = DATE_TRUNC('year', TO_TIMESTAMP(bs.start))::DATE
WHERE pa.price_aggregate_id IS NULL
GROUP BY bs.stock_id, DATE_TRUNC('year', TO_TIMESTAMP(bs.start))
ORDER BY stock_id, period_date;

INSERT INTO price_aggregate (stock_id, period_type, period_date, low, high, open, close, avg_price)
SELECT 
    bs.stock_id,
    'month' AS period_type,
    DATE_TRUNC('month', TO_TIMESTAMP(bs.start))::DATE AS period_date,
    MIN(bs.low) AS low,
    MAX(bs.high) AS high,
    (ARRAY_AGG(bs.open ORDER BY start ASC))[1] AS open,
    (ARRAY_AGG(bs.close ORDER BY start DESC))[1] AS close,
    AVG(bs.close) AS avg_price
FROM bulk_historical bs
LEFT JOIN price_aggregate pa
     ON bs.stock_id = pa.stock_id
     AND pa.period_type = 'month'
     AND pa.period_date = DATE_TRUNC('month', TO_TIMESTAMP(bs.start))::DATE
WHERE pa.price_aggregate_id IS NULL
GROUP BY bs.stock_id, DATE_TRUNC('month', TO_TIMESTAMP(bs.start))
ORDER BY stock_id, period_date;

UPDATE stock s SET historical_finished = 1::bit
FROM bulk_historical bh
WHERE s.stock_id = bh.stock_id;

TRUNCATE TABLE bulk_historical;
$$;


--
-- Name: position_audit_trigger(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.position_audit_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    old_json JSONB;
    new_json JSONB;
    key TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO position_audit (position_id, operation, column_name, old_value, new_value)
        VALUES (NEW.position_id, 'INSERT', NULL, NULL, to_jsonb(NEW)::text);
        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO position_audit (position_id, operation, column_name, old_value, new_value)
        VALUES (OLD.position_id, 'DELETE', NULL, to_jsonb(OLD)::text, NULL);
        RETURN OLD;

    ELSIF TG_OP = 'UPDATE' THEN
        old_json := to_jsonb(OLD);
        new_json := to_jsonb(NEW);
        FOR key IN SELECT jsonb_object_keys(new_json) LOOP
            IF old_json -> key IS DISTINCT FROM new_json -> key THEN
                INSERT INTO position_audit (position_id, operation, column_name, old_value, new_value)
                VALUES (NEW.position_id, 'UPDATE', key, old_json ->> key, new_json ->> key);
            END IF;
        END LOOP;
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$;


--
-- Name: thee_procedure(); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.thee_procedure()
    LANGUAGE sql
    AS $_$

INSERT INTO stock (name, date_created)
SELECT bs.id, NOW()
FROM bulk_stock bs
LEFT JOIN stock s ON bs.id = s.name
WHERE s.stock_id IS NULL
AND bs.id LIKE '%-USD';

-- trading_disabled is copied from Coinbase's own products feed (bulk_stock,
-- refreshed every cycle) and checked before ever picking a coin as a fresh
-- buy candidate below -- confirmed RNDR-USD and MKR-USD both come back
-- status: "delisted", trading_disabled: true, and were being retried as buy
-- candidates every cycle regardless, failing every time with
-- PERMISSION_DENIED. A coin whose product_id disappears from Coinbase's
-- catalog entirely (confirmed on LRC-USD) doesn't need this guard --
-- without a bulk_stock row at all, it was already never a candidate.
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
    min_price = (bs.json->>'quote_min_size')::double precision,
    trading_disabled = (bs.json->>'trading_disabled')::boolean
FROM bulk_stock bs
WHERE stock.name = bs.id
AND bs.id LIKE '%-USD'
AND bs.price != '';

-- 2026-10-07 STABLECOIN FLAG (Theodore: never buy stablecoins). Coinbase does
-- not label stablecoins (no field in the Advanced Trade products API), so it
-- is derived from price behavior in this minute's products feed (bulk_stock,
-- loaded by index.js processNewCoins()): a coin is a stablecoin when
--     price BETWEEN 1 - band AND 1 + band    (band = stablecoin_price_band_pct, default 3%  -> 0.97 .. 1.03)
--     AND (high_24h - low_24h) / price < max (max  = stablecoin_max_range_pct,  default 2%)
-- On 2026-10-07 live data this matched exactly USDT, USD1, USDS, PAX, DAI.
-- STICKY: only ever sets TRUE, never clears it -- a de-peg/spike day (PAX hit
-- $1.83 on 2026-09-27) must not make a stablecoin buyable again. Un-flag a
-- coin by hand if ever needed. Runs before every buy INSERT below, so a coin
-- flagged this minute is already excluded this minute.
-- Guards: values are cast only when they look like plain numbers (a bad or
-- empty string must never abort the whole procedure), price/high/low must
-- be > 0 with high >= low, and volume_24h must be > 0 -- a coin with no
-- trades in 24h reports a flat range that would look "stable" at any price
-- near $1.
UPDATE stock
SET is_stablecoin = TRUE
FROM bulk_stock bs
CROSS JOIN LATERAL (
    SELECT CASE WHEN bs.price                ~ '^[0-9]+(\.[0-9]+)?$' THEN bs.price::numeric                END AS px,
           CASE WHEN bs.json->>'high_24h'    ~ '^[0-9]+(\.[0-9]+)?$' THEN (bs.json->>'high_24h')::numeric   END AS hi,
           CASE WHEN bs.json->>'low_24h'     ~ '^[0-9]+(\.[0-9]+)?$' THEN (bs.json->>'low_24h')::numeric    END AS lo,
           CASE WHEN bs.json->>'volume_24h'  ~ '^[0-9]+(\.[0-9]+)?$' THEN (bs.json->>'volume_24h')::numeric END AS vol
) v
CROSS JOIN LATERAL (
    -- thresholds in percent, from config (defaults if a key is missing)
    SELECT COALESCE((SELECT value::numeric FROM config WHERE key = 'stablecoin_price_band_pct'), 3) AS band_pct,
           COALESCE((SELECT value::numeric FROM config WHERE key = 'stablecoin_max_range_pct'), 2)  AS range_pct
) cfg
WHERE stock.name = bs.id
AND bs.id LIKE '%-USD'
AND stock.is_stablecoin IS NOT TRUE          -- sticky: only FALSE -> TRUE, never back
AND v.px > 0 AND v.hi > 0 AND v.lo > 0 AND v.hi >= v.lo
AND v.vol > 0
AND v.px BETWEEN 1 - cfg.band_pct / 100 AND 1 + cfg.band_pct / 100
AND (v.hi - v.lo) / v.px < cfg.range_pct / 100;

-- 2026-09-25: flag coins that have vanished from Coinbase's product catalog.
-- The UPDATE above only touches stocks that still appear in bulk_stock, so a
-- coin removed from the catalog entirely (LRC-USD) kept trading_disabled NULL
-- and a frozen price forever -- the comment above assumed "not in the catalog"
-- meant "never a candidate", but its already-inserted planned buy row was
-- still retried every cycle, failing with 'Invalid product_id' (18,987 audit
-- rows on position 787). Marking it disabled lets processBuyOrders and both
-- INSERT gates skip it. Guarded on bulk_stock actually being populated
-- (> 100 -USD products; normally ~400) so a failed/empty fetchProducts()
-- can't mass-disable every coin. Self-healing: if a coin comes back, the
-- UPDATE above resets trading_disabled from Coinbase's own flag next cycle.
UPDATE stock
SET trading_disabled = TRUE
WHERE stock.name LIKE '%-USD'
AND stock.trading_disabled IS NOT TRUE
AND NOT EXISTS (SELECT 1 FROM bulk_stock bs WHERE bs.id = stock.name)
AND (SELECT COUNT(*) FROM bulk_stock WHERE id LIKE '%-USD') > 100;

-- Snapshot each stock's year-basis signal priority onto the stock row itself,
-- as a priority marker for what to buy -- vw_signal's priority isn't
-- otherwise persisted anywhere outside the view.
UPDATE stock
SET priority = vw.priority
FROM vw_signal vw
WHERE stock.stock_id = vw.stock_id
AND vw.period_type = 'year';

-- Archive every fill into the permanent ledger before anything else touches
-- bulk_fills this cycle. bulk_fills gets truncated at the end of every
-- cycle and was never meant to be a historical record; fills is. Keyed on
-- trade_id (Coinbase's own unique id per fill execution, since one order
-- can partially fill across several), so this is naturally idempotent --
-- a fill already archived on a previous cycle is silently skipped.
INSERT INTO fills (order_id, trade_id, product_id, side, price, size, fee, trade_time)
SELECT bf.order_id, bf.trade_id, bf.product_id, bf.side, bf.price, bf.size, bf.fee, bf.created_at
FROM bulk_fills bf
ON CONFLICT (trade_id) DO NOTHING;

-- Learn the taker fee from the single latest fill, not an average.
-- fee_percent is a percent with 2 decimal places: 0.90 means 0.90 percent,
-- not a 0.009 rate. Rounding the raw rate (fee / notional) to 2 decimals
-- would collapse 0.90 and 0.50 into 0.01, so the stored number is percent.
-- Sits here, just after the fills archive and before any buy/sell pricing,
-- so this cycle's fill is already in the ledger. A null or zero result
-- does not insert a row and does not wipe a value already stored.
INSERT INTO config (key, value)
SELECT 'fee_percent', learned.pct
FROM (
    SELECT ROUND(((fee / NULLIF(price * size, 0)) * 100)::numeric, 2)::text AS pct
    FROM fills
    WHERE fee > 0
      AND price > 0
      AND size > 0
    ORDER BY trade_time DESC
    LIMIT 1
) learned
WHERE learned.pct IS NOT NULL
  AND learned.pct::numeric <> 0
ON CONFLICT (key) DO NOTHING;

UPDATE config
SET value = learned.pct
FROM (
    SELECT ROUND(((fee / NULLIF(price * size, 0)) * 100)::numeric, 2)::text AS pct
    FROM fills
    WHERE fee > 0
      AND price > 0
      AND size > 0
    ORDER BY trade_time DESC
    LIMIT 1
) learned
WHERE config.key = 'fee_percent'
  AND learned.pct IS NOT NULL
  AND learned.pct::numeric <> 0;

-- Recover orphaned buy orders: open on Coinbase but missing from position table.
-- Skip if an unfilled buy position already exists for that coin + period_type.
-- 2026-10-07: deliberately NOT filtered on stock.is_stablecoin. This is not a
-- buy decision -- it only records an order that is already LIVE on Coinbase;
-- skipping a stablecoin here would leave a real resting order untracked (a
-- ghost order in vw_position_order_balance_audit).
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

-- Orphan sell recovery: re-link any Coinbase SELL order to a position that lost its sell_coinbase_order_id.
-- Uses DISTINCT ON (o.order_id) so each Coinbase order is only matched to one position row.
-- Orphan sell recovery also matches limit_limit_gtc: processSellOrders places
-- plain GTC limit sells (fee-floor take-profits) while underwater, which are
-- not stop_limit_stop_limit_gtc. Size still comes from whichever config is present.
WITH orphan_match AS (
    SELECT DISTINCT ON (o.order_id) p.buy_order_id AS pos_key, o.order_id
    FROM position p
    JOIN bulk_open_orders o ON o.side = 'SELL'
        AND o.product_id = p.name
        AND ABS(
            COALESCE(
                (o.order_configuration->'stop_limit_stop_limit_gtc'->>'base_size')::numeric,
                (o.order_configuration->'limit_limit_gtc'->>'base_size')::numeric
            ) - p.shares::numeric
        ) < 0.0001
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

-- 2026-09-25: expire stale planned buys. A planned row that never got a
-- Coinbase order (buy_coinbase_order_id NULL, never filled) sits in
-- processBuyOrders' queue forever, failing INSUFFICIENT_FUND every cycle
-- (USDS-USD had been planned since 8/13) and -- via the cash-backlog gate
-- below -- blocking new picks. Delete it once its last activity (created,
-- remade, placed, or released) is older than config.pending_buy_ttl_hours
-- (default 24). The signal logic simply re-picks the coin later if it's
-- still attractive. Never touches a row with a live Coinbase order: the
-- NULL buy_coinbase_order_id check plus a match on client_order_id in the
-- current open-orders snapshot (covers an order whose id was nulled while
-- still live). The position_audit trigger logs each DELETE.
DELETE FROM position p
WHERE p.buy_coinbase_order_id IS NULL
AND p.buy_filled_price IS NULL
AND p.sell_coinbase_order_id IS NULL
-- 2026-10-07: listing rows are exempt from every generic pending-row rule;
-- their unsent rows are handled by the listing block below (dropped and
-- re-planned each minute only while the snipe window is open).
AND p.period_type IS DISTINCT FROM 'listing'
AND GREATEST(p.date_created, p.last_remade_at, p.buy_placed_at, p.buy_released_at)
    < NOW() - make_interval(hours => COALESCE((SELECT value::int FROM config WHERE key = 'pending_buy_ttl_hours'), 24))
AND NOT EXISTS (
    SELECT 1 FROM bulk_open_orders o WHERE o.client_order_id = p.buy_order_id
);

-- ===========================================================================
-- 2026-10-05 PLANNED-ROW CLEAN-UP (one rule set, owned by this procedure)
-- ===========================================================================
-- Rule: a planned buy row (no Coinbase order yet) may only exist if index.js
-- processBuyOrders() would send it THIS minute. Before this change index.js
-- had its own placement filters (order-book gates, price-vs-trigger wait,
-- per-row cash check, trading_disabled, 30-min release cooldown), so rows
-- sat in position for hours doing nothing while still counting against the
-- cash-backlog gate below and blocking new picks (ABT / LSETH wide spread;
-- PNG / DOGE / VVV / GFI / QI waiting for price to drop under the 99% add-on
-- cap). Those filters now live here, on both INSERTs below (never create
-- such a row) and in these DELETEs (drop an existing row the moment it stops
-- qualifying). index.js keeps only reactions to Coinbase itself (rejection ->
-- error_message -> retry next minute, 'Invalid product_id', the live
-- "<= $1 available" guard). A deleted coin is simply re-picked later by the
-- INSERTs once it qualifies again. Runs before the INSERTs so freed backlog
-- cash is usable this same cycle.
--
-- Safety guards on every DELETE here (same as the TTL delete above): never
-- filled, no Coinbase order id, no sell side, and no live order under its
-- client_order_id in this run's bulk_open_orders. Live orders are never
-- touched. The position_audit trigger logs each DELETE (note: the audit
-- prune near the end of this procedure removes audit rows of deleted
-- positions, so the log is visible only within this transaction).
--
-- Reasons (any one deletes the row):
--  (a) pause_buys is not 'false' -- same test the INSERTs use. Chosen over a
--      pause check in index.js: with an index.js check, rows would sit
--      unsent for the whole pause (exactly what this rule forbids) and pause
--      logic would live in two places. Live orders are left alone.
--  (b) coin is trading_disabled (delisted / vanished from the catalog;
--      flagged earlier in this procedure). Was an index.js filter.
--  (c) row was released by index.js processFarBuyCashRelease() (its live
--      order was cancelled to free cash for something better). Used to sit
--      in a 30-min index.js cooldown; now dropped, the coin is re-picked
--      later if still attractive.
--  (d) below Coinbase minimum order size: shares < stock.min_shares
--      (base_min_size) or shares * buy_price < stock.min_price
--      (quote_min_size). Coinbase rejects these forever.
--  (e) trigger no longer above price on a coin already held: the add-on cap
--      below (add_buy_cap_ratio, default 0.99 x cheapest open bag) pins the
--      trigger, so once price is at/above that cap the stop-buy cannot be
--      placed (Coinbase needs the stop above market). Uncapped rows are not
--      deleted here: the "refresh stale buy candidates" UPDATE further down
--      re-prices them above market, and a safety DELETE after the cap
--      catches anything still at/below price.
--  (f) spread wider than config book_max_spread_pct (default 0.75%), from
--      bulk_best_bid_ask (loaded by index.js processBestBidAsk() just
--      before this procedure). Only judged when that table is fresh (loaded
--      within 3 minutes); then a coin missing from it or with a one-sided
--      quote (spread_pct NULL) counts as failing. Stale/empty = fail open.
--  (g) latest book_snapshot from the last 3 minutes is ask-heavy
--      (imbalance < book_skip_imbalance, default -0.4) or thin (ask
--      notional within 0.5% of mid < book_min_ask_notional_mult, default 5,
--      x the row's own dollar size). No fresh snapshot = allow. index.js
--      processBookSnapshots() now runs before this procedure and always
--      snapshots coins with a planned buy.
--  (h) 2026-10-07: coin is flagged stock.is_stablecoin (see the STABLECOIN
--      FLAG update near the top). Stablecoins are never bought, so an
--      unplaced planned row on one is dropped (placed / live orders are
--      never touched, same guards as every reason here).
DELETE FROM position p
USING stock s
WHERE s.stock_id = p.stock_id
AND p.buy_coinbase_order_id IS NULL
AND p.buy_filled_price IS NULL
AND p.sell_coinbase_order_id IS NULL
AND NOT EXISTS (
    SELECT 1 FROM bulk_open_orders o WHERE o.client_order_id = p.buy_order_id
)
-- 2026-10-07: listing rows exempt (own rules in the listing block below;
-- a new pair's launch book is often wider than book_max_spread_pct).
AND p.period_type IS DISTINCT FROM 'listing'
AND (
    -- (a) buys paused
    (SELECT value FROM config WHERE key = 'pause_buys') IS DISTINCT FROM 'false'
    -- (b) delisted / trading disabled
    OR s.trading_disabled IS TRUE
    -- (h) stablecoin (stock.is_stablecoin) -- never bought
    OR s.is_stablecoin IS TRUE
    -- (c) released by far-buy cash release
    OR p.buy_released_at IS NOT NULL
    -- (d) below Coinbase minimum order size
    OR p.shares IS NULL
    OR p.shares <= 0
    OR p.shares < COALESCE(s.min_shares, 0)
    OR (p.shares * p.buy_price) < COALESCE(s.min_price, 0)
    -- (e) held coin: price at/above the capped trigger
    OR s.price::numeric >= (
        SELECT TRUNC(MIN(f.buy_filled_price)::numeric
                     * COALESCE((SELECT value::numeric FROM config WHERE key = 'add_buy_cap_ratio'), 0.99),
                     s.price_rounding::integer)
        FROM position f
        WHERE f.stock_id = p.stock_id
        AND f.buy_filled_price IS NOT NULL
        AND f.sell_filled_price IS NULL
    )
    -- (f) wide spread (only with fresh best-bid/ask data)
    OR (
        EXISTS (SELECT 1 FROM bulk_best_bid_ask WHERE loaded_at > NOW() - INTERVAL '3 minutes')
        AND COALESCE(
                (SELECT bba.spread_pct FROM bulk_best_bid_ask bba WHERE bba.product_id = s.name),
                'Infinity'::double precision
            ) > COALESCE((SELECT value::double precision FROM config WHERE key = 'book_max_spread_pct'), 0.75)
    )
    -- (g) ask-heavy or thin book (fresh snapshot only)
    OR EXISTS (
        SELECT 1
        FROM (
            SELECT bs.imbalance, bs.near_ask_usd
            FROM book_snapshot bs
            WHERE bs.name = s.name
            AND bs.date_created > NOW() - INTERVAL '3 minutes'
            ORDER BY bs.date_created DESC
            LIMIT 1
        ) fresh_book
        WHERE fresh_book.imbalance < COALESCE((SELECT value::double precision FROM config WHERE key = 'book_skip_imbalance'), -0.4)
        OR fresh_book.near_ask_usd < (p.shares * p.buy_price)
            * COALESCE((SELECT value::double precision FROM config WHERE key = 'book_min_ask_notional_mult'), 5)
    )
);

-- 2026-10-05 affordability clean-up (was the per-row cashLeft check in
-- index.js processBuyOrders, which skipped -- but kept -- rows free cash
-- could not cover, so they sat and were retried every minute). Walk the
-- surviving planned rows in the same order processBuyOrders sends them
-- (stock.priority DESC, then position_id) with a running cash balance:
-- free USD (vw_balance.available, i.e. after holds of live orders) minus
-- this run's ETF reserve (vw_etf_cash_reserve). A row whose cost incl. the
-- ~1.2% taker-fee pad (shares * buy_price * 1.012, same pad index.js used)
-- fits is kept and its cost is taken off the balance; a row that does not
-- fit is deleted and the walk continues (greedy, exactly like the old
-- cashLeft loop). Same safety guards as above. Fail-open: when there is no
-- USD row in vw_balance (balance fetch failed this run) cash_left is NULL,
-- every comparison is NULL and nothing is deleted.
WITH RECURSIVE cand AS (
    SELECT p.position_id,
           (p.shares * p.buy_price)::numeric * 1.012 AS cost,
           ROW_NUMBER() OVER (ORDER BY s.priority DESC NULLS LAST, p.position_id) AS rn
    FROM position p
    JOIN stock s ON s.stock_id = p.stock_id
    WHERE p.buy_coinbase_order_id IS NULL
    AND p.buy_filled_price IS NULL
    AND p.sell_coinbase_order_id IS NULL
    AND NOT EXISTS (
        SELECT 1 FROM bulk_open_orders o WHERE o.client_order_id = p.buy_order_id
    )
    -- 2026-10-07: listing rows exempt (own cash gate in the listing INSERT).
    AND p.period_type IS DISTINCT FROM 'listing'
),
walk AS (
    SELECT 0::bigint AS rn,
           (SELECT available::numeric FROM vw_balance WHERE name = 'USD')
             - COALESCE((SELECT reserve_usd FROM vw_etf_cash_reserve), 0)
             -- 2026-10-07: profit queued for the USDC sweep is not spendable.
             - COALESCE((SELECT reserve_usd FROM vw_usdc_sweep_reserve), 0) AS cash_left,
           NULL::bigint AS position_id,
           FALSE AS drop_row
    UNION ALL
    SELECT c.rn,
           CASE WHEN c.cost <= w.cash_left THEN w.cash_left - c.cost ELSE w.cash_left END,
           c.position_id,
           c.cost > w.cash_left
    FROM walk w
    JOIN cand c ON c.rn = w.rn + 1
)
DELETE FROM position p
USING walk w
WHERE p.position_id = w.position_id
AND w.drop_row IS TRUE;

-- ===========================================================================
-- 2026-10-07 NEW-LISTING SNIPE (replaces the 2026-10-06 new_at version)
-- ===========================================================================
-- Theodore: the snipe window starts when trading ACTUALLY opens, not at
-- Coinbase products.new_at, and lasts config.listing_window_minutes
-- (default 5; "5 minutes, 15 at most" -- change that one config value).
-- Why: a 50-listing study showed trading typically opens ~18h after new_at
-- (only 2/50 traded within 60 min of it), every product carries a non-empty
-- new_at anyway, and the move is front-loaded (minute-1 buys hit +3% within
-- an hour 80% of the time vs 48% at minute 60). The old
-- "new_at within 60 minutes" gate is gone; new_at is now only a candidate
-- filter inside modules/listingWatch.js.
--
-- Window start = listing_watch.trading_open_at, written by index.js
-- (modules/listingWatch.js) BEFORE this procedure each minute: the EARLIER
-- of the pair's first completed trade (Exchange trade_id 1, or first 1-min
-- candle with volume) and the first time the bot saw the launch
-- restrictions cleared. A product first watched after it had already
-- traded gets its real (old) first-trade time, so stale listings never
-- qualify.
--
-- The buy (index.js processBuyOrders sends it as a PLAIN LIMIT, GTC, no
-- stop, no expiry; it rests until it fills or Theodore cancels it):
--   * limit (buy_price) = first trade price * (1 + listing_limit_cushion_pct
--     / 100, default 0.5%), rounded UP to the product's price increment
--     (price_increment, falling back to quote_increment) so the cushion is
--     never lost to rounding.
--   * shares = listing_buy_usd ($1) / limit, rounded UP to base_increment
--     (and at least base_min_size) so the order is >= $1 and clears
--     Coinbase's quote_min_size (usually $1) -- rounding down would land
--     just under $1 and be rejected.
--   * buy_stop_price = NULL: no stop trigger. NULL also keeps the row out of
--     every stop-based path (stale-candidate refresh, add-on cap, safety-net
--     delete, vw_edit_orders remakes, far-buy cash release); each of those
--     also exempts period_type 'listing' explicitly.
--   * Selling: the normal sell code once it fills -- no custom take-profit.

-- Unsent listing row from a previous minute (Coinbase rejected it, e.g.
-- still in auction / cancel-only, or cash was short): drop it so the INSERT
-- below re-plans it with fresh gates -- only while the window is still open.
-- After the window it is simply not re-planned, so nothing sits and blocks
-- the one-listing slot or the ETF gate. Never touches a placed order (same
-- guards as the generic clean-up: no Coinbase order id, not filled, no sell,
-- no live order under its client_order_id).
DELETE FROM position p
WHERE p.period_type = 'listing'
AND p.buy_coinbase_order_id IS NULL
AND p.buy_filled_price IS NULL
AND p.sell_coinbase_order_id IS NULL
AND NOT EXISTS (
    SELECT 1 FROM bulk_open_orders o WHERE o.client_order_id = p.buy_order_id
);

INSERT INTO position (stock_id, name, buy_price, buy_stop_price, shares, date_created, buy_order_id, period_type)
SELECT
    s.stock_id,
    s.name,
    px.limit_price          AS buy_price,       -- plain limit price (no stop)
    NULL                    AS buy_stop_price,  -- no stop trigger at all
    sz.shares               AS shares,          -- ~$1 at the limit price
    NOW()                   AS date_created,
    gen_random_uuid(),
    'listing'
FROM stock s
JOIN bulk_stock bs     ON bs.id = s.name
-- Only products the watcher has a real trading-open time for.
JOIN listing_watch lw  ON lw.product_id = s.name
CROSS JOIN vw_balance b
-- The three tunables (config keys; defaults if a key is missing):
--   listing_window_minutes    = 5    window length after trading_open_at
--   listing_buy_usd           = 1.00 dollars per snipe
--   listing_limit_cushion_pct = 0.5  limit = first trade price + 0.5%
CROSS JOIN LATERAL (
    SELECT COALESCE((SELECT value::numeric FROM config WHERE key = 'listing_window_minutes'), 5)      AS window_minutes,
           COALESCE((SELECT value::numeric FROM config WHERE key = 'listing_buy_usd'), 1.00)         AS buy_usd,
           COALESCE((SELECT value::numeric FROM config WHERE key = 'listing_limit_cushion_pct'), 0.5) AS cushion_pct
) cfg
-- Product increments straight from Coinbase's products payload.
CROSS JOIN LATERAL (
    SELECT NULLIF(COALESCE(NULLIF(bs.json->>'price_increment', ''), NULLIF(bs.json->>'quote_increment', ''))::numeric, 0) AS tick,
           NULLIF(NULLIF(bs.json->>'base_increment', '')::numeric, 0)                                                      AS lot,
           COALESCE(NULLIF(bs.json->>'base_min_size', '')::numeric, 0)                                                     AS base_min,
           COALESCE(NULLIF(bs.json->>'quote_min_size', '')::numeric, 0)                                                    AS quote_min
) inc
-- Limit = first trade price + cushion, rounded UP to the price tick.
CROSS JOIN LATERAL (
    SELECT CEIL(lw.first_trade_price * (1 + cfg.cushion_pct / 100) / inc.tick) * inc.tick AS limit_price
) px
-- Size = $buy_usd at the limit, rounded UP to the base increment, >= base_min_size.
CROSS JOIN LATERAL (
    SELECT GREATEST(CEIL(cfg.buy_usd / px.limit_price / inc.lot) * inc.lot, inc.base_min) AS shares
) sz
-- PRIMARY duplicate guard (Theodore): a coin that already has ANY position
-- row (any period_type, pending or filled) never gets a listing row -- so
-- the snipe can never create a second row for a new coin. LEFT JOIN ... IS
-- NULL against ONE row per coin (pre-aggregated by stock_id), so the join
-- can never multiply candidate rows.
LEFT JOIN (
    SELECT stock_id, MIN(position_id) AS position_id
    FROM position
    GROUP BY stock_id
) p ON p.stock_id = s.stock_id
-- One snipe per coin EVER: a coin whose listing snipe already closed (row
-- moved to profit_history and deleted from position) is skipped too. Same
-- LEFT JOIN ... IS NULL shape, also one row per coin.
LEFT JOIN (
    SELECT stock_id, MIN(profit_history_id) AS profit_history_id
    FROM profit_history
    WHERE period_type = 'listing'
    GROUP BY stock_id
) ph ON ph.stock_id = s.stock_id
WHERE b.name = 'USD'
AND (SELECT value FROM config WHERE key = 'pause_buys') = 'false'
AND s.name LIKE '%-USD'
-- Duplicate guards (see the two LEFT JOINs above) -- the PRIMARY guard.
-- DB backstop: partial unique index position_one_listing_per_stock
-- (position(stock_id) WHERE period_type = 'listing'). No ON CONFLICT here on
-- purpose (Theodore): if the backstop ever trips, the unique violation
-- aborts this procedure call for that minute instead of hiding the bug.
AND p.position_id IS NULL
AND ph.profit_history_id IS NULL
-- THE WINDOW: trading opened at most listing_window_minutes ago.
AND lw.trading_open_at IS NOT NULL
AND lw.trading_open_at <= NOW()
AND NOW() - lw.trading_open_at <= cfg.window_minutes * INTERVAL '1 minute'
-- The limit is priced off the first trade, so wait (inside the window)
-- until one exists if the window was opened by "restrictions cleared".
AND lw.first_trade_price > 0
-- Tradable now. limit_only is ALLOWED on purpose: the first minutes after
-- the first trade are normally Coinbase's launch limit-only phase, and a
-- plain limit order is accepted there. Not during the auction, cancel-only
-- or post-only (a taker limit would be rejected).
AND s.trading_disabled IS NOT TRUE
-- 2026-10-07: never snipe a stablecoin (stock.is_stablecoin, price-behavior
-- flag set near the top of this procedure).
AND s.is_stablecoin IS NOT TRUE
AND COALESCE(bs.trading_disabled, bs.json->>'trading_disabled', 'false') NOT IN ('true', 't', '1')
AND COALESCE(bs.status, bs.json->>'status', '') = 'online'
AND COALESCE(bs.json->>'product_type', 'SPOT') = 'SPOT'
AND COALESCE(bs.json->>'is_disabled', 'false') NOT IN ('true', 't', '1')
AND COALESCE(bs.auction_mode, bs.json->>'auction_mode', 'false') NOT IN ('true', 't', '1')
AND COALESCE(bs.cancel_only, bs.json->>'cancel_only', 'false') NOT IN ('true', 't', '1')
AND COALESCE(bs.post_only, bs.json->>'post_only', 'false') NOT IN ('true', 't', '1')
-- One-coin mutex (unchanged): no other listing bag open -- a resting
-- unfilled listing order or a filled-unsold listing bag both count.
AND NOT EXISTS (
    SELECT 1 FROM position lp
    WHERE lp.period_type = 'listing'
    AND lp.sell_filled_price IS NULL
)
-- Order sanity / Coinbase minimums.
AND inc.tick IS NOT NULL
AND inc.lot IS NOT NULL
AND px.limit_price > 0
AND sz.shares > 0
AND sz.shares * px.limit_price >= inc.quote_min
-- Keep it ~$buy_usd: skip a coin whose base increment / minimum would force
-- a much bigger order (> 1.25x listing_buy_usd).
AND sz.shares * px.limit_price <= cfg.buy_usd * 1.25
-- Cash: free USD must cover the order incl. the ~1.2% taker-fee pad (same
-- pad the other buy gates use). Listing is priority one, so the ETF reserve
-- is not subtracted (index.js skips ETF orders while a listing bag is open).
-- 2026-10-07: minus realized profit queued for the USDC sweep
-- (vw_usdc_sweep_reserve), so the snipe cannot spend it either.
AND b.available::numeric
    - COALESCE((SELECT reserve_usd FROM vw_usdc_sweep_reserve), 0)
    >= sz.shares * px.limit_price * 1.012
ORDER BY lw.trading_open_at DESC
LIMIT 1;

-- New position: $1 into the highest year-basis-priority coin not already
-- held, gated only on the coin's year-basis trend being positive -- no
-- day-timing signal (recommendation / current-vs-average dip) and no
-- priority floor, since the goal is broad $1 exposure across every coin
-- trending up over the year, ranked by priority, not picking entries by
-- short-term dip timing.
-- Always recorded as period_type 'day' (the existing $1-size bucket), even
-- though the signal driving the pick is the year row. One new position per
-- cycle.
-- Clip size: $1 for a brand-new day position on this coin; if this INSERT
-- is instead an add while open day rows already exist (price below the
-- lowest filled buy), use $N where N = open_count + 1 (2nd order $2, 3rd
-- $3, ...). Open = any buy still live (sell not filled). available must
-- cover that clip, not a hard-coded $1.
INSERT INTO position (stock_id, name, buy_price, buy_stop_price, shares, date_created, buy_order_id, period_type)
SELECT s.stock_id, s.name,
    -- 2026-10-05: price / trigger / size now come from the "plan" lateral
    -- below (same formulas as before, computed once) so the new gates can
    -- check the exact order this INSERT will create.
    plan.buy_price,
    plan.buy_stop_price,
    plan.shares,
    NOW() AS date_created,
    gen_random_uuid(),
    'day'
FROM vw_signal s
JOIN stock ON s.stock_id = stock.stock_id
CROSS JOIN vw_balance b
CROSS JOIN LATERAL (
    -- Cash-scaled new-buy stop gap: base 2%, stretched by total program
    -- equity / available USD (same components as the equity calc: filled
    -- bags at stock.price, USD available, USD hold in open buys, priced
    -- untracked dust). stop_mult = 1 + 0.02 * (equity / available).
    -- Falls back to 1.02 when available USD is 0/NULL.
    SELECT COALESCE(
        1 + 0.02 * (
            (
                COALESCE((
                    SELECT SUM(p2.shares::numeric * s2.price::numeric)
                    FROM position p2
                    JOIN stock s2 ON s2.stock_id = p2.stock_id
                    WHERE p2.buy_filled_price IS NOT NULL
                    AND p2.sell_filled_price IS NULL
                ), 0)
                + COALESCE((SELECT available::numeric FROM vw_balance WHERE name = 'USD'), 0)
                + COALESCE((SELECT hold::numeric FROM vw_balance WHERE name = 'USD'), 0)
                + COALESCE((
                    SELECT SUM(
                        CASE
                            WHEN a.currency IN ('USDS', 'USD1', 'PAX') THEN a.balance::numeric
                            WHEN st.price IS NOT NULL THEN a.balance::numeric * st.price::numeric
                            ELSE 0
                        END
                    )
                    FROM vw_position_order_balance_audit a
                    LEFT JOIN stock st ON st.name = a.name
                    WHERE a.issue_type = 'untracked_holding'
                ), 0)
            ) / NULLIF((SELECT available::numeric FROM vw_balance WHERE name = 'USD'), 0)
        ),
        1.02
    ) AS stop_mult
) gap
LEFT JOIN position p ON p.stock_id = s.stock_id
    AND p.period_type = 'day'
    AND p.buy_order_id IS NOT NULL
    AND p.buy_filled_price IS NULL
-- 2026-10-05 book gates (moved here from index.js processBuyOrders(); see
-- the clean-up delete near the top for the full rationale and fail-open
-- rules). Latest L2 snapshot from the last 3 minutes only -- before this,
-- any age was used, and coins past the old 40-coin alphabetical snapshot
-- cap were judged on hours-old books. NULL = no fresh snapshot = allow.
LEFT JOIN LATERAL (
    SELECT bs.imbalance, bs.near_ask_usd
    FROM book_snapshot bs
    WHERE bs.name = s.name
    AND bs.date_created > NOW() - INTERVAL '3 minutes'
    ORDER BY bs.date_created DESC
    LIMIT 1
) book ON TRUE
-- This run's top-of-book for the coin (spread gate).
LEFT JOIN bulk_best_bid_ask bba ON bba.product_id = s.name
-- Thresholds from config (defaults = the old index.js constants) and
-- whether bulk_best_bid_ask is fresh enough to judge spread at all.
CROSS JOIN LATERAL (
    SELECT
        COALESCE((SELECT value::numeric FROM config WHERE key = 'book_max_spread_pct'), 0.75)       AS max_spread_pct,
        COALESCE((SELECT value::numeric FROM config WHERE key = 'book_skip_imbalance'), -0.4)        AS skip_imbalance,
        COALESCE((SELECT value::numeric FROM config WHERE key = 'book_min_ask_notional_mult'), 5)    AS min_ask_mult,
        EXISTS (SELECT 1 FROM bulk_best_bid_ask WHERE loaded_at > NOW() - INTERVAL '3 minutes')     AS bba_fresh
) bookcfg
-- Dollar size of this clip ($1 new, $N for the Nth open day row), the same
-- count + 1 the shares / cash-backlog expressions use; the thin-ask gate
-- compares near-ask notional to clip_usd * book_min_ask_notional_mult.
CROSS JOIN LATERAL (
    SELECT COUNT(*)::numeric + 1 AS clip_usd
    FROM position open_sz
    WHERE open_sz.stock_id = s.stock_id
    AND open_sz.period_type = 'day'
    AND open_sz.buy_order_id IS NOT NULL
    AND open_sz.sell_filled_price IS NULL
) clip
-- 2026-10-05 the order this INSERT will create (formulas unchanged from the
-- old inline SELECT list): trigger = signal close * cash-scaled stop gap,
-- limit 1% above, shares = clip dollars / close.
CROSS JOIN LATERAL (
    SELECT
        TRUNC((s.close::numeric * gap.stop_mult * 1.01), stock.price_rounding::integer) AS buy_price,
        TRUNC((s.close::numeric * gap.stop_mult),        stock.price_rounding::integer) AS buy_stop_price,
        TRUNC(clip.clip_usd / s.close::numeric, stock.share_rounding::integer)          AS shares
) plan
-- 2026-10-05 add-on cap preview: the "add-on buy cap" UPDATE near the end
-- of this procedure pins an unsent buy on a coin already held to
-- add_buy_cap_ratio (default 0.99) x the cheapest open bag (limit 1% above).
-- Computed here so the gates judge the trigger/limit the row will really
-- have. NULLs when the coin has no open filled bag (no cap applies).
CROSS JOIN LATERAL (
    SELECT
        TRUNC(MIN(f.buy_filled_price)::numeric
              * COALESCE((SELECT value::numeric FROM config WHERE key = 'add_buy_cap_ratio'), 0.99),
              stock.price_rounding::integer) AS cap_stop,
        TRUNC(MIN(f.buy_filled_price)::numeric
              * COALESCE((SELECT value::numeric FROM config WHERE key = 'add_buy_cap_ratio'), 0.99) * 1.01,
              stock.price_rounding::integer) AS cap_limit
    FROM position f
    WHERE f.stock_id = s.stock_id
    AND f.buy_filled_price IS NOT NULL
    AND f.sell_filled_price IS NULL
) addcap
-- Effective limit price after the cap (LEAST ignores the NULL cap) and the
-- dollar cost of the order, plain and with the ~1.2% taker-fee pad (1.012,
-- the same pad index.js used for its old per-row cash check).
CROSS JOIN LATERAL (
    SELECT
        plan.shares * LEAST(plan.buy_price, addcap.cap_limit)         AS cost_usd,
        plan.shares * LEAST(plan.buy_price, addcap.cap_limit) * 1.012 AS cost_with_fee
) eff
-- Day row of vw_signal: today's close-vs-yesterday % vs this coin's
-- average historical day-over-day %. Keeps the year-basis priority pick
-- (s.period_type = 'year') but blocks chase entries on hot days (e.g.
-- MSOL up hard today while year signal still says BUY).
JOIN vw_signal d
  ON d.stock_id = s.stock_id
 AND d.period_type = 'day'
WHERE b.name = 'USD'
AND (SELECT value FROM config WHERE key = 'pause_buys') = 'false'
-- 2026-09-25 cash-backlog gate: free USD minus what is already promised to
-- planned buys that have no live order yet. Previously only free USD was
-- compared to the clip, so every brief cash bump (e.g. a far-buy release)
-- inserted another planned row that then failed INSUFFICIENT_FUND forever.
-- 2026-10-04: index.js writes config.etf_usd_reserve before this procedure
-- and vw_etf_cash_reserve exposes it. Subtract that from free USD so a new
-- crypto plan cannot spend dollars this run's ETF attempts still need.
-- The reserve is only those attempts (open NORMAL session, dip rules
-- passed, not already filled, and not skipped for lack of cash). A closed
-- session stores 0. ETF orders are placed after this procedure, same minute.
-- pause_buys still gates only these crypto inserts, not the ETF buys.
AND b.available
    - COALESCE((SELECT reserve_usd FROM vw_etf_cash_reserve), 0)
    -- 2026-10-07: realized profit queued for the USDC sweep is reserved too.
    - COALESCE((SELECT reserve_usd FROM vw_usdc_sweep_reserve), 0)
    - COALESCE((SELECT SUM(pb.shares * pb.buy_price * 1.012)::numeric  -- 2026-10-05: + fee pad
                FROM position pb JOIN stock sb ON sb.stock_id = pb.stock_id
                WHERE pb.buy_coinbase_order_id IS NULL
                AND pb.buy_filled_price IS NULL
                AND sb.trading_disabled IS NOT TRUE), 0)
-- 2026-10-05 (#2): compare against the real cost of THIS order incl. the
-- fee pad (was: the clip dollars, ~20% less than the order actually holds,
-- so rows were inserted that free cash could not cover and they sat).
  >= eff.cost_with_fee
AND s.period_type = 'year'
AND p.buy_order_id IS NULL
AND s.historical_avg_change_percent > 0
AND d.current_change_percent < d.historical_avg_change_percent
AND stock.trading_disabled IS NOT TRUE
-- 2026-10-07: never open a position in a stablecoin (stock.is_stablecoin,
-- price-behavior flag set near the top of this procedure). stock., not s.:
-- s is vw_signal in this INSERT.
AND stock.is_stablecoin IS NOT TRUE
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
-- Book gates (2026-10-05, were index.js placement-time checks):
--   spread:    only judged when bulk_best_bid_ask is fresh; then a missing
--              coin / one-sided quote (spread_pct NULL) fails the <= test.
--   imbalance: fresh snapshot not ask-heavy (>= threshold; was > -0.4 here
--              and >= -0.4 in index.js -- now one rule). NULL = allow.
--   thin ask:  near-ask notional >= order cost (eff.cost_usd, i.e. shares x
--              limit, same notional index.js used) * multiple. NULL = allow.
-- Prefer bid-heavy (+0.2) via ORDER BY below is unchanged.
AND (NOT bookcfg.bba_fresh OR bba.spread_pct <= bookcfg.max_spread_pct)
AND (book.imbalance IS NULL OR book.imbalance >= bookcfg.skip_imbalance)
AND (book.near_ask_usd IS NULL OR book.near_ask_usd >= eff.cost_usd * bookcfg.min_ask_mult)
-- 2026-10-05 (#3) trigger must already be above price: on a coin already
-- held the cap pins the trigger at addcap.cap_stop, so only create the row
-- when price is under it (was: inserted anyway, then index.js waited for
-- price to fall -- the PNG/DOGE/VVV/GFI/QI rows). No cap = no limit here
-- (the refresh UPDATE keeps uncapped triggers above market).
AND stock.price::numeric < COALESCE(addcap.cap_stop, 'Infinity'::numeric)  -- stock.price: s is vw_signal here
-- 2026-10-05 (#11) Coinbase minimum order size: base size >= base_min_size
-- (stock.min_shares) and quote size (shares x effective limit) >=
-- quote_min_size (stock.min_price). NULL minimum = no limit.
AND plan.shares > 0
AND plan.shares >= COALESCE(stock.min_shares, 0)
AND eff.cost_usd >= COALESCE(stock.min_price, 0)
ORDER BY
    CASE WHEN book.imbalance IS NOT NULL AND book.imbalance > 0.2 THEN 0 ELSE 1 END,
    book.imbalance DESC NULLS LAST,
    s.priority DESC NULLS LAST
LIMIT 1;

-- Buy again if current price has dropped below the MOST RECENT
-- already-filled price for a stock+period (not the lowest ever --
-- anchored on whichever fill actually happened last, so this can
-- re-trigger even after a good fill if price has since moved against
-- the latest one). Anchored on position itself, not vw_signal — purely
-- "average down further," no recommendation conditions involved.
-- Clip size scales with depth: $N for the Nth open buy on that
-- stock+period (1 open filled → next is $2; 2 open → next is $3). Open
-- means buy_order_id set and sell not filled. available must exceed that
-- clip. Only triggers off a coin whose buy is actually filled, and only if
-- there's no other buy order currently open/pending for that same
-- stock+period. When multiple held coins qualify in the same cycle,
-- ranked by stock.priority descending (same year-basis priority marker the
-- new-position buy uses) so the highest-priority coin gets the
-- average-down clip first. One new position per cycle.
WITH held AS (
    SELECT DISTINCT ON (stock_id, period_type)
        stock_id, period_type, buy_filled_price AS last_filled_price
    FROM position
    WHERE buy_filled_price IS NOT NULL
    ORDER BY stock_id, period_type, buy_filled_date DESC
),
sized AS (
    SELECT
        h.*,
        (
            SELECT COUNT(*)::numeric
            FROM position op
            WHERE op.stock_id = h.stock_id
            AND op.period_type = h.period_type
            AND op.buy_order_id IS NOT NULL
            AND op.sell_filled_price IS NULL
        ) + 1 AS clip_usd
    FROM held h
)
INSERT INTO position (stock_id, name, buy_price, buy_stop_price, shares, date_created, buy_order_id, period_type)
SELECT
    s.stock_id,
    s.name,
    -- 2026-10-05: from the "plan" lateral below (formulas unchanged).
    plan.buy_price,
    plan.buy_stop_price,
    plan.shares,
    NOW() AS date_created,
    gen_random_uuid(),
    sized.period_type
FROM sized
JOIN stock s ON s.stock_id = sized.stock_id
CROSS JOIN vw_balance b
-- 2026-10-05 book gates (moved here from index.js processBuyOrders(); see
-- the clean-up delete near the top for the full rationale and fail-open
-- rules). Latest L2 snapshot from the last 3 minutes only -- before this,
-- any age was used, and coins past the old 40-coin alphabetical snapshot
-- cap were judged on hours-old books. NULL = no fresh snapshot = allow.
LEFT JOIN LATERAL (
    SELECT bs.imbalance, bs.near_ask_usd
    FROM book_snapshot bs
    WHERE bs.name = s.name
    AND bs.date_created > NOW() - INTERVAL '3 minutes'
    ORDER BY bs.date_created DESC
    LIMIT 1
) book ON TRUE
-- This run's top-of-book for the coin (spread gate).
LEFT JOIN bulk_best_bid_ask bba ON bba.product_id = s.name
-- Thresholds from config (defaults = the old index.js constants) and
-- whether bulk_best_bid_ask is fresh enough to judge spread at all.
CROSS JOIN LATERAL (
    SELECT
        COALESCE((SELECT value::numeric FROM config WHERE key = 'book_max_spread_pct'), 0.75)       AS max_spread_pct,
        COALESCE((SELECT value::numeric FROM config WHERE key = 'book_skip_imbalance'), -0.4)        AS skip_imbalance,
        COALESCE((SELECT value::numeric FROM config WHERE key = 'book_min_ask_notional_mult'), 5)    AS min_ask_mult,
        EXISTS (SELECT 1 FROM bulk_best_bid_ask WHERE loaded_at > NOW() - INTERVAL '3 minutes')     AS bba_fresh
) bookcfg
-- 2026-10-05 the order this INSERT will create (formulas unchanged from the
-- old inline SELECT list): trigger 1% above current price, limit 1.1%
-- above, shares = clip dollars / price.
CROSS JOIN LATERAL (
    SELECT
        TRUNC(s.price::numeric * 1.011, s.price_rounding::integer)               AS buy_price,
        TRUNC(s.price::numeric * 1.01,  s.price_rounding::integer)               AS buy_stop_price,
        TRUNC((sized.clip_usd / s.price::numeric), s.share_rounding::integer)    AS shares
) plan
-- 2026-10-05 add-on cap preview: the "add-on buy cap" UPDATE near the end
-- of this procedure pins an unsent buy on a coin already held to
-- add_buy_cap_ratio (default 0.99) x the cheapest open bag (limit 1% above).
-- Computed here so the gates judge the trigger/limit the row will really
-- have. NULLs when the coin has no open filled bag (no cap applies).
CROSS JOIN LATERAL (
    SELECT
        TRUNC(MIN(f.buy_filled_price)::numeric
              * COALESCE((SELECT value::numeric FROM config WHERE key = 'add_buy_cap_ratio'), 0.99),
              s.price_rounding::integer) AS cap_stop,
        TRUNC(MIN(f.buy_filled_price)::numeric
              * COALESCE((SELECT value::numeric FROM config WHERE key = 'add_buy_cap_ratio'), 0.99) * 1.01,
              s.price_rounding::integer) AS cap_limit
    FROM position f
    WHERE f.stock_id = s.stock_id
    AND f.buy_filled_price IS NOT NULL
    AND f.sell_filled_price IS NULL
) addcap
-- Effective limit price after the cap (LEAST ignores the NULL cap) and the
-- dollar cost of the order, plain and with the ~1.2% taker-fee pad (1.012,
-- the same pad index.js used for its old per-row cash check).
CROSS JOIN LATERAL (
    SELECT
        plan.shares * LEAST(plan.buy_price, addcap.cap_limit)         AS cost_usd,
        plan.shares * LEAST(plan.buy_price, addcap.cap_limit) * 1.012 AS cost_with_fee
) eff
WHERE b.name = 'USD'
-- 2026-09-25 cash-backlog gate (same as the new-position insert above):
-- don't add another planned buy the free cash can't cover once the
-- existing no-order planned rows are funded.
-- 2026-10-04: index.js writes config.etf_usd_reserve before this procedure
-- and vw_etf_cash_reserve exposes it. Subtract that from free USD so a new
-- crypto plan cannot spend dollars this run's ETF attempts still need.
-- The reserve is only those attempts (open NORMAL session, dip rules
-- passed, not already filled, and not skipped for lack of cash). A closed
-- session stores 0. ETF orders are placed after this procedure, same minute.
-- pause_buys still gates only these crypto inserts, not the ETF buys.
AND b.available
    - COALESCE((SELECT reserve_usd FROM vw_etf_cash_reserve), 0)
    -- 2026-10-07: realized profit queued for the USDC sweep is reserved too.
    - COALESCE((SELECT reserve_usd FROM vw_usdc_sweep_reserve), 0)
    - COALESCE((SELECT SUM(pb.shares * pb.buy_price * 1.012)::numeric  -- 2026-10-05: + fee pad
                FROM position pb JOIN stock sb ON sb.stock_id = pb.stock_id
                WHERE pb.buy_coinbase_order_id IS NULL
                AND pb.buy_filled_price IS NULL
                AND sb.trading_disabled IS NOT TRUE), 0)
-- 2026-10-05 (#2): real cost of this order incl. fee pad (was clip dollars).
  >= eff.cost_with_fee
AND (SELECT value FROM config WHERE key = 'pause_buys') = 'false'
AND TRUNC(s.price::numeric * 1.011, s.price_rounding::integer) < sized.last_filled_price
AND s.trading_disabled IS NOT TRUE
-- 2026-10-07: never average down into a stablecoin (stock.is_stablecoin,
-- price-behavior flag set near the top of this procedure).
AND s.is_stablecoin IS NOT TRUE
AND NOT EXISTS (
    SELECT 1 FROM position existing
    WHERE existing.stock_id = sized.stock_id
    AND existing.period_type = sized.period_type
    AND existing.buy_order_id IS NOT NULL
    AND existing.buy_filled_price IS NULL
)
-- Book gates (2026-10-05, were index.js placement-time checks):
--   spread:    only judged when bulk_best_bid_ask is fresh; then a missing
--              coin / one-sided quote (spread_pct NULL) fails the <= test.
--   imbalance: fresh snapshot not ask-heavy (>= threshold; was > -0.4 here
--              and >= -0.4 in index.js -- now one rule). NULL = allow.
--   thin ask:  near-ask notional >= order cost (eff.cost_usd, i.e. shares x
--              limit, same notional index.js used) * multiple. NULL = allow.
-- Prefer bid-heavy (+0.2) via ORDER BY below is unchanged.
AND (NOT bookcfg.bba_fresh OR bba.spread_pct <= bookcfg.max_spread_pct)
AND (book.imbalance IS NULL OR book.imbalance >= bookcfg.skip_imbalance)
AND (book.near_ask_usd IS NULL OR book.near_ask_usd >= eff.cost_usd * bookcfg.min_ask_mult)
-- 2026-10-05 (#3) trigger must already be above price: on a coin already
-- held the cap pins the trigger at addcap.cap_stop, so only create the row
-- when price is under it (was: inserted anyway, then index.js waited for
-- price to fall -- the PNG/DOGE/VVV/GFI/QI rows). No cap = no limit here
-- (the refresh UPDATE keeps uncapped triggers above market).
AND s.price::numeric < COALESCE(addcap.cap_stop, 'Infinity'::numeric)
-- 2026-10-05 (#11) Coinbase minimum order size: base size >= base_min_size
-- (stock.min_shares) and quote size (shares x effective limit) >=
-- quote_min_size (stock.min_price). NULL minimum = no limit.
AND plan.shares > 0
AND plan.shares >= COALESCE(s.min_shares, 0)
AND eff.cost_usd >= COALESCE(s.min_price, 0)
ORDER BY
    CASE WHEN book.imbalance IS NOT NULL AND book.imbalance > 0.2 THEN 0 ELSE 1 END,
    book.imbalance DESC NULLS LAST,
    s.priority DESC NULLS LAST
LIMIT 1;

-- Initial sell stop, floored at a breakeven price unconditionally — a
-- position must never be sold at a net loss, underwater or not. The floor
-- is NOT raw buy_filled_price: profit is (sell_price*shares - sell_fee) -
-- (buy_price*shares + buy_fee), so selling at exactly buy_filled_price
-- still loses both fees. This expression solves for the sell price where
-- post-fee proceeds exactly cover total cost, using this position's own
-- realized buy-side fee rate as the estimate for the sell-side fee
-- (falling back to config.fee_percent / 100 when the buy fee is unknown).
-- LATERAL can't be used
-- here since UPDATE's target table isn't a FROM-list item it can see, so
-- the formula is inlined directly instead of computed once via a join.
-- When underwater this floor makes the stop land above current market,
-- which Coinbase will reject at placement time; processSellOrders() must
-- not respond to that rejection by substituting a lower (loss-making)
-- price — it should leave the position unprotected and retry with fresh
-- preview data next cycle until price recovers enough for this floor to
-- clear.
--
-- Happy-path sell target sits ABOVE fee breakeven by config.sell_net_cushion
-- (default 0.015 = +1.5% net after fees). Fee floor is still the no-loss
-- minimum; cushion multiplies that floor so closes book real cents instead
-- of $0 scrapes. sell_stop_price keeps the extra 1.01 vs sell_price so the
-- stop-limit has a trigger gap (LSETH stranding bug). Volatility branch is
-- unchanged and still wins via GREATEST when spot is strong enough.
-- Cushion lives in config.sell_net_cushion so it can be tuned without a
-- procedure edit.
UPDATE position
SET sell_stop_price = GREATEST(
        CEIL(
            (position.buy_filled_price::numeric
                * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100))
                / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100)))
                * (1 + COALESCE((SELECT value::numeric FROM config WHERE key = 'sell_net_cushion'), 0.015))
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
                * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100))
                / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100)))
                * (1 + COALESCE((SELECT value::numeric FROM config WHERE key = 'sell_net_cushion'), 0.015))
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
JOIN vw_signal d
  ON d.stock_id = stock.stock_id
 AND d.period_type = 'day'
WHERE position.stock_id = stock.stock_id
AND pat.period_type = position.period_type
AND position.buy_filled_price IS NOT NULL
AND position.sell_price IS NULL
-- Sell stays unpriced until today is stronger than this coin's usual day,
-- the mirror of the buy dip filter (current day change below the day
-- average). The sell price is still written only once.
AND d.current_change_percent > d.historical_avg_change_percent
-- Estimated profit, from buy_filled_price and buy_fee alone: at the
-- fee-adjusted floor price (same CEIL(...) breakeven formula as above),
-- proceeds after an estimated sell fee (same buy-side fee rate, falling
-- back to config.fee_percent / 100) must exceed total cost (buy_filled_price * shares +
-- buy_fee). Uses only known buy-side values, not current market price.
AND (
    (CEIL(
        (position.buy_filled_price::numeric
            * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100))
            / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100)))
        * POWER(10::numeric, stock.price_rounding::int)
    ) / POWER(10::numeric, stock.price_rounding::int))
    * position.shares::numeric
    * (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100))
    - (position.buy_filled_price::numeric * position.shares::numeric + COALESCE(position.buy_fee::numeric, 0))
) > 0;

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
-- using the same cash-scaled stop gap a fresh pick uses, off current price
-- instead of the stale signal-time price.
UPDATE position
SET buy_stop_price = TRUNC(stock.price::numeric * gap.stop_mult, stock.price_rounding::integer),
    buy_price = TRUNC(stock.price::numeric * gap.stop_mult * 1.01, stock.price_rounding::integer)
FROM stock
CROSS JOIN LATERAL (
    -- Cash-scaled new-buy stop gap: base 2%, stretched by total program
    -- equity / available USD (same components as the equity calc: filled
    -- bags at stock.price, USD available, USD hold in open buys, priced
    -- untracked dust). stop_mult = 1 + 0.02 * (equity / available).
    -- Falls back to 1.02 when available USD is 0/NULL.
    SELECT COALESCE(
        1 + 0.02 * (
            (
                COALESCE((
                    SELECT SUM(p2.shares::numeric * s2.price::numeric)
                    FROM position p2
                    JOIN stock s2 ON s2.stock_id = p2.stock_id
                    WHERE p2.buy_filled_price IS NOT NULL
                    AND p2.sell_filled_price IS NULL
                ), 0)
                + COALESCE((SELECT available::numeric FROM vw_balance WHERE name = 'USD'), 0)
                + COALESCE((SELECT hold::numeric FROM vw_balance WHERE name = 'USD'), 0)
                + COALESCE((
                    SELECT SUM(
                        CASE
                            WHEN a.currency IN ('USDS', 'USD1', 'PAX') THEN a.balance::numeric
                            WHEN st.price IS NOT NULL THEN a.balance::numeric * st.price::numeric
                            ELSE 0
                        END
                    )
                    FROM vw_position_order_balance_audit a
                    LEFT JOIN stock st ON st.name = a.name
                    WHERE a.issue_type = 'untracked_holding'
                ), 0)
            ) / NULLIF((SELECT available::numeric FROM vw_balance WHERE name = 'USD'), 0)
        ),
        1.02
    ) AS stop_mult
) gap
WHERE position.stock_id = stock.stock_id
AND position.buy_coinbase_order_id IS NULL
AND position.buy_filled_price IS NULL
-- 2026-10-07: listing rows are plain limits (no stop) -- never re-priced here.
AND position.period_type IS DISTINCT FROM 'listing'
AND stock.price::numeric >= position.buy_stop_price::numeric;

-- 2026-09-27 add-on buy cap: a buy on a coin you already hold must never be
-- priced above your cheapest open bag. Plans use a cash-scaled stop gap (base 2%) and the
-- reset step just above can raise them again, so OCEAN bag 939 filled at
-- 0.1718 even though bag 926 was bought at 0.1695. This caps the trigger at
-- config.add_buy_cap_ratio (default 0.99 = 1% below) times the cheapest open
-- bag, with the limit 1% above that trigger (0.99 * 1.01 = 0.9999, still
-- below the bag). Only buys not yet sent to Coinbase are touched; live orders
-- are only ever lowered by the remake step. processBuyOrders then waits to
-- place a capped buy until price is below its trigger.
UPDATE position p
SET buy_stop_price = TRUNC(c.min_fill * cap.ratio,        s.price_rounding::integer),
    buy_price      = TRUNC(c.min_fill * cap.ratio * 1.01, s.price_rounding::integer)
FROM stock s,
     (SELECT stock_id, MIN(buy_filled_price)::numeric AS min_fill
      FROM position
      WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL
      GROUP BY stock_id) c,
     (SELECT COALESCE((SELECT value::numeric FROM config WHERE key = 'add_buy_cap_ratio'), 0.99) AS ratio) cap
WHERE p.stock_id = s.stock_id
AND c.stock_id = p.stock_id
AND p.buy_coinbase_order_id IS NULL
AND p.buy_filled_price IS NULL
-- 2026-10-07: listing rows exempt (plain limit, and never on a held coin).
AND p.period_type IS DISTINCT FROM 'listing'
AND p.buy_stop_price::numeric > c.min_fill * cap.ratio;

-- 2026-10-05 (#3) safety net: after the refresh and cap UPDATEs above, an
-- unsent planned row whose trigger is still not above current price cannot
-- be placed (Coinbase needs the stop above market) -- index.js used to wait
-- on these (`s.price < p.buy_stop_price`); now they are deleted so nothing
-- sits. The INSERT gates and clean-up (e) above should already prevent this;
-- this catches rounding edge cases. Same safety guards as the clean-up.
DELETE FROM position p
USING stock s
WHERE s.stock_id = p.stock_id
AND p.buy_coinbase_order_id IS NULL
AND p.buy_filled_price IS NULL
AND p.sell_coinbase_order_id IS NULL
AND NOT EXISTS (
    SELECT 1 FROM bulk_open_orders o WHERE o.client_order_id = p.buy_order_id
)
-- 2026-10-07: listing rows exempt (no stop; a first-trade-priced limit may
-- legitimately sit below the current price).
AND p.period_type IS DISTINCT FROM 'listing'
AND s.price::numeric >= p.buy_stop_price::numeric;

-- Clear error_message on unfilled buy positions instead of deleting them.
-- 2026-09-25: except permanent rejections. Clearing 'Invalid product_id'
-- every cycle made processBuyOrders retry a delisted coin (LRC-USD) forever;
-- that error can never succeed on retry, so it is left in place and the row
-- stays out of processBuyOrders' `error_message IS NULL` queue.
UPDATE position SET error_message = NULL
WHERE error_message IS NOT NULL
AND buy_coinbase_order_id IS NULL
AND buy_filled_price IS NULL
AND error_message NOT IN ('Invalid product_id');

-- Step 1: match fills for either side of a position (buy or sell).
-- Deliberately does not compute profit here -- that happens fresh in Step 2
-- from position's own stored columns, decoupled from this statement, so a
-- NULL fee here can never silently block the close-out the way it used to.
--
-- 2026-09-25 rewrite (was: UPDATE ... FROM bulk_fills with `bf.fee > 0`):
--  * Source is the permanent `fills` ledger (archived from bulk_fills at the
--    top of this procedure), not bulk_fills. bulk_fills only holds Coinbase's
--    recent-fills window, so a fill whose fee/price wasn't captured in that
--    window (e.g. PAX 468/578) could never be matched again.
--  * Aggregated per order: an order can fill in several partial fills, and
--    UPDATE ... FROM bulk_fills picked ONE arbitrary fill row -- so price was
--    one partial's price and fee was one partial's fee (understated, e.g.
--    MAMO 568 fee 0.00043 vs 0.00188 actual). Now price = size-weighted VWAP
--    across all fills of the order, fee = SUM of all their commissions.
--  * A zero fee is accepted. Coinbase charges $0 on some maker fills (PAX),
--    and the old `fee > 0` test left sell_fee NULL forever, so Step 2 never
--    recorded the close and Step 3 never deleted the row. Because Coinbase
--    can briefly report commission 0 before it settles, a 0 fee is only
--    accepted once the order's last fill is > 15 minutes old.
--  * The fee is finalized only once the order is fully filled (filled size
--    covers position.shares), so a first partial fill can't lock in a
--    partial fee. Fallback: if the order's last fill is > 1 day old, accept
--    whatever filled (a partially-filled-then-cancelled order must not
--    block the close-out forever).
--  * Filled price keeps refreshing to the latest VWAP until the fee is
--    finalized (i.e. while partial fills are still arriving);
--    buy_filled_date is still stamped only on the first match.
--  * Buy and sell aggregates are joined separately (fb / fs) so a position
--    whose buy and sell orders both have fills is updated deterministically
--    in one pass instead of depending on which join row Postgres picks.
WITH f AS (
    SELECT order_id,
           SUM(price * size) / NULLIF(SUM(size), 0) AS vwap,        -- size-weighted avg price over partial fills
           SUM(size)                                AS filled_size, -- total base filled so far
           SUM(fee)                                 AS fee,         -- total commission across partial fills
           MAX(trade_time)                          AS last_fill    -- most recent partial fill
    FROM fills
    GROUP BY order_id
),
m AS (
    SELECT p.position_id,
           fb.vwap AS b_vwap, fs.vwap AS s_vwap,
           -- buy fee is final when: fully filled AND (fee > 0 OR fill settled > 15 min),
           -- or the order simply stopped filling > 1 day ago
           CASE WHEN fb.order_id IS NOT NULL AND (
                    (fb.filled_size >= p.shares::numeric * 0.999
                        AND (fb.fee > 0 OR fb.last_fill < NOW() - INTERVAL '15 minutes'))
                    OR fb.last_fill < NOW() - INTERVAL '1 day')
                THEN fb.fee END AS b_fee_final,
           -- same rule for the sell side
           CASE WHEN fs.order_id IS NOT NULL AND (
                    (fs.filled_size >= p.shares::numeric * 0.999
                        AND (fs.fee > 0 OR fs.last_fill < NOW() - INTERVAL '15 minutes'))
                    OR fs.last_fill < NOW() - INTERVAL '1 day')
                THEN fs.fee END AS s_fee_final
    FROM position p
    LEFT JOIN f fb ON fb.order_id = p.buy_coinbase_order_id
    LEFT JOIN f fs ON fs.order_id = p.sell_coinbase_order_id
    -- only rows that still have something to fill in
    WHERE (fb.order_id IS NOT NULL AND (p.buy_filled_price  IS NULL OR p.buy_fee  IS NULL))
       OR (fs.order_id IS NOT NULL AND (p.sell_filled_price IS NULL OR p.sell_fee IS NULL))
)
UPDATE position
SET buy_filled_price  = CASE WHEN m.b_vwap IS NOT NULL AND position.buy_fee  IS NULL THEN m.b_vwap ELSE position.buy_filled_price END,
    buy_filled_date   = CASE WHEN m.b_vwap IS NOT NULL AND position.buy_filled_price IS NULL THEN NOW() ELSE position.buy_filled_date END,
    buy_fee           = COALESCE(position.buy_fee,  m.b_fee_final),
    sell_filled_price = CASE WHEN m.s_vwap IS NOT NULL AND position.sell_fee IS NULL THEN m.s_vwap ELSE position.sell_filled_price END,
    sell_fee          = COALESCE(position.sell_fee, m.s_fee_final)
FROM m
WHERE position.position_id = m.position_id;

-- Step 1b (2026-10-07, USDC profit sweep): fill in profit_converted_usdc on
-- every fully bought-and-sold position that has all six inputs, i.e. the
-- exact same rows Step 2 is about to record. Same formula as Step 2's
-- profit (which already nets out BOTH fees):
--     (sell_filled_price * shares - sell_fee) - (buy_filled_price * shares + buy_fee)
-- truncated to cents (so we never sweep more than was earned), and a loss
-- is stored as 0 (never negative). Fees are the summed Coinbase commissions
-- of every fill of the buy / sell order (Step 1 above, from the fills
-- ledger). index.js sweepProfitToUsdc() later converts these dollars to
-- USDC. Step 2 only records, and Step 3 only deletes, rows where this is
-- NOT NULL, so a row can never disappear before its amount is filled in.
UPDATE position p
SET profit_converted_usdc = GREATEST(0::numeric, TRUNC((
        (p.sell_filled_price::numeric * p.shares::numeric - p.sell_fee::numeric)
      - (p.buy_filled_price::numeric  * p.shares::numeric + p.buy_fee::numeric))::numeric, 2))
WHERE p.profit_converted_usdc IS NULL
AND p.buy_coinbase_order_id IS NOT NULL
AND p.sell_coinbase_order_id IS NOT NULL
AND p.buy_filled_price IS NOT NULL
AND p.sell_filled_price IS NOT NULL
AND p.buy_fee IS NOT NULL
AND p.sell_fee IS NOT NULL;

-- Step 2: record any fully bought-and-sold position into profit_history,
-- computing profit fresh from position's current buy/sell price and fee
-- columns. Requires every one of buy/sell order_id, buy/sell filled price,
-- and buy/sell fee to actually be populated -- no COALESCE fallback, so a
-- still-missing fee (e.g. not yet settled by Coinbase) correctly holds this
-- position back rather than recording a wrong, understated profit. It'll
-- pick it up automatically once Step 1 finishes backfilling it. Skips
-- anything already recorded, matched on both the buy and sell order_id
-- together.
-- 2026-10-07: also carries profit_converted_usdc over (Step 1b) and only
-- records rows where it is filled in.
INSERT INTO profit_history (stock_id, name, period_type, buy_coinbase_order_id, sell_fills_id, buy_fee, sell_fee, profit, profit_converted_usdc)
SELECT
    p.stock_id, p.name, p.period_type, p.buy_coinbase_order_id, p.sell_coinbase_order_id AS sell_fills_id,
    TRUNC(p.buy_fee::numeric, 2) AS buy_fee,
    TRUNC(p.sell_fee::numeric, 2) AS sell_fee,
    TRUNC(((p.sell_filled_price::numeric * p.shares::numeric - p.sell_fee::numeric)
         - (p.buy_filled_price::numeric * p.shares::numeric + p.buy_fee::numeric))::numeric, 2) AS profit,
    p.profit_converted_usdc
FROM position p
WHERE p.buy_coinbase_order_id IS NOT NULL
AND p.sell_coinbase_order_id IS NOT NULL
AND p.buy_filled_price IS NOT NULL
AND p.sell_filled_price IS NOT NULL
AND p.buy_fee IS NOT NULL
AND p.sell_fee IS NOT NULL
AND p.profit_converted_usdc IS NOT NULL
AND NOT EXISTS (
    SELECT 1 FROM profit_history ph
    WHERE ph.buy_coinbase_order_id = p.buy_coinbase_order_id AND ph.sell_fills_id = p.sell_coinbase_order_id
);

-- Step 3: delete the position row, but only once it's confirmed recorded in
-- profit_history — never delete on the strength of this statement's own
-- assumptions the way the old combined version did.
-- 2026-10-07: and only once profit_converted_usdc is filled in (Step 1b),
-- so the sweep amount is never lost with the row.
DELETE FROM position p
WHERE p.buy_filled_price IS NOT NULL AND p.sell_filled_price IS NOT NULL
AND p.profit_converted_usdc IS NOT NULL
AND EXISTS (
    SELECT 1 FROM profit_history ph
    WHERE ph.buy_coinbase_order_id = p.buy_coinbase_order_id AND ph.sell_fills_id = p.sell_coinbase_order_id
);

-- 2026-10-05: number each open position per coin (creation_hierarchy).
-- Only rows with sell_price IS NOT NULL are ranked. 1 = cheapest fill
-- (lowest buy_filled_price), then lowest buy_stop_price; NOT the oldest
-- row. Rows with sell_price NULL keep creation_hierarchy NULL (not numbered).
-- "Coin" means stock_id, not period_type, so day/month/year rows share one
-- sequence. Order among ranked rows: buy_filled_price ASC NULLS LAST,
-- buy_stop_price ASC NULLS LAST, position_id ASC (tie-break).
-- Placed here, after every INSERT and DELETE on position in this run
-- (orphan recovery, new and average-down buys, stale-plan expiry, and the
-- Step 3 close-out), so the numbers match the rows that are left.
-- Recomputed every run, so a closed or deleted row makes the rows after it
-- move down. Only rows whose number actually changes are written, so the
-- position_audit trigger does not log an unchanged row every run.
UPDATE position p
SET creation_hierarchy = r.rn
FROM (
    SELECT p_all.position_id,
           ranked.rn
    FROM position p_all
    LEFT JOIN (
        SELECT position_id,
               ROW_NUMBER() OVER (
                   PARTITION BY stock_id
                   ORDER BY buy_filled_price ASC NULLS LAST,
                            buy_stop_price ASC NULLS LAST,
                            position_id ASC
               ) AS rn
        FROM position
        WHERE sell_price IS NOT NULL
    ) ranked ON ranked.position_id = p_all.position_id
) r
WHERE p.position_id = r.position_id
  AND p.creation_hierarchy IS DISTINCT FROM r.rn;

-- Once the position row is gone, its audit history goes with it. The DELETE
-- trigger's snapshot is included, on purpose.
DELETE FROM position_audit AS pa
USING position_audit AS a
LEFT JOIN position AS p ON p.position_id = a.position_id
WHERE pa.audit_id = a.audit_id
  AND p.position_id IS NULL;

-- Prune position_audit records older than a month.
DELETE FROM position_audit WHERE changed_at < NOW() - INTERVAL '1 month';

-- Catch any fill this cycle that no position and no profit_history row
-- claims, before bulk_fills is truncated below and the evidence is gone
-- for good. Checked against both live positions (buy/sell_coinbase_order_id)
-- and already-recorded closes (profit_history.buy_coinbase_order_id /
-- sell_fills_id), so a fill legitimately matched and closed out earlier
-- this same cycle (Step 1-3 above) is correctly excluded, not
-- re-flagged as orphaned. NOT EXISTS against unmatched_fills itself
-- avoids re-logging the same fill every cycle it keeps showing up in
-- Coinbase's recent-fills window.
INSERT INTO unmatched_fills (order_id, trade_id, product_id, side, price, size, fee, trade_time)
SELECT bf.order_id, bf.trade_id, bf.product_id, bf.side, bf.price, bf.size, bf.fee, bf.created_at
FROM bulk_fills bf
WHERE NOT EXISTS (
    SELECT 1 FROM position p
    WHERE p.buy_coinbase_order_id = bf.order_id OR p.sell_coinbase_order_id = bf.order_id
)
AND NOT EXISTS (
    SELECT 1 FROM profit_history ph
    WHERE ph.buy_coinbase_order_id = bf.order_id OR ph.sell_fills_id = bf.order_id
)
AND NOT EXISTS (
    SELECT 1 FROM unmatched_fills uf WHERE uf.order_id = bf.order_id
)
-- 2026-10-06: ETF orders (daily market buy and limit ladder) are tracked in
-- etf_buy, not position, so they are not orphans. Without this every ETF
-- fill logged "ERROR: unmatched fill detected" and tripped the health check.
AND NOT EXISTS (
    SELECT 1 FROM etf_buy eb WHERE eb.coinbase_order_id = bf.order_id
);

TRUNCATE TABLE bulk_stock;
TRUNCATE TABLE bulk_fills;
-- bulk_currency and bulk_open_orders are no longer truncated here -- moved to
-- insertCurrency()/insertOpenOrders() in modules/database.js, immediately
-- before each fresh insert, so these tables hold a continuously-queryable
-- last-cycle snapshot the whole time instead of being emptied the moment
-- this procedure finishes. Needed for vw_position_order_balance_audit to be
-- queryable anytime, not just in the brief window mid-cycle.

$_$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: stock; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stock (
    stock_id integer NOT NULL,
    name text,
    date_created date,
    price double precision,
    historical_finished bit(1),
    historical_last_date date,
    priority numeric,
    price_movement text,
    max_shares double precision,
    min_shares double precision,
    min_price double precision,
    max_price double precision,
    share_rounding integer,
    price_rounding integer,
    trading_disabled boolean,
    is_stablecoin boolean DEFAULT false NOT NULL
);


--
-- Name: COLUMN stock.is_stablecoin; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.stock.is_stablecoin IS 'TRUE = behaves like a $1 stablecoin (price within config.stablecoin_price_band_pct of $1 and 24h high-low range under config.stablecoin_max_range_pct of price, from the Coinbase products feed). Set by thee_procedure, sticky (never auto-cleared). Every buy INSERT in thee_procedure skips these coins.';


--
-- Name: Stock_StockID_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.stock ALTER COLUMN stock_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public."Stock_StockID_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: account; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account (
    account_id integer NOT NULL,
    date_created timestamp without time zone,
    email text
);


--
-- Name: COLUMN account.email; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.account.email IS 'Email for this account. Nullable so the original row did not need a value.';


--
-- Name: account_account_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.account ALTER COLUMN account_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.account_account_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: book_snapshot; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.book_snapshot (
    book_snapshot_id integer NOT NULL,
    stock_id integer,
    name text,
    best_bid double precision,
    best_ask double precision,
    mid double precision,
    spread_pct double precision,
    near_bid_usd double precision,
    near_ask_usd double precision,
    imbalance double precision,
    band_pct double precision,
    bid_levels integer,
    ask_levels integer,
    date_created timestamp without time zone DEFAULT now()
);


--
-- Name: book_snapshot_book_snapshot_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.book_snapshot ALTER COLUMN book_snapshot_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.book_snapshot_book_snapshot_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: bulk_best_bid_ask; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bulk_best_bid_ask (
    product_id text NOT NULL,
    best_bid double precision,
    best_bid_size double precision,
    best_ask double precision,
    best_ask_size double precision,
    spread_pct double precision,
    quote_time timestamp with time zone,
    loaded_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE bulk_best_bid_ask; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.bulk_best_bid_ask IS 'Best bid/ask for every product, reloaded each run by index.js processBestBidAsk() before thee_procedure(). Feeds the procedure spread gate. Empty or >3 min old = fail open.';


--
-- Name: COLUMN bulk_best_bid_ask.spread_pct; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.bulk_best_bid_ask.spread_pct IS '(best_ask - best_bid) / mid * 100. NULL when there is no two-sided quote (rejected by the spread gate when data is fresh).';


--
-- Name: bulk_currency; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bulk_currency (
    bulk_currency_id integer NOT NULL,
    id text,
    currency text,
    balance double precision,
    hold double precision,
    available double precision,
    profile_id text,
    trading_enabled text
);


--
-- Name: bulk_currency_bulk_currency_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bulk_currency_bulk_currency_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bulk_currency_bulk_currency_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bulk_currency_bulk_currency_id_seq OWNED BY public.bulk_currency.bulk_currency_id;


--
-- Name: bulk_fills; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bulk_fills (
    bulk_fills_id integer NOT NULL,
    created_at timestamp with time zone,
    trade_id text,
    product_id text,
    order_id text,
    profile_id text,
    liquidity text,
    price double precision,
    size double precision,
    fee double precision,
    side text,
    settled text
);


--
-- Name: bulk_fills_bulk_fills_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bulk_fills_bulk_fills_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bulk_fills_bulk_fills_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bulk_fills_bulk_fills_id_seq OWNED BY public.bulk_fills.bulk_fills_id;


--
-- Name: bulk_historical; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bulk_historical (
    stock_id integer,
    start bigint,
    low double precision,
    high double precision,
    open double precision,
    close double precision,
    volume double precision
);


--
-- Name: bulk_open_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bulk_open_orders (
    bulk_open_orders_id integer NOT NULL,
    order_id text,
    product_id text,
    user_id text,
    order_configuration json,
    side text,
    client_order_id text,
    status text,
    time_in_force text,
    created_time timestamp without time zone,
    completion_percentage double precision,
    filled_size double precision,
    average_filled_price double precision,
    fee text,
    number_of_fills integer,
    filled_value double precision,
    pending_cancel boolean,
    size_in_quote boolean,
    total_fees double precision,
    size_inclusive_of_fees boolean,
    total_value_after_fees double precision,
    trigger_status text,
    order_type text,
    reject_reason text,
    settled boolean,
    product_type text,
    reject_message text,
    cancel_message text,
    order_placement_source text,
    outstanding_hold_amount double precision,
    is_liquidation boolean,
    last_fill_time timestamp without time zone,
    edit_history json,
    leverage text,
    margin_type text,
    retail_portfolio_id text,
    originating_order_id text,
    attached_order_id text,
    attached_order_configuration json,
    current_pending_replace json,
    commission_detail_total json,
    workable_size text,
    workable_size_completion_pct text,
    product_details json,
    cost_basis_method text,
    displayed_order_config text,
    equity_trading_session text,
    prediction_side text,
    last_update_time timestamp without time zone
);


--
-- Name: bulk_open_orders_bulk_open_orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bulk_open_orders_bulk_open_orders_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bulk_open_orders_bulk_open_orders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bulk_open_orders_bulk_open_orders_id_seq OWNED BY public.bulk_open_orders.bulk_open_orders_id;


--
-- Name: bulk_stock; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bulk_stock (
    bulk_stock_id integer NOT NULL,
    id text,
    quote_increment text,
    base_increment text,
    min_market_funds text,
    trading_disabled text,
    post_only text,
    cancel_only text,
    system text,
    price text,
    "json" json,
    status text,
    limit_only text,
    auction_mode text,
    is_new text,
    new_at text
);


--
-- Name: bulk_stock_bulk_stock_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bulk_stock_bulk_stock_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bulk_stock_bulk_stock_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bulk_stock_bulk_stock_id_seq OWNED BY public.bulk_stock.bulk_stock_id;


--
-- Name: config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.config (
    key text NOT NULL,
    value text NOT NULL
);


--
-- Name: etf; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.etf (
    ticker text NOT NULL,
    product_id text NOT NULL,
    quote_usd numeric DEFAULT 1 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    is_special boolean DEFAULT false NOT NULL
);


--
-- Name: TABLE etf; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.etf IS 'Equity ETFs bought on the Coinbase NORMAL session under dip rules. is_special selects the repeat rule.';


--
-- Name: COLUMN etf.product_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.etf.product_id IS 'Canonical EQUITY product_id from the products API. Do not substitute the ticker.';


--
-- Name: COLUMN etf.quote_usd; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.etf.quote_usd IS 'Quote USD notional for one market buy. Default $1. Not a share count.';


--
-- Name: COLUMN etf.is_special; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.etf.is_special IS 'True for BLOX, CHPY, TOPW, TSLW, XDTE, SPCX, and YBTC. XDTE was made a special on 2026-10-04 so it gets same-day dip rebuys and the 2:45 PM CT catch-up. SPCX (SpaceX common stock) added as a special on 2026-10-05. YBTC (Roundhill Bitcoin Covered Call ETF) added as a special on 2026-10-06; YETH skipped (Coinbase liquidate_only).';


--
-- Name: etf_buy; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.etf_buy (
    etf_buy_id bigint NOT NULL,
    ticker text NOT NULL,
    chicago_date date NOT NULL,
    quote_usd numeric NOT NULL,
    filled boolean DEFAULT false NOT NULL,
    closed_session boolean DEFAULT false NOT NULL,
    coinbase_order_id text,
    client_order_id text,
    error_message text,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    dip_price numeric,
    fill_price numeric,
    order_type text,
    status text,
    limit_price numeric,
    base_size numeric,
    expires_at timestamp with time zone,
    basis_price numeric,
    price_basis text,
    closed_at timestamp with time zone
);


--
-- Name: TABLE etf_buy; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.etf_buy IS 'ETF buy attempts. filled = true counts for the Chicago-day dip rules. A closed-market reject or zero fill stays filled = false and does not count.';


--
-- Name: COLUMN etf_buy.closed_session; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.etf_buy.closed_session IS 'Closed-market reject. Does not count as today''s buy.';


--
-- Name: COLUMN etf_buy.dip_price; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.etf_buy.dip_price IS 'Live price the dip rule compared. Null when the attempt did not need a price (no shares held yet, or the special 2:45 PM Chicago catch-up).';


--
-- Name: COLUMN etf_buy.fill_price; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.etf_buy.fill_price IS 'Execution price from filled value / filled size. The next same-day dip uses the latest non-null value. Null when size was not returned.';


--
-- Name: COLUMN etf_buy.order_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.etf_buy.order_type IS 'market = the once-per-Chicago-day $1 market buy (and pre-2026-10-06 dip re-buys). limit = a resting ladder limit buy.';


--
-- Name: COLUMN etf_buy.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.etf_buy.status IS 'PLACING (row reserved, order not yet confirmed), OPEN (resting on Coinbase), FILLED, EXPIRED (bot cancelled it at expires_at), CANCELLED (cancelled by Coinbase/user, or a market IOC that did not fill), REJECTED (create failed), ABANDONED (PLACING row whose order never appeared).';


--
-- Name: COLUMN etf_buy.limit_price; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.etf_buy.limit_price IS 'Limit price sent to Coinbase (limit rows only), floored to price_increment.';


--
-- Name: COLUMN etf_buy.base_size; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.etf_buy.base_size IS 'Shares sent to Coinbase (limit rows only): quote_usd / limit_price rounded UP to base_increment so notional >= $1.';


--
-- Name: COLUMN etf_buy.expires_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.etf_buy.expires_at IS 'Bot-side expiry for limit rows: placed + config.etf_limit_ttl_hours. Coinbase has no GTD for equities, so index.js cancels the GTC order after this time.';


--
-- Name: COLUMN etf_buy.basis_price; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.etf_buy.basis_price IS 'Price the limit was stepped down from: the latest buy fill VWAP (fills.price) or, with no fill ever, the best bid.';


--
-- Name: COLUMN etf_buy.price_basis; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.etf_buy.price_basis IS 'Where basis_price came from: last_fill, coinbase_bid, or iex_bid.';


--
-- Name: COLUMN etf_buy.closed_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.etf_buy.closed_at IS 'When the bot saw the limit reach a terminal status (FILLED / EXPIRED / CANCELLED / ABANDONED).';


--
-- Name: etf_buy_etf_buy_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.etf_buy ALTER COLUMN etf_buy_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.etf_buy_etf_buy_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: fills; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fills (
    fill_id bigint NOT NULL,
    order_id text,
    trade_id text,
    product_id text,
    side text,
    price double precision,
    size double precision,
    fee double precision,
    trade_time timestamp with time zone,
    recorded_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: fills_fill_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.fills_fill_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: fills_fill_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.fills_fill_id_seq OWNED BY public.fills.fill_id;


--
-- Name: listing_watch; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.listing_watch (
    product_id text NOT NULL,
    stock_id integer,
    is_new boolean,
    new_at timestamp with time zone,
    first_watched_at timestamp with time zone DEFAULT now() NOT NULL,
    last_checked_at timestamp with time zone,
    check_count integer DEFAULT 0 NOT NULL,
    last_flags jsonb,
    restricted_seen_at timestamp with time zone,
    restrictions_cleared_at timestamp with time zone,
    first_trade_at timestamp with time zone,
    first_trade_price numeric,
    first_trade_source text,
    trading_open_at timestamp with time zone,
    trading_open_source text,
    last_error text
);


--
-- Name: TABLE listing_watch; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.listing_watch IS 'Candidate new -USD listings (new = true or new_at within 7 days) watched each minute by modules/listingWatch.js until their real trading open time is known. thee_procedure''s listing snipe fires only within config.listing_window_minutes of trading_open_at.';


--
-- Name: COLUMN listing_watch.restricted_seen_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.listing_watch.restricted_seen_at IS 'First time the bot saw the product still launch-restricted (not online, trading_disabled, auction_mode, limit_only or cancel_only).';


--
-- Name: COLUMN listing_watch.restrictions_cleared_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.listing_watch.restrictions_cleared_at IS 'First time the bot observed status online AND NOT trading_disabled/auction_mode/limit_only/cancel_only.';


--
-- Name: COLUMN listing_watch.first_trade_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.listing_watch.first_trade_at IS 'Time of the pair''s first completed trade: Exchange API trade_id 1 (exact), or fallback the first ONE_MINUTE candle with volume > 0 (minute start).';


--
-- Name: COLUMN listing_watch.first_trade_price; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.listing_watch.first_trade_price IS 'Price of that first trade (candle open in the fallback). The listing limit buy is priced off this.';


--
-- Name: COLUMN listing_watch.trading_open_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.listing_watch.trading_open_at IS 'Window start = LEAST(first_trade_at, restrictions_cleared_at). Set once and never moved.';


--
-- Name: portfolio; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.portfolio (
    portfolio_id integer NOT NULL,
    account_id integer,
    date_created timestamp without time zone
);


--
-- Name: portfolio_portfolio_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.portfolio ALTER COLUMN portfolio_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.portfolio_portfolio_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: position; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."position" (
    stock_id integer,
    name text,
    shares double precision,
    date_created timestamp without time zone,
    error_message text,
    period_type text,
    buy_filled_price double precision,
    buy_price double precision,
    sell_price double precision,
    buy_order_id text,
    sell_order_id text,
    buy_coinbase_order_id text,
    sell_coinbase_order_id text,
    buy_stop_price double precision,
    sell_stop_price double precision,
    sell_filled_price double precision,
    buy_fee double precision,
    sell_fee double precision,
    profit double precision,
    daily_sell boolean DEFAULT false NOT NULL,
    sell_counter integer DEFAULT 0 NOT NULL,
    buy_counter integer DEFAULT 0 NOT NULL,
    buy_filled_date timestamp without time zone,
    daily_buy boolean DEFAULT false NOT NULL,
    position_id bigint NOT NULL,
    last_remade_at timestamp without time zone,
    buy_placed_at timestamp without time zone,
    buy_released_at timestamp without time zone,
    creation_hierarchy integer,
    profit_converted_usdc numeric
);


--
-- Name: COLUMN "position".creation_hierarchy; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public."position".creation_hierarchy IS 'Per-coin sequence of open positions with sell_price set (1 = cheapest fill); NULL when sell_price IS NULL. Order: buy_filled_price ASC NULLS LAST, then buy_stop_price ASC NULLS LAST, then position_id. Recomputed every run by thee_procedure.';


--
-- Name: COLUMN "position".profit_converted_usdc; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public."position".profit_converted_usdc IS 'Net profit to sweep to USDC: GREATEST(0, TRUNC((sell_filled_price*shares - sell_fee) - (buy_filled_price*shares + buy_fee), 2)). Fees are the summed fill commissions. Losses = 0. Set by thee_procedure; the close-out waits for it.';


--
-- Name: position_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.position_audit (
    audit_id bigint NOT NULL,
    position_id bigint,
    operation text NOT NULL,
    column_name text,
    old_value text,
    new_value text,
    changed_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: position_audit_audit_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.position_audit_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: position_audit_audit_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.position_audit_audit_id_seq OWNED BY public.position_audit.audit_id;


--
-- Name: position_position_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.position_position_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: position_position_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.position_position_id_seq OWNED BY public."position".position_id;


--
-- Name: price_aggregate; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.price_aggregate (
    price_aggregate_id integer NOT NULL,
    stock_id integer,
    period_type text,
    period_date date,
    open double precision,
    close double precision,
    high double precision,
    low double precision,
    avg_price double precision
);


--
-- Name: price_aggregate_comparison; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.price_aggregate_comparison (
    price_aggregate_comparison_id integer NOT NULL,
    before_id integer,
    after_id integer,
    change_percent double precision
);


--
-- Name: price_aggregate_comparison_price_aggregate_comparison_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.price_aggregate_comparison ALTER COLUMN price_aggregate_comparison_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.price_aggregate_comparison_price_aggregate_comparison_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: price_aggregate_total; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.price_aggregate_total (
    price_aggregate_total_id integer NOT NULL,
    stock_id integer,
    period_type text,
    avg_change_percent double precision,
    std_dev double precision,
    std_dev_upper_bound double precision,
    std_dev_lower_bound double precision
);


--
-- Name: price_aggregate_total_price_aggregate_total_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.price_aggregate_total ALTER COLUMN price_aggregate_total_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.price_aggregate_total_price_aggregate_total_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: price_aggregates_price_aggregate_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.price_aggregates_price_aggregate_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: price_aggregates_price_aggregate_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.price_aggregates_price_aggregate_id_seq OWNED BY public.price_aggregate.price_aggregate_id;


--
-- Name: price_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.price_history (
    price_history_id integer NOT NULL,
    stock_id integer,
    price double precision,
    date_created timestamp without time zone
);


--
-- Name: price_history_price_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.price_history ALTER COLUMN price_history_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.price_history_price_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: profit_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profit_history (
    profit_history_id integer NOT NULL,
    stock_id integer,
    name text,
    period_type text,
    buy_coinbase_order_id text,
    sell_fills_id text,
    buy_fee double precision,
    sell_fee double precision,
    profit double precision,
    date_created timestamp without time zone DEFAULT now(),
    profit_converted_usdc numeric,
    usdc_convert_status text,
    usdc_convert_trade_id text,
    usdc_converted_at timestamp with time zone,
    CONSTRAINT profit_history_usdc_convert_status_check CHECK (((usdc_convert_status IS NULL) OR (usdc_convert_status = ANY (ARRAY['pending'::text, 'completed'::text, 'failed'::text]))))
);


--
-- Name: COLUMN profit_history.profit_converted_usdc; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profit_history.profit_converted_usdc IS 'Copied from position at close. Swept to USDC by index.js sweepProfitToUsdc().';


--
-- Name: COLUMN profit_history.usdc_convert_status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profit_history.usdc_convert_status IS 'USDC sweep state: NULL = not swept yet, pending = in an in-flight convert, completed = converted, failed = retried next minute.';


--
-- Name: COLUMN profit_history.usdc_convert_trade_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profit_history.usdc_convert_trade_id IS 'Coinbase convert trade id of the latest sweep attempt (set just before commit).';


--
-- Name: COLUMN profit_history.usdc_converted_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profit_history.usdc_converted_at IS 'When Coinbase confirmed the USD -> USDC convert for this row.';


--
-- Name: profit_history_profit_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.profit_history_profit_history_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: profit_history_profit_history_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.profit_history_profit_history_id_seq OWNED BY public.profit_history.profit_history_id;


--
-- Name: unmatched_fills; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.unmatched_fills (
    unmatched_fill_id bigint NOT NULL,
    order_id text,
    trade_id text,
    product_id text,
    side text,
    price double precision,
    size double precision,
    fee double precision,
    trade_time timestamp with time zone,
    detected_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: unmatched_fills_unmatched_fill_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.unmatched_fills_unmatched_fill_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: unmatched_fills_unmatched_fill_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.unmatched_fills_unmatched_fill_id_seq OWNED BY public.unmatched_fills.unmatched_fill_id;


--
-- Name: usd_transfer; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usd_transfer (
    id bigint NOT NULL,
    type text NOT NULL,
    amount numeric(14,2) NOT NULL,
    date timestamp without time zone NOT NULL,
    CONSTRAINT usd_transfer_type_check CHECK ((type = ANY (ARRAY['deposit'::text, 'withdrawal'::text])))
);


--
-- Name: TABLE usd_transfer; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.usd_transfer IS 'Completed USD deposits/withdrawals between the bank and Coinbase (net invested capital). Inserted each minute by index.js (modules/usdTransferSync.js) and backfilled by node scripts/exportUsdDeposits.js --load-db. UNIQUE (type, amount, date) dedupes.';


--
-- Name: COLUMN usd_transfer.type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.usd_transfer.type IS 'deposit = money in from the bank, withdrawal = money out to the bank.';


--
-- Name: COLUMN usd_transfer.amount; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.usd_transfer.amount IS 'USD, always positive. Direction comes from type.';


--
-- Name: COLUMN usd_transfer.date; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.usd_transfer.date IS 'When Coinbase created the deposit/withdrawal, America/Chicago local time (same convention as date_created / created_at).';


--
-- Name: usd_transfer_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.usd_transfer ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.usd_transfer_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: vw_balance; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_balance AS
 SELECT s.name,
    s.stock_id,
    bc.balance,
    bc.hold,
    bc.available,
    (s.price * bc.balance) AS price_balance,
    (s.price * bc.available) AS price_available,
    (s.price * bc.hold) AS price_hold,
    (bc.balance * s.price) AS value
   FROM (public.bulk_currency bc
     JOIN public.stock s ON ((concat(bc.currency, '-USD') = s.name)))
UNION
 SELECT bc.currency AS name,
    NULL::integer AS stock_id,
    bc.balance,
    bc.hold,
    bc.available,
    0 AS price_balance,
    0 AS price_available,
    0 AS price_hold,
    bc.balance AS value
   FROM public.bulk_currency bc
  WHERE (bc.currency = ANY (ARRAY['USD'::text, 'USDC'::text]));


--
-- Name: vw_edit_orders; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_edit_orders AS
 SELECT p.name,
    p.period_type,
    trunc((((s.price)::numeric * bal.stop_mult) * 1.01), s.price_rounding) AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.buy_coinbase_order_id AS coinbase_order_id,
    p.shares,
    trunc(((s.price)::numeric * bal.stop_mult), s.price_rounding) AS new_stop_price,
    'buy'::text AS order_type,
    trunc((1.0 - ((s.price)::numeric / NULLIF(( SELECT (min(pa.low))::numeric AS min
           FROM public.price_aggregate pa
          WHERE ((pa.stock_id = p.stock_id) AND (pa.period_type = p.period_type))), (0)::numeric))), 4) AS estimated_profit,
    p.last_remade_at,
    p.buy_counter AS counter,
    (abs((trunc(((s.price)::numeric * bal.stop_mult), s.price_rounding) - (p.buy_stop_price)::numeric)) / NULLIF((s.price)::numeric, (0)::numeric)) AS price_diff
   FROM ((public."position" p
     JOIN public.stock s ON ((p.stock_id = s.stock_id)))
     CROSS JOIN LATERAL ( SELECT GREATEST(1.001, (1.05 - ((p.buy_counter)::numeric * 0.005))) AS stop_mult) bal)
  WHERE ((p.buy_coinbase_order_id IS NOT NULL) AND (p.buy_filled_price IS NULL) AND (p.period_type IS DISTINCT FROM 'listing'::text) AND (p.buy_stop_price > (trunc(((s.price)::numeric * bal.stop_mult), s.price_rounding))::double precision) AND (p.buy_price > (trunc((((s.price)::numeric * bal.stop_mult) * 1.01), s.price_rounding))::double precision))
UNION ALL
 SELECT p.name,
    p.period_type,
    p.sell_price AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.sell_coinbase_order_id AS coinbase_order_id,
    p.shares,
    ns.new_stop AS new_stop_price,
    'sell'::text AS order_type,
    trunc(pr.net_at_new_stop, 2) AS estimated_profit,
    p.last_remade_at,
    p.sell_counter AS counter,
    (abs((ns.new_stop - (p.sell_stop_price)::numeric)) / NULLIF((s.price)::numeric, (0)::numeric)) AS price_diff
   FROM (((public."position" p
     JOIN public.stock s ON ((p.stock_id = s.stock_id)))
     CROSS JOIN LATERAL ( SELECT LEAST(GREATEST((p.sell_price)::numeric, trunc(((s.price)::numeric * (0.99 + ((p.sell_counter)::numeric * 0.005))), s.price_rounding)), trunc(((s.price)::numeric * 0.995), s.price_rounding)) AS new_stop) ns)
     CROSS JOIN LATERAL ( SELECT (((ns.new_stop * (p.shares)::numeric) * ((1)::numeric - COALESCE((NULLIF((p.buy_fee)::numeric, (0)::numeric) / NULLIF(((p.buy_filled_price)::numeric * (p.shares)::numeric), (0)::numeric)), (COALESCE(( SELECT (config.value)::numeric AS value
                   FROM public.config
                  WHERE (config.key = 'fee_percent'::text)), 1.20) / (100)::numeric)))) - (((p.buy_filled_price)::numeric * (p.shares)::numeric) + COALESCE((p.buy_fee)::numeric, (0)::numeric))) AS net_at_new_stop) pr)
  WHERE ((p.sell_coinbase_order_id IS NOT NULL) AND (p.sell_filled_price IS NULL) AND (p.daily_sell = true) AND (p.sell_stop_price < (ns.new_stop)::double precision) AND (ns.new_stop >= (p.sell_price)::numeric) AND (pr.net_at_new_stop > (0)::numeric) AND ((pr.net_at_new_stop)::double precision > ( SELECT COALESCE(avg(profit_history.profit), (0)::double precision) AS "coalesce"
           FROM public.profit_history
          WHERE (profit_history.period_type = p.period_type))) AND (p.creation_hierarchy = 1))
UNION ALL
 SELECT p.name,
    p.period_type,
    p.sell_price AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.sell_coinbase_order_id AS coinbase_order_id,
    p.shares,
    ns.new_stop AS new_stop_price,
    'sell'::text AS order_type,
    trunc(pr.net_at_new_stop, 2) AS estimated_profit,
    p.last_remade_at,
    p.sell_counter AS counter,
    (abs((ns.new_stop - (p.sell_stop_price)::numeric)) / NULLIF((s.price)::numeric, (0)::numeric)) AS price_diff
   FROM (((((public."position" p
     JOIN public.stock s ON ((p.stock_id = s.stock_id)))
     JOIN public.price_aggregate_total pat ON (((p.stock_id = pat.stock_id) AND (p.period_type = pat.period_type))))
     CROSS JOIN LATERAL ( SELECT
                CASE p.period_type
                    WHEN 'day'::text THEN LEAST(0.99, GREATEST(0.90, ((1)::numeric - ((pat.std_dev)::numeric / (200)::numeric))))
                    WHEN 'month'::text THEN LEAST(0.97, GREATEST(0.75, ((1)::numeric - ((pat.std_dev)::numeric / (200)::numeric))))
                    WHEN 'year'::text THEN LEAST(0.95, GREATEST(0.60, ((1)::numeric - ((pat.std_dev)::numeric / (200)::numeric))))
                    ELSE NULL::numeric
                END AS stop_ratio) vol)
     CROSS JOIN LATERAL ( SELECT LEAST(GREATEST((p.sell_price)::numeric, trunc(((s.price)::numeric * (vol.stop_ratio + ((p.sell_counter)::numeric * 0.005))), s.price_rounding)), trunc(((s.price)::numeric * 0.995), s.price_rounding)) AS new_stop) ns)
     CROSS JOIN LATERAL ( SELECT (((ns.new_stop * (p.shares)::numeric) * ((1)::numeric - COALESCE((NULLIF((p.buy_fee)::numeric, (0)::numeric) / NULLIF(((p.buy_filled_price)::numeric * (p.shares)::numeric), (0)::numeric)), (COALESCE(( SELECT (config.value)::numeric AS value
                   FROM public.config
                  WHERE (config.key = 'fee_percent'::text)), 1.20) / (100)::numeric)))) - (((p.buy_filled_price)::numeric * (p.shares)::numeric) + COALESCE((p.buy_fee)::numeric, (0)::numeric))) AS net_at_new_stop) pr)
  WHERE ((p.sell_coinbase_order_id IS NOT NULL) AND (p.sell_filled_price IS NULL) AND (p.daily_sell = false) AND (p.sell_stop_price < (ns.new_stop)::double precision) AND (ns.new_stop >= (p.sell_price)::numeric) AND (pr.net_at_new_stop > (0)::numeric) AND ((pr.net_at_new_stop)::double precision > ( SELECT COALESCE(avg(profit_history.profit), (0)::double precision) AS "coalesce"
           FROM public.profit_history
          WHERE (profit_history.period_type = p.period_type))) AND (p.creation_hierarchy = 1))
  ORDER BY 11 NULLS FIRST, 13 DESC;


--
-- Name: vw_etf_cash_reserve; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_etf_cash_reserve AS
 SELECT COALESCE(( SELECT (config.value)::numeric AS value
           FROM public.config
          WHERE (config.key = 'etf_usd_reserve'::text)), (0)::numeric) AS reserve_usd;


--
-- Name: VIEW vw_etf_cash_reserve; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.vw_etf_cash_reserve IS 'Default USD index.js reserved for this run''s ETF attempts. thee_procedure subtracts it from crypto buy plans. 0 when the equity session is closed, a listing bag is open (listing is priority one), or nothing qualifies.';


--
-- Name: vw_latest_fills; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_latest_fills AS
 SELECT s.stock_id,
    s.name,
    bfs.bulk_fills_id AS sell_id,
    bfs.order_id AS sell_order,
    bfs.created_at AS sell_date,
    bfs.price AS sell_price,
    bfs.size AS sell_size,
    bfs.fee AS sell_fee,
    (bfs.price * bfs.size) AS sell_value,
    bfb.bulk_fills_id AS buy_id,
    bfb.order_id AS buy_order,
    bfb.created_at AS buy_date,
    bfb.price AS buy_price,
    bfb.size AS buy_size,
    bfb.fee AS buy_fee,
    (bfb.price * bfb.size) AS buy_value
   FROM ((((public.stock s
     LEFT JOIN ( SELECT bulk_fills.product_id,
            bulk_fills.side,
            max(bulk_fills.bulk_fills_id) AS max_id
           FROM public.bulk_fills
          WHERE (bulk_fills.side = 'SELL'::text)
          GROUP BY bulk_fills.product_id, bulk_fills.side) max_sell ON ((s.name = max_sell.product_id)))
     LEFT JOIN public.bulk_fills bfs ON ((max_sell.max_id = bfs.bulk_fills_id)))
     LEFT JOIN ( SELECT bulk_fills.product_id,
            bulk_fills.side,
            max(bulk_fills.bulk_fills_id) AS max_id
           FROM public.bulk_fills
          WHERE (bulk_fills.side = 'BUY'::text)
          GROUP BY bulk_fills.product_id, bulk_fills.side) max_buy ON ((s.name = max_sell.product_id)))
     LEFT JOIN public.bulk_fills bfb ON ((max_buy.max_id = bfb.bulk_fills_id)));


--
-- Name: vw_position; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_position AS
 SELECT stock_id,
    name,
    period_type,
    count(*) FILTER (WHERE ((buy_filled_price IS NOT NULL) AND (sell_filled_price IS NULL))) AS cnt,
    sum(shares) FILTER (WHERE ((buy_filled_price IS NOT NULL) AND (sell_filled_price IS NULL))) AS sum_shares,
    max(buy_price) FILTER (WHERE ((buy_filled_price IS NOT NULL) AND (sell_filled_price IS NULL))) AS max_buy_price,
    min(buy_price) FILTER (WHERE ((buy_filled_price IS NOT NULL) AND (sell_filled_price IS NULL))) AS min_buy_price,
    sum((buy_price * shares)) FILTER (WHERE ((buy_filled_price IS NOT NULL) AND (sell_filled_price IS NULL))) AS sum_buy_value,
    max(buy_order_id) FILTER (WHERE ((buy_filled_price IS NOT NULL) AND (sell_filled_price IS NULL))) AS max_buy_order_id,
    min(buy_order_id) FILTER (WHERE ((buy_filled_price IS NOT NULL) AND (sell_filled_price IS NULL))) AS min_buy_order_id,
    max(buy_coinbase_order_id) FILTER (WHERE ((buy_filled_price IS NOT NULL) AND (sell_filled_price IS NULL))) AS max_buy_coinbase_order_id,
    min(buy_coinbase_order_id) FILTER (WHERE ((buy_filled_price IS NOT NULL) AND (sell_filled_price IS NULL))) AS min_buy_coinbase_order_id,
    max(buy_filled_price) FILTER (WHERE ((buy_filled_price IS NOT NULL) AND (sell_filled_price IS NULL))) AS max_buy_filled_price,
    min(buy_filled_price) FILTER (WHERE ((buy_filled_price IS NOT NULL) AND (sell_filled_price IS NULL))) AS min_buy_filled_price,
    min(buy_stop_price) FILTER (WHERE ((buy_filled_price IS NOT NULL) AND (sell_filled_price IS NULL))) AS min_buy_stop_price,
    max(buy_stop_price) FILTER (WHERE ((buy_filled_price IS NOT NULL) AND (sell_filled_price IS NULL))) AS max_buy_stop_price,
    min(date_created) FILTER (WHERE ((buy_filled_price IS NOT NULL) AND (sell_filled_price IS NULL))) AS min_date_created,
    max(date_created) FILTER (WHERE ((buy_filled_price IS NOT NULL) AND (sell_filled_price IS NULL))) AS max_date_created,
    sum(((buy_filled_price * shares) + COALESCE(buy_fee, (0)::double precision))) FILTER (WHERE ((buy_filled_price IS NOT NULL) AND (sell_filled_price IS NULL))) AS held_cost_filled,
    count(*) FILTER (WHERE (buy_filled_price IS NULL)) AS pending_cnt,
    sum(shares) FILTER (WHERE (buy_filled_price IS NULL)) AS pending_shares,
    sum((buy_price * shares)) FILTER (WHERE (buy_filled_price IS NULL)) AS pending_value,
    count(*) FILTER (WHERE (sell_filled_price IS NOT NULL)) AS sold_unclosed_cnt
   FROM public."position"
  GROUP BY stock_id, name, period_type;


--
-- Name: vw_position_order_balance_audit; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_position_order_balance_audit AS
 SELECT 'ghost_buy_order'::text AS issue_type,
    p.name,
    p.buy_coinbase_order_id AS order_id,
    NULL::text AS currency,
    NULL::double precision AS balance,
    (((('position '::text || p.position_id) || ' references buy order '::text) || p.buy_coinbase_order_id) || ' which is not in bulk_open_orders'::text) AS detail
   FROM public."position" p
  WHERE ((p.buy_coinbase_order_id IS NOT NULL) AND (p.buy_filled_price IS NULL) AND (NOT (EXISTS ( SELECT 1
           FROM public.bulk_open_orders o
          WHERE (o.order_id = p.buy_coinbase_order_id)))))
UNION ALL
 SELECT 'ghost_sell_order'::text AS issue_type,
    p.name,
    p.sell_coinbase_order_id AS order_id,
    NULL::text AS currency,
    NULL::double precision AS balance,
    (((('position '::text || p.position_id) || ' references sell order '::text) || p.sell_coinbase_order_id) || ' which is not in bulk_open_orders'::text) AS detail
   FROM public."position" p
  WHERE ((p.sell_coinbase_order_id IS NOT NULL) AND (p.sell_filled_price IS NULL) AND (NOT (EXISTS ( SELECT 1
           FROM public.bulk_open_orders o
          WHERE (o.order_id = p.sell_coinbase_order_id)))))
UNION ALL
 SELECT 'untracked_holding'::text AS issue_type,
    (bc.currency || '-USD'::text) AS name,
    NULL::text AS order_id,
    bc.currency,
    bc.balance,
    (((('bulk_currency shows '::text || bc.balance) || ' '::text) || bc.currency) || ' held with no matching open position'::text) AS detail
   FROM public.bulk_currency bc
  WHERE ((bc.currency <> ALL (ARRAY['USD'::text, 'USDC'::text])) AND (bc.balance > (0)::double precision) AND (NOT (EXISTS ( SELECT 1
           FROM public."position" p
          WHERE ((p.name = (bc.currency || '-USD'::text)) AND (p.buy_filled_price IS NOT NULL) AND (p.sell_filled_price IS NULL))))))
UNION ALL
 SELECT 'orphaned_coinbase_order'::text AS issue_type,
    o.product_id AS name,
    o.order_id,
    NULL::text AS currency,
    NULL::double precision AS balance,
    (((((('bulk_open_orders has '::text || o.side) || ' order '::text) || o.order_id) || ' for '::text) || o.product_id) || ' not referenced by any position or unfilled etf_buy'::text) AS detail
   FROM public.bulk_open_orders o
  WHERE ((NOT (EXISTS ( SELECT 1
           FROM public."position" p
          WHERE ((p.buy_coinbase_order_id = o.order_id) OR (p.sell_coinbase_order_id = o.order_id))))) AND (NOT (EXISTS ( SELECT 1
           FROM public.etf_buy e
          WHERE ((e.coinbase_order_id = o.order_id) AND (e.filled = false))))));


--
-- Name: vw_profit_summary; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_profit_summary AS
 SELECT period_type,
    count(*) AS total_trades,
    round((sum(profit))::numeric, 2) AS all_time_profit,
    round((avg(profit))::numeric, 2) AS all_time_avg,
    count(*) FILTER (WHERE ((date_created)::date = CURRENT_DATE)) AS today_trades,
    round((COALESCE(sum(profit) FILTER (WHERE ((date_created)::date = CURRENT_DATE)), (0)::double precision))::numeric, 2) AS today_profit,
    round((avg(profit) FILTER (WHERE ((date_created)::date = CURRENT_DATE)))::numeric, 2) AS today_avg,
    count(*) FILTER (WHERE (date_trunc('month'::text, date_created) = date_trunc('month'::text, now()))) AS month_trades,
    round((COALESCE(sum(profit) FILTER (WHERE (date_trunc('month'::text, date_created) = date_trunc('month'::text, now()))), (0)::double precision))::numeric, 2) AS month_profit,
    round((avg(profit) FILTER (WHERE (date_trunc('month'::text, date_created) = date_trunc('month'::text, now()))))::numeric, 2) AS month_avg,
    count(*) FILTER (WHERE (date_trunc('year'::text, date_created) = date_trunc('year'::text, now()))) AS year_trades,
    round((COALESCE(sum(profit) FILTER (WHERE (date_trunc('year'::text, date_created) = date_trunc('year'::text, now()))), (0)::double precision))::numeric, 2) AS year_profit,
    round((avg(profit) FILTER (WHERE (date_trunc('year'::text, date_created) = date_trunc('year'::text, now()))))::numeric, 2) AS year_avg
   FROM public.profit_history
  GROUP BY period_type
  ORDER BY period_type;


--
-- Name: vw_rsi; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_rsi AS
 WITH price_changes AS (
         SELECT price_aggregate.stock_id,
            price_aggregate.period_type,
            price_aggregate.period_date,
            price_aggregate.close,
            lag(price_aggregate.close) OVER (PARTITION BY price_aggregate.stock_id, price_aggregate.period_type ORDER BY price_aggregate.period_date) AS prev_close
           FROM public.price_aggregate
        ), gains_losses AS (
         SELECT price_changes.stock_id,
            price_changes.period_type,
            price_changes.period_date,
            GREATEST((price_changes.close - price_changes.prev_close), (0)::double precision) AS gain,
            GREATEST((price_changes.prev_close - price_changes.close), (0)::double precision) AS loss,
            row_number() OVER (PARTITION BY price_changes.stock_id, price_changes.period_type ORDER BY price_changes.period_date DESC) AS rn
           FROM price_changes
          WHERE (price_changes.prev_close IS NOT NULL)
        ), rsi_calc AS (
         SELECT gains_losses.stock_id,
            gains_losses.period_type,
            avg(gains_losses.gain) AS avg_gain,
            avg(gains_losses.loss) AS avg_loss
           FROM gains_losses
          WHERE (gains_losses.rn <= 14)
          GROUP BY gains_losses.stock_id, gains_losses.period_type
        )
 SELECT stock_id,
    period_type,
    round((
        CASE
            WHEN (avg_loss = (0)::double precision) THEN (100)::double precision
            ELSE ((100)::double precision - ((100.0)::double precision / ((1)::double precision + (avg_gain / avg_loss))))
        END)::numeric, 2) AS rsi
   FROM rsi_calc;


--
-- Name: vw_signal; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_signal AS
 SELECT s.name,
    s.stock_id,
    pa.period_type,
    pa.period_date,
    period_score.cnt AS period_count,
    period_score.prices,
    pa.open,
    pa.close,
    pa.high,
    pa.low,
    pa.avg_price,
    trunc((pat.avg_change_percent)::numeric, 2) AS historical_avg_change_percent,
    trunc((pat.std_dev)::numeric, 2) AS std_dev,
    trunc((pat.std_dev_upper_bound)::numeric, 2) AS std_dev_upper_bound,
    trunc((pat.std_dev_lower_bound)::numeric, 2) AS std_dev_lower_bound,
    trunc((pac.change_percent)::numeric, 2) AS current_change_percent,
    trunc((((pac.change_percent - pat.avg_change_percent) / NULLIF(pat.std_dev, (0)::double precision)))::numeric, 2) AS signal,
    trunc(((((period_score.cnt)::double precision * pat.avg_change_percent) / NULLIF(pat.std_dev, (0)::double precision)))::numeric, 2) AS score,
    trunc((((((period_score.cnt)::double precision * pat.avg_change_percent) / NULLIF(pat.std_dev, (0)::double precision)) * abs(((pac.change_percent - pat.avg_change_percent) / NULLIF(pat.std_dev, (0)::double precision)))))::numeric, 2) AS priority,
        CASE
            WHEN (((pac.change_percent - pat.avg_change_percent) / NULLIF(pat.std_dev, (0)::double precision)) < (0)::double precision) THEN 'BUY'::text
            WHEN (((pac.change_percent - pat.avg_change_percent) / NULLIF(pat.std_dev, (0)::double precision)) > (0)::double precision) THEN 'SELL'::text
            ELSE 'HOLD'::text
        END AS recommendation
   FROM ((((public.price_aggregate pa
     JOIN public.price_aggregate_comparison pac ON ((pa.price_aggregate_id = pac.after_id)))
     JOIN public.stock s ON ((s.stock_id = pa.stock_id)))
     JOIN public.price_aggregate_total pat ON (((pa.stock_id = pat.stock_id) AND (pa.period_type = pat.period_type))))
     JOIN ( SELECT price_aggregate.stock_id,
            price_aggregate.period_type,
            count(1) AS cnt,
            string_agg((trunc((price_aggregate.close)::numeric, 2))::text, ','::text ORDER BY price_aggregate.period_date) AS prices
           FROM public.price_aggregate
          GROUP BY price_aggregate.stock_id, price_aggregate.period_type) period_score ON (((pa.stock_id = period_score.stock_id) AND (pa.period_type = period_score.period_type))))
  WHERE (((pa.period_type = 'day'::text) AND (pa.period_date = (now())::date)) OR ((pa.period_type = 'month'::text) AND (pa.period_date = (date_trunc('month'::text, now()))::date)) OR ((pa.period_type = 'year'::text) AND (pa.period_date = (date_trunc('year'::text, now()))::date)))
  ORDER BY pa.period_type DESC, (trunc((((((period_score.cnt)::double precision * pat.avg_change_percent) / NULLIF(pat.std_dev, (0)::double precision)) * abs(((pac.change_percent - pat.avg_change_percent) / NULLIF(pat.std_dev, (0)::double precision)))))::numeric, 2)) DESC NULLS LAST;


--
-- Name: vw_usdc_sweep_reserve; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_usdc_sweep_reserve AS
 SELECT
        CASE
            WHEN (COALESCE(( SELECT config.value
               FROM public.config
              WHERE (config.key = 'usdc_sweep_enabled'::text)), 'true'::text) = 'true'::text) THEN COALESCE(( SELECT sum(profit_history.profit_converted_usdc) AS sum
               FROM public.profit_history
              WHERE ((profit_history.profit_converted_usdc > (0)::numeric) AND (profit_history.usdc_convert_status IS DISTINCT FROM 'completed'::text))), (0)::numeric)
            ELSE (0)::numeric
        END AS reserve_usd;


--
-- Name: VIEW vw_usdc_sweep_reserve; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.vw_usdc_sweep_reserve IS 'Unswept realized profit (USD) queued for the USDC sweep (usdc_convert_status not completed). Subtracted from free USD by thee_procedure buy gates and the index.js ETF plan. 0 when config.usdc_sweep_enabled <> true.';


--
-- Name: bulk_currency bulk_currency_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_currency ALTER COLUMN bulk_currency_id SET DEFAULT nextval('public.bulk_currency_bulk_currency_id_seq'::regclass);


--
-- Name: bulk_fills bulk_fills_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_fills ALTER COLUMN bulk_fills_id SET DEFAULT nextval('public.bulk_fills_bulk_fills_id_seq'::regclass);


--
-- Name: bulk_open_orders bulk_open_orders_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_open_orders ALTER COLUMN bulk_open_orders_id SET DEFAULT nextval('public.bulk_open_orders_bulk_open_orders_id_seq'::regclass);


--
-- Name: bulk_stock bulk_stock_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_stock ALTER COLUMN bulk_stock_id SET DEFAULT nextval('public.bulk_stock_bulk_stock_id_seq'::regclass);


--
-- Name: fills fill_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fills ALTER COLUMN fill_id SET DEFAULT nextval('public.fills_fill_id_seq'::regclass);


--
-- Name: position position_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."position" ALTER COLUMN position_id SET DEFAULT nextval('public.position_position_id_seq'::regclass);


--
-- Name: position_audit audit_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.position_audit ALTER COLUMN audit_id SET DEFAULT nextval('public.position_audit_audit_id_seq'::regclass);


--
-- Name: price_aggregate price_aggregate_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_aggregate ALTER COLUMN price_aggregate_id SET DEFAULT nextval('public.price_aggregates_price_aggregate_id_seq'::regclass);


--
-- Name: profit_history profit_history_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profit_history ALTER COLUMN profit_history_id SET DEFAULT nextval('public.profit_history_profit_history_id_seq'::regclass);


--
-- Name: unmatched_fills unmatched_fill_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unmatched_fills ALTER COLUMN unmatched_fill_id SET DEFAULT nextval('public.unmatched_fills_unmatched_fill_id_seq'::regclass);


--
-- Name: stock Stock_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock
    ADD CONSTRAINT "Stock_pkey" PRIMARY KEY (stock_id);


--
-- Name: account account_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_pkey PRIMARY KEY (account_id);


--
-- Name: book_snapshot book_snapshot_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.book_snapshot
    ADD CONSTRAINT book_snapshot_pkey PRIMARY KEY (book_snapshot_id);


--
-- Name: bulk_best_bid_ask bulk_best_bid_ask_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_best_bid_ask
    ADD CONSTRAINT bulk_best_bid_ask_pkey PRIMARY KEY (product_id);


--
-- Name: bulk_currency bulk_currency_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_currency
    ADD CONSTRAINT bulk_currency_pkey PRIMARY KEY (bulk_currency_id);


--
-- Name: bulk_fills bulk_fills_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_fills
    ADD CONSTRAINT bulk_fills_pkey PRIMARY KEY (bulk_fills_id);


--
-- Name: bulk_open_orders bulk_open_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_open_orders
    ADD CONSTRAINT bulk_open_orders_pkey PRIMARY KEY (bulk_open_orders_id);


--
-- Name: bulk_stock bulk_stock_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_stock
    ADD CONSTRAINT bulk_stock_pkey PRIMARY KEY (bulk_stock_id);


--
-- Name: config config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.config
    ADD CONSTRAINT config_pkey PRIMARY KEY (key);


--
-- Name: etf_buy etf_buy_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.etf_buy
    ADD CONSTRAINT etf_buy_pkey PRIMARY KEY (etf_buy_id);


--
-- Name: etf etf_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.etf
    ADD CONSTRAINT etf_pkey PRIMARY KEY (ticker);


--
-- Name: fills fills_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fills
    ADD CONSTRAINT fills_pkey PRIMARY KEY (fill_id);


--
-- Name: listing_watch listing_watch_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.listing_watch
    ADD CONSTRAINT listing_watch_pkey PRIMARY KEY (product_id);


--
-- Name: portfolio portfolio_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.portfolio
    ADD CONSTRAINT portfolio_pkey PRIMARY KEY (portfolio_id);


--
-- Name: position_audit position_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.position_audit
    ADD CONSTRAINT position_audit_pkey PRIMARY KEY (audit_id);


--
-- Name: position position_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."position"
    ADD CONSTRAINT position_pkey PRIMARY KEY (position_id);


--
-- Name: price_aggregate_comparison price_aggregate_comparison_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_aggregate_comparison
    ADD CONSTRAINT price_aggregate_comparison_pkey PRIMARY KEY (price_aggregate_comparison_id);


--
-- Name: price_aggregate_total price_aggregate_total_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_aggregate_total
    ADD CONSTRAINT price_aggregate_total_pkey PRIMARY KEY (price_aggregate_total_id);


--
-- Name: price_aggregate price_aggregates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_aggregate
    ADD CONSTRAINT price_aggregates_pkey PRIMARY KEY (price_aggregate_id);


--
-- Name: price_history price_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_history
    ADD CONSTRAINT price_history_pkey PRIMARY KEY (price_history_id);


--
-- Name: profit_history profit_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profit_history
    ADD CONSTRAINT profit_history_pkey PRIMARY KEY (profit_history_id);


--
-- Name: unmatched_fills unmatched_fills_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unmatched_fills
    ADD CONSTRAINT unmatched_fills_pkey PRIMARY KEY (unmatched_fill_id);


--
-- Name: usd_transfer usd_transfer_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usd_transfer
    ADD CONSTRAINT usd_transfer_pkey PRIMARY KEY (id);


--
-- Name: usd_transfer usd_transfer_type_amount_date_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usd_transfer
    ADD CONSTRAINT usd_transfer_type_amount_date_key UNIQUE (type, amount, date);


--
-- Name: book_snapshot_name_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX book_snapshot_name_created_idx ON public.book_snapshot USING btree (name, date_created DESC);


--
-- Name: etf_buy_filled_day_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX etf_buy_filled_day_idx ON public.etf_buy USING btree (ticker, chicago_date) WHERE filled;


--
-- Name: etf_buy_one_open_limit_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX etf_buy_one_open_limit_idx ON public.etf_buy USING btree (ticker) WHERE ((order_type = 'limit'::text) AND (status = ANY (ARRAY['PLACING'::text, 'OPEN'::text])));


--
-- Name: idx_fills_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fills_order_id ON public.fills USING btree (order_id);


--
-- Name: idx_fills_trade_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_fills_trade_id ON public.fills USING btree (trade_id);


--
-- Name: idx_position_audit_changed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_position_audit_changed_at ON public.position_audit USING btree (changed_at);


--
-- Name: idx_position_audit_column_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_position_audit_column_name ON public.position_audit USING btree (column_name);


--
-- Name: idx_position_audit_position_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_position_audit_position_id ON public.position_audit USING btree (position_id);


--
-- Name: idx_unmatched_fills_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_unmatched_fills_order_id ON public.unmatched_fills USING btree (order_id);


--
-- Name: position_one_listing_per_stock; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX position_one_listing_per_stock ON public."position" USING btree (stock_id) WHERE (period_type = 'listing'::text);


--
-- Name: profit_history_usdc_unswept; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profit_history_usdc_unswept ON public.profit_history USING btree (profit_history_id) WHERE ((profit_converted_usdc > (0)::numeric) AND (usdc_convert_status IS DISTINCT FROM 'completed'::text));


--
-- Name: position position_audit_trg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER position_audit_trg AFTER INSERT OR DELETE OR UPDATE ON public."position" FOR EACH ROW EXECUTE FUNCTION public.position_audit_trigger();


--
-- Name: etf_buy etf_buy_ticker_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.etf_buy
    ADD CONSTRAINT etf_buy_ticker_fkey FOREIGN KEY (ticker) REFERENCES public.etf(ticker);


--
-- PostgreSQL database dump complete
--

\unrestrict HRelLC2K2SyCeAgn8Z6IwrLZs8sfQxkIPF1O1XCc5Dh5Ew0LqeHdWcza7T4E6Jc

