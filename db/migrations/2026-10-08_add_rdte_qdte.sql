-- 2026-10-08: add RDTE (Roundhill Russell 2000 0DTE Covered Call Strategy
-- ETF) and QDTE (Roundhill Nasdaq-100 0DTE Covered Call Strategy ETF) to
-- the ETF buys (Theodore: "can you rdte and qdte?"). Configured exactly like
-- the other enabled ETFs: enabled, quote_usd $1, is_special = true, and the
-- USDC product id set so they buy with USDC first (USD fallback per
-- config.etf_usdc_fallback_usd), like BLOX / CHPY / TSLW / XDTE / YBTC.
--
-- Verified 2026-10-08 with GET /api/v3/brokerage/products?product_type=EQUITY
-- (full scan, matched on the alias field) and GET /api/v3/brokerage/products/{id}
-- per id, plus the bot's own equityProduct() check (blocked = null on all four):
--   RDTE  USD  662f356e... (alias '')       USDC 125da21f... (alias = USD id)
--   QDTE  USD  91808512... (alias '')       USDC 77467ffc... (alias = USD id)
-- All four: EQUITY ETF, trading_disabled / is_disabled / view_only /
-- cancel_only false, liquidate_only false (AAPW was true), fractionable true
-- (GLDW was false), trading_halted false, base_increment 0.00001,
-- fractional_notional_min_size $1 -- so $1-2 fractional buys work.
--
-- Sizing note: vw_etf_buy_usd gives any enabled ETF below the average filled
-- dollars invested config.etf_catchup_usd ($2) per buy, so both start at $2
-- per buy (they begin at $0 invested) until they catch up to the average.
-- No code change: modules/alpacaMarketData.js syncs every enabled ticker's
-- price (inserting the stock row on first sight) and index.js buildEtfPlan
-- reads enabled etf rows.
BEGIN;

INSERT INTO public.etf (ticker, product_id, quote_usd, enabled, is_special, usdc_product_id)
VALUES
    ('RDTE', '662f356ecdab4fab53952f5e4f46263d15d08fe00fe6bfbdc5118360f230eae9', 1, true, true,
             '125da21f00a1fb61559c2bf5ee66fc4d5549ec856064749322b08fcbf6b94c7d'),
    ('QDTE', '918085127215e15e90a7b264b0e0344e8773f73c154c0eab706e2a02eb224bf7', 1, true, true,
             '77467ffc46962d9d229fe6a8daf265b73cbf7b1f001adb2a11fe514610c78988')
ON CONFLICT (ticker) DO UPDATE
SET product_id      = EXCLUDED.product_id,
    quote_usd       = EXCLUDED.quote_usd,
    enabled         = EXCLUDED.enabled,
    is_special      = EXCLUDED.is_special,
    usdc_product_id = EXCLUDED.usdc_product_id;

COMMENT ON COLUMN public.etf.is_special IS
    'True for every ETF row (BLOX, CHPY, TOPW, TSLW, XDTE, SPCX, YBTC, RDTE, QDTE). XDTE became a special 2026-10-04; SPCX added 2026-10-05 (disabled 2026-10-07); YBTC 2026-10-06 (YETH skipped: liquidate_only); RDTE and QDTE 2026-10-08 (AAPW skipped: liquidate_only; GLDW skipped: not fractionable).';

COMMIT;
