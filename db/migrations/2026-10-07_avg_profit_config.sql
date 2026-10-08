-- 2026-10-07: config.avg_profit -- the all-time average realized profit per
-- closed position, i.e. AVG(profit_history.profit) in dollars (~0.025 across
-- 1108 rows when added). Approved by Theodore.
--
-- Why: one stored, always-current number for "what does a typical closed
-- trade earn", so later rules can read config instead of recomputing it.
-- NOTHING reads it yet -- it is stored only.
--
-- Code: db/procedures/thee_procedure.sql refreshes it at the START of every
-- run (UPDATE config SET value = ... WHERE key = 'avg_profit'), so it
-- reflects profit_history as of the previous run. Stored as text like every
-- config value, rounded to 6 decimals; 0 when profit_history is empty.
--
-- This file only seeds the row (current average) if it is missing.
-- Undo: DELETE FROM config WHERE key = 'avg_profit'; (and remove the UPDATE
-- from thee_procedure).
BEGIN;

INSERT INTO public.config (key, value)
SELECT 'avg_profit', ROUND(COALESCE(AVG(profit), 0)::numeric, 6)::text
FROM public.profit_history
ON CONFLICT (key) DO NOTHING;

COMMIT;
