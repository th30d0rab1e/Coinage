-- 2026-10-11 (Theodore, voice): catch sharp intraday flushes (e.g. OP-USD
-- noon 2026-10-08) that the stop-above-market buy path misses.
-- 1) Turn on unheld dip_buy (plain limits below market).
-- 2) Reload thee_procedure so held-coin average-down that is already
--    dip_buy_gap_pct under the cheapest bag places a dip LIMIT instead of a
--    stop-limit above the market.
UPDATE config SET value = 'true' WHERE key = 'dip_buy_enabled';
-- Remake at 4% and TTL 24h (existing defaults) keep small wiggles from churning.
