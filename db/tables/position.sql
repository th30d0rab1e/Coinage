CREATE TABLE IF NOT EXISTS public.position (
    stock_id               integer,
    name                   text,
    shares                 double precision,
    date_created           timestamp without time zone,
    error_message          text,
    period_type            text,
    buy_filled_price       double precision,
    buy_price              double precision,
    sell_price             double precision,
    buy_order_id           text,
    sell_order_id          text,
    buy_coinbase_order_id  text,
    sell_coinbase_order_id text,
    buy_stop_price         double precision,
    sell_stop_price        double precision,
    sell_filled_price      double precision,
    buy_fee                double precision,
    sell_fee               double precision,
    profit                 double precision,
    daily_sell             boolean NOT NULL DEFAULT false,
    sell_counter           integer NOT NULL DEFAULT 0,
    buy_counter            integer NOT NULL DEFAULT 0,
    last_remade_at         timestamp without time zone,
    -- 2026-09-25 (migrations/2026-09-25_buy_placed_released_at.sql):
    -- when the current buy order was created/remade, and when far-buy cash
    -- release last cancelled it. Used to stop the place/cancel loop.
    buy_placed_at          timestamp without time zone,
    buy_released_at        timestamp without time zone,
    -- 2026-10-05 (migrations/2026-10-05_position_creation_hierarchy.sql):
    -- per-coin sequence of open positions with sell_price set (1 = cheapest
    -- fill); NULL when sell_price IS NULL. Order: buy_filled_price ASC
    -- NULLS LAST, then buy_stop_price ASC NULLS LAST, then position_id.
    -- thee_procedure recomputes it every run.
    creation_hierarchy       integer,
    -- 2026-10-07 (migrations/2026-10-07_usdc_profit_sweep.sql): net profit
    -- to sweep to USDC, GREATEST(0, TRUNC((sell*shares - sell_fee) -
    -- (buy*shares + buy_fee), 2)). NULL until thee_procedure fills it in;
    -- a closed row is not moved to profit_history / deleted before that.
    profit_converted_usdc    numeric,
    -- 2026-10-07 (migrations/2026-10-07_listing_usdc_fallback.sql):
    -- currency that paid for the BUY. NULL = USD on position.name
    -- (<COIN>-USD); 'USDC' = listing snipe sent to <COIN>-USDC because free
    -- USD was short (config.listing_usdc_fallback). The sell always goes on
    -- position.name (-USD) and returns USD.
    buy_quote_currency       text
);
