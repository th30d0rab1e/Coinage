-- 2026-10-07: config.initial_buy_top_pct -- the NEW POSITION (initial $1 buy)
-- INSERT in thee_procedure may only pick a coin in the top N% (default 50)
-- of the year-uptrend set by priority. Approved by Theodore.
--
-- Ranking set: vw_signal year rows with historical_avg_change_percent > 0
-- and priority NOT NULL, excluding stablecoins and trading_disabled coins
-- (they can never be bought). Ranked by priority DESC, stock_id as the
-- tiebreak; the top CEIL(set size x N / 100) coins are eligible. The cut is
-- taken BEFORE the cash / book / held gates, so it does not shift with them.
--
-- Same change: that INSERT no longer orders by order-book imbalance; it
-- picks by priority DESC (stock_id tiebreak). The book gates (spread,
-- imbalance >= book_skip_imbalance, thin ask) still filter.
--
-- Only the initial-buy INSERT reads this key (not average-down / add-on,
-- listing or ETF buys). Stored as text like every config value; 100 = no
-- cut, values are clamped to 0..100, and a missing row means 50.
-- Undo: DELETE FROM config WHERE key = 'initial_buy_top_pct'; (and remove the
-- "topbuy" join from thee_procedure).
BEGIN;

INSERT INTO public.config (key, value)
VALUES ('initial_buy_top_pct', '50')
ON CONFLICT (key) DO NOTHING;

COMMIT;
