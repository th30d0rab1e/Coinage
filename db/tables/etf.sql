-- Equity ETF buys. Separate from crypto stock/position.
-- product_id is the canonical Advanced Trade id (64-hex), not the ticker.
-- Orders must use product_id; the ticker is only a label.
-- is_special distinguishes the Alpaca-style repeat rules. BLOX, CHPY,
-- TOPW, TSLW, XDTE, and SPCX are specials.
-- XDTE was made a special on 2026-10-04 so it gets same-day dip rebuys and the 2:45 PM CT catch-up.
-- SPCX (SpaceX common stock, not an ETF) was added 2026-10-05 as a $1
-- special; see db/migrations/2026-10-05_add_spcx_etf.sql for the product_id check.
CREATE TABLE IF NOT EXISTS public.etf (
    ticker     text PRIMARY KEY,
    product_id text NOT NULL,
    -- Notional of one market buy. Not a share count.
    quote_usd  numeric NOT NULL DEFAULT 1,
    enabled    boolean NOT NULL DEFAULT true,
    -- Specials may all buy in one minute and repeat when price < last fill.
    -- Regulars (default) need price < last fill * 0.99 and only one attempt
    -- per minute. The flag exists so a regular is not given the special
    -- repeat-buy or 2:45 PM Chicago catch-up.
    is_special boolean NOT NULL DEFAULT false
);

COMMENT ON TABLE public.etf IS
    'Equity ETFs bought on Coinbase NORMAL session under dip rules. is_special selects the repeat rule.';
COMMENT ON COLUMN public.etf.product_id IS
    'Canonical EQUITY product_id from the products API. Do not substitute the ticker.';
COMMENT ON COLUMN public.etf.quote_usd IS
    'Quote USD notional for one market buy. Default $1.';
COMMENT ON COLUMN public.etf.is_special IS
    'True for BLOX, CHPY, TOPW, TSLW, XDTE, and SPCX. XDTE was made a special on 2026-10-04 so it gets same-day dip rebuys and the 2:45 PM CT catch-up. SPCX (SpaceX common stock) added as a special on 2026-10-05.';
