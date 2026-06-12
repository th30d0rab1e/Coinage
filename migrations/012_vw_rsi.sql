-- RSI view using 14-period simple average of gains/losses per stock and period_type

CREATE OR REPLACE VIEW public.vw_rsi AS
WITH price_changes AS (
    SELECT
        stock_id,
        period_type,
        period_date,
        close,
        LAG(close) OVER (PARTITION BY stock_id, period_type ORDER BY period_date) AS prev_close
    FROM price_aggregate
),
gains_losses AS (
    SELECT
        stock_id,
        period_type,
        period_date,
        GREATEST(close - prev_close, 0) AS gain,
        GREATEST(prev_close - close, 0) AS loss,
        ROW_NUMBER() OVER (PARTITION BY stock_id, period_type ORDER BY period_date DESC) AS rn
    FROM price_changes
    WHERE prev_close IS NOT NULL
),
rsi_calc AS (
    SELECT
        stock_id,
        period_type,
        AVG(gain) AS avg_gain,
        AVG(loss) AS avg_loss
    FROM gains_losses
    WHERE rn <= 14
    GROUP BY stock_id, period_type
)
SELECT
    stock_id,
    period_type,
    ROUND(
        CASE WHEN avg_loss = 0 THEN 100
             ELSE 100 - 100.0 / (1 + avg_gain / avg_loss)
        END::numeric, 2
    ) AS rsi
FROM rsi_calc;
