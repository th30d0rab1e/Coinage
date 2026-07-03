CREATE TABLE IF NOT EXISTS public.bulk_stock (
    bulk_stock_id     integer PRIMARY KEY DEFAULT nextval('bulk_stock_bulk_stock_id_seq'),
    id                text,
    quote_increment   text,
    base_increment    text,
    min_market_funds  text,
    trading_disabled  text,
    post_only         text,
    cancel_only       text,
    system            text,
    price             text,
    json              json
);
