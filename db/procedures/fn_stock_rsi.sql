-- 2026-10-11: Wilder RSI for stock.rsi, computed from price_aggregate DAY closes.
-- price_aggregate is INPUT ONLY here: this function only reads it and writes
-- nothing. Replaces fn_price_aggregate_rsi (price_aggregate no longer has rsi).
-- Per stock_id, the day series (period_type = 'day') ordered by period_date,
-- rows with NULL close skipped:
--   change     = close - previous close
--   first avg  = simple average of the first p_period gains / losses
--   after that = Wilder smoothing: (prev_avg * (p_period - 1) + current) / p_period
--   RSI        = 100 - 100 / (1 + avg_gain / avg_loss)
--                avg_loss = 0 -> 100; flat (both 0) -> 50
-- Returns ONE row per stock_id: the RSI as of its latest day close. A stock
-- needs p_period + 1 day closes (15 for RSI(14)); fewer -> no row (stock.rsi NULL).
CREATE OR REPLACE FUNCTION public.fn_stock_rsi(p_period integer DEFAULT 14)
RETURNS TABLE(out_stock_id integer, out_rsi numeric)
LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
    r          record;
    cur_stock  integer;
    prev_close double precision;
    n          integer;           -- changes seen so far for cur_stock
    sum_gain   double precision;
    sum_loss   double precision;
    avg_gain   double precision;
    avg_loss   double precision;
    change     double precision;

BEGIN
    FOR r IN
        SELECT pa.stock_id, pa.close
        FROM price_aggregate pa
        WHERE pa.period_type = 'day'
        AND pa.close IS NOT NULL
        ORDER BY pa.stock_id, pa.period_date
    LOOP
        IF cur_stock IS DISTINCT FROM r.stock_id THEN
            -- Finish the previous stock: its last computed RSI is the latest.
            IF cur_stock IS NOT NULL AND n >= p_period THEN
                out_stock_id := cur_stock;
                out_rsi := CASE
                    WHEN avg_loss = 0 AND avg_gain = 0 THEN 50
                    WHEN avg_loss = 0 THEN 100
                    ELSE ROUND((100 - 100 / (1 + avg_gain / avg_loss))::numeric, 4)
                END;
                RETURN NEXT;
            END IF;
            -- New stock: first close is only the baseline for the next change.
            cur_stock := r.stock_id;
            prev_close := r.close;
            n := 0; sum_gain := 0; sum_loss := 0;
            CONTINUE;
        END IF;

        change := r.close - prev_close;
        prev_close := r.close;
        n := n + 1;

        IF n <= p_period THEN
            -- Seed window: accumulate, first averages land on change #p_period.
            sum_gain := sum_gain + GREATEST(change, 0);
            sum_loss := sum_loss + GREATEST(-change, 0);
            IF n = p_period THEN
                avg_gain := sum_gain / p_period;
                avg_loss := sum_loss / p_period;
            END IF;
        ELSE
            -- Wilder smoothing.
            avg_gain := (avg_gain * (p_period - 1) + GREATEST(change, 0)) / p_period;
            avg_loss := (avg_loss * (p_period - 1) + GREATEST(-change, 0)) / p_period;
        END IF;
    END LOOP;

    -- Last stock in the scan.
    IF cur_stock IS NOT NULL AND n >= p_period THEN
        out_stock_id := cur_stock;
        out_rsi := CASE
            WHEN avg_loss = 0 AND avg_gain = 0 THEN 50
            WHEN avg_loss = 0 THEN 100
            ELSE ROUND((100 - 100 / (1 + avg_gain / avg_loss))::numeric, 4)
        END;
        RETURN NEXT;
    END IF;
END
$fn$;

COMMENT ON FUNCTION public.fn_stock_rsi(integer) IS
    'Wilder RSI(p_period, default 14) per stock_id as of its latest price_aggregate day close (period_type=''day'', ordered by period_date). Reads price_aggregate only. One row per stock with at least p_period+1 day closes. Used by aggregate() to fill stock.rsi.';
