CREATE TABLE IF NOT EXISTS public.bulk_historical (
    stock_id integer,
    start    bigint,
    low      double precision,
    high     double precision,
    open     double precision,
    close    double precision,
    volume   double precision
);
