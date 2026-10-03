CREATE TABLE IF NOT EXISTS public.portfolio (
    portfolio_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Which account owns this portfolio. Nullable so a row can exist before it is assigned.
    account_id   integer REFERENCES public.account (account_id),
    date_created timestamp without time zone
);
