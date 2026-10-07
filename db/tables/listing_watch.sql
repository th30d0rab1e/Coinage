-- 2026-10-07 (migrations/2026-10-07_listing_trading_open_window.sql):
-- candidate new -USD listings, written only by modules/listingWatch.js
-- (index.js calls it every minute before thee_procedure). Read by the
-- listing snipe INSERT in thee_procedure.
--
-- Why: Coinbase's products.new_at is not when trading opens (study: ~18h
-- earlier on average; only 2/50 listings traded within 60 min of it). The
-- snipe window now starts at trading_open_at = the EARLIER of
--   (a) the pair's first completed trade (Exchange API trade_id 1, or the
--       first ONE_MINUTE candle with volume > 0 as fallback), and
--   (b) the first time the bot observed launch restrictions cleared
--       (status online AND NOT trading_disabled / auction_mode /
--        limit_only / cancel_only).
CREATE TABLE IF NOT EXISTS public.listing_watch (
    product_id              text PRIMARY KEY,          -- e.g. CT-USD
    stock_id                integer,                   -- stock.stock_id (NULL until thee_procedure inserts the stock row)
    is_new                  boolean,                   -- products.new at last check
    new_at                  timestamptz,               -- products.new_at (candidate filter only, NOT the window start)
    first_watched_at        timestamptz NOT NULL DEFAULT now(),
    last_checked_at         timestamptz,
    check_count             integer NOT NULL DEFAULT 0,
    last_flags              jsonb,                     -- status / trading_disabled / auction_mode / limit_only / cancel_only / post_only seen last check
    restricted_seen_at      timestamptz,               -- first time seen still restricted
    restrictions_cleared_at timestamptz,               -- first time seen fully unrestricted (b)
    first_trade_at          timestamptz,               -- first completed trade (a)
    first_trade_price       numeric,                   -- its price; the listing limit buy is priced off this
    first_trade_source      text,                      -- 'exchange_trade_id_1' | 'candles_1m'
    trading_open_at         timestamptz,               -- LEAST(a, b); set once, never moved
    trading_open_source     text,                      -- 'first_trade' | 'restrictions_cleared'
    last_error              text,                      -- last API problem while checking (NULL when the last check was clean)
    -- 2026-10-07 (migrations/2026-10-07_listing_24h_window.sql): set by
    -- index.js reconcileListingBuys() when this coin's listing buy ended with
    -- NO fill (cancelled / expired / failed) and its row was deleted;
    -- thee_procedure never re-snipes a coin with this set (24h window).
    snipe_cancelled_at      timestamptz,
    -- 2026-10-07 (migrations/2026-10-07_listing_buy_immediately.sql): set by
    -- thee_procedure when this coin, inside its window, is skipped only
    -- because its smallest valid order costs more than
    -- config.listing_max_buy_usd (refreshed each minute while it lasts);
    -- first time noted; when index.js logListingSkips() printed it (once).
    snipe_skip_reason       text,
    snipe_skipped_at        timestamptz,
    snipe_skip_logged_at    timestamptz
);
