-- 2026-10-11 (Theodore, voice): capture stock.rsi over time for logging/charts.
-- Does not change buy selection.

\i db/tables/rsi_history.sql
\i db/procedures/fn_capture_rsi_history.sql

-- Hook after stock.rsi refresh inside aggregate().
\i db/procedures/aggregate.sql

-- Seed the first bucket from whatever stock.rsi already has.
SELECT public.fn_capture_rsi_history();
