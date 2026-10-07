CREATE TABLE IF NOT EXISTS public.profit_history (
    profit_history_id      integer PRIMARY KEY DEFAULT nextval('profit_history_profit_history_id_seq'),
    stock_id               integer,
    name                   text,
    period_type            text,
    buy_coinbase_order_id  text,
    sell_fills_id          text,
    buy_fee                double precision,
    sell_fee               double precision,
    profit                 double precision,
    date_created           timestamp without time zone DEFAULT now(),
    -- 2026-10-07 (migrations/2026-10-07_usdc_profit_sweep.sql):
    -- copied from position at close; swept to USDC by index.js.
    profit_converted_usdc  numeric,
    -- USDC sweep state: NULL = not swept, 'pending' = in an in-flight
    -- convert, 'completed', 'failed' (retried next minute).
    usdc_convert_status    text
                           CONSTRAINT profit_history_usdc_convert_status_check
                           CHECK (usdc_convert_status IS NULL
                                  OR usdc_convert_status IN ('pending', 'completed', 'failed')),
    -- Coinbase convert trade id of the latest attempt (set just before commit).
    usdc_convert_trade_id  text,
    -- when Coinbase confirmed the convert.
    usdc_converted_at      timestamptz
);

CREATE INDEX IF NOT EXISTS profit_history_usdc_unswept
    ON public.profit_history (profit_history_id)
    WHERE profit_converted_usdc > 0
    AND usdc_convert_status IS DISTINCT FROM 'completed';
