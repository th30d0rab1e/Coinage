-- 2026-10-11 (Theodore, voice): snapshot USD and USDC totals on each
-- profit_history close so we can see cash on hand at the moment the
-- row was written (same totals Pushover already reports live).
--
-- Existing rows stay NULL — we have no historical balance log to
-- backfill from. New closes get both columns from vw_balance in
-- thee_procedure.

ALTER TABLE public.profit_history
    ADD COLUMN IF NOT EXISTS usd_balance  numeric,
    ADD COLUMN IF NOT EXISTS usdc_balance numeric;

COMMENT ON COLUMN public.profit_history.usd_balance IS
  'USD total (available + hold) from vw_balance at the moment this close was recorded. NULL on rows written before 2026-10-11.';

COMMENT ON COLUMN public.profit_history.usdc_balance IS
  'USDC total (available + hold) from vw_balance at the moment this close was recorded. NULL on rows written before 2026-10-11.';
