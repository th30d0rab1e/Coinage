-- 2026-10-08 (Theodore): BUY remakes only after the price has dropped.
--
-- Before: vw_edit_orders remade an open buy whenever the new stop came out
-- lower than the current one. Because buy_counter shrinks the stop
-- multiplier by buy_remake_step_pct each remake, that happened about once a
-- minute even when the price never moved.
--
-- Now: position.buy_remade_price stores the live price (stock.price, the
-- view's price_now) at the moment of the last SUCCESSFUL buy remake. It is
-- written only by index.js processRemakeOrders() on a buy remake.
-- vw_edit_orders' BUY branch then requires the current price to be below
-- it before remaking again. NULL = never remade, so the first remake is
-- allowed exactly as before.
ALTER TABLE position ADD COLUMN IF NOT EXISTS buy_remade_price numeric;

COMMENT ON COLUMN position.buy_remade_price IS
  'Live price (stock.price) at the last successful BUY remake, set by index.js processRemakeOrders(). vw_edit_orders only remakes a buy again once the price is below this. NULL = never remade.';
