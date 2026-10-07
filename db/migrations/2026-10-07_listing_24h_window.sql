-- 2026-10-07: listing snipe 24h window (Theodore: "if its new today it needs
-- a buy order"; PONS opened 12:20 PM CT while free USD was short and was
-- never bought inside the old 5-minute window).
--
-- What changes (code in db/procedures/thee_procedure.sql listing INSERT,
-- modules/listingWatch.js and index.js; this file adds only the data):
--   * config listing_buy_window_hours = 24: a coin can be sniped for a
--     ROLLING 24h after listing_watch.trading_open_at (not a calendar day).
--     listing_window_minutes (5) stays and now only marks the first-trade
--     pricing phase; after it the limit is the fresh best ask + cushion.
--   * config listing_max_open_bags = 3: replaces the one-listing-at-a-time
--     mutex. Still one snipe per coin EVER (per-coin guards + the unique
--     index position_one_listing_per_stock).
--   * listing_watch.snipe_cancelled_at: stamped by index.js
--     reconcileListingBuys() when a listing buy ends with NO fill (cancelled
--     by hand, expired, failed) and its row is deleted. thee_procedure skips
--     such coins, so the 24h window never re-snipes a coin whose snipe was
--     cancelled (same "coin is done" outcome as with the 5-minute window).
--
-- Undo the window: UPDATE config SET value = '0.0834' WHERE key = 'listing_buy_window_hours';  (~5 min)
BEGIN;

INSERT INTO public.config (key, value) VALUES ('listing_buy_window_hours', '24')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.config (key, value) VALUES ('listing_max_open_bags', '3')
ON CONFLICT (key) DO NOTHING;

ALTER TABLE public.listing_watch ADD COLUMN IF NOT EXISTS snipe_cancelled_at timestamptz;
COMMENT ON COLUMN public.listing_watch.snipe_cancelled_at IS
  'Set by index.js reconcileListingBuys() when this coin''s listing buy ended with no fill (cancelled / expired / failed) and its position row was deleted. thee_procedure never re-snipes a coin with this set (24h window).';

COMMIT;
