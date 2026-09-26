-- 2026-09-25: timestamps used to break the far-buy place/cancel loop.
-- processFarBuyCashRelease cancelled the same ETC/TRB/ATOM buys every other
-- minute and processBuyOrders re-placed them the next minute at identical
-- prices (nothing else could use the freed cash).
--   buy_placed_at   -- set whenever a buy order is created (processBuyOrders)
--                      or remade (processRemakeOrders); far-release will not
--                      cancel an order younger than 30 minutes.
--   buy_released_at -- set when far-release cancels a buy to free cash;
--                      processBuyOrders won't re-place that row for 30
--                      minutes, so the freed cash can go to the beneficiary.
-- Nullable, no default: existing rows read as "old / never released".
-- The position_audit trigger will log changes to these like any column.
ALTER TABLE position ADD COLUMN IF NOT EXISTS buy_placed_at   timestamp without time zone;
ALTER TABLE position ADD COLUMN IF NOT EXISTS buy_released_at timestamp without time zone;
