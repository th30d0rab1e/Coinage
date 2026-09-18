-- Read-only order-book pressure log. Does not drive buys/sells.
-- imbalance: (near_bid_usd - near_ask_usd) / (near_bid_usd + near_ask_usd)
--   near +1 = bid-heavy, near -1 = ask-heavy, within band_pct of mid.
CREATE TABLE IF NOT EXISTS public.book_snapshot (
    book_snapshot_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    stock_id         integer,
    name             text,
    best_bid         double precision,
    best_ask         double precision,
    mid              double precision,
    spread_pct       double precision,
    near_bid_usd     double precision,
    near_ask_usd     double precision,
    imbalance        double precision,
    band_pct         double precision,
    bid_levels       integer,
    ask_levels       integer,
    date_created     timestamp DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS book_snapshot_name_created_idx
    ON public.book_snapshot (name, date_created DESC);
