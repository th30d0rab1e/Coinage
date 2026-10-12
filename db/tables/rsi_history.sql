-- 2026-10-11 (Theodore, voice): time series of stock.rsi for charting / logging.
-- Wilder RSI(7) itself still lives on stock and is computed in aggregate();
-- this table only snapshots that value on a regular interval (5-minute buckets).
CREATE TABLE IF NOT EXISTS public.rsi_history (
    rsi_history_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    stock_id       integer NOT NULL REFERENCES public.stock (stock_id),
    rsi            numeric NOT NULL,
    captured_at    timestamptz NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS rsi_history_stock_captured_uidx
    ON public.rsi_history (stock_id, captured_at);

CREATE INDEX IF NOT EXISTS rsi_history_captured_idx
    ON public.rsi_history (captured_at DESC);

COMMENT ON TABLE public.rsi_history IS
    'Snapshots of stock.rsi (Wilder 14) for history/charting. One row per stock per 5-minute bucket. Rows older than 30 days are deleted in aggregate(). Buy logic does not read this table.';
COMMENT ON COLUMN public.rsi_history.rsi IS
    'Copy of stock.rsi at captured_at (5-minute floor of NOW()).';
COMMENT ON COLUMN public.rsi_history.captured_at IS
    'Bucket start: date_trunc(''minute'', now()) floored to 5 minutes (America/Chicago box clock / timestamptz).';
