-- 2026-10-07: cash-scaled buy stops on EVERY buy + "below lowest paid" rule.
-- Approved by Theodore 2026-10-07 ("were not using USDC to buy crypto").
--
-- Code (each file carries its own dated comment):
--   * db/views/vw_buy_stop_gap.sql       ONE place for the cash-scaled gap:
--       gap = buy_stop_base_pct/100 * sqrt(total_equity / free USD)
--       total_equity = filled bags at stock.price + USD available + USD hold
--       + priced untracked dust (same definition as 2026-10-05 33cbe3a; USDC
--       is never cash). No maximum. Free USD 0/NULL -> treated as $0.01.
--   * db/procedures/fn_buy_below_paid.sql  the below-lowest-paid rule: a buy
--       on a coin with open filled bags must have its LIMIT below the lowest
--       buy_filled_price; if not, limit = largest tick below it and
--       stop = limit / 1.01 rounded down to the tick.
--   * db/views/vw_edit_orders.sql  buy remake: stop multiplier =
--       GREATEST(1 + buy_remake_floor_pct/100,
--                1 + gap - buy_counter * buy_remake_step_pct/100),
--       limit x 1.01, then the below-lowest-paid rule; only-lower ratchet kept.
--   * db/procedures/thee_procedure.sql  placement (signal insert, average-
--       down insert, stale refresh) uses stop = close/price x (1 + gap),
--       limit = stop x 1.01; the add-on UPDATE applies the below-lowest-paid
--       rule (replaces the 0.99 x cheapest-bag cap); cash / thin-ask checks
--       use shares x the final limit.
--
-- This file only adds the config rows (defaults = the values the code falls
-- back to when a row is missing):
--   buy_stop_base_pct    2    base gap in percent, stretched by sqrt(equity / free USD)
--   buy_remake_step_pct  0.5  each buy remake tightens the multiplier by this many points
--   buy_remake_floor_pct 0.1  the remake never goes tighter than price x (1 + this/100)
-- config add_buy_cap_ratio (0.99) is LEFT IN PLACE BUT NO LONGER READ: the
-- below-lowest-paid rule replaced its 99% stop math.
BEGIN;

INSERT INTO public.config (key, value) VALUES ('buy_stop_base_pct', '2')    ON CONFLICT (key) DO NOTHING;
INSERT INTO public.config (key, value) VALUES ('buy_remake_step_pct', '0.5') ON CONFLICT (key) DO NOTHING;
INSERT INTO public.config (key, value) VALUES ('buy_remake_floor_pct', '0.1') ON CONFLICT (key) DO NOTHING;

COMMIT;
