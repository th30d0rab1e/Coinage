CREATE TABLE IF NOT EXISTS public.account (
    account_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_created timestamp without time zone,
    -- Email for this account. Nullable so the original row did not need a value.
    email        text
);
