CREATE TABLE IF NOT EXISTS public.bulk_currency (
    bulk_currency_id integer PRIMARY KEY DEFAULT nextval('bulk_currency_bulk_currency_id_seq'),
    id               text,
    currency         text,
    balance          double precision,
    hold             double precision,
    available        double precision,
    profile_id       text,
    trading_enabled  text
);
