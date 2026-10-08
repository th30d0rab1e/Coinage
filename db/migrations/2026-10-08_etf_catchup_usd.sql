-- 2026-10-08: ETF catch-up sizing (Theodore, approved).
-- config.etf_catchup_usd = 2: dollars per buy (daily market buy and resting
-- limit) for any ENABLED etf whose total filled dollars invested
-- (SUM(etf_buy.quote_usd) WHERE filled, manual rows included) is below the
-- average across enabled ETFs. ETFs at or above the average keep
-- etf.quote_usd ($1). Recomputed every run by db/views/vw_etf_buy_usd.sql,
-- which index.js buildEtfPlan() reads; the plan's notional is what
-- config.etf_usd_reserve / vw_etf_cash_reserve reserve. USDC-first funding
-- is unchanged. Undo: DELETE the row and drop the view join in index.js
-- (or set the value to 1 to turn catch-up off without a code change).
BEGIN;

INSERT INTO public.config (key, value) VALUES ('etf_catchup_usd', '2')
ON CONFLICT (key) DO NOTHING;

\ir ../views/vw_etf_buy_usd.sql

COMMIT;
