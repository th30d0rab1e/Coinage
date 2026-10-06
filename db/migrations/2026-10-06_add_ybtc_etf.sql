-- Add YBTC (Roundhill Bitcoin Covered Call Strategy ETF) to the equity buy
-- list, configured exactly like SPCX and the other specials (BLOX, CHPY,
-- TOPW, TSLW, XDTE, SPCX): enabled, $1 quote_usd market buy,
-- is_special = true (same-minute repeat when price < last fill, plus the
-- 2:45 PM CT catch-up). Requested by the user 2026-10-06 ("add ybtc and
-- yeth").
--
-- product_id verified 2026-10-06 against GET /api/v3/brokerage/products
-- ?product_type=EQUITY and GET /api/v3/brokerage/products/{id}: ticker YBTC
-- has two ids. Same rule as the others: use the one with
-- quote_currency_id = USD and empty alias (4ca13a26...). The other
-- (c4f0ef73..., quote USDC) aliases to it and is not used. Product checked:
-- trading_disabled false, is_disabled false, view_only / cancel_only /
-- limit_only false, trading_halted false, liquidate_only false,
-- fractionable true, fractional_notional_min_size $1, subtype ETF.
-- Alpaca IEX snapshot returns a two-sided quote for YBTC.
--
-- YETH (Roundhill Ether Covered Call Strategy ETF) was requested too but is
-- deliberately NOT added: its USD product (d8b6aa98...) is
-- liquidate_only = true and fractionable = false on Coinbase, so a $1 buy
-- can never be placed (sell-only, whole shares). Re-check later and add it
-- with the same INSERT if Coinbase lifts liquidate_only.
--
-- No code change needed: modules/alpacaMarketData.js syncs every enabled
-- etf.ticker into stock.price each minute (inserting the stock row on
-- first sight), and the ETF plan reads enabled rows from this table.
INSERT INTO public.etf (ticker, product_id, quote_usd, enabled, is_special)
VALUES (
    'YBTC',
    '4ca13a26f0e64dadd796f2fe82d931adf81732b6bd95a267cba0623a8a03e263',
    1,
    true,
    true
)
ON CONFLICT (ticker) DO UPDATE
SET product_id = EXCLUDED.product_id,
    quote_usd = EXCLUDED.quote_usd,
    enabled = EXCLUDED.enabled,
    is_special = EXCLUDED.is_special;

COMMENT ON COLUMN public.etf.is_special IS
    'True for BLOX, CHPY, TOPW, TSLW, XDTE, SPCX, and YBTC. XDTE was made a special on 2026-10-04 so it gets same-day dip rebuys and the 2:45 PM CT catch-up. SPCX (SpaceX common stock) added as a special on 2026-10-05. YBTC (Roundhill Bitcoin Covered Call ETF) added as a special on 2026-10-06; YETH skipped (Coinbase liquidate_only).';
