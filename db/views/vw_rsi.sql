CREATE OR REPLACE VIEW public.vw_rsi AS
WITH price_changes AS (
    SELECT price_aggregate.stock_id,
        price_aggregate.period_type,
        price_aggregate.period_date,
        price_aggregate.close,
        lag(price_aggregate.close) OVER (PARTITION BY price_aggregate.stock_id, price_aggregate.period_type ORDER BY price_aggregate.period_date) AS prev_close
    FROM price_aggregate
),
gains_losses AS (
    SELECT price_changes.stock_id,
        price_changes.period_type,
        price_changes.period_date,
        GREATEST(price_changes.close - price_changes.prev_close, 0::double precision) AS gain,
        GREATEST(price_changes.prev_close - price_changes.close, 0::double precision) AS loss,
        row_number() OVER (PARTITION BY price_changes.stock_id, price_changes.period_type ORDER BY price_changes.period_date DESC) AS rn
    FROM price_changes
    WHERE price_changes.prev_close IS NOT NULL
),
rsi_calc AS (
    SELECT gains_losses.stock_id,
        gains_losses.period_type,
        avg(gains_losses.gain) AS avg_gain,
        avg(gains_losses.loss) AS avg_loss
    FROM gains_losses
    WHERE gains_losses.rn <= 14
    GROUP BY gains_losses.stock_id, gains_losses.period_type
)
SELECT stock_id,
    period_type,
    round(
        CASE
            WHEN avg_loss = 0::double precision THEN 100::double precision
            ELSE 100::double precision - 100.0::double precision / (1::double precision + avg_gain / avg_loss)
        END::numeric, 2) AS rsi
FROM rsi_calc;
