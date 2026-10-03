CREATE TABLE IF NOT EXISTS public.portfolio (
    portfolio_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id   integer,
    date_created timestamp without time zone
);
