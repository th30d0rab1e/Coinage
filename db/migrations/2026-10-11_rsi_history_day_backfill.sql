-- 2026-10-11: seed rsi_history with daily RSI so charts render a line immediately.
\i db/procedures/fn_backfill_rsi_history_days.sql
SELECT public.fn_backfill_rsi_history_days(90);
