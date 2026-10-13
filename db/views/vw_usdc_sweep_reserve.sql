-- 2026-10-07 (migrations/2026-10-07_usdc_profit_sweep.sql): dollars of
-- realized profit that are still in USD waiting to be swept to USDC, i.e.
-- profit_history rows with profit_converted_usdc > 0 whose
-- usdc_convert_status is NULL, 'pending' or 'failed' (anything but
-- 'completed'). Pending rows count until Coinbase confirms, so the reserve
-- only drops once the USD has actually left.
--
-- thee_procedure subtracts this from free USD in every buy gate (next to
-- vw_etf_cash_reserve), and index.js subtracts it from the ETF plan's cash,
-- so the bot never spends profit that is queued for USDC.
--
-- Honors the kill switch: with usdc_sweep_enabled <> 'true' nothing is being
-- swept, so nothing is held back (0) and the bot can trade that cash. If the
-- switch is turned back on, every unswept row since then is swept at once.
CREATE OR REPLACE VIEW public.vw_usdc_sweep_reserve AS
-- 2026-10-13 (Theodore): only reserve queued USDC-sweep profit once it reaches usdc_sweep_min_usd (the sweep threshold); below that it stays spendable.
WITH cfg AS (
    SELECT MAX(value) FILTER (WHERE key = 'usdc_sweep_enabled') AS sweep_enabled,
           MAX(value) FILTER (WHERE key = 'usdc_sweep_min_usd') AS sweep_min_usd
    FROM config
), q AS (
    SELECT COALESCE(SUM(profit_converted_usdc), 0) AS queued_usd
    FROM profit_history
    WHERE profit_converted_usdc > 0
    AND usdc_convert_status IS DISTINCT FROM 'completed'
)
SELECT CASE
           WHEN COALESCE(cfg.sweep_enabled, 'true') = 'true'
           AND q.queued_usd >= COALESCE(cfg.sweep_min_usd::numeric, 1.00)
           THEN q.queued_usd
           ELSE 0
       END::numeric AS reserve_usd
FROM cfg, q;

COMMENT ON VIEW public.vw_usdc_sweep_reserve IS
    'Unswept realized profit (USD) queued for the USDC sweep (usdc_convert_status not completed). Subtracted from free USD by thee_procedure buy gates and the index.js ETF plan. 0 when config.usdc_sweep_enabled <> true or the queued total is below config.usdc_sweep_min_usd.';
