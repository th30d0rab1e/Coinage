-- 2026-10-07 (migrations/2026-10-07_usdc_profit_sweep.sql): dollars of
-- realized profit that are still in USD waiting to be swept to USDC.
--
-- thee_procedure subtracts this from free USD in every buy gate (next to
-- vw_etf_cash_reserve), and index.js subtracts it from the ETF plan's cash,
-- so the bot never spends profit that is queued for USDC. Includes rows of a
-- sweep that is still pending/submitted (they keep usdc_convert_id NULL
-- until Coinbase confirms), so the reserve only drops once the USD has
-- actually left.
--
-- Honors the kill switch: with usdc_sweep_enabled <> 'true' nothing is being
-- swept, so nothing is held back (0) and the bot can trade that cash. If the
-- switch is turned back on, every unswept row since then is swept at once.
CREATE OR REPLACE VIEW public.vw_usdc_sweep_reserve AS
SELECT CASE
           WHEN COALESCE((SELECT value FROM config WHERE key = 'usdc_sweep_enabled'), 'true') = 'true'
           THEN COALESCE((
                    SELECT SUM(profit_converted_usdc)
                    FROM profit_history
                    WHERE usdc_convert_id IS NULL
                    AND profit_converted_usdc > 0
                ), 0)
           ELSE 0
       END::numeric AS reserve_usd;

COMMENT ON VIEW public.vw_usdc_sweep_reserve IS
    'Unswept realized profit (USD) queued for the USDC sweep. Subtracted from free USD by thee_procedure buy gates and the index.js ETF plan. 0 when config.usdc_sweep_enabled <> true.';
