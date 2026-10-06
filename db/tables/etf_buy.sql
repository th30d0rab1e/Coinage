-- One row per ETF order attempt. Since 2026-10-06 there are two kinds
-- (order_type): the once-per-Chicago-day $1 market buy, and resting
-- limit-ladder buys (one PLACING/OPEN limit per ticker, enforced by
-- etf_buy_one_open_limit_idx). See db/migrations/2026-10-06_etf_limit_ladder.sql.
-- filled = true means the order filled (a market row with filled = true
-- for today's chicago_date is today's morning buy). A closed-market rejection or a zero fill
-- stays filled = false and does not count. A failed fill GET may be
-- stored filled = true so the same quote is not sent twice.
CREATE TABLE IF NOT EXISTS public.etf_buy (
    etf_buy_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticker            text NOT NULL REFERENCES public.etf (ticker),
    chicago_date      date NOT NULL,
    quote_usd         numeric NOT NULL,
    filled            boolean NOT NULL DEFAULT false,
    -- True when Coinbase rejected because the equity market was not open.
    -- Those rows are history only; they do not count as today's buy.
    closed_session    boolean NOT NULL DEFAULT false,
    coinbase_order_id text,
    client_order_id   text,
    error_message     text,
    created_at        timestamp without time zone NOT NULL DEFAULT NOW(),
    -- Live price the dip rule compared. Null when the attempt did not
    -- need a price (no shares yet, or the special end-of-session catch-up).
    dip_price         numeric,
    -- Execution price (filled value / filled size). The next same-day dip
    -- uses the latest non-null value. Null when the fill GET did not
    -- return a size, including a failed GET recorded as filled.
    fill_price        numeric,
    -- 2026-10-06 limit ladder columns (see the COMMENTs below).
    order_type        text,
    status            text,
    limit_price       numeric,
    base_size         numeric,
    expires_at        timestamptz,
    basis_price       numeric,
    price_basis       text,
    closed_at         timestamptz
);

-- At most one resting (PLACING/OPEN) limit per ticker, even if cron runs overlap.
CREATE UNIQUE INDEX IF NOT EXISTS etf_buy_one_open_limit_idx
    ON public.etf_buy (ticker)
    WHERE order_type = 'limit' AND status IN ('PLACING', 'OPEN');

CREATE INDEX IF NOT EXISTS etf_buy_filled_day_idx
    ON public.etf_buy (ticker, chicago_date)
    WHERE filled;

COMMENT ON TABLE public.etf_buy IS
    'ETF buy attempts: the daily $1 market buy (order_type market) and the resting limit ladder (order_type limit).';
COMMENT ON COLUMN public.etf_buy.closed_session IS
    'Closed-market reject. Does not count as today''s buy.';
COMMENT ON COLUMN public.etf_buy.dip_price IS
    'Legacy (pre-2026-10-06 dip re-buys): price used for the dip check. Null on limit rows and on the daily market buy.';
COMMENT ON COLUMN public.etf_buy.fill_price IS
    'Fill price of the order. Limit rows store the VWAP of fills.price; market rows may store filled_value / filled_size.';
COMMENT ON COLUMN public.etf_buy.order_type IS
    'market = the once-per-Chicago-day $1 market buy (and pre-2026-10-06 dip re-buys). limit = a resting ladder limit buy.';
COMMENT ON COLUMN public.etf_buy.status IS
    'PLACING (row reserved, order not yet confirmed), OPEN (resting on Coinbase), FILLED, EXPIRED (bot cancelled it at expires_at), CANCELLED (cancelled by Coinbase/user, or a market IOC that did not fill), REJECTED (create failed), ABANDONED (PLACING row whose order never appeared).';
COMMENT ON COLUMN public.etf_buy.limit_price IS
    'Limit price sent to Coinbase (limit rows only), floored to price_increment.';
COMMENT ON COLUMN public.etf_buy.base_size IS
    'Shares sent to Coinbase (limit rows only): quote_usd / limit_price rounded UP to base_increment so notional >= $1.';
COMMENT ON COLUMN public.etf_buy.expires_at IS
    'Bot-side expiry for limit rows: placed + config.etf_limit_ttl_hours. Coinbase has no GTD for equities, so index.js cancels the GTC order after this time.';
COMMENT ON COLUMN public.etf_buy.basis_price IS
    'Price the limit was stepped down from: the latest buy fill VWAP (fills.price) or, with no fill ever, the best bid.';
COMMENT ON COLUMN public.etf_buy.price_basis IS
    'Where basis_price came from: last_fill, coinbase_bid, or iex_bid.';
COMMENT ON COLUMN public.etf_buy.closed_at IS
    'When the bot saw the limit reach a terminal status (FILLED / EXPIRED / CANCELLED / ABANDONED).';
