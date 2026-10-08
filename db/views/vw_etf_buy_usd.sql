-- 2026-10-08 ETF CATCH-UP SIZING (Theodore). One row per ENABLED etf with
-- the dollars to spend per buy this minute (buy_usd), recomputed fresh
-- every time it is read:
--   invested     = SUM(etf_buy.quote_usd) over FILLED rows, all order types,
--                  manual rows included (e.g. the XDTE $3.17 market row)
--   avg_invested = AVG(invested) across ENABLED etfs only (disabled ones,
--                  e.g. SPCX, neither count toward the average nor buy)
--   buy_usd      = config.etf_catchup_usd (default 2) when invested <
--                  avg_invested, else etf.quote_usd ($1)
-- So the ETFs that are behind get bigger buys until they reach the average.
-- Read by index.js buildEtfPlan() for BOTH the daily market buy and the
-- resting limit; the plan's notional feeds config.etf_usd_reserve, so
-- vw_etf_cash_reserve reserves the same (larger) amount. Funding is
-- unchanged (USDC first where etf.usdc_product_id is set, USD fallback).
CREATE OR REPLACE VIEW public.vw_etf_buy_usd AS
WITH inv AS (
    SELECT e.ticker,
           e.quote_usd,
           COALESCE(SUM(b.quote_usd) FILTER (WHERE b.filled), 0) AS invested
    FROM etf e
    LEFT JOIN etf_buy b ON b.ticker = e.ticker
    WHERE e.enabled
    GROUP BY e.ticker, e.quote_usd
),
avg_inv AS (
    SELECT AVG(invested) AS avg_invested FROM inv
)
SELECT inv.ticker,
       inv.invested,
       avg_inv.avg_invested,
       inv.invested < avg_inv.avg_invested AS catching_up,
       CASE WHEN inv.invested < avg_inv.avg_invested
            THEN COALESCE((SELECT value::numeric FROM config WHERE key = 'etf_catchup_usd'), 2)
            ELSE inv.quote_usd
       END AS buy_usd
FROM inv
CROSS JOIN avg_inv;

COMMENT ON VIEW public.vw_etf_buy_usd IS
    'Per-buy dollars for each enabled ETF: config.etf_catchup_usd (default 2) when its filled total invested is below the average across enabled ETFs, else etf.quote_usd. Read by index.js buildEtfPlan (market + limit sizing, and so the ETF USD reserve).';
