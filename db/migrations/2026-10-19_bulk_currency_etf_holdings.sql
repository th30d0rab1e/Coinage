-- 2026-10-19 (Theodore): ETF holdings saved in bulk_currency each minute by
-- index.js buildEtfPlan() -> db.insertEtfHoldings(). value_usd = dollar
-- value, run_at = run time; run_at IS NOT NULL marks an ETF row. No new table.
ALTER TABLE public.bulk_currency ADD COLUMN IF NOT EXISTS value_usd double precision;
ALTER TABLE public.bulk_currency ADD COLUMN IF NOT EXISTS run_at timestamp with time zone;
