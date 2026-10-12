-- 2026-10-11 (Theodore, voice): snapshot stock.rsi into rsi_history.
-- 5-minute buckets so a once-a-minute bot run does not explode the table.
-- Skips NULL rsi. ON CONFLICT skips duplicate bucket. No buy-logic side effects.
CREATE OR REPLACE FUNCTION public.fn_capture_rsi_history()
RETURNS integer
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_bucket timestamptz :=
        to_timestamp(floor(extract(epoch FROM clock_timestamp()) / 300) * 300);
    v_n integer;
BEGIN
    INSERT INTO public.rsi_history (stock_id, rsi, captured_at)
    SELECT s.stock_id, s.rsi, v_bucket
    FROM public.stock s
    WHERE s.rsi IS NOT NULL
    ON CONFLICT (stock_id, captured_at) DO NOTHING;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$fn$;

COMMENT ON FUNCTION public.fn_capture_rsi_history() IS
    'Inserts current non-NULL stock.rsi into rsi_history for the current 5-minute bucket. Returns rows inserted. Called from aggregate() after stock.rsi refresh.';
