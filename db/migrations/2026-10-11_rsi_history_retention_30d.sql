-- 2026-10-11 (Theodore, voice): keep rsi_history for 30 days only.
-- Cleanup runs inside aggregate() each minute (same cycle as price_history).

\i db/procedures/aggregate.sql

COMMENT ON TABLE public.rsi_history IS
    'Snapshots of stock.rsi (Wilder 14) for history/charting. One row per stock per 5-minute bucket. Rows older than 30 days are deleted in aggregate(). Buy logic does not read this table.';
