-- Permanent, append-only ledger of every fill this account has ever had.
-- Populated by thee_procedure() each cycle from bulk_fills (which gets
-- truncated every cycle and is not itself a historical record). Source
-- of truth for fill history going forward -- reconstructing past fills
-- from position_audit's DELETE snapshots (a side effect of the audit
-- trigger, not designed for this) is fragile and was already found
-- bypassable.
CREATE TABLE IF NOT EXISTS public.fills (
    fill_id      BIGSERIAL PRIMARY KEY,
    order_id     text,
    trade_id     text,
    product_id   text,
    side         text,
    price        double precision,
    size         double precision,
    fee          double precision,
    trade_time   timestamp without time zone,
    recorded_at  timestamp without time zone NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_fills_trade_id ON public.fills (trade_id);
CREATE INDEX IF NOT EXISTS idx_fills_order_id ON public.fills (order_id);
