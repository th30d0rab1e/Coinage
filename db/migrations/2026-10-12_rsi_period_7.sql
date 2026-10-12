-- 2026-10-12 (Theodore): Wilder RSI lookback 14 -> 7 day closes (likes the volatility).
-- Thresholds (buy < 50, sell > 50) unchanged.
\i db/procedures/fn_stock_rsi.sql
\i db/procedures/aggregate.sql
\i db/procedures/fn_backfill_rsi_history_days.sql
COMMENT ON COLUMN public.stock.rsi IS
    'Wilder RSI(7) from price_aggregate day closes (period_type=''day'', ordered by period_date), as of the latest day. NULL until the stock has 8 day closes. Filled by aggregate() via fn_stock_rsi(7).';
UPDATE stock st SET rsi = fr.out_rsi
FROM fn_stock_rsi(7) fr WHERE fr.out_stock_id = st.stock_id;
SELECT public.fn_backfill_rsi_history_days(90);
SELECT public.fn_capture_rsi_history();
