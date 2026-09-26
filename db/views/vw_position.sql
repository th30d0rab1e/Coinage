-- vw_position: per coin + period_type summary of the position table.
--
-- 2026-09-25 fix: the view used to aggregate EVERY position row, including
-- planned buys that never filled (buy_filled_price NULL, often with no
-- Coinbase order at all) and rows whose sell already filled but hadn't been
-- closed out yet. That overstated holdings by ~$37 vs the real Coinbase
-- balance (83 "bags" vs 65 actually held).
--
-- Now the ORIGINAL column names mean HELD bags only (buy filled, sell not
-- filled) -- i.e. coin that is really sitting in the account -- so
-- sum(sum_shares * stock.price) reconciles to vw_balance. Pending and
-- sold-but-unclosed rows are reported separately in columns appended at the
-- end (CREATE OR REPLACE VIEW only allows adding columns at the end, and
-- keeping existing names/types avoids breaking anything that selects them).
-- Coins with only pending rows still appear, with cnt = 0 and NULL sums.
CREATE OR REPLACE VIEW public.vw_position AS
SELECT stock_id,
    name,
    period_type,
    -- ---- held bags only (bought and not yet sold) ----
    count(*)                   FILTER (WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL) AS cnt,
    sum(shares)                FILTER (WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL) AS sum_shares,
    max(buy_price)             FILTER (WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL) AS max_buy_price,
    min(buy_price)             FILTER (WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL) AS min_buy_price,
    sum(buy_price * shares)    FILTER (WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL) AS sum_buy_value,
    max(buy_order_id)          FILTER (WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL) AS max_buy_order_id,
    min(buy_order_id)          FILTER (WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL) AS min_buy_order_id,
    max(buy_coinbase_order_id) FILTER (WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL) AS max_buy_coinbase_order_id,
    min(buy_coinbase_order_id) FILTER (WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL) AS min_buy_coinbase_order_id,
    max(buy_filled_price)      FILTER (WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL) AS max_buy_filled_price,
    -- (old CASE bool_or(buy_filled_price IS NULL) guard no longer needed: held rows are always filled)
    min(buy_filled_price)      FILTER (WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL) AS min_buy_filled_price,
    min(buy_stop_price)        FILTER (WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL) AS min_buy_stop_price,
    max(buy_stop_price)        FILTER (WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL) AS max_buy_stop_price,
    min(date_created)          FILTER (WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL) AS min_date_created,
    max(date_created)          FILTER (WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL) AS max_date_created,
    -- ---- appended 2026-09-25 ----
    -- true cost basis of held bags: actual fill price * shares + buy fee
    sum(buy_filled_price * shares + COALESCE(buy_fee, 0))
                               FILTER (WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL) AS held_cost_filled,
    -- planned / open buys that have not filled: no coin in the account yet
    count(*)                   FILTER (WHERE buy_filled_price IS NULL)       AS pending_cnt,
    sum(shares)                FILTER (WHERE buy_filled_price IS NULL)       AS pending_shares,
    sum(buy_price * shares)    FILTER (WHERE buy_filled_price IS NULL)       AS pending_value,
    -- sell filled but row not yet moved to profit_history; should always be 0
    count(*)                   FILTER (WHERE sell_filled_price IS NOT NULL)  AS sold_unclosed_cnt
FROM position
GROUP BY stock_id, name, period_type;
