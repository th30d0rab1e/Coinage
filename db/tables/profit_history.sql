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
    -- usdc_convert row that swept it (NULL = not swept yet).
    usdc_convert_id        integer REFERENCES public.usdc_convert (id)
);

CREATE INDEX IF NOT EXISTS profit_history_unswept
    ON public.profit_history (profit_history_id)
    WHERE usdc_convert_id IS NULL AND profit_converted_usdc > 0;
