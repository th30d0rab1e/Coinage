CREATE OR REPLACE PROCEDURE public.aggregate()
LANGUAGE sql
AS $$

DELETE FROM price_history
WHERE date_created < NOW() - INTERVAL '25 hours';

DELETE FROM price_aggregate
WHERE period_date < NOW() - INTERVAL '31 days'
AND period_type = 'day';

DELETE FROM price_aggregate
WHERE period_date < NOW() - INTERVAL '13 months'
AND period_type = 'month';

INSERT INTO price_history(stock_id, price, date_created)
SELECT stock_id, price, now()
FROM stock;

INSERT INTO price_aggregate (stock_id, period_type, period_date, open, close, high, low, avg_price)
SELECT stock_id, 'day', DATE_TRUNC('day', NOW())::DATE,
    MIN(price), MAX(price), MAX(price), MIN(price), AVG(price)
FROM stock
WHERE NOT EXISTS (
    SELECT 1 FROM price_aggregate pa
    WHERE pa.stock_id = stock.stock_id
    AND pa.period_type = 'day'
    AND pa.period_date = DATE_TRUNC('day', NOW())::DATE
)
GROUP BY stock_id

UNION ALL

SELECT stock_id, 'month', DATE_TRUNC('month', NOW())::DATE,
    MIN(open), MAX(close), MAX(high), MIN(low), AVG(avg_price)
FROM price_aggregate
WHERE period_type = 'day'
AND period_date >= NOW() - INTERVAL '30 days'
AND NOT EXISTS (
    SELECT 1 FROM price_aggregate pa
    WHERE pa.stock_id = price_aggregate.stock_id
    AND pa.period_type = 'month'
    AND pa.period_date = DATE_TRUNC('month', NOW())::DATE
)
GROUP BY stock_id

UNION ALL

SELECT stock_id, 'year', DATE_TRUNC('year', NOW())::DATE,
    MIN(open), MAX(close), MAX(high), MIN(low), AVG(avg_price)
FROM price_aggregate
WHERE period_type = 'month'
AND period_date >= NOW() - INTERVAL '12 months'
AND NOT EXISTS (
    SELECT 1 FROM price_aggregate pa
    WHERE pa.stock_id = price_aggregate.stock_id
    AND pa.period_type = 'year'
    AND pa.period_date = DATE_TRUNC('year', NOW())::DATE
)
GROUP BY stock_id;

UPDATE price_aggregate pa
SET
    open = s.open,
    close = s.close,
    high = s.max_price,
    low = s.min_price,
    avg_price = s.avg_price
