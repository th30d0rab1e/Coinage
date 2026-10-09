-- 2026-10-08 (Theodore): SELL remakes only after the price has risen.
-- Mirror of 2026-10-08_buy_remake_requires_price_drop.sql for sells.
--
-- position.sell_remade_price stores the live price (stock.price, the view's
-- price_now) at the moment of the last SUCCESSFUL sell remake. It is written
-- only by index.js processRemakeOrders() on a sell remake. Both SELL
-- branches of vw_edit_orders then require the current price to be ABOVE it
-- before remaking again. NULL = never remade, so the first remake is
-- allowed exactly as before.
ALTER TABLE position ADD COLUMN IF NOT EXISTS sell_remade_price numeric;

COMMENT ON COLUMN position.sell_remade_price IS
  'Live price (stock.price) at the last successful SELL remake, set by index.js processRemakeOrders(). vw_edit_orders only remakes a sell again once the price is above this. NULL = never remade.';
