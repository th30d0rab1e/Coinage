CREATE OR REPLACE VIEW public.vw_latest_fills AS
SELECT s.stock_id,
    s.name,
    bfs.bulk_fills_id AS sell_id,
    bfs.order_id AS sell_order,
    bfs.created_at AS sell_date,
    bfs.price AS sell_price,
    bfs.size AS sell_size,
    bfs.fee AS sell_fee,
    bfs.price * bfs.size AS sell_value,
    bfb.bulk_fills_id AS buy_id,
    bfb.order_id AS buy_order,
    bfb.created_at AS buy_date,
    bfb.price AS buy_price,
    bfb.size AS buy_size,
    bfb.fee AS buy_fee,
    bfb.price * bfb.size AS buy_value
FROM stock s
LEFT JOIN (
    SELECT bulk_fills.product_id, bulk_fills.side, max(bulk_fills.bulk_fills_id) AS max_id
    FROM bulk_fills
    WHERE bulk_fills.side = 'SELL'::text
    GROUP BY bulk_fills.product_id, bulk_fills.side
) max_sell ON s.name = max_sell.product_id
LEFT JOIN bulk_fills bfs ON max_sell.max_id = bfs.bulk_fills_id
LEFT JOIN (
    SELECT bulk_fills.product_id, bulk_fills.side, max(bulk_fills.bulk_fills_id) AS max_id
    FROM bulk_fills
    WHERE bulk_fills.side = 'BUY'::text
    GROUP BY bulk_fills.product_id, bulk_fills.side
) max_buy ON s.name = max_sell.product_id
LEFT JOIN bulk_fills bfb ON max_buy.max_id = bfb.bulk_fills_id;
