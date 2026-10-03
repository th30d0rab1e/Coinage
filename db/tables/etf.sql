-- Daily equity ETF buys. Separate from crypto stock/position so a closed
-- equity session never reserves USD and never blocks crypto buys.
-- product_id is the canonical Advanced Trade id (64-hex), not the ticker.
-- Orders must use product_id; the ticker is only a label.
CREATE TABLE IF NOT EXISTS public.etf (
    ticker     text PRIMARY KEY,
    product_id text NOT NULL,
    -- Quote USD for the one market buy on each Chicago calendar day.
    -- The bot must not send more than this.
    quote_usd  numeric NOT NULL DEFAULT 1,
    enabled    boolean NOT NULL DEFAULT true
);

COMMENT ON TABLE public.etf IS
    'Enabled equity ETFs bought once per Chicago day while the normal session is open.';
COMMENT ON COLUMN public.etf.product_id IS
    'Canonical EQUITY product_id from the products API. Do not substitute the ticker.';
COMMENT ON COLUMN public.etf.quote_usd IS
    'Maximum quote USD for that day''s market buy. Default $1.';
