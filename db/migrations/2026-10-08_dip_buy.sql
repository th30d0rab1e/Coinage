-- 2026-10-08: DIP-BUY limit orders (Theodore, approved on a voice call
-- 2026-10-08). SHIPPED SWITCHED OFF (dip_buy_enabled = '0').
--
-- What it does when switched on (thee_procedure "DIP-BUY" block + index.js
-- processBuyOrders / processDipBuys):
--   * Coins: stock.priority > 0, -USD product, not a stablecoin, not
--     trading_disabled, no filled open position and no other open/planned
--     buy of any kind. Coins already held are left to the existing buys.
--   * Order: plain LIMIT buy (limit_limit_gtc, no stop) for ~dip_buy_usd
--     ($1) at current price x (1 - dip_buy_gap_pct/100), price rounded DOWN
--     to the coin's price increment, size rounded UP to its size increment
--     (so the cost is >= $1); skipped if under the coin's min size / min
--     notional. USD only.
--   * Highest stock.priority first; at most dip_buy_max_open dip orders
--     open (unfilled) at once.
--   * Cash: only while free USD minus the ETF reserve, the USDC-sweep
--     reserve and every planned-but-unsent buy covers the running total
--     (cost x 1.012 fee pad) -- the same gate the existing buys use. Placed
--     after the first-buy and average-down inserts, sent last.
--   * Remake: limit more than dip_buy_remake_pct below the current price ->
--     cancel and re-place at current x (1 - gap). TTL: cancel after
--     dip_buy_ttl_hours, then the coin may get a fresh dip buy.
--   * On fill it is a normal 'day' position (normal sell logic), marked
--     position.buy_source = 'dip_buy' (carried to profit_history).
-- Switch OFF: no new dip rows; planned (unsent) dip rows are dropped; dip
-- orders already resting wind down via remake/TTL (remakes stop, because
-- the re-priced row is dropped). With no dip rows nothing changes.
--
-- Turn on:  UPDATE config SET value = '1' WHERE key = 'dip_buy_enabled';
-- Turn off: UPDATE config SET value = '0' WHERE key = 'dip_buy_enabled';
-- Apply with: psql -U theodorecross -d coinbase -f db/migrations/2026-10-08_dip_buy.sql
-- (then reload the procedure: psql ... -f db/procedures/thee_procedure.sql)
BEGIN;

-- Marker for rows created by the dip-buy feature. NULL = every existing
-- flow (first buy, average-down, listing snipe, orphan recovery).
ALTER TABLE public.position ADD COLUMN IF NOT EXISTS buy_source text;
COMMENT ON COLUMN public.position.buy_source IS
    'Which feature created the buy: ''dip_buy'' = dip-buy limit order (2026-10-08). NULL = the normal buy flows.';
ALTER TABLE public.profit_history ADD COLUMN IF NOT EXISTS buy_source text;
COMMENT ON COLUMN public.profit_history.buy_source IS
    'Copied from position.buy_source when the closed position is recorded (''dip_buy'' or NULL).';

-- Master switch. '1' / 'true' = on; anything else or a missing row = off.
INSERT INTO public.config (key, value) VALUES ('dip_buy_enabled', '0')     ON CONFLICT (key) DO NOTHING;
-- Limit price = current price x (1 - dip_buy_gap_pct / 100).
INSERT INTO public.config (key, value) VALUES ('dip_buy_gap_pct', '2')     ON CONFLICT (key) DO NOTHING;
-- Dollars per dip buy (size rounded up to the coin's increment).
INSERT INTO public.config (key, value) VALUES ('dip_buy_usd', '1')         ON CONFLICT (key) DO NOTHING;
-- Max unfilled dip orders at once (5 is a placeholder; Theodore to confirm).
INSERT INTO public.config (key, value) VALUES ('dip_buy_max_open', '5')    ON CONFLICT (key) DO NOTHING;
-- Re-place when the limit is more than this % below the current price.
INSERT INTO public.config (key, value) VALUES ('dip_buy_remake_pct', '4')  ON CONFLICT (key) DO NOTHING;
-- Cancel a dip order that has rested this many hours.
INSERT INTO public.config (key, value) VALUES ('dip_buy_ttl_hours', '24')  ON CONFLICT (key) DO NOTHING;

\ir ../views/vw_dip_buy_actions.sql

COMMIT;
