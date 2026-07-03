CREATE TABLE IF NOT EXISTS public.price_aggregate_comparison (
    price_aggregate_comparison_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    before_id                     integer,
    after_id                      integer,
    change_percent                double precision
);
