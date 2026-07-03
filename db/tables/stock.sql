CREATE TABLE IF NOT EXISTS public.stock (
    stock_id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name                 text,
    date_created         date,
    price                double precision,
    historical_finished  bit(1),
    historical_last_date date,
    score                bigint,
    price_movement       text,
    max_shares           double precision,
    min_shares           double precision,
    min_price            double precision,
    max_price            double precision,
    share_rounding       integer,
    price_rounding       integer
);
