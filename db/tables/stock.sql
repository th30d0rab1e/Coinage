CREATE TABLE IF NOT EXISTS public.stock (
    stock_id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name                 text,
    date_created         date,
    price                double precision,
    historical_finished  bit(1),
    historical_last_date date,
    priority             bigint,
    price_movement       text,
    max_shares           double precision,
    min_shares           double precision,
    min_price            double precision,
    max_price            double precision,
    share_rounding       integer,
    price_rounding       integer,
    trading_disabled     boolean,
    -- 2026-10-07: TRUE = behaves like a $1 stablecoin (price within
    -- config.stablecoin_price_band_pct of $1 and 24h range under
    -- config.stablecoin_max_range_pct). Set by thee_procedure from the
    -- products feed, sticky (never auto-cleared); every buy INSERT skips it.
    -- See db/migrations/2026-10-07_stablecoin_flag.sql.
    is_stablecoin        boolean NOT NULL DEFAULT false
);