FROM (
    SELECT DISTINCT ON (stock_id)
        stock_id,
        FIRST_VALUE(price) OVER (PARTITION BY stock_id ORDER BY price_history_id ASC) AS open,
        LAST_VALUE(price) OVER (PARTITION BY stock_id ORDER BY price_history_id ASC ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS close,
        MIN(price) OVER (PARTITION BY stock_id) AS min_price,
        MAX(price) OVER (PARTITION BY stock_id) AS max_price,
        AVG(price) OVER (PARTITION BY stock_id) AS avg_price
    FROM price_history
    WHERE date_created::date = DATE_TRUNC('day', NOW())::DATE
    ORDER BY stock_id
) s
WHERE pa.stock_id = s.stock_id
AND pa.period_type = 'day'
AND pa.period_date = DATE_TRUNC('day', NOW())::DATE;

UPDATE price_aggregate pa
SET
    open = s.open,
    close = s.close,
    high = s.high,
    low = s.low,
    avg_price = s.avg_price
FROM (
    SELECT stock_id,
        (ARRAY_AGG(open ORDER BY period_date ASC))[1] AS open,
        (ARRAY_AGG(close ORDER BY period_date DESC))[1] AS close,
        MAX(high) AS high,
        MIN(low) AS low,
        AVG(avg_price) AS avg_price
    FROM price_aggregate
    WHERE period_type = 'day'
    AND period_date >= NOW() - INTERVAL '30 days'
    GROUP BY stock_id
) s
WHERE pa.stock_id = s.stock_id
AND pa.period_type = 'month'
AND pa.period_date = DATE_TRUNC('month', NOW())::DATE;

UPDATE price_aggregate pa
SET
    open = s.open,
    close = s.close,
    high = s.high,
    low = s.low,
    avg_price = s.avg_price
FROM (
    SELECT stock_id,
        (ARRAY_AGG(open ORDER BY period_date ASC))[1] AS open,
        (ARRAY_AGG(close ORDER BY period_date DESC))[1] AS close,
        MAX(high) AS high,
        MIN(low) AS low,
        AVG(avg_price) AS avg_price
    FROM price_aggregate
    WHERE period_type = 'month'
    AND period_date >= NOW() - INTERVAL '12 months'
    GROUP BY stock_id
) s
WHERE pa.stock_id = s.stock_id
AND pa.period_type = 'year'
AND pa.period_date = DATE_TRUNC('year', NOW())::DATE;

INSERT INTO price_aggregate_comparison (before_id, after_id, change_percent)
SELECT
    pa_before.price_aggregate_id AS before_id,
    pa_after.price_aggregate_id AS after_id,
    ((pa_after.close - pa_before.close) / pa_before.close) * 100 AS change_percent
FROM price_aggregate pa_before
JOIN price_aggregate pa_after
    ON pa_before.stock_id = pa_after.stock_id
    AND pa_before.period_type = pa_after.period_type
    AND (
        (pa_before.period_type = 'day' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 day')
        OR (pa_before.period_type = 'year' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 year')
        OR (pa_before.period_type = 'month' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 month')
    )
LEFT JOIN price_aggregate_comparison pac
    ON pa_before.price_aggregate_id = pac.before_id
    AND pa_after.price_aggregate_id = pac.after_id
WHERE pac.price_aggregate_comparison_id IS NULL;

UPDATE price_aggregate_comparison pac
SET change_percent = ((pa_after.close - pa_before.close) / pa_before.close) * 100
FROM price_aggregate pa_before
JOIN price_aggregate pa_after
    ON pa_before.stock_id = pa_after.stock_id
    AND pa_before.period_type = pa_after.period_type
    AND (
        (pa_before.period_type = 'day' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 day')
        OR (pa_before.period_type = 'year' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 year')
        OR (pa_before.period_type = 'month' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 month')
    )
WHERE pac.before_id = pa_before.price_aggregate_id
AND pac.after_id = pa_after.price_aggregate_id;

INSERT INTO price_aggregate_total (stock_id, period_type, avg_change_percent)
SELECT
    pa.stock_id,
    pa.period_type,
    AVG(pac.change_percent) AS avg_change_percent
FROM price_aggregate_comparison pac
JOIN price_aggregate pa ON pa.price_aggregate_id = pac.before_id
LEFT JOIN price_aggregate_total pat
    ON pa.stock_id = pat.stock_id
    AND pa.period_type = pat.period_type
WHERE pat.price_aggregate_total_id IS NULL
GROUP BY pa.stock_id, pa.period_type;

UPDATE price_aggregate_total pat
SET
    avg_change_percent = x.avg_change_percent,
    std_dev = x.std_dev,
    std_dev_upper_bound = x.avg_change_percent + (2 * x.std_dev),
    std_dev_lower_bound = x.avg_change_percent - (2 * x.std_dev)
FROM (
    SELECT
        pa.stock_id,
        pa.period_type,
        AVG(pac.change_percent) AS avg_change_percent,
        STDDEV(pac.change_percent) AS std_dev
    FROM price_aggregate_comparison pac
    JOIN price_aggregate pa ON pa.price_aggregate_id = pac.before_id
    GROUP BY pa.stock_id, pa.period_type
) x
WHERE pat.stock_id = x.stock_id
AND pat.period_type = x.period_type;

-- 2026-10-11: stock.rsi = Wilder RSI(14) from price_aggregate DAY closes
-- (see db/procedures/fn_stock_rsi.sql). Runs after the day closes above are
-- refreshed, so the current day's close counts. price_aggregate is input only;
-- nothing here writes RSI to it. Stocks with under 15 day closes go to NULL.
UPDATE stock s
SET rsi = r.out_rsi
FROM (
    SELECT st.stock_id, fr.out_rsi
    FROM stock st
    LEFT JOIN fn_stock_rsi(14) fr ON fr.out_stock_id = st.stock_id
) r
WHERE s.stock_id = r.stock_id
AND s.rsi IS DISTINCT FROM r.out_rsi;

-- 2026-10-11 (Theodore, voice): log stock.rsi into rsi_history (5-min buckets)
-- for charting later. Buy logic does not read rsi_history.
-- aggregate() is LANGUAGE sql, so SELECT the capture function (not PERFORM).
SELECT public.fn_capture_rsi_history();

$$;
