-- Coinage: missed post-sell upside analysis
-- Run on Mini: psql -U theodorecross -d coinbase -f coinage_left_on_table_analysis.sql
-- Or: cd "/Volumes/2TBSSD/theodorecrossX/Coinbase tedTosterone" && node -e '...' using modules/database.js
--
-- METHOD:
--   Closes: profit_history (last 7 CT days, or last 30 rows)
--   Fill/shares: position_audit DELETE snapshot (preferred) OR fills by order_id
--   Post-sell max: price_history ticks (kept ~25h) then price_aggregate day high as fallback
--   Missed USD: shares * (post_sell_max - sell_filled_price) when max > sell

\pset pager off

-- 0) Granularity sanity
SELECT 'price_history_span' AS k,
       MIN(date_created) AS min_ts, MAX(date_created) AS max_ts, COUNT(*) AS n
FROM price_history
UNION ALL
SELECT 'price_aggregate_day', MIN(period_date)::timestamp, MAX(period_date)::timestamp, COUNT(*)
FROM price_aggregate WHERE period_type = 'day';

-- 1) Recent closes with fill snapshot from position_audit DELETE
WITH closes AS (
  SELECT
    ph.profit_history_id,
    ph.name,
    ph.buy_coinbase_order_id,
    ph.sell_fills_id AS sell_order_id,
    ph.buy_fee,
    ph.sell_fee,
    ph.profit AS booked_profit,
    ph.date_created AS sell_ts,
    (pa.old_value::jsonb ->> 'shares')::float8 AS shares,
    (pa.old_value::jsonb ->> 'buy_filled_price')::float8 AS buy_filled_price,
    (pa.old_value::jsonb ->> 'sell_filled_price')::float8 AS sell_filled_price
  FROM profit_history ph
  LEFT JOIN LATERAL (
    SELECT old_value
    FROM position_audit pa
    WHERE pa.operation = 'DELETE'
      AND (pa.old_value::jsonb ->> 'buy_coinbase_order_id') = ph.buy_coinbase_order_id
      AND (pa.old_value::jsonb ->> 'sell_coinbase_order_id') = ph.sell_fills_id
    ORDER BY pa.changed_at DESC
    LIMIT 1
  ) pa ON TRUE
  WHERE ph.date_created::date >= (NOW() AT TIME ZONE 'America/Chicago')::date - 6
  ORDER BY ph.date_created DESC
  LIMIT 30
),
-- fallback shares/prices from fills ledger when audit missing
fills_agg AS (
  SELECT c.profit_history_id,
         COALESCE(c.shares, sf.size) AS shares,
         COALESCE(c.buy_filled_price, bf.price) AS buy_filled_price,
         COALESCE(c.sell_filled_price, sf.price) AS sell_filled_price
  FROM closes c
  LEFT JOIN LATERAL (
    SELECT price, size FROM fills
    WHERE order_id = c.sell_order_id AND side ILIKE 'sell'
    ORDER BY trade_time DESC NULLS LAST LIMIT 1
  ) sf ON TRUE
  LEFT JOIN LATERAL (
    SELECT price FROM fills
    WHERE order_id = c.buy_coinbase_order_id AND side ILIKE 'buy'
    ORDER BY trade_time DESC NULLS LAST LIMIT 1
  ) bf ON TRUE
),
enriched AS (
  SELECT c.*, f.shares AS sh, f.buy_filled_price AS buy_px, f.sell_filled_price AS sell_px,
         s.stock_id
  FROM closes c
  JOIN fills_agg f USING (profit_history_id)
  LEFT JOIN stock s ON s.name = c.name
),
post AS (
  SELECT e.*,
    (SELECT MAX(ph.price) FROM price_history ph
      WHERE ph.stock_id = e.stock_id AND ph.date_created > e.sell_ts) AS max_after_tick,
    (SELECT MAX(ph.price) FROM price_history ph
      WHERE ph.stock_id = e.stock_id
        AND ph.date_created > e.sell_ts
        AND ph.date_created <= e.sell_ts + INTERVAL '1 hour') AS max_1h,
    (SELECT MAX(ph.price) FROM price_history ph
      WHERE ph.stock_id = e.stock_id
        AND ph.date_created > e.sell_ts
        AND ph.date_created <= e.sell_ts + INTERVAL '4 hours') AS max_4h,
    (SELECT MAX(ph.price) FROM price_history ph
      WHERE ph.stock_id = e.stock_id
        AND ph.date_created > e.sell_ts
        AND ph.date_created <= e.sell_ts + INTERVAL '24 hours') AS max_24h_tick,
    (SELECT MAX(pa.high) FROM price_aggregate pa
      WHERE pa.stock_id = e.stock_id AND pa.period_type = 'day'
        AND pa.period_date >= e.sell_ts::date
        AND pa.period_date <= (e.sell_ts + INTERVAL '1 day')::date) AS day_high_near
  FROM enriched e
)
SELECT
  name,
  ROUND(sh::numeric, 6) AS shares,
  ROUND(buy_px::numeric, 8) AS buy_filled,
  ROUND(sell_px::numeric, 8) AS sell_filled,
  ROUND(buy_fee::numeric, 4) AS buy_fee,
  ROUND(sell_fee::numeric, 4) AS sell_fee,
  ROUND(booked_profit::numeric, 4) AS booked_profit,
  sell_ts,
  ROUND(max_after_tick::numeric, 8) AS max_after_tick,
  ROUND(max_1h::numeric, 8) AS max_1h,
  ROUND(max_4h::numeric, 8) AS max_4h,
  ROUND(max_24h_tick::numeric, 8) AS max_24h_tick,
  ROUND(day_high_near::numeric, 8) AS day_high_near,
  ROUND((CASE WHEN max_after_tick > sell_px
         THEN sh * (max_after_tick - sell_px) ELSE 0 END)::numeric, 4) AS missed_usd_tick,
  ROUND((CASE WHEN max_1h > sell_px
         THEN sh * (max_1h - sell_px) ELSE 0 END)::numeric, 4) AS missed_usd_1h,
  ROUND((CASE WHEN max_4h > sell_px
         THEN sh * (max_4h - sell_px) ELSE 0 END)::numeric, 4) AS missed_usd_4h,
  CASE
    WHEN sell_px IS NULL THEN 'no_sell_px'
    WHEN max_after_tick IS NULL AND day_high_near IS NULL THEN 'no_price_data'
    WHEN max_after_tick IS NULL THEN 'tick_gap_use_day_agg'
    WHEN max_after_tick <= sell_px THEN 'good_exit_fell_or_flat'
    WHEN booked_profit <= 0.02 AND (max_after_tick - sell_px)/NULLIF(sell_px,0) < 0.01 THEN 'fee_floor_scrape'
    WHEN (max_after_tick - sell_px)/NULLIF(sell_px,0) >= 0.05 THEN 'missed_runner'
    ELSE 'left_some_on_table'
  END AS verdict
