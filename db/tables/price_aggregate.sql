CREATE TABLE IF NOT EXISTS public.price_aggregate (
    price_aggregate_id integer PRIMARY KEY DEFAULT nextval('price_aggregates_price_aggregate_id_seq'),
    stock_id           integer,
    period_type        text,
    period_date        date,
    open               double precision,
    close              double precision,
    high               double precision,
    low                double precision,
    avg_price          double precision
);
