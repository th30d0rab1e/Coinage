-- Dollars index.js reserved this minute for ETF attempts (config.etf_usd_reserve).
--
-- Priority (2026-10-06 afternoon, kept 2026-10-07): 
--   1) new-listing snipe (period_type='listing') — index.js sets the reserve to 0
--      and skips ETF placement while any listing bag is open;
--   2) ETF buys (BLOX, CHPY, YBTC, TOPW, SPCX, TSLW, XDTE) during equity hours —
--      reserveEtfCash() writes the dollar total for this run's ETF plan into
--      config.etf_usd_reserve BEFORE thee_procedure runs;
--   3) regular crypto / add-on buys — thee_procedure subtracts reserve_usd from
--      free USD so those plans cannot spend cash the ETF ladder still needs.
--
-- Outside equity hours (or when nothing qualifies) index.js stores 0, so crypto
-- may use the cash. This view must read config — never hardcode 0 — or crypto
-- plans would ignore the reserve and outspend ETFs during the session.
CREATE OR REPLACE VIEW public.vw_etf_cash_reserve AS
SELECT COALESCE(
    (SELECT value::numeric FROM config WHERE key = 'etf_usd_reserve'),
    0::numeric
) AS reserve_usd;

COMMENT ON VIEW public.vw_etf_cash_reserve IS
    'Default USD index.js reserved for this run''s ETF attempts. thee_procedure subtracts it from crypto buy plans. 0 when the equity session is closed, a listing bag is open (listing is priority one), or nothing qualifies.';
