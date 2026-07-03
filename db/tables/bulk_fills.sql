CREATE TABLE IF NOT EXISTS public.bulk_fills (
    bulk_fills_id integer PRIMARY KEY DEFAULT nextval('bulk_fills_bulk_fills_id_seq'),
    created_at    timestamp without time zone,
    trade_id      text,
    product_id    text,
    order_id      text,
    profile_id    text,
    liquidity     text,
    price         double precision,
    size          double precision,
    fee           double precision,
    side          text,
    settled       text
);
