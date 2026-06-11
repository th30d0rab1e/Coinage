-- Drop views that reference old columns
DROP VIEW IF EXISTS vw_edit_orders;
DROP VIEW IF EXISTS vw_position;

-- Remove all sell rows
DELETE FROM position WHERE side = 'sell';

-- Populate buy_price from price (buy rows only remain)
UPDATE position SET buy_price = price;

-- Add new columns
ALTER TABLE position
  ADD COLUMN buy_order_id TEXT,
  ADD COLUMN sell_order_id TEXT,
  ADD COLUMN buy_coinbase_order_id TEXT,
  ADD COLUMN sell_coinbase_order_id TEXT,
  ADD COLUMN buy_stop_price DOUBLE PRECISION,
  ADD COLUMN sell_stop_price DOUBLE PRECISION,
  ADD COLUMN sell_filled_price DOUBLE PRECISION;

-- Populate new columns from old ones
UPDATE position SET
  buy_order_id = order_id,
  buy_coinbase_order_id = coinbase_order_id,
  buy_stop_price = stop_price;

-- Rename filled_price to buy_filled_price
ALTER TABLE position RENAME COLUMN filled_price TO buy_filled_price;

-- Drop old columns
ALTER TABLE position
  DROP COLUMN order_id,
  DROP COLUMN coinbase_order_id,
  DROP COLUMN price,
  DROP COLUMN stop_price,
  DROP COLUMN side,
  DROP COLUMN is_created,
  DROP COLUMN is_filled,
  DROP COLUMN buy_is_created,
  DROP COLUMN sell_is_created,
  DROP COLUMN buy_is_filled,
  DROP COLUMN sell_is_filled,
  DROP COLUMN needs_to_replace;

-- Recreate vw_edit_orders for buy orders whose stop price needs adjustment
CREATE VIEW vw_edit_orders AS
SELECT
  p.name,
  p.period_type,
  p.buy_stop_price,
  p.buy_price,
  s.price AS price_now,
  p.buy_order_id,
  p.buy_coinbase_order_id,
  p.shares,
  trunc((s.price::numeric * 1.01), s.price_rounding) AS new_stop_price
FROM position p
JOIN stock s ON p.stock_id = s.stock_id
WHERE p.buy_coinbase_order_id IS NOT NULL
  AND p.buy_filled_price IS NULL
  AND p.buy_stop_price > trunc((s.price::numeric * 1.01), s.price_rounding)::double precision
ORDER BY p.name, p.period_type;

-- Recreate vw_position
CREATE VIEW vw_position AS
SELECT
  stock_id,
  name,
  period_type,
  count(1) AS cnt,
  sum(shares) AS sum_shares,
  max(buy_price) AS max_buy_price,
  min(buy_price) AS min_buy_price,
  sum(buy_price * shares) AS sum_buy_value,
  max(buy_order_id) AS max_buy_order_id,
  min(buy_order_id) AS min_buy_order_id,
  max(buy_coinbase_order_id) AS max_buy_coinbase_order_id,
  min(buy_coinbase_order_id) AS min_buy_coinbase_order_id,
  max(buy_filled_price) AS max_buy_filled_price,
  min(buy_filled_price) AS min_buy_filled_price,
  min(buy_stop_price) AS min_buy_stop_price,
  max(buy_stop_price) AS max_buy_stop_price
FROM position
WHERE error_message IS NULL
GROUP BY stock_id, name, period_type;
