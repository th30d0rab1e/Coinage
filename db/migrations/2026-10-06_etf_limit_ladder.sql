-- 2026-10-06: ETF limit ladder (alongside the morning $1 market buy).
--
-- Why: on 2026-10-06 the special "dip" re-buys compared a stale/wide Alpaca
-- IEX mid with the last Coinbase fill, which is always above the mid, so
-- every special re-bought $1 at market every minute (151 fills in 37 min).
-- Retired: the per-minute market dip re-buy and the 2:45 PM CT market
-- catch-up. Kept: one $1 market buy per ticker per Chicago day at the open.
-- New: each enabled ticker keeps exactly ONE resting limit buy for ~$1,
-- priced etf_limit_step_pct (0.10%) under the latest real fill VWAP (or
-- under the best bid when the ticker has never filled). When it fills the
-- next one goes another step under that fill. Coinbase rejects GTD for
-- equities ("only market and limit orders are supported for CCM"), so the
-- order is GTC and the bot cancels it itself at expires_at
-- (placed + etf_limit_ttl_hours, default 12), then places a fresh one.
--
-- Additive only: new nullable columns, a backfill of the new columns on
-- old rows, one partial unique index, and two config keys.

ALTER TABLE public.etf_buy
    ADD COLUMN IF NOT EXISTS order_type  text,
    ADD COLUMN IF NOT EXISTS status      text,
    ADD COLUMN IF NOT EXISTS limit_price numeric,
    ADD COLUMN IF NOT EXISTS base_size   numeric,
    ADD COLUMN IF NOT EXISTS expires_at  timestamptz,
    ADD COLUMN IF NOT EXISTS basis_price numeric,
    ADD COLUMN IF NOT EXISTS price_basis text,
    ADD COLUMN IF NOT EXISTS closed_at   timestamptz;

-- Every row written before this migration was a $1 market buy.
UPDATE public.etf_buy SET order_type = 'market' WHERE order_type IS NULL;

-- Market rows: FILLED when filled, else a terminal non-fill. Market IOC
-- orders never rest, so none of these can still be working.
UPDATE public.etf_buy
SET status = CASE
        WHEN filled THEN 'FILLED'
        WHEN closed_session OR coinbase_order_id IS NULL THEN 'REJECTED'
        ELSE 'CANCELLED'
    END
WHERE order_type = 'market' AND status IS NULL;

-- Hard guarantee of "one resting limit per ticker": a second PLACING/OPEN
-- limit row for the same ticker fails to insert, even if two cron runs
-- overlap. index.js inserts the PLACING row BEFORE calling Coinbase.
CREATE UNIQUE INDEX IF NOT EXISTS etf_buy_one_open_limit_idx
    ON public.etf_buy (ticker)
    WHERE order_type = 'limit' AND status IN ('PLACING', 'OPEN');

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

INSERT INTO public.config (key, value) VALUES ('etf_limit_step_pct', '0.10')
    ON CONFLICT (key) DO NOTHING;
INSERT INTO public.config (key, value) VALUES ('etf_limit_ttl_hours', '12')
    ON CONFLICT (key) DO NOTHING;
