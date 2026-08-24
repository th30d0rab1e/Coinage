-- Any fill this cycle sees in bulk_fills that no position and no
-- profit_history row claims (checked by buy_coinbase_order_id /
-- sell_coinbase_order_id / sell_fills_id) gets logged here by
-- thee_procedure() right before bulk_fills is truncated, instead of
-- silently disappearing. This is the gap that let 22 real trades vanish
-- untracked between 2026-08-14 and 2026-08-19 -- whatever the cause,
-- a fill can no longer leave zero trace.
CREATE TABLE IF NOT EXISTS public.unmatched_fills (
    unmatched_fill_id BIGSERIAL PRIMARY KEY,
    order_id          text,
    trade_id          text,
    product_id        text,
    side              text,
    price             double precision,
    size              double precision,
    fee               double precision,
    trade_time        timestamp without time zone,
    detected_at       timestamp without time zone NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_unmatched_fills_order_id ON public.unmatched_fills (order_id);