FROM post
ORDER BY sell_ts DESC;

-- 2) Summary
WITH closes AS (
  SELECT ph.*, (pa.old_value::jsonb ->> 'shares')::float8 AS shares,
         (pa.old_value::jsonb ->> 'sell_filled_price')::float8 AS sell_px
  FROM profit_history ph
  LEFT JOIN LATERAL (
    SELECT old_value FROM position_audit pa
    WHERE pa.operation = 'DELETE'
      AND (pa.old_value::jsonb ->> 'buy_coinbase_order_id') = ph.buy_coinbase_order_id
      AND (pa.old_value::jsonb ->> 'sell_coinbase_order_id') = ph.sell_fills_id
    ORDER BY pa.changed_at DESC LIMIT 1
  ) pa ON TRUE
  WHERE ph.date_created::date >= (NOW() AT TIME ZONE 'America/Chicago')::date - 6
),
post AS (
  SELECT c.*, s.stock_id,
    (SELECT MAX(price) FROM price_history ph
      WHERE ph.stock_id = s.stock_id AND ph.date_created > c.date_created) AS max_after
  FROM closes c
  LEFT JOIN stock s ON s.name = c.name
)
SELECT
  COUNT(*) AS closes,
  COUNT(*) FILTER (WHERE profit IS NOT NULL AND profit <= 0.02) AS near_zero_profit,
  COUNT(*) FILTER (WHERE max_after IS NOT NULL AND max_after > sell_px) AS rose_after_sell,
  COUNT(*) FILTER (WHERE max_after IS NOT NULL AND max_after <= sell_px) AS fell_or_flat_after,
  COUNT(*) FILTER (WHERE max_after IS NULL) AS no_tick_after,
  ROUND(COALESCE(SUM(CASE WHEN max_after > sell_px THEN shares*(max_after-sell_px) END),0)::numeric, 4) AS total_missed_usd_tick,
  ROUND(COALESCE(SUM(profit),0)::numeric, 4) AS total_booked_profit
FROM post;
