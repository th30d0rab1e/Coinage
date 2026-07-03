CREATE TABLE IF NOT EXISTS public.price_history (
    price_history_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    stock_id         integer,
    price            double precision,
    date_created     date
);
