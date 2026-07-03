CREATE OR REPLACE VIEW public.vw_position AS
SELECT stock_id,
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
    CASE
        WHEN bool_or(buy_filled_price IS NULL) THEN NULL::double precision
        ELSE min(buy_filled_price)
    END AS min_buy_filled_price,
    min(buy_stop_price) AS min_buy_stop_price,
    max(buy_stop_price) AS max_buy_stop_price,
    min(date_created) AS min_date_created,
    max(date_created) AS max_date_created
FROM position
GROUP BY stock_id, name, period_type;
