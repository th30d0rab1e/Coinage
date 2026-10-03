-- One row per ETF order attempt. A filled row is today''s buy and must
-- not be repeated (so a filled $1 is not retried all day). A closed-market
-- rejection (weekend full close, "order queueing is not available",
-- UNTRADABLE_PRODUCT) is stored with filled = false and does NOT count,
-- so the next open session can still buy.
CREATE TABLE IF NOT EXISTS public.etf_buy (
    etf_buy_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticker            text NOT NULL REFERENCES public.etf (ticker),
    chicago_date      date NOT NULL,
    quote_usd         numeric NOT NULL,
    filled            boolean NOT NULL DEFAULT false,
    -- True when Coinbase rejected because the equity market was not open.
    -- Those rows are history only; the daily-buy check ignores them.
    closed_session    boolean NOT NULL DEFAULT false,
    coinbase_order_id text,
    client_order_id   text,
    error_message     text,
    created_at        timestamp without time zone NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS etf_buy_filled_day_idx
    ON public.etf_buy (ticker, chicago_date)
    WHERE filled;

COMMENT ON TABLE public.etf_buy IS
    'ETF buy attempts. Only filled = true blocks another buy that Chicago date.';
COMMENT ON COLUMN public.etf_buy.closed_session IS
    'Closed-market reject. Does not count as today''s buy.';
