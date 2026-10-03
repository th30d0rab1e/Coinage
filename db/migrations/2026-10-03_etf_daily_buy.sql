-- 2026-10-03: daily equity ETF buys (BLOX, TOPW, CHPY, TSLW).
-- One market buy of quote_usd (default $1) per enabled row per Chicago day,
-- and only while the normal equity session is open. A closed session must
-- not reserve cash and must not block crypto. "Already bought today" is a
-- fills row (BUY, Chicago date of trade_time), not a second table.
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

-- etf_buy used to live here. It was removed: a buy already happened today
-- when fills has a BUY whose trade_time is today's America/Chicago date.
-- See 2026-10-03_drop_etf_buy.sql. Do not recreate etf_buy.

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

-- Reserve view is defined in 2026-10-03_etf_default_portfolio_only.sql.
-- It stays 0. ETF buys spend Default portfolio USD and do not hold crypto cash.
