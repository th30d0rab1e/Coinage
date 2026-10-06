-- 2026-10-05: move every buy-placement filter from index.js into
-- thee_procedure(), so a planned buy row only exists if index.js
-- processBuyOrders() will send it this minute (no row sits unsent):
-- order-book gates (spread / imbalance / thin ask), trigger-above-price
-- (add-on cap), Coinbase minimum order size, affordability incl. 1.2% fee,
-- trading_disabled, pause_buys, far-release cooldown. See the
-- "PLANNED-ROW CLEAN-UP" block and the INSERT gates in
-- db/procedures/thee_procedure.sql (re-applied with step 3 below).
--
-- 1. bulk_best_bid_ask: per-run top-of-book for every product (spread gate).
-- 2. Shared thresholds in config, read by thee_procedure() (the gates and
--    the clean-up delete). Values are the ones index.js hard-coded before
--    (BOOK_SKIP_IMBALANCE / BOOK_MAX_SPREAD_PCT / BOOK_MIN_ASK_NOTIONAL_MULT).
--    The procedure also COALESCEs to these defaults if a key is missing.
\ir ../tables/bulk_best_bid_ask.sql

INSERT INTO public.config (key, value) VALUES
    -- Skip a buy when the latest fresh L2 snapshot imbalance is below this
    -- (ask-heavy book). Range -1..1, + = bid-heavy.
    ('book_skip_imbalance', '-0.4'),
    -- Skip a buy when (ask - bid) / mid * 100 is above this percent.
    ('book_max_spread_pct', '0.75'),
    -- Skip a buy when ask notional within 0.5% of mid is below this many
    -- times the order's dollar size (thin ask).
    ('book_min_ask_notional_mult', '5')
ON CONFLICT (key) DO NOTHING;

-- 3. Reload the procedure with the new gates and clean-up. Apply this
--    migration BEFORE deploying the matching index.js (which no longer has
--    its own placement filters), so there is no window with neither.
\ir ../procedures/thee_procedure.sql
