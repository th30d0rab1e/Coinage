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
    json              json,
    -- 2026-10-07: launch-restriction / new-listing fields from the same
    -- products payload, as columns (they were only inside json). Used by
    -- modules/listingWatch.js and the listing snipe in thee_procedure.
    status            text,
    limit_only        text,
    auction_mode      text,
    is_new            text,
    new_at            text
);
