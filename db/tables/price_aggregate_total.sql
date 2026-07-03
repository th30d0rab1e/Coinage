CREATE TABLE IF NOT EXISTS public.price_aggregate_total (
    price_aggregate_total_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    stock_id                 integer,
    period_type              text,
    avg_change_percent       double precision,
    std_dev                  double precision,
    std_dev_upper_bound      double precision,
    std_dev_lower_bound      double precision
);
