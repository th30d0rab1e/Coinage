-- Top-of-book (best bid / best ask) for EVERY Coinbase product, refreshed
-- once per bot run by index.js processBestBidAsk() BEFORE thee_procedure(),
-- from ONE call: GET /api/v3/brokerage/best_bid_ask with no product_ids
-- (~1000 products, ~0.2 s). The products feed (bulk_stock) has empty
-- best_bid_price / best_ask_price, so this is the only per-minute spread
-- source for all coins, including never-held ones.
--
-- Why (2026-10-05): the wide-spread / ask-heavy / thin-ask buy checks used
-- to run in index.js processBuyOrders() AFTER rows were already planned, so
-- a coin like ABT or LSETH (spread ~2%) was planned, then deferred every
-- minute while its row kept reserving cash in the procedure's backlog gate.
-- thee_procedure() now applies the spread gate on both buy inserts and
-- deletes unsent planned rows that fail it, using this table.
--
-- Replaced wholesale each run (DELETE + INSERT in one transaction). If the
-- API call fails the table is emptied, and thee_procedure() treats an empty
-- or stale (loaded_at older than 3 minutes) table as "no data" and fails
-- open on spread. With fresh data, a coin missing from the table (or with
-- no two-sided quote, spread_pct NULL) is rejected.
CREATE TABLE IF NOT EXISTS public.bulk_best_bid_ask (
    product_id     text PRIMARY KEY,
    best_bid       double precision,
    best_bid_size  double precision,
    best_ask       double precision,
    best_ask_size  double precision,
    -- (ask - bid) / mid * 100. NULL when either side is missing or <= 0.
    spread_pct     double precision,
    -- Coinbase's quote time for this book (can be old on illiquid products).
    quote_time     timestamptz,
    -- When this run loaded the row (DB convention: Chicago local, now()).
    loaded_at      timestamp without time zone NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.bulk_best_bid_ask IS
    'Best bid/ask for every product, reloaded each run by index.js processBestBidAsk() before thee_procedure(). Feeds the procedure spread gate. Empty or >3 min old = fail open.';
COMMENT ON COLUMN public.bulk_best_bid_ask.spread_pct IS
    '(best_ask - best_bid) / mid * 100. NULL when there is no two-sided quote (rejected by the spread gate when data is fresh).';
