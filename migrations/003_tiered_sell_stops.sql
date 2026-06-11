-- Widen sell stops based on intra-period volatility analysis
-- Day:   median intra-day drop 2.49%  → 3% stop  (was 1%)
-- Month: median monthly drop   8.79%  → 10% stop (was 1%)
-- Year:  median yearly drop   21.49%  → 25% stop (was 1%)

-- Backfill existing unfilled sell positions
UPDATE position
SET sell_stop_price = CASE period_type
        WHEN 'day'   THEN TRUNC(stock.price::numeric * 0.97, stock.price_rounding::int)
        WHEN 'month' THEN TRUNC(stock.price::numeric * 0.90, stock.price_rounding::int)
        WHEN 'year'  THEN TRUNC(stock.price::numeric * 0.75, stock.price_rounding::int)
    END,
    sell_price = CASE period_type
        WHEN 'day'   THEN TRUNC(stock.price::numeric * 0.96, stock.price_rounding::int)
        WHEN 'month' THEN TRUNC(stock.price::numeric * 0.89, stock.price_rounding::int)
        WHEN 'year'  THEN TRUNC(stock.price::numeric * 0.74, stock.price_rounding::int)
    END
FROM stock
WHERE position.stock_id = stock.stock_id
  AND position.buy_filled_price IS NOT NULL
  AND position.sell_filled_price IS NULL;
