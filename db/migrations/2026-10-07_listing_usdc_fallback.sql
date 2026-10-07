-- 2026-10-07: USDC fallback for the new-coin LISTING SNIPE only (Theodore).
--
-- Why: PONS-USD opened for trading at 12:20:53 PM CT on 2026-10-07 and the
-- snipe never fired because free USD was $0.70 (the $1 snipe needs ~$1.012
-- incl. the fee pad) while ~$75 sat in USDC. Coinbase lists every -USD
-- crypto pair with a -USDC twin whose alias is the -USD pair (one shared
-- order book, same new_at / launch flags -- checked on all 405 USD pairs),
-- and an order on the -USDC product is paid in USDC.
--
-- Rule (thee_procedure listing INSERT): pay with USD when free USD (minus
-- the USDC-sweep reserve) covers the order incl. the 1.2% fee pad, exactly
-- as before; otherwise, when config.listing_usdc_fallback = 'true', free
-- USDC covers it and the coin's -USDC twin is tradable in bulk_stock, plan
-- the snipe on <COIN>-USDC paid with USDC. Normal crypto buys stay USD only.
--
-- What this adds:
--   position.buy_quote_currency       NULL = bought on the -USD pair with USD
--                                     (every row before this, and every
--                                     non-listing row); 'USDC' = the buy was
--                                     sent to <COIN>-USDC. position.name stays
--                                     <COIN>-USD so every stock / balance /
--                                     audit join keeps working, and the SELL
--                                     still goes on <COIN>-USD (returns USD;
--                                     approved: no sell-side change).
--   profit_history.buy_quote_currency copied from position at close (history).
--   config.listing_usdc_fallback      'true' = fallback on (kill switch:
--                                     set 'false' to snipe with USD only).

BEGIN;

ALTER TABLE public.position ADD COLUMN IF NOT EXISTS buy_quote_currency text;
ALTER TABLE public.profit_history ADD COLUMN IF NOT EXISTS buy_quote_currency text;

COMMENT ON COLUMN public.position.buy_quote_currency IS
    'Currency that paid for the BUY: NULL = USD on position.name (<COIN>-USD); ''USDC'' = listing snipe sent to <COIN>-USDC because free USD was short (config.listing_usdc_fallback). The sell always goes on position.name (-USD).';
COMMENT ON COLUMN public.profit_history.buy_quote_currency IS
    'Copied from position.buy_quote_currency at close: NULL = bought with USD, ''USDC'' = listing snipe bought on <COIN>-USDC with USDC.';

INSERT INTO public.config (key, value) VALUES ('listing_usdc_fallback', 'true')
ON CONFLICT (key) DO NOTHING;

COMMIT;
