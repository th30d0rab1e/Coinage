-- One row per ETF order attempt. filled = true means that attempt
-- counts as a buy for the Chicago date (the dip rules may still buy
-- again later the same day). A closed-market rejection or a zero fill
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
    fill_price        numeric
);

CREATE INDEX IF NOT EXISTS etf_buy_filled_day_idx
    ON public.etf_buy (ticker, chicago_date)
    WHERE filled;

COMMENT ON TABLE public.etf_buy IS
    'ETF buy attempts. filled = true counts toward the Chicago-day dip rules. It does not by itself block every later buy.';
COMMENT ON COLUMN public.etf_buy.closed_session IS
    'Closed-market reject. Does not count as today''s buy.';
COMMENT ON COLUMN public.etf_buy.dip_price IS
    'Price used for the red/dip check. Null when that check did not use a price.';
COMMENT ON COLUMN public.etf_buy.fill_price IS
    'Average fill price from the order. Later dip checks compare against the latest one.';
