-- 2026-10-11: Wilder RSI over price_aggregate closes.
-- One ordered scan of price_aggregate; each (stock_id, period_type) is its own
-- series ordered by period_date ('day' rows -> daily RSI, 'month' -> monthly,
-- 'year' -> yearly). Rows with NULL close are skipped.
--   change     = close - previous close
--   first avg  = simple average of the first p_period gains / losses
--   after that = Wilder smoothing: (prev_avg * (p_period - 1) + current) / p_period
--   RSI        = 100 - 100 / (1 + avg_gain / avg_loss)
--                avg_loss = 0 -> 100; flat (both 0) -> 50
-- A row gets RSI only once p_period changes exist before it (p_period + 1
-- closes), so the first p_period rows of each series return nothing.
CREATE OR REPLACE FUNCTION public.fn_price_aggregate_rsi(p_period integer DEFAULT 14)
RETURNS TABLE(out_price_aggregate_id integer, out_rsi numeric)
LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
    r          record;
    series_key text;
    prev_close double precision;
    n          integer;           -- changes seen so far in this series
    sum_gain   double precision;
    sum_loss   double precision;
    avg_gain   double precision;
    avg_loss   double precision;
    change     double precision;
BEGIN
    FOR r IN
        SELECT pa.price_aggregate_id, pa.stock_id, pa.period_type, pa.close
        FROM price_aggregate pa
        WHERE pa.close IS NOT NULL
        ORDER BY pa.stock_id, pa.period_type, pa.period_date
    LOOP
        -- New series: first close is only the baseline for the next change.
        IF series_key IS DISTINCT FROM r.stock_id || '|' || r.period_type THEN
            series_key := r.stock_id || '|' || r.period_type;
            prev_close := r.close;
            n := 0; sum_gain := 0; sum_loss := 0;
            CONTINUE;
        END IF;

        change := r.close - prev_close;
        prev_close := r.close;
        n := n + 1;

        IF n <= p_period THEN
            -- Seed window: accumulate, first RSI lands on change #p_period.
            sum_gain := sum_gain + GREATEST(change, 0);
            sum_loss := sum_loss + GREATEST(-change, 0);
            IF n < p_period THEN CONTINUE; END IF;
            avg_gain := sum_gain / p_period;
            avg_loss := sum_loss / p_period;
        ELSE
            -- Wilder smoothing.
            avg_gain := (avg_gain * (p_period - 1) + GREATEST(change, 0)) / p_period;
            avg_loss := (avg_loss * (p_period - 1) + GREATEST(-change, 0)) / p_period;
        END IF;

        out_price_aggregate_id := r.price_aggregate_id;
        out_rsi := CASE
            WHEN avg_loss = 0 AND avg_gain = 0 THEN 50
            WHEN avg_loss = 0 THEN 100
            ELSE ROUND((100 - 100 / (1 + avg_gain / avg_loss))::numeric, 4)
        END;
        RETURN NEXT;
    END LOOP;
END
$fn$;

COMMENT ON FUNCTION public.fn_price_aggregate_rsi(integer) IS
    'Wilder RSI(p_period, default 14) for every price_aggregate row with p_period prior changes in its (stock_id, period_type) series ordered by period_date, from close. Used by aggregate() to fill price_aggregate.rsi.';
