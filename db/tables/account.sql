CREATE TABLE IF NOT EXISTS public.account (
    account_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_created timestamp without time zone
);
