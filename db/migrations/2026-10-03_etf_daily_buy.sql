-- 2026-10-03: daily equity ETF buys (BLOX, TOPW, CHPY, TSLW).
-- One market buy of quote_usd (default $1) per enabled row per Chicago day,
-- and only while the normal equity session is open. A closed session must
-- not reserve cash and must not block crypto. Closed-market rejects are
-- recorded in etf_buy with filled = false so they do not count as the buy.
-- Idempotent: safe to re-run. Seed does not overwrite quote_usd / enabled
-- if the row already exists.

CREATE TABLE IF NOT EXISTS public.etf (
    ticker     text PRIMARY KEY,
    -- Canonical EQUITY product_id from List Products. Not the display ticker.
    product_id text NOT NULL,
    -- Cap for that day's market buy. The bot must not send more than this.
    quote_usd  numeric NOT NULL DEFAULT 1,
    enabled    boolean NOT NULL DEFAULT true
);

COMMENT ON TABLE public.etf IS
    'Enabled equity ETFs bought once per Chicago day while the normal session is open.';
COMMENT ON COLUMN public.etf.product_id IS
    'Canonical EQUITY product_id from the products API. Do not substitute the ticker.';
COMMENT ON COLUMN public.etf.quote_usd IS
    'Maximum quote USD for that day''s market buy. Default $1.';

-- Attempts. filled = true is the only "already bought today" marker.
-- closed_session rejects stay filled = false so Monday can still buy.
CREATE TABLE IF NOT EXISTS public.etf_buy (
    etf_buy_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticker            text NOT NULL REFERENCES public.etf (ticker),
    chicago_date      date NOT NULL,
    quote_usd         numeric NOT NULL,
    filled            boolean NOT NULL DEFAULT false,
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
    'Closed-market reject (queueing unavailable / UNTRADABLE). Does not count as today''s buy.';

-- Absent or not 'true' means closed: do not reserve cash.
INSERT INTO public.config (key, value) VALUES ('equity_session_open', 'false')
ON CONFLICT (key) DO NOTHING;

-- Product ids confirmed against product_type=EQUITY on 2026-10-03.
-- TSLW had a single id. BLOX/TOPW/CHPY are the canonical ids already agreed
-- (each ticker also had a second id in the catalog; those are not used).
INSERT INTO public.etf (ticker, product_id, quote_usd, enabled) VALUES
    ('BLOX', 'b00c6138f30e9f64073251d311d38324de73a36acfd22867427b293adc143d3c', 1, true),
    ('TOPW', 'b05be8d4f84762b36f6a5c304b8f4722b0b7c6139c76b944b4726fdc760924ff', 1, true),
    ('CHPY', '6aa416c41dd7b2ecfc474bc5d269d526fc3895f51c492b4116f4a63101665dde', 1, true),
    ('TSLW', 'c14a9c069c5b045e2fbff2f79d2cd08884a1ebec246add36b1f34261f0970d8d', 1, true)
ON CONFLICT (ticker) DO NOTHING;

-- USD held back from new crypto buys only while the session flag is true
-- and that ticker has no filled etf_buy for the Chicago date.
CREATE OR REPLACE VIEW public.vw_etf_cash_reserve AS
SELECT COALESCE(
    CASE
        WHEN (SELECT value FROM public.config WHERE key = 'equity_session_open') = 'true'
        THEN (
            SELECT SUM(e.quote_usd)
            FROM public.etf e
            WHERE e.enabled
            AND NOT EXISTS (
                SELECT 1
                FROM public.etf_buy b
                WHERE b.ticker = e.ticker
                  AND b.chicago_date = (timezone('America/Chicago', now()))::date
                  AND b.filled
            )
        )
        ELSE 0
    END
, 0)::numeric AS reserve_usd;

COMMENT ON VIEW public.vw_etf_cash_reserve IS
    'Unfilled ETF quote USD to keep away from new crypto buys. 0 when the equity session is closed.';
