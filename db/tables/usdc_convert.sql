-- 2026-10-07 (migrations/2026-10-07_usdc_profit_sweep.sql): one row per
-- profit-to-USDC sweep attempt by index.js sweepProfitToUsdc().
-- status: pending (commit not sent) -> submitted (commit sent) ->
-- success (Coinbase TRADE_STATUS_COMPLETED) | failed (rows not stamped,
-- retried next minute). profit_history_ids = the exact rows it covers;
-- on success those rows get profit_history.usdc_convert_id = id.
CREATE TABLE IF NOT EXISTS public.usdc_convert (
    id                 serial PRIMARY KEY,
    amount_usd         numeric NOT NULL,
    usdc_received      numeric,
    coinbase_trade_id  text,
    status             text NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending', 'submitted', 'success', 'failed')),
    error              text,
    profit_history_ids integer[] NOT NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),
    completed_at       timestamptz
);

-- Only one unfinished sweep at a time (double-sweep guard).
CREATE UNIQUE INDEX IF NOT EXISTS usdc_convert_one_open
    ON public.usdc_convert ((true))
    WHERE status IN ('pending', 'submitted');
