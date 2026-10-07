-- 2026-10-07: new-coin (listing) snipe buys immediately, no high-price skip.
-- Theodore: "I dont want the new coins to have a restriction if its too
-- high in price. I want the buy order in immediately."
--
-- Code: db/procedures/thee_procedure.sql listing INSERT (one pricing rule:
-- fresh ask, else last trade, else first trade, x 1.02 rounded up to the
-- tick; size = GREATEST(listing_buy_usd, quote_min) rounded up to the lot,
-- >= base_min; ceiling listing_max_buy_usd; stablecoin flag not applied in
-- the 24h window; may buy before the first-trade lookup when restrictions
-- are cleared and a fresh ask exists) and index.js logListingSkips().
-- This file only adds the data:
--   * config listing_max_buy_usd = 5: most one snipe may cost (replaces the
--     old "<= 1.25 x listing_buy_usd" cap that skipped high-priced coins).
--   * config listing_limit_cushion_pct 0.5 -> 2: limit = reference + 2%, so
--     the plain GTC limit sits above the ask and fills right away (it pays
--     the real ask; the cushion is only the worst case if the book moves).
--   * listing_watch.snipe_skip_reason / snipe_skipped_at / snipe_skip_logged_at:
--     why a coin in its window was skipped (only "over listing_max_buy_usd"),
--     when first, and when index.js printed it.
--   * config listing_window_minutes is left in place but is no longer read.
--
-- Undo the cushion: UPDATE config SET value = '0.5' WHERE key = 'listing_limit_cushion_pct';
BEGIN;

INSERT INTO public.config (key, value) VALUES ('listing_max_buy_usd', '5')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.config (key, value) VALUES ('listing_limit_cushion_pct', '2')
ON CONFLICT (key) DO UPDATE SET value = '2';

ALTER TABLE public.listing_watch ADD COLUMN IF NOT EXISTS snipe_skip_reason    text;
ALTER TABLE public.listing_watch ADD COLUMN IF NOT EXISTS snipe_skipped_at     timestamptz;
ALTER TABLE public.listing_watch ADD COLUMN IF NOT EXISTS snipe_skip_logged_at timestamptz;
COMMENT ON COLUMN public.listing_watch.snipe_skip_reason IS
  'Set by thee_procedure when this coin, inside its listing window, is skipped only because its smallest valid order costs more than config.listing_max_buy_usd. Refreshed each minute while it lasts.';
COMMENT ON COLUMN public.listing_watch.snipe_skipped_at IS
  'First time thee_procedure noted snipe_skip_reason for this coin.';
COMMENT ON COLUMN public.listing_watch.snipe_skip_logged_at IS
  'When index.js logListingSkips() printed the skip to the output log (printed once).';

COMMIT;
