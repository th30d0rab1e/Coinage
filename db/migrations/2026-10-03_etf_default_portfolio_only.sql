-- 2026-10-03: ETF dollars are not reserved from the crypto portfolio.
-- Default (equity key) funds the $1 buys. If it is short, the buy is skipped.
-- Replaces vw_etf_cash_reserve so it can no longer subtract from crypto plans.
-- Crypto does not reserve cash for equity ETFs. The $1 buys (BLOX, TSLW,
-- TOPW, CHPY) spend only available USD in the Default portfolio, and only
-- while the equity session is open. If Default is short, that buy is skipped.
-- This view stays 0 so a crypto planner cannot hold USD back for ETFs,
-- whether the session is open or closed. No transfer from tedTosterone.
CREATE OR REPLACE VIEW public.vw_etf_cash_reserve AS
SELECT 0::numeric AS reserve_usd;

COMMENT ON VIEW public.vw_etf_cash_reserve IS
    'Always 0. ETF buys spend Default portfolio USD only and never reserve or transfer crypto cash.';
