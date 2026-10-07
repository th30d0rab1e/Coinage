-- 2026-10-07: new-listing snipe keyed to when trading ACTUALLY opens.
--
-- Why: a 50-listing study showed Coinbase's products.new_at is NOT the
-- launch time -- trading typically opened ~18h after new_at (only 2/50
-- traded within 60 min of it), and every product in the public list has a
-- non-empty new_at anyway (only new = true marks a currently-new listing).
-- The price move is front-loaded (minute-1 buys hit +3% within an hour 80%
-- of the time vs 48% at minute 60), so the snipe window now starts at
-- listing_watch.trading_open_at (first trade, or first observed fully
-- unrestricted trading, whichever is earlier) and lasts
-- config.listing_window_minutes (default 5).
--
-- Additive only: nullable bulk_stock columns, one new table, three config
-- keys, one partial unique index on position (backstop, see 4).

-- 1) bulk_stock: keep the launch-restriction flags the products feed already
--    returns as real columns (they were only inside bulk_stock.json).
--    trading_disabled / post_only / cancel_only already had columns.
ALTER TABLE public.bulk_stock
    ADD COLUMN IF NOT EXISTS status       text,
    ADD COLUMN IF NOT EXISTS limit_only   text,
    ADD COLUMN IF NOT EXISTS auction_mode text,
    ADD COLUMN IF NOT EXISTS is_new       text,
    ADD COLUMN IF NOT EXISTS new_at       text;

-- 2) listing_watch: one row per candidate new -USD listing, written only by
--    modules/listingWatch.js (called from index.js before thee_procedure).
CREATE TABLE IF NOT EXISTS public.listing_watch (
    product_id              text PRIMARY KEY,
    stock_id                integer,
    is_new                  boolean,
    new_at                  timestamptz,
    first_watched_at        timestamptz NOT NULL DEFAULT now(),
    last_checked_at         timestamptz,
    check_count             integer NOT NULL DEFAULT 0,
    last_flags              jsonb,
    restricted_seen_at      timestamptz,
    restrictions_cleared_at timestamptz,
    first_trade_at          timestamptz,
    first_trade_price       numeric,
    first_trade_source      text,
    trading_open_at         timestamptz,
    trading_open_source     text,
    last_error              text
);

COMMENT ON TABLE public.listing_watch IS
    'Candidate new -USD listings (new = true or new_at within 7 days) watched each minute by modules/listingWatch.js until their real trading open time is known. thee_procedure''s listing snipe fires only within config.listing_window_minutes of trading_open_at.';
COMMENT ON COLUMN public.listing_watch.restricted_seen_at IS
    'First time the bot saw the product still launch-restricted (not online, trading_disabled, auction_mode, limit_only or cancel_only).';
COMMENT ON COLUMN public.listing_watch.restrictions_cleared_at IS
    'First time the bot observed status online AND NOT trading_disabled/auction_mode/limit_only/cancel_only.';
COMMENT ON COLUMN public.listing_watch.first_trade_at IS
    'Time of the pair''s first completed trade: Exchange API trade_id 1 (exact), or fallback the first ONE_MINUTE candle with volume > 0 (minute start).';
COMMENT ON COLUMN public.listing_watch.first_trade_price IS
    'Price of that first trade (candle open in the fallback). The listing limit buy is priced off this.';
COMMENT ON COLUMN public.listing_watch.trading_open_at IS
    'Window start = LEAST(first_trade_at, restrictions_cleared_at). Set once and never moved.';

-- 3) config: the three tunables, one clearly named key each.
--    listing_window_minutes   : snipe window length after trading_open_at
--                               (Theodore: "5 minutes, 15 at most").
--    listing_buy_usd          : dollars per listing snipe ($1).
--    listing_limit_cushion_pct: limit price = first trade price * (1 + this/100).
INSERT INTO public.config (key, value) VALUES
    ('listing_window_minutes',    '5'),
    ('listing_buy_usd',           '1.00'),
    ('listing_limit_cushion_pct', '0.5')
ON CONFLICT (key) DO NOTHING;

-- 4) DB backstop: at most ONE position row per coin with period_type
--    'listing'. The PRIMARY guard is in thee_procedure's listing INSERT
--    (LEFT JOIN position ... IS NULL: any position row for the coin, any
--    period_type, blocks it; LEFT JOIN profit_history ... IS NULL blocks a
--    coin already sniped before). This index only makes a second listing
--    row for the same coin physically impossible if that logic is ever
--    broken. The INSERT deliberately has NO ON CONFLICT (Theodore), so if
--    this index ever trips, the unique violation aborts that minute's
--    thee_procedure call (rolled back as a whole; index.js logs it and
--    carries on) -- a loud signal, never a silent duplicate.
--    Created only when no duplicates exist (verified 0 listing rows before
--    this migration ran).
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.position
        WHERE period_type = 'listing'
        GROUP BY stock_id HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'duplicate listing rows exist in position; resolve before creating position_one_listing_per_stock';
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS position_one_listing_per_stock
    ON public.position (stock_id)
    WHERE period_type = 'listing';
