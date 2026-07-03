CREATE OR REPLACE PROCEDURE public.insert_aggregate()
LANGUAGE sql
AS $$

INSERT INTO price_aggregate (stock_id, period_type, period_date, low, high, open, close, avg_price)
SELECT
    bs.stock_id,
    'year' AS period_type,
    DATE_TRUNC('year', TO_TIMESTAMP(bs.start))::DATE AS period_date,
    MIN(bs.low) AS low,
    MAX(bs.high) AS high,
    (ARRAY_AGG(bs.open ORDER BY start ASC))[1] AS open,
    (ARRAY_AGG(bs.close ORDER BY start DESC))[1] AS close,
    AVG(bs.close) AS avg_price
FROM bulk_historical bs
LEFT JOIN price_aggregate pa
     ON bs.stock_id = pa.stock_id
     AND pa.period_type = 'year'
     AND pa.period_date = DATE_TRUNC('year', TO_TIMESTAMP(bs.start))::DATE
WHERE pa.price_aggregate_id IS NULL
GROUP BY bs.stock_id, DATE_TRUNC('year', TO_TIMESTAMP(bs.start))
ORDER BY stock_id, period_date;

INSERT INTO price_aggregate (stock_id, period_type, period_date, low, high, open, close, avg_price)
SELECT
    bs.stock_id,
    'month' AS period_type,
    DATE_TRUNC('month', TO_TIMESTAMP(bs.start))::DATE AS period_date,
    MIN(bs.low) AS low,
    MAX(bs.high) AS high,
    (ARRAY_AGG(bs.open ORDER BY start ASC))[1] AS open,
    (ARRAY_AGG(bs.close ORDER BY start DESC))[1] AS close,
    AVG(bs.close) AS avg_price
FROM bulk_historical bs
LEFT JOIN price_aggregate pa
     ON bs.stock_id = pa.stock_id
     AND pa.period_type = 'month'
     AND pa.period_date = DATE_TRUNC('month', TO_TIMESTAMP(bs.start))::DATE
WHERE pa.price_aggregate_id IS NULL
GROUP BY bs.stock_id, DATE_TRUNC('month', TO_TIMESTAMP(bs.start))
ORDER BY stock_id, period_date;

UPDATE stock s SET historical_finished = 1::bit
FROM bulk_historical bh
WHERE s.stock_id = bh.stock_id;

TRUNCATE TABLE bulk_historical;

$$;
