--
-- PostgreSQL database dump
--

\restrict MWA57IKz1wwc2Pr1v10ZQieeCRB2nvL6D56Z6V60EqhgknriWcponk0XHDLYRgK

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
AND GREATEST(p.date_created, p.last_remade_at, p.buy_placed_at, p.buy_released_at)
    < NOW() - make_interval(hours => COALESCE((SELECT value::int FROM config WHERE key = 'pending_buy_ttl_hours'), 24))
AND NOT EXISTS (
    SELECT 1 FROM bulk_open_orders o WHERE o.client_order_id = p.buy_order_id
);

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
    TRUNC((s.close::numeric * gap.stop_mult * 1.01), stock.price_rounding::integer) AS buy_price,
    TRUNC((s.close::numeric * gap.stop_mult),        stock.price_rounding::integer) AS buy_stop_price,
    TRUNC((
        (
            SELECT COUNT(*)::numeric
            FROM position open_sz
            WHERE open_sz.stock_id = s.stock_id
            AND open_sz.period_type = 'day'
            AND open_sz.buy_order_id IS NOT NULL
            AND open_sz.sell_filled_price IS NULL
        ) + 1
    ) / s.close::numeric, stock.share_rounding::integer) AS shares,
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
LEFT JOIN LATERAL (
    SELECT bs.imbalance
    FROM book_snapshot bs
    WHERE bs.name = s.name
    ORDER BY bs.date_created DESC
    LIMIT 1
) book ON TRUE
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
    - COALESCE((SELECT SUM(pb.shares * pb.buy_price)::numeric
                FROM position pb JOIN stock sb ON sb.stock_id = pb.stock_id
                WHERE pb.buy_coinbase_order_id IS NULL
                AND pb.buy_filled_price IS NULL
                AND sb.trading_disabled IS NOT TRUE), 0)
  > (
    SELECT COUNT(*)::numeric
    FROM position open_sz
    WHERE open_sz.stock_id = s.stock_id
    AND open_sz.period_type = 'day'
    AND open_sz.buy_order_id IS NOT NULL
    AND open_sz.sell_filled_price IS NULL
) + 1
AND s.period_type = 'year'
AND p.buy_order_id IS NULL
AND s.historical_avg_change_percent > 0
AND d.current_change_percent < d.historical_avg_change_percent
AND stock.trading_disabled IS NOT TRUE
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
-- Book gate: do not insert a new/add day buy when the latest L2 snapshot is
-- ask-heavy. Prefer bid-heavy (+0.2) via ORDER BY below. NULL snapshot = allow.
AND (book.imbalance IS NULL OR book.imbalance > -0.4)
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
    TRUNC(s.price::numeric * 1.011, s.price_rounding::integer) AS buy_price,
    TRUNC(s.price::numeric * 1.01,  s.price_rounding::integer) AS buy_stop_price,
    TRUNC((sized.clip_usd / s.price::numeric), s.share_rounding::integer) AS shares,
    NOW() AS date_created,
    gen_random_uuid(),
    sized.period_type
FROM sized
JOIN stock s ON s.stock_id = sized.stock_id
CROSS JOIN vw_balance b
LEFT JOIN LATERAL (
    SELECT bs.imbalance
    FROM book_snapshot bs
    WHERE bs.name = s.name
    ORDER BY bs.date_created DESC
    LIMIT 1
) book ON TRUE
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
    - COALESCE((SELECT SUM(pb.shares * pb.buy_price)::numeric
                FROM position pb JOIN stock sb ON sb.stock_id = pb.stock_id
                WHERE pb.buy_coinbase_order_id IS NULL
                AND pb.buy_filled_price IS NULL
                AND sb.trading_disabled IS NOT TRUE), 0)
  > sized.clip_usd
AND (SELECT value FROM config WHERE key = 'pause_buys') = 'false'
AND TRUNC(s.price::numeric * 1.011, s.price_rounding::integer) < sized.last_filled_price
AND s.trading_disabled IS NOT TRUE
AND NOT EXISTS (
    SELECT 1 FROM position existing
    WHERE existing.stock_id = sized.stock_id
    AND existing.period_type = sized.period_type
    AND existing.buy_order_id IS NOT NULL
    AND existing.buy_filled_price IS NULL
)
AND (book.imbalance IS NULL OR book.imbalance > -0.4)
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
AND p.buy_stop_price::numeric > c.min_fill * cap.ratio;

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
    trading_disabled boolean
);


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
    "json" json
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

COMMENT ON COLUMN public.etf.is_special IS 'True for BLOX, CHPY, TOPW, TSLW (special repeat and end-of-session catch-up). False for regulars such as XDTE, which need a 1% dip and only one attempt per minute.';


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
    fill_price numeric
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
    creation_hierarchy integer
);


--
-- Name: COLUMN "position".creation_hierarchy; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public."position".creation_hierarchy IS 'Per-coin sequence of open positions with sell_price set (1 = cheapest fill); NULL when sell_price IS NULL. Order: buy_filled_price ASC NULLS LAST, then buy_stop_price ASC NULLS LAST, then position_id. Recomputed every run by thee_procedure.';


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
    date_created timestamp without time zone DEFAULT now()
);


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
  WHERE ((p.buy_coinbase_order_id IS NOT NULL) AND (p.buy_filled_price IS NULL) AND (p.buy_stop_price > (trunc(((s.price)::numeric * bal.stop_mult), s.price_rounding))::double precision) AND (p.buy_price > (trunc((((s.price)::numeric * bal.stop_mult) * 1.01), s.price_rounding))::double precision))
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

COMMENT ON VIEW public.vw_etf_cash_reserve IS 'Default USD index.js reserved for this run''s ETF attempts. thee_procedure subtracts it from crypto buy plans. 0 when the equity session is closed or nothing qualifies.';


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
    (((((('bulk_open_orders has '::text || o.side) || ' order '::text) || o.order_id) || ' for '::text) || o.product_id) || ' not referenced by any position'::text) AS detail
   FROM public.bulk_open_orders o
  WHERE (NOT (EXISTS ( SELECT 1
           FROM public."position" p
          WHERE ((p.buy_coinbase_order_id = o.order_id) OR (p.sell_coinbase_order_id = o.order_id)))));


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
-- Name: book_snapshot_name_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX book_snapshot_name_created_idx ON public.book_snapshot USING btree (name, date_created DESC);


--
-- Name: etf_buy_filled_day_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX etf_buy_filled_day_idx ON public.etf_buy USING btree (ticker, chicago_date) WHERE filled;


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

\unrestrict MWA57IKz1wwc2Pr1v10ZQieeCRB2nvL6D56Z6V60EqhgknriWcponk0XHDLYRgK

