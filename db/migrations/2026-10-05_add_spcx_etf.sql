-- Add SPCX (SpaceX, Space Exploration Technologies Corp Class A common
-- stock) to the equity buy list, configured exactly like the existing five
-- specials (BLOX, CHPY, TOPW, TSLW, XDTE): enabled, $1 quote_usd market
-- buy, is_special = true (same-minute repeat when price < last fill, plus
-- the 2:45 PM CT catch-up). Requested by the user 2026-10-05.
--
-- SPCX is a common stock, not an ETF; the etf table/code path does not
-- depend on subtype (it only needs an EQUITY product_id and a ticker).
--
-- product_id verified 2026-10-05 against GET /api/v3/brokerage/products
-- ?product_type=EQUITY: ticker SPCX has two ids. Same rule as the other
-- five: use the one with quote_currency_id = USD and empty alias
-- (d0484aea...). The other (ed1f0189..., quote USDC) aliases to it and is
-- not used. Product checked: trading_disabled false, view_only/cancel_only
-- false, not halted, not liquidate_only, fractionable, $1 notional min.
--
-- No code change needed: modules/alpacaMarketData.js syncs every enabled
-- etf.ticker into stock.price each minute (inserting the stock row on
-- first sight), and the ETF plan reads enabled rows from this table.
INSERT INTO public.etf (ticker, product_id, quote_usd, enabled, is_special)
VALUES (
    'SPCX',
    'd0484aeacc93f88a18b0431b8d2aac6efededa3b203ff4b55c72b64805aa5a2e',
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
    'True for BLOX, CHPY, TOPW, TSLW, XDTE, and SPCX. XDTE was made a special on 2026-10-04 so it gets same-day dip rebuys and the 2:45 PM CT catch-up. SPCX (SpaceX common stock) added as a special on 2026-10-05.';
