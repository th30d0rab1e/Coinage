-- 2026-10-11 (Theodore, voice): seed rsi_history from day closes (Wilder 14),
-- one point per stock per day. Live capture remains 5-minute via aggregate().
CREATE OR REPLACE FUNCTION public.fn_backfill_rsi_history_days(p_days integer DEFAULT 90)
RETURNS integer
LANGUAGE plpgsql
AS $fn$
DECLARE
    r record;
    cur_stock integer;
    prev_close double precision;
    n integer;
    sum_gain double precision;
    sum_loss double precision;
    avg_gain double precision;
    avg_loss double precision;
    change double precision;
    rsi numeric;
    v_n integer := 0;
    p_period integer := 14;
    inserted integer;
BEGIN
    FOR r IN
        SELECT pa.stock_id, pa.period_date, pa.close
        FROM price_aggregate pa
        WHERE pa.period_type = 'day'
          AND pa.close IS NOT NULL
          AND pa.period_date >= (CURRENT_DATE - (p_days + p_period + 5))
        ORDER BY pa.stock_id, pa.period_date
    LOOP
        IF cur_stock IS DISTINCT FROM r.stock_id THEN
            cur_stock := r.stock_id;
            prev_close := r.close;
            n := 0; sum_gain := 0; sum_loss := 0;
            avg_gain := 0; avg_loss := 0;
            CONTINUE;
        END IF;

        change := r.close - prev_close;
        prev_close := r.close;
        n := n + 1;

        IF n <= p_period THEN
            sum_gain := sum_gain + GREATEST(change, 0);
            sum_loss := sum_loss + GREATEST(-change, 0);
            IF n = p_period THEN
                avg_gain := sum_gain / p_period;
                avg_loss := sum_loss / p_period;
            ELSE
                CONTINUE;
            END IF;
        ELSE
            avg_gain := (avg_gain * (p_period - 1) + GREATEST(change, 0)) / p_period;
            avg_loss := (avg_loss * (p_period - 1) + GREATEST(-change, 0)) / p_period;
        END IF;

        IF r.period_date < CURRENT_DATE - p_days THEN
            CONTINUE;
        END IF;

        rsi := CASE
            WHEN avg_loss = 0 AND avg_gain = 0 THEN 50
            WHEN avg_loss = 0 THEN 100
            ELSE ROUND((100 - 100 / (1 + avg_gain / avg_loss))::numeric, 4)
        END;

        INSERT INTO rsi_history (stock_id, rsi, captured_at)
        VALUES (
            r.stock_id,
            rsi,
            ((r.period_date + 1) AT TIME ZONE 'America/Chicago') - interval '1 second'
        )
        ON CONFLICT (stock_id, captured_at) DO NOTHING;
        GET DIAGNOSTICS inserted = ROW_COUNT;
        v_n := v_n + inserted;
    END LOOP;
    RETURN v_n;
END;
$fn$;

COMMENT ON FUNCTION public.fn_backfill_rsi_history_days(integer) IS
    'Inserts one Wilder RSI(14) point per stock per day into rsi_history for the last p_days. Idempotent via unique (stock_id, captured_at).';
