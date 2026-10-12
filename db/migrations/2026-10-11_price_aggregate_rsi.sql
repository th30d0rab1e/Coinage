-- 2026-10-11: RSI(14) on price_aggregate (Theodore, voice).
-- Column + Wilder function + one-time backfill. aggregate() keeps it current
-- every cycle (see db/procedures/aggregate.sql).
ALTER TABLE price_aggregate ADD COLUMN IF NOT EXISTS rsi numeric;

COMMENT ON COLUMN price_aggregate.rsi IS
    'Wilder RSI(14) from close, per (stock_id, period_type) series ordered by period_date. NULL until 15 closes exist in the series. Filled by aggregate() via fn_price_aggregate_rsi(14).';

\i db/procedures/fn_price_aggregate_rsi.sql
\i db/procedures/aggregate.sql

-- Backfill: every row that has enough history.
UPDATE price_aggregate pa
SET rsi = r.out_rsi
FROM fn_price_aggregate_rsi(14) r
WHERE pa.price_aggregate_id = r.out_price_aggregate_id;
