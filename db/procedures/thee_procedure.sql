CREATE OR REPLACE PROCEDURE public.thee_procedure()
LANGUAGE plpgsql
AS $$
-- ===========================================================================
-- 2026-10-07 BUY STOPS (Theodore; migrations/2026-10-07_buy_stop_cash_scaled.sql)
-- ===========================================================================
-- Every crypto buy (not listing snipes) is priced from ONE cash-scaled gap,
-- vw_buy_stop_gap.gap = buy_stop_base_pct/100 * sqrt(total_equity / free USD)
-- (USD only, no maximum; free USD 0/NULL -> $0.01):
--   * signal insert:       stop = close x (1 + gap), limit = stop x 1.01
--   * average-down insert: stop = price x (1 + gap), limit = stop x 1.01
--                          (was a flat price x 1.01 / x 1.011)
--   * stale refresh:       stop = price x (1 + gap), limit = stop x 1.01
--   * remake:              vw_edit_orders buy branch (same gap view)
-- Below-lowest-paid rule (fn_buy_below_paid) replaces the 0.99 x cheapest-bag
-- cap (config add_buy_cap_ratio, left in place but no longer read): on a coin
-- with open filled bags the LIMIT must be below the lowest buy_filled_price,
-- else limit = largest tick below it, stop = limit / 1.01 rounded down. The
-- inserts write the final stop/limit and judge the cash and thin-ask checks
-- on shares x that final limit; the add-on UPDATE re-applies the rule after
-- the stale refresh; clean-up (e) uses the highest stop the rule allows.

-- ===========================================================================
-- 2026-10-07 CONFIG VARIABLES (refactor; zero behavior change)
-- ===========================================================================
-- This procedure was LANGUAGE sql with config read inline (scalar subqueries
-- and CROSS JOIN LATERAL cfg / bookcfg blocks repeated per statement). It is
-- now LANGUAGE plpgsql: each config value is read ONCE into a variable, with
-- the SAME cast and COALESCE default the inline lookup used. ALL variables
-- are assigned once, at the top (right after the avg_profit refresh); none
-- is re-read mid-run (Theodore, 2026-10-07). Per-coin laterals
-- (clip size, min paid, fn_buy_below_paid, book snapshot, plan / eff math)
-- are unchanged.
--
--   variable                       config key (default)                 assigned
--   v_stablecoin_price_band_pct    stablecoin_price_band_pct  (3)        top
--   v_stablecoin_max_range_pct     stablecoin_max_range_pct   (2)        top
--   v_pending_buy_ttl_hours        pending_buy_ttl_hours      (24, int)  top
--   v_pause_buys                   pause_buys  (text; NULL if missing)    top
--   v_book_max_spread_pct          book_max_spread_pct        (0.75)     top
--   v_book_skip_imbalance          book_skip_imbalance        (-0.4)     top
--   v_book_min_ask_notional_mult   book_min_ask_notional_mult (5)        top
--   v_listing_buy_window_hours     listing_buy_window_hours   (24)       top
--   v_listing_buy_usd              listing_buy_usd            (1.00)     top
--   v_listing_max_buy_usd          listing_max_buy_usd        (5)        top
--   v_listing_limit_cushion_pct    listing_limit_cushion_pct  (2)        top
--   v_listing_max_open_bags        listing_max_open_bags      (3, int)   top
--   v_listing_usdc_fallback        listing_usdc_fallback = 'true' (missing = false)  top
--   (v_initial_buy_top_pct / config.initial_buy_top_pct retired 2026-10-08: the
--    initial-buy top-50% cut was replaced by WHERE s.priority > 0.)
--   v_sell_net_cushion             sell_net_cushion           (0.015)    top
--   v_fee_percent                  fee_percent                (1.20)     top
--     CONSEQUENCE: read BEFORE the fee-learning INSERT/UPDATE below, so a fee
--     learned this run takes effect in next minute's run (the old inline
--     lookups saw it in the same run).
--   Not config, same "read once" treatment:
--   v_bba_fresh   bulk_best_bid_ask loaded in the last 3 minutes (NOW() is fixed
--                 for the whole run and this procedure never writes that table).
--   v_gap         vw_buy_stop_gap.gap, assigned once at the top.
--     CONSEQUENCE: the signal insert, average-down insert and stale refresh all
--     use the same start-of-run gap (the old CROSS JOINs re-read the view per
--     statement, so position / balance changes earlier in the run could
--     shift it slightly).
-- config.avg_profit is refreshed by the first statement but not read here
-- (vw_edit_orders reads it), so it has no variable. The variables are
-- assigned after that UPDATE anyway.
DECLARE
    v_stablecoin_price_band_pct  numeric;
    v_stablecoin_max_range_pct   numeric;
    v_pending_buy_ttl_hours      integer;
    v_pause_buys                 text;
    v_book_max_spread_pct        numeric;
    v_book_skip_imbalance        numeric;
    v_book_min_ask_notional_mult numeric;
    v_listing_buy_window_hours   numeric;
    v_listing_buy_usd            numeric;
    v_listing_max_buy_usd        numeric;
    v_listing_limit_cushion_pct  numeric;
    v_listing_max_open_bags      integer;
    v_listing_usdc_fallback      boolean;
    v_sell_net_cushion           numeric;
    v_fee_percent                numeric;
    v_bba_fresh                  boolean;
    v_gap                        numeric;
BEGIN

-- 2026-10-07 (migrations/2026-10-07_avg_profit_config.sql): refresh
-- config.avg_profit = all-time AVG(profit_history.profit), the average
-- realized profit (USD) per closed position. Runs first, so it reflects
-- profit_history as of the previous run (this run's closes are recorded
-- further down). Text like every config value, 6 decimals, 0 when
-- profit_history is empty. Stored only: nothing reads it yet. If the row
-- is missing (migration not applied) this updates nothing.
UPDATE config
SET value = (SELECT ROUND(COALESCE(AVG(profit), 0)::numeric, 6)::text FROM profit_history)
WHERE key = 'avg_profit';

-- 2026-10-07 config variables (see the header): read once, after the
-- avg_profit refresh above. Same casts / defaults as the old inline lookups.
v_stablecoin_price_band_pct  := COALESCE((SELECT value::numeric FROM config WHERE key = 'stablecoin_price_band_pct'), 3);
v_stablecoin_max_range_pct   := COALESCE((SELECT value::numeric FROM config WHERE key = 'stablecoin_max_range_pct'), 2);
v_pending_buy_ttl_hours      := COALESCE((SELECT value::int     FROM config WHERE key = 'pending_buy_ttl_hours'), 24);
v_pause_buys                 := (SELECT value FROM config WHERE key = 'pause_buys');
v_book_max_spread_pct        := COALESCE((SELECT value::numeric FROM config WHERE key = 'book_max_spread_pct'), 0.75);
v_book_skip_imbalance        := COALESCE((SELECT value::numeric FROM config WHERE key = 'book_skip_imbalance'), -0.4);
v_book_min_ask_notional_mult := COALESCE((SELECT value::numeric FROM config WHERE key = 'book_min_ask_notional_mult'), 5);
v_listing_buy_window_hours   := COALESCE((SELECT value::numeric FROM config WHERE key = 'listing_buy_window_hours'), 24);
v_listing_buy_usd            := COALESCE((SELECT value::numeric FROM config WHERE key = 'listing_buy_usd'), 1.00);
v_listing_max_buy_usd        := COALESCE((SELECT value::numeric FROM config WHERE key = 'listing_max_buy_usd'), 5);
v_listing_limit_cushion_pct  := COALESCE((SELECT value::numeric FROM config WHERE key = 'listing_limit_cushion_pct'), 2);
v_listing_max_open_bags      := COALESCE((SELECT value::int     FROM config WHERE key = 'listing_max_open_bags'), 3);
-- Kill switch; a missing row means OFF.
v_listing_usdc_fallback      := COALESCE((SELECT value FROM config WHERE key = 'listing_usdc_fallback'), 'false') = 'true';
v_sell_net_cushion           := COALESCE((SELECT value::numeric FROM config WHERE key = 'sell_net_cushion'), 0.015);
-- Is this minute's best bid/ask data fresh enough to judge spread at all?
v_bba_fresh                  := EXISTS (SELECT 1 FROM bulk_best_bid_ask WHERE loaded_at > NOW() - INTERVAL '3 minutes');
-- Read before the fee-learning step below: a newly learned fee applies next run.
v_fee_percent                := COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20);
-- Start-of-run cash-scaled buy-stop gap, shared by all three buy statements.
v_gap                        := (SELECT gap FROM vw_buy_stop_gap);

INSERT INTO stock (name, date_created)
SELECT bs.id, NOW()
FROM bulk_stock bs
LEFT JOIN stock s ON bs.id = s.name
WHERE s.stock_id IS NULL
AND bs.id LIKE '%-USD';

-- trading_disabled is copied from Coinbase's own products feed (bulk_stock,
-- refreshed every cycle) and checked before ever picking a coin as a fresh
-- buy candidate below -- confirmed RNDR-USD and MKR-USD both come back
-- status: "delisted", trading_disabled: true, and were being retried as buy
-- candidates every cycle regardless, failing every time with
-- PERMISSION_DENIED. A coin whose product_id disappears from Coinbase's
-- catalog entirely (confirmed on LRC-USD) doesn't need this guard --
-- without a bulk_stock row at all, it was already never a candidate.
UPDATE stock
SET price = bs.price::DOUBLE PRECISION,
    share_rounding = CASE
        WHEN (bs.json->>'base_increment') LIKE '%.%'
        THEN length(bs.json->>'base_increment') - position('.' IN bs.json->>'base_increment')
        ELSE 0
    END,
    price_rounding = CASE
        WHEN (bs.json->>'quote_increment') LIKE '%.%'
        THEN length(bs.json->>'quote_increment') - position('.' IN bs.json->>'quote_increment')
        ELSE 0
    END,
    max_shares = (bs.json->>'base_max_size')::double precision,
    min_shares = (bs.json->>'base_min_size')::double precision,
    max_price = (bs.json->>'quote_max_size')::double precision,
    min_price = (bs.json->>'quote_min_size')::double precision,
    trading_disabled = (bs.json->>'trading_disabled')::boolean
FROM bulk_stock bs
WHERE stock.name = bs.id
AND bs.id LIKE '%-USD'
AND bs.price != '';

-- 2026-10-07 STABLECOIN FLAG (Theodore: never buy stablecoins). Coinbase does
-- not label stablecoins (no field in the Advanced Trade products API), so it
-- is derived from price behavior in this minute's products feed (bulk_stock,
-- loaded by index.js processNewCoins()): a coin is a stablecoin when
--     price BETWEEN 1 - band AND 1 + band    (band = stablecoin_price_band_pct, default 3%  -> 0.97 .. 1.03)
--     AND (high_24h - low_24h) / price < max (max  = stablecoin_max_range_pct,  default 2%)
-- On 2026-10-07 live data this matched exactly USDT, USD1, USDS, PAX, DAI.
-- STICKY: only ever sets TRUE, never clears it -- a de-peg/spike day (PAX hit
-- $1.83 on 2026-09-27) must not make a stablecoin buyable again. Un-flag a
-- coin by hand if ever needed. Runs before every buy INSERT below, so a coin
-- flagged this minute is already excluded this minute.
-- Guards: values are cast only when they look like plain numbers (a bad or
-- empty string must never abort the whole procedure), price/high/low must
-- be > 0 with high >= low, and volume_24h must be > 0 -- a coin with no
-- trades in 24h reports a flat range that would look "stable" at any price
-- near $1.
UPDATE stock
SET is_stablecoin = TRUE
FROM bulk_stock bs
CROSS JOIN LATERAL (
    SELECT CASE WHEN bs.price                ~ '^[0-9]+(\.[0-9]+)?$' THEN bs.price::numeric                END AS px,
           CASE WHEN bs.json->>'high_24h'    ~ '^[0-9]+(\.[0-9]+)?$' THEN (bs.json->>'high_24h')::numeric   END AS hi,
           CASE WHEN bs.json->>'low_24h'     ~ '^[0-9]+(\.[0-9]+)?$' THEN (bs.json->>'low_24h')::numeric    END AS lo,
           CASE WHEN bs.json->>'volume_24h'  ~ '^[0-9]+(\.[0-9]+)?$' THEN (bs.json->>'volume_24h')::numeric END AS vol
) v
-- thresholds in percent: v_stablecoin_price_band_pct / v_stablecoin_max_range_pct
-- (config, defaults 3 / 2 -- see the header)
WHERE stock.name = bs.id
AND bs.id LIKE '%-USD'
AND stock.is_stablecoin IS NOT TRUE          -- sticky: only FALSE -> TRUE, never back
AND v.px > 0 AND v.hi > 0 AND v.lo > 0 AND v.hi >= v.lo
AND v.vol > 0
AND v.px BETWEEN 1 - v_stablecoin_price_band_pct / 100 AND 1 + v_stablecoin_price_band_pct / 100
AND (v.hi - v.lo) / v.px < v_stablecoin_max_range_pct / 100;

-- 2026-09-25: flag coins that have vanished from Coinbase's product catalog.
-- The UPDATE above only touches stocks that still appear in bulk_stock, so a
-- coin removed from the catalog entirely (LRC-USD) kept trading_disabled NULL
-- and a frozen price forever -- the comment above assumed "not in the catalog"
-- meant "never a candidate", but its already-inserted planned buy row was
-- still retried every cycle, failing with 'Invalid product_id' (18,987 audit
-- rows on position 787). Marking it disabled lets processBuyOrders and both
-- INSERT gates skip it. Guarded on bulk_stock actually being populated
-- (> 100 -USD products; normally ~400) so a failed/empty fetchProducts()
-- can't mass-disable every coin. Self-healing: if a coin comes back, the
-- UPDATE above resets trading_disabled from Coinbase's own flag next cycle.
UPDATE stock
SET trading_disabled = TRUE
WHERE stock.name LIKE '%-USD'
AND stock.trading_disabled IS NOT TRUE
AND NOT EXISTS (SELECT 1 FROM bulk_stock bs WHERE bs.id = stock.name)
AND (SELECT COUNT(*) FROM bulk_stock WHERE id LIKE '%-USD') > 100;

-- Snapshot each stock's year-basis signal priority onto the stock row itself,
-- as a priority marker for what to buy -- vw_signal's priority isn't
-- otherwise persisted anywhere outside the view.
UPDATE stock
SET priority = vw.priority
FROM vw_signal vw
WHERE stock.stock_id = vw.stock_id
AND vw.period_type = 'year';

-- Archive every fill into the permanent ledger before anything else touches
-- bulk_fills this cycle. bulk_fills gets truncated at the end of every
-- cycle and was never meant to be a historical record; fills is. Keyed on
-- trade_id (Coinbase's own unique id per fill execution, since one order
-- can partially fill across several), so this is naturally idempotent --
-- a fill already archived on a previous cycle is silently skipped.
INSERT INTO fills (order_id, trade_id, product_id, side, price, size, fee, trade_time)
SELECT bf.order_id, bf.trade_id, bf.product_id, bf.side, bf.price, bf.size, bf.fee, bf.created_at
FROM bulk_fills bf
ON CONFLICT (trade_id) DO NOTHING;

-- Learn the taker fee from the single latest fill, not an average.
-- fee_percent is a percent with 2 decimal places: 0.90 means 0.90 percent,
-- not a 0.009 rate. Rounding the raw rate (fee / notional) to 2 decimals
-- would collapse 0.90 and 0.50 into 0.01, so the stored number is percent.
-- Sits here, just after the fills archive and before any buy/sell pricing,
-- so this cycle's fill is already in the ledger. A null or zero result
-- does not insert a row and does not wipe a value already stored.
INSERT INTO config (key, value)
SELECT 'fee_percent', learned.pct
FROM (
    SELECT ROUND(((fee / NULLIF(price * size, 0)) * 100)::numeric, 2)::text AS pct
    FROM fills
    WHERE fee > 0
      AND price > 0
      AND size > 0
    ORDER BY trade_time DESC
    LIMIT 1
) learned
WHERE learned.pct IS NOT NULL
  AND learned.pct::numeric <> 0
ON CONFLICT (key) DO NOTHING;

UPDATE config
SET value = learned.pct
FROM (
    SELECT ROUND(((fee / NULLIF(price * size, 0)) * 100)::numeric, 2)::text AS pct
    FROM fills
    WHERE fee > 0
      AND price > 0
      AND size > 0
    ORDER BY trade_time DESC
    LIMIT 1
) learned
WHERE config.key = 'fee_percent'
  AND learned.pct IS NOT NULL
  AND learned.pct::numeric <> 0;

-- Recover orphaned buy orders: open on Coinbase but missing from position table.
-- Skip if an unfilled buy position already exists for that coin + period_type.
-- 2026-10-07: deliberately NOT filtered on stock.is_stablecoin. This is not a
-- buy decision -- it only records an order that is already LIVE on Coinbase;
-- skipping a stablecoin here would leave a real resting order untracked (a
-- ghost order in vw_position_order_balance_audit).
INSERT INTO position (stock_id, name, buy_price, buy_stop_price, shares, date_created, buy_order_id, buy_coinbase_order_id, period_type)
SELECT
    s.stock_id,
    o.product_id,
    (o.order_configuration->'stop_limit_stop_limit_gtc'->>'limit_price')::double precision,
    (o.order_configuration->'stop_limit_stop_limit_gtc'->>'stop_price')::double precision,
    (o.order_configuration->'stop_limit_stop_limit_gtc'->>'base_size')::double precision,
    o.created_time,
    o.client_order_id,
    o.order_id,
    CASE
        WHEN ((o.order_configuration->'stop_limit_stop_limit_gtc'->>'limit_price')::numeric *
              (o.order_configuration->'stop_limit_stop_limit_gtc'->>'base_size')::numeric) < 5   THEN 'day'
        WHEN ((o.order_configuration->'stop_limit_stop_limit_gtc'->>'limit_price')::numeric *
              (o.order_configuration->'stop_limit_stop_limit_gtc'->>'base_size')::numeric) < 50  THEN 'month'
        ELSE 'year'
    END
FROM bulk_open_orders o
JOIN stock s ON s.name = o.product_id
LEFT JOIN position p ON p.buy_coinbase_order_id = o.order_id
WHERE o.side = 'BUY'
AND p.buy_coinbase_order_id IS NULL
AND o.order_configuration::text LIKE '%stop_limit_stop_limit_gtc%'
AND NOT EXISTS (
    SELECT 1 FROM position existing
    WHERE existing.stock_id = s.stock_id
    AND existing.buy_filled_price IS NULL
    AND existing.buy_order_id IS NOT NULL
    AND existing.period_type = CASE
        WHEN ((o.order_configuration->'stop_limit_stop_limit_gtc'->>'limit_price')::numeric *
              (o.order_configuration->'stop_limit_stop_limit_gtc'->>'base_size')::numeric) < 5   THEN 'day'
        WHEN ((o.order_configuration->'stop_limit_stop_limit_gtc'->>'limit_price')::numeric *
              (o.order_configuration->'stop_limit_stop_limit_gtc'->>'base_size')::numeric) < 50  THEN 'month'
        ELSE 'year'
    END
);

-- Orphan sell recovery: re-link any Coinbase SELL order to a position that lost its sell_coinbase_order_id.
-- Uses DISTINCT ON (o.order_id) so each Coinbase order is only matched to one position row.
-- Orphan sell recovery also matches limit_limit_gtc: processSellOrders places
-- plain GTC limit sells (fee-floor take-profits) while underwater, which are
-- not stop_limit_stop_limit_gtc. Size still comes from whichever config is present.
WITH orphan_match AS (
    SELECT DISTINCT ON (o.order_id) p.buy_order_id AS pos_key, o.order_id
    FROM position p
    JOIN bulk_open_orders o ON o.side = 'SELL'
        AND o.product_id = p.name
        AND ABS(
            COALESCE(
                (o.order_configuration->'stop_limit_stop_limit_gtc'->>'base_size')::numeric,
                (o.order_configuration->'limit_limit_gtc'->>'base_size')::numeric
            ) - p.shares::numeric
        ) < 0.0001
        AND NOT EXISTS (SELECT 1 FROM position p2 WHERE p2.sell_coinbase_order_id = o.order_id)
    WHERE p.buy_filled_price IS NOT NULL
    AND p.sell_filled_price IS NULL
    AND p.sell_coinbase_order_id IS NULL
    ORDER BY o.order_id
)
UPDATE position p
SET sell_coinbase_order_id = om.order_id
FROM orphan_match om
WHERE p.buy_order_id = om.pos_key;

-- 2026-09-25: expire stale planned buys. A planned row that never got a
-- Coinbase order (buy_coinbase_order_id NULL, never filled) sits in
-- processBuyOrders' queue forever, failing INSUFFICIENT_FUND every cycle
-- (USDS-USD had been planned since 8/13) and -- via the cash-backlog gate
-- below -- blocking new picks. Delete it once its last activity (created,
-- remade, placed, or released) is older than config.pending_buy_ttl_hours
-- (default 24). The signal logic simply re-picks the coin later if it's
-- still attractive. Never touches a row with a live Coinbase order: the
-- NULL buy_coinbase_order_id check plus a match on client_order_id in the
-- current open-orders snapshot (covers an order whose id was nulled while
-- still live). The position_audit trigger logs each DELETE.
DELETE FROM position p
WHERE p.buy_coinbase_order_id IS NULL
AND p.buy_filled_price IS NULL
AND p.sell_coinbase_order_id IS NULL
-- 2026-10-07: listing rows are exempt from every generic pending-row rule;
-- their unsent rows are handled by the listing block below (dropped and
-- re-planned each minute only while the coin's 24h buy window is open).
AND p.period_type IS DISTINCT FROM 'listing'
AND GREATEST(p.date_created, p.last_remade_at, p.buy_placed_at, p.buy_released_at)
    < NOW() - make_interval(hours => v_pending_buy_ttl_hours)
AND NOT EXISTS (
    SELECT 1 FROM bulk_open_orders o WHERE o.client_order_id = p.buy_order_id
);

-- ===========================================================================
-- 2026-10-05 PLANNED-ROW CLEAN-UP (one rule set, owned by this procedure)
-- ===========================================================================
-- Rule: a planned buy row (no Coinbase order yet) may only exist if index.js
-- processBuyOrders() would send it THIS minute. Before this change index.js
-- had its own placement filters (order-book gates, price-vs-trigger wait,
-- per-row cash check, trading_disabled, 30-min release cooldown), so rows
-- sat in position for hours doing nothing while still counting against the
-- cash-backlog gate below and blocking new picks (ABT / LSETH wide spread;
-- PNG / DOGE / VVV / GFI / QI waiting for price to drop under the 99% add-on
-- cap). Those filters now live here, on both INSERTs below (never create
-- such a row) and in these DELETEs (drop an existing row the moment it stops
-- qualifying). index.js keeps only reactions to Coinbase itself (rejection ->
-- error_message -> retry next minute, 'Invalid product_id', the live
-- "<= $1 available" guard). A deleted coin is simply re-picked later by the
-- INSERTs once it qualifies again. Runs before the INSERTs so freed backlog
-- cash is usable this same cycle.
--
-- Safety guards on every DELETE here (same as the TTL delete above): never
-- filled, no Coinbase order id, no sell side, and no live order under its
-- client_order_id in this run's bulk_open_orders. Live orders are never
-- touched. The position_audit trigger logs each DELETE (note: the audit
-- prune near the end of this procedure removes audit rows of deleted
-- positions, so the log is visible only within this transaction).
--
-- Reasons (any one deletes the row):
--  (a) pause_buys is not 'false' -- same test the INSERTs use. Chosen over a
--      pause check in index.js: with an index.js check, rows would sit
--      unsent for the whole pause (exactly what this rule forbids) and pause
--      logic would live in two places. Live orders are left alone.
--  (b) coin is trading_disabled (delisted / vanished from the catalog;
--      flagged earlier in this procedure). Was an index.js filter.
--  (c) row was released by index.js processFarBuyCashRelease() (its live
--      order was cancelled to free cash for something better). Used to sit
--      in a 30-min index.js cooldown; now dropped, the coin is re-picked
--      later if still attractive.
--  (d) below Coinbase minimum order size: shares < stock.min_shares
--      (base_min_size) or shares * buy_price < stock.min_price
--      (quote_min_size). Coinbase rejects these forever.
--  (e) trigger no longer above price on a coin already held: the
--      below-lowest-paid rule (fn_buy_below_paid; 2026-10-07, replaced the
--      add_buy_cap_ratio 0.99 cap) allows at most stop = (largest tick below
--      the lowest paid) / 1.01, so once price is at/above that the stop-buy
--      cannot be placed (Coinbase needs the stop above market). Uncapped rows are not
--      deleted here: the "refresh stale buy candidates" UPDATE further down
--      re-prices them above market, and a safety DELETE after the cap
--      catches anything still at/below price.
--  (f) spread wider than config book_max_spread_pct (default 0.75%), from
--      bulk_best_bid_ask (loaded by index.js processBestBidAsk() just
--      before this procedure). Only judged when that table is fresh (loaded
--      within 3 minutes); then a coin missing from it or with a one-sided
--      quote (spread_pct NULL) counts as failing. Stale/empty = fail open.
--  (g) latest book_snapshot from the last 3 minutes is ask-heavy
--      (imbalance < book_skip_imbalance, default -0.4) or thin (ask
--      notional within 0.5% of mid < book_min_ask_notional_mult, default 5,
--      x the row's own dollar size). No fresh snapshot = allow. index.js
--      processBookSnapshots() now runs before this procedure and always
--      snapshots coins with a planned buy.
--  (h) 2026-10-07: coin is flagged stock.is_stablecoin (see the STABLECOIN
--      FLAG update near the top). Stablecoins are never bought, so an
--      unplaced planned row on one is dropped (placed / live orders are
--      never touched, same guards as every reason here).
DELETE FROM position p
USING stock s
WHERE s.stock_id = p.stock_id
AND p.buy_coinbase_order_id IS NULL
AND p.buy_filled_price IS NULL
AND p.sell_coinbase_order_id IS NULL
AND NOT EXISTS (
    SELECT 1 FROM bulk_open_orders o WHERE o.client_order_id = p.buy_order_id
)
-- 2026-10-07: listing rows exempt (own rules in the listing block below;
-- a new pair's launch book is often wider than book_max_spread_pct).
AND p.period_type IS DISTINCT FROM 'listing'
AND (
    -- (a) buys paused
    v_pause_buys IS DISTINCT FROM 'false'
    -- (b) delisted / trading disabled
    OR s.trading_disabled IS TRUE
    -- (h) stablecoin (stock.is_stablecoin) -- never bought
    OR s.is_stablecoin IS TRUE
    -- (c) released by far-buy cash release
    OR p.buy_released_at IS NOT NULL
    -- (d) below Coinbase minimum order size
    OR p.shares IS NULL
    OR p.shares <= 0
    OR p.shares < COALESCE(s.min_shares, 0)
    OR (p.shares * p.buy_price) < COALESCE(s.min_price, 0)
    -- (e) held coin: price at/above the highest stop the below-lowest-paid
    -- rule allows (fn_buy_below_paid with limit = lowest paid forces the
    -- clamp). NULL when the coin has no open filled bag -> not deleted.
    OR s.price::numeric >= (
        SELECT (fn_buy_below_paid(NULL, m.min_paid, m.min_paid, s.price_rounding::integer)).stop_price
        FROM (
            SELECT MIN(f.buy_filled_price)::numeric AS min_paid
            FROM position f
            WHERE f.stock_id = p.stock_id
            AND f.buy_filled_price IS NOT NULL
            AND f.sell_filled_price IS NULL
        ) m
    )
    -- (f) wide spread (only with fresh best-bid/ask data)
    OR (
        v_bba_fresh
        AND COALESCE(
                (SELECT bba.spread_pct FROM bulk_best_bid_ask bba WHERE bba.product_id = s.name),
                'Infinity'::double precision
            ) > v_book_max_spread_pct::double precision
    )
    -- (g) ask-heavy or thin book (fresh snapshot only)
    OR EXISTS (
        SELECT 1
        FROM (
            SELECT bs.imbalance, bs.near_ask_usd
            FROM book_snapshot bs
            WHERE bs.name = s.name
            AND bs.date_created > NOW() - INTERVAL '3 minutes'
            ORDER BY bs.date_created DESC
            LIMIT 1
        ) fresh_book
        WHERE fresh_book.imbalance < v_book_skip_imbalance::double precision
        OR fresh_book.near_ask_usd < (p.shares * p.buy_price)
            * v_book_min_ask_notional_mult::double precision
    )
);

-- 2026-10-05 affordability clean-up (was the per-row cashLeft check in
-- index.js processBuyOrders, which skipped -- but kept -- rows free cash
-- could not cover, so they sat and were retried every minute). Walk the
-- surviving planned rows in the same order processBuyOrders sends them
-- (stock.priority DESC, then position_id) with a running cash balance:
-- free USD (vw_balance.available, i.e. after holds of live orders) minus
-- this run's ETF reserve (vw_etf_cash_reserve). A row whose cost incl. the
-- ~1.2% taker-fee pad (shares * buy_price * 1.012, same pad index.js used)
-- fits is kept and its cost is taken off the balance; a row that does not
-- fit is deleted and the walk continues (greedy, exactly like the old
-- cashLeft loop). Same safety guards as above. Fail-open: when there is no
-- USD row in vw_balance (balance fetch failed this run) cash_left is NULL,
-- every comparison is NULL and nothing is deleted.
WITH RECURSIVE cand AS (
    SELECT p.position_id,
           (p.shares * p.buy_price)::numeric * 1.012 AS cost,
           ROW_NUMBER() OVER (ORDER BY s.priority DESC NULLS LAST, p.position_id) AS rn
    FROM position p
    JOIN stock s ON s.stock_id = p.stock_id
    WHERE p.buy_coinbase_order_id IS NULL
    AND p.buy_filled_price IS NULL
    AND p.sell_coinbase_order_id IS NULL
    AND NOT EXISTS (
        SELECT 1 FROM bulk_open_orders o WHERE o.client_order_id = p.buy_order_id
    )
    -- 2026-10-07: listing rows exempt (own cash gate in the listing INSERT).
    AND p.period_type IS DISTINCT FROM 'listing'
),
walk AS (
    SELECT 0::bigint AS rn,
           -- 2026-10-07: USD only on purpose; USDC is not crypto buy cash.
           (SELECT available::numeric FROM vw_balance WHERE name = 'USD')
             - COALESCE((SELECT reserve_usd FROM vw_etf_cash_reserve), 0)
             -- 2026-10-07: profit queued for the USDC sweep is not spendable.
             - COALESCE((SELECT reserve_usd FROM vw_usdc_sweep_reserve), 0) AS cash_left,
           NULL::bigint AS position_id,
           FALSE AS drop_row
    UNION ALL
    SELECT c.rn,
           CASE WHEN c.cost <= w.cash_left THEN w.cash_left - c.cost ELSE w.cash_left END,
           c.position_id,
           c.cost > w.cash_left
    FROM walk w
    JOIN cand c ON c.rn = w.rn + 1
)
DELETE FROM position p
USING walk w
WHERE p.position_id = w.position_id
AND w.drop_row IS TRUE;

-- ===========================================================================
-- 2026-10-07 NEW-LISTING SNIPE (replaces the 2026-10-06 new_at version)
-- 2026-10-07 (later): 24h WINDOW, migrations/2026-10-07_listing_24h_window.sql
-- ===========================================================================
-- Theodore: "if its new today it needs a buy order". A coin is snipeable for
-- a ROLLING config.listing_buy_window_hours (default 24) after its trading
-- ACTUALLY opens -- not at Coinbase products.new_at, and no longer only the
-- first 5 minutes (PONS opened 12:20 PM CT on 2026-10-07 while free USD was
-- short and was never bought).
-- Why the open time and not new_at: a 50-listing study showed trading
-- typically opens ~18h after new_at (only 2/50 traded within 60 min of it)
-- and every product carries a non-empty new_at anyway; new_at is only a
-- candidate filter inside modules/listingWatch.js.
--
-- Window start = listing_watch.trading_open_at, written by index.js
-- (modules/listingWatch.js) BEFORE this procedure each minute: the EARLIER
-- of the pair's first completed trade (Exchange trade_id 1, or -- only for a
-- launch the watcher actually observed -- the first 1-min candle with
-- volume) and the first time the bot saw the launch restrictions cleared. A
-- product first watched after it had already traded gets its real (old)
-- first-trade time, so a listing older than the window never qualifies.
--
-- 2026-10-07 (later still, migrations/2026-10-07_listing_buy_immediately.sql):
-- Theodore: "I dont want the new coins to have a restriction if its too high
-- in price. I want the buy order in immediately." So inside the window:
--   * ONE pricing rule (the 5-minute first-trade phase is gone;
--     config.listing_window_minutes is no longer read):
--       reference = fresh best ask (bulk_best_bid_ask, loaded < 3 min ago,
--                   ask > 0), else this minute's last trade price
--                   (products payload bulk_stock.price), else the first
--                   trade price (listing_watch.first_trade_price);
--       limit     = reference * (1 + listing_limit_cushion_pct / 100)
--                   (2% -> limit is ABOVE the ask, so the plain limit buy
--                   crosses the book and fills right away at the real ask
--                   price), rounded UP to the price increment
--                   (price_increment, falling back to quote_increment).
--   * no high-price skip: the old "order <= 1.25 x listing_buy_usd" cap
--     dropped every coin whose smallest lot cost more than $1.25 (e.g. any
--     base_increment 0.1 coin above $12.50). Now the only ceiling is
--     config.listing_max_buy_usd (5); a coin over it is skipped AND noted on
--     listing_watch.snipe_skip_reason (index.js logs it once).
--   * the stablecoin flag is NOT applied to listing coins inside their
--     window (a $1.00 launch with a quiet first hours could be flagged).
--   * a coin may be bought before the watcher has its first trade, as long
--     as restrictions are cleared and a fresh ask exists.
--
-- The buy (index.js processBuyOrders sends it as a PLAIN LIMIT, GTC, no
-- stop, no expiry; it rests until it fills or Theodore cancels it; market
-- orders are not accepted while Coinbase has the pair limit-only):
--   * shares = GREATEST(listing_buy_usd, quote_min_size) / limit, rounded UP
--     to base_increment, and at least base_min_size -- rounding down would
--     land under Coinbase's quote_min_size and be rejected. A high-priced
--     coin whose smallest lot costs more than $1 is bought at that smallest
--     lot, up to listing_max_buy_usd.
--   * buy_stop_price = NULL: no stop trigger. NULL also keeps the row out of
--     every stop-based path (stale-candidate refresh, add-on cap, safety-net
--     delete, vw_edit_orders remakes, far-buy cash release); each of those
--     also exempts period_type 'listing' explicitly.
--   * Selling: the normal sell code once it fills -- no custom take-profit.
--   * At most config.listing_max_open_bags (default 3) listing rows open at
--     once (resting buy or filled-unsold bag), one per coin EVER.

-- Unsent listing row from a previous minute (Coinbase rejected it, e.g.
-- still in auction / cancel-only, or cash was short): drop it so the INSERT
-- below re-plans it with fresh gates and a fresh price -- only while the
-- coin's 24h window is still open. After the window it is simply not
-- re-planned, so nothing sits and holds a listing_max_open_bags slot or the
-- ETF gate. Never touches a placed order (same
-- guards as the generic clean-up: no Coinbase order id, not filled, no sell,
-- no live order under its client_order_id).
DELETE FROM position p
WHERE p.period_type = 'listing'
AND p.buy_coinbase_order_id IS NULL
AND p.buy_filled_price IS NULL
AND p.sell_coinbase_order_id IS NULL
AND NOT EXISTS (
    SELECT 1 FROM bulk_open_orders o WHERE o.client_order_id = p.buy_order_id
);

-- 2026-10-07 USDC FALLBACK (Theodore; db/migrations/2026-10-07_listing_usdc_fallback.sql):
-- pay with USD when free USD covers the snipe (unchanged rule), else with
-- USDC on the coin's -USDC twin (same order book; alias = the -USD pair)
-- when config.listing_usdc_fallback = 'true'. buy_quote_currency records
-- the choice (NULL = USD, 'USDC'); index.js listingBuyProductId() sends the
-- order to <COIN>-USDC for 'USDC'. name stays <COIN>-USD and the sell goes
-- on -USD as for every other bag. See the "fund" laterals below.
INSERT INTO position (stock_id, name, buy_price, buy_stop_price, shares, date_created, buy_order_id, period_type, buy_quote_currency)
SELECT
    s.stock_id,
    s.name,
    px.limit_price          AS buy_price,       -- plain limit price (no stop)
    NULL                    AS buy_stop_price,  -- no stop trigger at all
    sz.shares               AS shares,          -- ~$1 at the limit price
    NOW()                   AS date_created,
    gen_random_uuid(),
    'listing',
    -- NULL = USD (the -USD pair, as before); 'USDC' = buy on <COIN>-USDC.
    CASE WHEN fund.funding = 'USDC' THEN 'USDC' END AS buy_quote_currency
FROM stock s
JOIN bulk_stock bs     ON bs.id = s.name
-- Only products the watcher has a real trading-open time for.
JOIN listing_watch lw  ON lw.product_id = s.name
-- The tunables (config keys; defaults if a key is missing):
--   listing_buy_window_hours  = 24   rolling buy window after trading_open_at
--   listing_buy_usd           = 1.00 target dollars per snipe
--   listing_max_buy_usd       = 5    most one snipe may cost (smallest lot of a high-priced coin)
--   listing_limit_cushion_pct = 2    limit = reference price + 2%
--   listing_max_open_bags     = 3    max listing rows open at once
-- (listing_window_minutes is no longer read: no first-trade pricing phase.)
-- 2026-10-07: these now come from the v_listing_* variables (header).
-- Product increments straight from Coinbase's products payload.
CROSS JOIN LATERAL (
    SELECT NULLIF(COALESCE(NULLIF(bs.json->>'price_increment', ''), NULLIF(bs.json->>'quote_increment', ''))::numeric, 0) AS tick,
           NULLIF(NULLIF(bs.json->>'base_increment', '')::numeric, 0)                                                      AS lot,
           COALESCE(NULLIF(bs.json->>'base_min_size', '')::numeric, 0)                                                     AS base_min,
           COALESCE(NULLIF(bs.json->>'quote_min_size', '')::numeric, 0)                                                    AS quote_min
) inc
-- Current best ask for the pair, only if this run's top-of-book load is
-- fresh (< 3 minutes, same freshness rule as the spread gate) and the ask
-- is real. LIMIT 1 so it can never multiply candidate rows.
LEFT JOIN LATERAL (
    SELECT bba.best_ask::numeric AS best_ask
    FROM bulk_best_bid_ask bba
    WHERE bba.product_id = s.name
    AND bba.loaded_at > NOW() - INTERVAL '3 minutes'
    AND bba.best_ask > 0
    LIMIT 1
) ask ON TRUE
-- Reference price (2026-10-07, one rule for the whole window): fresh best
-- ask, else this minute's last trade price from the products payload
-- (bulk_stock.price; '' / non-numeric / 0 -> NULL), else the first trade
-- price. Limit = reference + cushion (2%), rounded UP to the price tick, so
-- with a fresh ask the limit is always >= the ask (crosses -> fills now).
CROSS JOIN LATERAL (
    SELECT COALESCE(
               ask.best_ask,
               NULLIF(CASE WHEN bs.price ~ '^[0-9]+(\.[0-9]+)?$' THEN bs.price::numeric END, 0),
               NULLIF(lw.first_trade_price, 0)
           ) AS ref_price
) ref
CROSS JOIN LATERAL (
    SELECT CEIL(ref.ref_price * (1 + v_listing_limit_cushion_pct / 100) / inc.tick) * inc.tick AS limit_price
) px
-- Size = GREATEST($buy_usd, quote_min_size) at the limit, rounded UP to the
-- base increment, >= base_min_size. For a high-priced coin this is simply
-- its smallest valid lot (may cost more than $1; capped by
-- listing_max_buy_usd below).
CROSS JOIN LATERAL (
    SELECT GREATEST(CEIL(GREATEST(v_listing_buy_usd, inc.quote_min) / px.limit_price / inc.lot) * inc.lot, inc.base_min) AS shares
) sz
-- 2026-10-07: cash for the snipe, both currencies. (Replaces the old
-- CROSS JOIN vw_balance b / WHERE b.name = 'USD' gate.)
--   usd_free  = free USD (vw_balance.available, i.e. after holds of live
--               orders) minus realized profit queued for the USDC sweep
--               (vw_usdc_sweep_reserve) -- same as the old gate. The ETF
--               reserve is still not subtracted: listing is priority one and
--               index.js skips ETF orders while a listing bag is open.
--   usdc_free = free USDC (vw_balance name = 'USDC', available = after
--               holds, so resting USDC ETF limits are already excluded).
--               Nothing else needs USDC this minute: processEquityEtfBuys()
--               runs after this procedure and skips every ETF order while a
--               listing row exists, and the profit sweep only ADDS USDC.
--   cost      = order incl. the ~1.2% taker-fee pad (same pad as before).
-- A missing USD/USDC row (balance fetch failed) gives NULL, so that
-- currency simply cannot fund the snipe (fail-closed, as before).
CROSS JOIN LATERAL (
    SELECT (SELECT available::numeric FROM vw_balance WHERE name = 'USD')
             - COALESCE((SELECT reserve_usd FROM vw_usdc_sweep_reserve), 0)  AS usd_free,
           (SELECT available::numeric FROM vw_balance WHERE name = 'USDC')   AS usdc_free,
           sz.shares * px.limit_price * 1.012                                AS cost,
           -- Kill switch; a missing row means OFF (v_listing_usdc_fallback, header).
           v_listing_usdc_fallback                                           AS usdc_on
) cash
-- The coin's -USDC twin from this minute's products payload (bulk_stock
-- holds every product, -USDC pairs included). LIMIT 1 so it can never
-- multiply candidate rows.
LEFT JOIN LATERAL (
    SELECT x.* FROM bulk_stock x
    WHERE x.id = regexp_replace(s.name, '-USD$', '-USDC')
    LIMIT 1
) bsc ON TRUE
-- Funding decision: USD first (unchanged behaviour), then USDC only if the
-- fallback is on, USDC covers it, and the twin is tradable right now AND is
-- an alias of this -USD pair (same order book, so the first-trade price,
-- increments and launch flags checked above on the -USD row apply to it).
-- NULL = cannot fund either way -> no snipe this minute (re-tried next
-- minute while the 24h window is open).
CROSS JOIN LATERAL (
    SELECT CASE
        WHEN cash.usd_free >= cash.cost THEN 'USD'
        WHEN cash.usdc_on
         AND cash.usdc_free >= cash.cost
         AND bsc.id IS NOT NULL
         AND bsc.json->>'alias' = s.name
         AND COALESCE(bsc.status, bsc.json->>'status', '') = 'online'
         AND COALESCE(bsc.trading_disabled, bsc.json->>'trading_disabled', 'false') NOT IN ('true', 't', '1')
         AND COALESCE(bsc.json->>'is_disabled', 'false') NOT IN ('true', 't', '1')
         AND COALESCE(bsc.auction_mode, bsc.json->>'auction_mode', 'false') NOT IN ('true', 't', '1')
         AND COALESCE(bsc.cancel_only, bsc.json->>'cancel_only', 'false') NOT IN ('true', 't', '1')
         AND COALESCE(bsc.post_only, bsc.json->>'post_only', 'false') NOT IN ('true', 't', '1')
        THEN 'USDC'
    END AS funding
) fund
-- PRIMARY duplicate guard (Theodore): a coin that already has ANY position
-- row (any period_type, pending or filled) never gets a listing row -- so
-- the snipe can never create a second row for a new coin. LEFT JOIN ... IS
-- NULL against ONE row per coin (pre-aggregated by stock_id), so the join
-- can never multiply candidate rows.
LEFT JOIN (
    SELECT stock_id, MIN(position_id) AS position_id
    FROM position
    GROUP BY stock_id
) p ON p.stock_id = s.stock_id
-- One snipe per coin EVER: a coin whose listing snipe already closed (row
-- moved to profit_history and deleted from position) is skipped too. Same
-- LEFT JOIN ... IS NULL shape, also one row per coin.
LEFT JOIN (
    SELECT stock_id, MIN(profit_history_id) AS profit_history_id
    FROM profit_history
    WHERE period_type = 'listing'
    GROUP BY stock_id
) ph ON ph.stock_id = s.stock_id
-- 2026-10-07: the LISTING SNIPE is the one buy that may use USDC (fallback
-- above, only when USD is short). Every other crypto buy below stays USD only.
WHERE v_pause_buys = 'false'
AND s.name LIKE '%-USD'
-- Duplicate guards (see the two LEFT JOINs above) -- the PRIMARY guard.
-- DB backstop: partial unique index position_one_listing_per_stock
-- (position(stock_id) WHERE period_type = 'listing'). No ON CONFLICT here on
-- purpose (Theodore): if the backstop ever trips, the unique violation
-- aborts this procedure call for that minute instead of hiding the bug.
AND p.position_id IS NULL
AND ph.profit_history_id IS NULL
-- THE WINDOW: trading opened at most listing_buy_window_hours (24) ago --
-- rolling from the open, not a calendar day (Theodore).
AND lw.trading_open_at IS NOT NULL
AND lw.trading_open_at <= NOW()
AND NOW() - lw.trading_open_at <= v_listing_buy_window_hours * INTERVAL '1 hour'
-- A snipe that ended with NO fill (Theodore cancelled it, or Coinbase
-- expired/failed it) means that coin is done: index.js
-- reconcileListingBuys() deleted the row and stamped snipe_cancelled_at, so
-- the 24h window must not re-snipe it.
AND lw.snipe_cancelled_at IS NULL
-- Proof the pair really trades (2026-10-07, relaxed): a real first trade
-- exists, OR the watcher saw the launch restrictions cleared AND there is a
-- fresh best ask to price off -- so the buy does not wait for the watcher's
-- first-trade lookup.
AND (lw.first_trade_price > 0
     OR (lw.restrictions_cleared_at IS NOT NULL AND ask.best_ask IS NOT NULL))
-- Tradable now. limit_only is ALLOWED on purpose: the first minutes after
-- the first trade are normally Coinbase's launch limit-only phase, and a
-- plain limit order is accepted there. Not during the auction, cancel-only
-- or post-only (a taker limit would be rejected).
AND s.trading_disabled IS NOT TRUE
-- 2026-10-07 (later): stock.is_stablecoin is deliberately NOT checked here.
-- Every coin reaching this INSERT is inside its 24h listing window, and the
-- price-behavior flag (set near the top of this procedure: price within 3%
-- of $1 and a < 2% 24h range) can wrongly tag a new coin that launches at
-- ~$1.00 and trades quietly at first -- and the flag is sticky. Theodore:
-- buy new coins immediately, no such restriction. Normal (non-listing) buys
-- still honor the flag.
AND COALESCE(bs.trading_disabled, bs.json->>'trading_disabled', 'false') NOT IN ('true', 't', '1')
AND COALESCE(bs.status, bs.json->>'status', '') = 'online'
AND COALESCE(bs.json->>'product_type', 'SPOT') = 'SPOT'
AND COALESCE(bs.json->>'is_disabled', 'false') NOT IN ('true', 't', '1')
AND COALESCE(bs.auction_mode, bs.json->>'auction_mode', 'false') NOT IN ('true', 't', '1')
AND COALESCE(bs.cancel_only, bs.json->>'cancel_only', 'false') NOT IN ('true', 't', '1')
AND COALESCE(bs.post_only, bs.json->>'post_only', 'false') NOT IN ('true', 't', '1')
-- Open-bag cap (2026-10-07, replaces the one-listing-at-a-time mutex so a
-- second coin opening the same day is not blocked by the first one's bag):
-- fewer than listing_max_open_bags (3) listing rows open -- a resting
-- unfilled listing order or a filled-unsold listing bag both count (unsent
-- rows were dropped just above). Duplicates per coin are still impossible:
-- the per-coin-ever LEFT JOIN guards above + position_one_listing_per_stock.
-- With LIMIT 1 below at most one new listing row is added per minute.
AND (
    SELECT count(*) FROM position lp
    WHERE lp.period_type = 'listing'
    AND lp.sell_filled_price IS NULL
) < v_listing_max_open_bags
-- Order sanity / Coinbase minimums.
AND inc.tick IS NOT NULL
AND inc.lot IS NOT NULL
AND px.limit_price > 0
AND sz.shares > 0
AND sz.shares * px.limit_price >= inc.quote_min
-- 2026-10-07: the only cost ceiling is config.listing_max_buy_usd ($5) --
-- replaces the old "<= 1.25 x listing_buy_usd" cap that skipped every
-- high-priced coin. A coin over it is noted on listing_watch by the UPDATE
-- right after this INSERT.
AND sz.shares * px.limit_price <= v_listing_max_buy_usd
-- Cash: USD (minus the sweep reserve) or, as the fallback, USDC must cover
-- the order incl. the ~1.2% fee pad -- decided in the "fund" lateral above.
AND fund.funding IS NOT NULL
ORDER BY lw.trading_open_at DESC
LIMIT 1;

-- 2026-10-07: note a listing coin skipped ONLY because its smallest valid
-- order costs more than config.listing_max_buy_usd, so it is visible
-- (index.js logListingSkips() prints it once; the reason is refreshed each
-- minute while it lasts). Same reference price / limit / size formulas as
-- the INSERT above -- KEEP THEM IN SYNC. Only coins that would otherwise be
-- live candidates (in window, not cancelled, never sniped, tradable now).
-- (Target aliased "tgt" and joined to its own row "lw" because an UPDATE's
-- target table cannot be referenced from the LATERAL subqueries.)
UPDATE listing_watch tgt
SET snipe_skip_reason = 'smallest order $' || ROUND(sz.shares * px.limit_price, 2)
                        || ' (' || sz.shares || ' @ ' || px.limit_price
                        || ') exceeds listing_max_buy_usd $' || v_listing_max_buy_usd,
    snipe_skipped_at  = COALESCE(tgt.snipe_skipped_at, NOW())
FROM listing_watch lw
JOIN stock s       ON s.name = lw.product_id
JOIN bulk_stock bs ON bs.id = s.name
-- 2026-10-07: listing tunables from the v_listing_* variables (header).
CROSS JOIN LATERAL (
    SELECT NULLIF(COALESCE(NULLIF(bs.json->>'price_increment', ''), NULLIF(bs.json->>'quote_increment', ''))::numeric, 0) AS tick,
           NULLIF(NULLIF(bs.json->>'base_increment', '')::numeric, 0)                                                      AS lot,
           COALESCE(NULLIF(bs.json->>'base_min_size', '')::numeric, 0)                                                     AS base_min,
           COALESCE(NULLIF(bs.json->>'quote_min_size', '')::numeric, 0)                                                    AS quote_min
) inc
LEFT JOIN LATERAL (
    SELECT bba.best_ask::numeric AS best_ask
    FROM bulk_best_bid_ask bba
    WHERE bba.product_id = s.name
    AND bba.loaded_at > NOW() - INTERVAL '3 minutes'
    AND bba.best_ask > 0
    LIMIT 1
) ask ON TRUE
CROSS JOIN LATERAL (
    SELECT CEIL(COALESCE(
               ask.best_ask,
               NULLIF(CASE WHEN bs.price ~ '^[0-9]+(\.[0-9]+)?$' THEN bs.price::numeric END, 0),
               NULLIF(lw.first_trade_price, 0)
           ) * (1 + v_listing_limit_cushion_pct / 100) / inc.tick) * inc.tick AS limit_price
) px
CROSS JOIN LATERAL (
    SELECT GREATEST(CEIL(GREATEST(v_listing_buy_usd, inc.quote_min) / px.limit_price / inc.lot) * inc.lot, inc.base_min) AS shares
) sz
WHERE tgt.product_id = lw.product_id
AND s.name LIKE '%-USD'
AND lw.trading_open_at IS NOT NULL
AND lw.trading_open_at <= NOW()
AND NOW() - lw.trading_open_at <= v_listing_buy_window_hours * INTERVAL '1 hour'
AND lw.snipe_cancelled_at IS NULL
AND NOT EXISTS (SELECT 1 FROM position p WHERE p.stock_id = s.stock_id)
AND NOT EXISTS (SELECT 1 FROM profit_history h WHERE h.stock_id = s.stock_id AND h.period_type = 'listing')
AND COALESCE(bs.status, bs.json->>'status', '') = 'online'
AND COALESCE(bs.trading_disabled, bs.json->>'trading_disabled', 'false') NOT IN ('true', 't', '1')
AND COALESCE(bs.cancel_only, bs.json->>'cancel_only', 'false') NOT IN ('true', 't', '1')
AND COALESCE(bs.auction_mode, bs.json->>'auction_mode', 'false') NOT IN ('true', 't', '1')
AND inc.tick IS NOT NULL
AND inc.lot IS NOT NULL
AND px.limit_price > 0
AND sz.shares * px.limit_price > v_listing_max_buy_usd;

-- New position: $1 into the highest year-basis-priority coin not already
-- held, gated only on the coin's year-basis trend being positive -- no
-- day-timing signal (recommendation / current-vs-average dip) and no
-- priority floor, since the goal is broad $1 exposure across every coin
-- trending up over the year, ranked by priority, not picking entries by
-- short-term dip timing.
-- Always recorded as period_type 'day' (the existing $1-size bucket), even
-- though the signal driving the pick is the year row. One new position per
-- cycle.
-- 2026-10-07 (Theodore): the pick is by priority alone -- the order book
-- no longer ranks candidates (its gates still filter).
-- 2026-10-08 (Theodore: "take out the top 50% ... add a where statement
-- where priority > 0"): the top-50% ranking/cutoff (join "topbuy",
-- config.initial_buy_top_pct) is removed; any coin with s.priority > 0 that
-- passes the other gates may be picked, highest priority first.
-- Clip size: $1 for a brand-new day position on this coin; if this INSERT
-- is instead an add while open day rows already exist (price below the
-- lowest filled buy), use $N where N = open_count + 1 (2nd order $2, 3rd
-- $3, ...). Open = any buy still live (sell not filled). available must
-- cover that clip, not a hard-coded $1.
INSERT INTO position (stock_id, name, buy_price, buy_stop_price, shares, date_created, buy_order_id, period_type)
SELECT s.stock_id, s.name,
    -- 2026-10-05: price / trigger / size now come from the "plan" lateral
    -- below (same formulas as before, computed once) so the new gates can
    -- check the exact order this INSERT will create.
    -- 2026-10-07: the FINAL stop/limit (after the below-lowest-paid rule,
    -- lateral "fin") are written directly.
    fin.limit_price AS buy_price,
    fin.stop_price  AS buy_stop_price,
    plan.shares,
    NOW() AS date_created,
    gen_random_uuid(),
    'day'
FROM vw_signal s
JOIN stock ON s.stock_id = stock.stock_id
CROSS JOIN vw_balance b
-- 2026-10-07: cash-scaled gap from the ONE shared place (vw_buy_stop_gap:
-- buy_stop_base_pct/100 * sqrt(equity / free USD), USD only, no max).
-- Replaces the inline 1 + 0.02 * (equity / free USD) of 2026-10-05.
-- (gap: v_gap, assigned once at the top of the run)
LEFT JOIN position p ON p.stock_id = s.stock_id
    AND p.period_type = 'day'
    AND p.buy_order_id IS NOT NULL
    AND p.buy_filled_price IS NULL
-- 2026-10-05 book gates (moved here from index.js processBuyOrders(); see
-- the clean-up delete near the top for the full rationale and fail-open
-- rules). Latest L2 snapshot from the last 3 minutes only -- before this,
-- any age was used, and coins past the old 40-coin alphabetical snapshot
-- cap were judged on hours-old books. NULL = no fresh snapshot = allow.
LEFT JOIN LATERAL (
    SELECT bs.imbalance, bs.near_ask_usd
    FROM book_snapshot bs
    WHERE bs.name = s.name
    AND bs.date_created > NOW() - INTERVAL '3 minutes'
    ORDER BY bs.date_created DESC
    LIMIT 1
) book ON TRUE
-- This run's top-of-book for the coin (spread gate).
LEFT JOIN bulk_best_bid_ask bba ON bba.product_id = s.name
-- Thresholds from config (defaults = the old index.js constants) and
-- whether bulk_best_bid_ask is fresh enough to judge spread at all:
-- 2026-10-07 now v_book_* / v_bba_fresh (header), was the bookcfg lateral.
-- Dollar size of this clip ($1 new, $N for the Nth open day row), the same
-- count + 1 the shares / cash-backlog expressions use; the thin-ask gate
-- compares near-ask notional to clip_usd * book_min_ask_notional_mult.
CROSS JOIN LATERAL (
    SELECT COUNT(*)::numeric + 1 AS clip_usd
    FROM position open_sz
    WHERE open_sz.stock_id = s.stock_id
    AND open_sz.period_type = 'day'
    AND open_sz.buy_order_id IS NOT NULL
    AND open_sz.sell_filled_price IS NULL
) clip
-- 2026-10-05 the order this INSERT will create: trigger = signal close x
-- (1 + cash-scaled gap), limit = trigger x 1.01, shares = clip dollars /
-- close. (2026-10-07: gap from vw_buy_stop_gap.)
CROSS JOIN LATERAL (
    SELECT
        TRUNC((s.close::numeric * (1 + v_gap) * 1.01), stock.price_rounding::integer) AS buy_price,
        TRUNC((s.close::numeric * (1 + v_gap)),        stock.price_rounding::integer) AS buy_stop_price,
        TRUNC(clip.clip_usd / s.close::numeric, stock.share_rounding::integer)        AS shares
) plan
-- 2026-10-07 below-lowest-paid rule (replaces the add_buy_cap_ratio 0.99
-- cap preview): lowest price paid among this coin's open filled bags (NULL
-- = not held), then fn_buy_below_paid gives the final stop/limit this row
-- is written with (unchanged when not held or already below).
CROSS JOIN LATERAL (
    SELECT MIN(f.buy_filled_price)::numeric AS min_paid
    FROM position f
    WHERE f.stock_id = s.stock_id
    AND f.buy_filled_price IS NOT NULL
    AND f.sell_filled_price IS NULL
) paid
CROSS JOIN LATERAL fn_buy_below_paid(plan.buy_stop_price, plan.buy_price, paid.min_paid, stock.price_rounding::integer) fin
-- Dollar cost of the REAL order: shares x the final limit (2026-10-07: was
-- LEAST(pre-cap limit, cap limit)), plain and with the ~1.2% taker-fee pad
-- (1.012, the same pad index.js used for its old per-row cash check).
-- Shares are sized at close, so a $1 clip costs $1 x (1 + gap) x 1.01 at
-- the limit (what Coinbase holds for the order).
CROSS JOIN LATERAL (
    SELECT
        plan.shares * fin.limit_price         AS cost_usd,
        plan.shares * fin.limit_price * 1.012 AS cost_with_fee
) eff
-- Day row of vw_signal: today's close-vs-yesterday % vs this coin's
-- average historical day-over-day %. Keeps the year-basis priority pick
-- (s.period_type = 'year') but blocks chase entries on hot days (e.g.
-- MSOL up hard today while year signal still says BUY).
JOIN vw_signal d
  ON d.stock_id = s.stock_id
 AND d.period_type = 'day'
-- 2026-10-07: crypto buys stay USD ONLY on purpose. USDC (vw_balance
-- name = 'USDC') is never cash here: it is profit parked by the USDC sweep
-- and the pot USDC-capable ETFs buy with (index.js fundAttemptsByCurrency).
-- vw_etf_cash_reserve holds only USD-funded ETF attempts.
WHERE b.name = 'USD'
AND v_pause_buys = 'false'
-- 2026-09-25 cash-backlog gate: free USD minus what is already promised to
-- planned buys that have no live order yet. Previously only free USD was
-- compared to the clip, so every brief cash bump (e.g. a far-buy release)
-- inserted another planned row that then failed INSUFFICIENT_FUND forever.
-- 2026-10-04: index.js writes config.etf_usd_reserve before this procedure
-- and vw_etf_cash_reserve exposes it. Subtract that from free USD so a new
-- crypto plan cannot spend dollars this run's ETF attempts still need.
-- The reserve is only those attempts (open NORMAL session, dip rules
-- passed, not already filled, and not skipped for lack of cash). A closed
-- session stores 0. ETF orders are placed after this procedure, same minute.
-- pause_buys still gates only these crypto inserts, not the ETF buys.
AND b.available
    - COALESCE((SELECT reserve_usd FROM vw_etf_cash_reserve), 0)
    -- 2026-10-07: realized profit queued for the USDC sweep is reserved too.
    - COALESCE((SELECT reserve_usd FROM vw_usdc_sweep_reserve), 0)
    - COALESCE((SELECT SUM(pb.shares * pb.buy_price * 1.012)::numeric  -- 2026-10-05: + fee pad
                FROM position pb JOIN stock sb ON sb.stock_id = pb.stock_id
                WHERE pb.buy_coinbase_order_id IS NULL
                AND pb.buy_filled_price IS NULL
                AND sb.trading_disabled IS NOT TRUE), 0)
-- 2026-10-05 (#2): compare against the real cost of THIS order incl. the
-- fee pad (was: the clip dollars, ~20% less than the order actually holds,
-- so rows were inserted that free cash could not cover and they sat).
  >= eff.cost_with_fee
AND s.period_type = 'year'
AND p.buy_order_id IS NULL
AND s.historical_avg_change_percent > 0
-- 2026-10-08 (Theodore): positive year-basis priority only. Replaces the
-- top-50%-by-priority cut (ba3e579); s is the vw_signal year row.
AND s.priority > 0
AND d.current_change_percent < d.historical_avg_change_percent
AND stock.trading_disabled IS NOT TRUE
-- 2026-10-07: never open a position in a stablecoin (stock.is_stablecoin,
-- price-behavior flag set near the top of this procedure). stock., not s.:
-- s is vw_signal in this INSERT.
AND stock.is_stablecoin IS NOT TRUE
AND (
    NOT EXISTS (
        SELECT 1 FROM position existing
        WHERE existing.stock_id = s.stock_id
        AND existing.period_type = 'day'
        AND existing.buy_filled_price IS NOT NULL
        AND existing.sell_filled_price IS NULL
    )
    OR s.close < (
        SELECT MIN(existing.buy_filled_price)
        FROM position existing
        WHERE existing.stock_id = s.stock_id
        AND existing.period_type = 'day'
        AND existing.buy_filled_price IS NOT NULL
        AND existing.sell_filled_price IS NULL
    )
)
-- Book gates (2026-10-05, were index.js placement-time checks):
--   spread:    only judged when bulk_best_bid_ask is fresh; then a missing
--              coin / one-sided quote (spread_pct NULL) fails the <= test.
--   imbalance: fresh snapshot not ask-heavy (>= threshold; was > -0.4 here
--              and >= -0.4 in index.js -- now one rule). NULL = allow.
--   thin ask:  near-ask notional >= order cost (eff.cost_usd, i.e. shares x
--              limit, same notional index.js used) * multiple. NULL = allow.
-- 2026-10-07: these are filters only. The book no longer ranks candidates
-- (the bid-heavy +0.2 preference / imbalance DESC were removed from the
-- ORDER BY below; the pick is by priority).
AND (NOT v_bba_fresh OR bba.spread_pct <= v_book_max_spread_pct)
AND (book.imbalance IS NULL OR book.imbalance >= v_book_skip_imbalance)
AND (book.near_ask_usd IS NULL OR book.near_ask_usd >= eff.cost_usd * v_book_min_ask_notional_mult)
-- 2026-10-05 (#3) trigger must already be above price: on a coin already
-- held the trigger is the final (below-lowest-paid) stop, so only create
-- the row when price is under it (was: inserted anyway, then index.js
-- waited for price to fall -- the PNG/DOGE/VVV/GFI/QI rows). Not held = no
-- limit here (the refresh UPDATE keeps those triggers above market).
-- 2026-10-07: compares to fin.stop_price (was addcap.cap_stop).
AND stock.price::numeric < CASE WHEN paid.min_paid IS NOT NULL THEN fin.stop_price
                                ELSE 'Infinity'::numeric END  -- stock.price: s is vw_signal here
-- 2026-10-05 (#11) Coinbase minimum order size: base size >= base_min_size
-- (stock.min_shares) and quote size (shares x effective limit) >=
-- quote_min_size (stock.min_price). NULL minimum = no limit.
AND plan.shares > 0
AND plan.shares >= COALESCE(stock.min_shares, 0)
AND eff.cost_usd >= COALESCE(stock.min_price, 0)
-- 2026-10-07 (Theodore: buys "should be sorted by priority desc only"):
-- highest priority wins, nothing else in the sort. (Was: bid-heavy book
-- first, then imbalance DESC, then priority; briefly + stock_id tiebreak.)
ORDER BY
    s.priority DESC NULLS LAST
LIMIT 1;

-- Buy again if current price has dropped below the MOST RECENT
-- already-filled price for a stock+period (not the lowest ever --
-- anchored on whichever fill actually happened last, so this can
-- re-trigger even after a good fill if price has since moved against
-- the latest one). Anchored on position itself, not vw_signal — purely
-- "average down further," no recommendation conditions involved.
-- Clip size scales with depth: $N for the Nth open buy on that
-- stock+period (1 open filled → next is $2; 2 open → next is $3). Open
-- means buy_order_id set and sell not filled. available must exceed that
-- clip. Only triggers off a coin whose buy is actually filled, and only if
-- there's no other buy order currently open/pending for that same
-- stock+period. When multiple held coins qualify in the same cycle,
-- ranked by stock.priority descending (same year-basis priority marker the
-- new-position buy uses) so the highest-priority coin gets the
-- average-down clip first. One new position per cycle.
-- 2026-10-07 (Theodore): sorted by priority DESC ONLY -- the order book no
-- longer ranks candidates here (its gates below still filter).
WITH held AS (
    SELECT DISTINCT ON (stock_id, period_type)
        stock_id, period_type, buy_filled_price AS last_filled_price
    FROM position
    WHERE buy_filled_price IS NOT NULL
    ORDER BY stock_id, period_type, buy_filled_date DESC
),
sized AS (
    SELECT
        h.*,
        (
            SELECT COUNT(*)::numeric
            FROM position op
            WHERE op.stock_id = h.stock_id
            AND op.period_type = h.period_type
            AND op.buy_order_id IS NOT NULL
            AND op.sell_filled_price IS NULL
        ) + 1 AS clip_usd
    FROM held h
)
INSERT INTO position (stock_id, name, buy_price, buy_stop_price, shares, date_created, buy_order_id, period_type)
SELECT
    s.stock_id,
    s.name,
    -- 2026-10-05: from the "plan" lateral below.
    -- 2026-10-07: FINAL stop/limit after the below-lowest-paid rule.
    fin.limit_price AS buy_price,
    fin.stop_price  AS buy_stop_price,
    plan.shares,
    NOW() AS date_created,
    gen_random_uuid(),
    sized.period_type
FROM sized
JOIN stock s ON s.stock_id = sized.stock_id
CROSS JOIN vw_balance b
-- 2026-10-05 book gates (moved here from index.js processBuyOrders(); see
-- the clean-up delete near the top for the full rationale and fail-open
-- rules). Latest L2 snapshot from the last 3 minutes only -- before this,
-- any age was used, and coins past the old 40-coin alphabetical snapshot
-- cap were judged on hours-old books. NULL = no fresh snapshot = allow.
LEFT JOIN LATERAL (
    SELECT bs.imbalance, bs.near_ask_usd
    FROM book_snapshot bs
    WHERE bs.name = s.name
    AND bs.date_created > NOW() - INTERVAL '3 minutes'
    ORDER BY bs.date_created DESC
    LIMIT 1
) book ON TRUE
-- This run's top-of-book for the coin (spread gate).
LEFT JOIN bulk_best_bid_ask bba ON bba.product_id = s.name
-- Thresholds from config (defaults = the old index.js constants) and
-- whether bulk_best_bid_ask is fresh enough to judge spread at all:
-- 2026-10-07 now v_book_* / v_bba_fresh (header), was the bookcfg lateral.
-- 2026-10-07 cash-scaled gap from the ONE shared place (vw_buy_stop_gap).
-- Theodore: cash scaling on EVERY buy, so the average-down add now uses it
-- too (was a flat trigger 1% / limit 1.1% above price). The below-lowest-
-- paid rule then normally pins it, since this coin is always held.
-- (gap: v_gap, assigned once at the top of the run)
-- The order this INSERT will create: trigger = price x (1 + gap), limit =
-- trigger x 1.01, shares = clip dollars / price.
CROSS JOIN LATERAL (
    SELECT
        TRUNC(s.price::numeric * (1 + v_gap) * 1.01, s.price_rounding::integer)  AS buy_price,
        TRUNC(s.price::numeric * (1 + v_gap),        s.price_rounding::integer)  AS buy_stop_price,
        TRUNC((sized.clip_usd / s.price::numeric), s.share_rounding::integer)    AS shares
) plan
-- 2026-10-07 below-lowest-paid rule (replaces the add_buy_cap_ratio 0.99
-- cap preview): final stop/limit the row is written with.
CROSS JOIN LATERAL (
    SELECT MIN(f.buy_filled_price)::numeric AS min_paid
    FROM position f
    WHERE f.stock_id = s.stock_id
    AND f.buy_filled_price IS NOT NULL
    AND f.sell_filled_price IS NULL
) paid
CROSS JOIN LATERAL fn_buy_below_paid(plan.buy_stop_price, plan.buy_price, paid.min_paid, s.price_rounding::integer) fin
-- Dollar cost of the REAL order: shares x the final limit, plain and with
-- the ~1.2% taker-fee pad (1.012).
CROSS JOIN LATERAL (
    SELECT
        plan.shares * fin.limit_price         AS cost_usd,
        plan.shares * fin.limit_price * 1.012 AS cost_with_fee
) eff
-- 2026-10-07: crypto buys stay USD ONLY on purpose. USDC (vw_balance
-- name = 'USDC') is never cash here: it is profit parked by the USDC sweep
-- and the pot USDC-capable ETFs buy with (index.js fundAttemptsByCurrency).
-- vw_etf_cash_reserve holds only USD-funded ETF attempts.
WHERE b.name = 'USD'
-- 2026-09-25 cash-backlog gate (same as the new-position insert above):
-- don't add another planned buy the free cash can't cover once the
-- existing no-order planned rows are funded.
-- 2026-10-04: index.js writes config.etf_usd_reserve before this procedure
-- and vw_etf_cash_reserve exposes it. Subtract that from free USD so a new
-- crypto plan cannot spend dollars this run's ETF attempts still need.
-- The reserve is only those attempts (open NORMAL session, dip rules
-- passed, not already filled, and not skipped for lack of cash). A closed
-- session stores 0. ETF orders are placed after this procedure, same minute.
-- pause_buys still gates only these crypto inserts, not the ETF buys.
AND b.available
    - COALESCE((SELECT reserve_usd FROM vw_etf_cash_reserve), 0)
    -- 2026-10-07: realized profit queued for the USDC sweep is reserved too.
    - COALESCE((SELECT reserve_usd FROM vw_usdc_sweep_reserve), 0)
    - COALESCE((SELECT SUM(pb.shares * pb.buy_price * 1.012)::numeric  -- 2026-10-05: + fee pad
                FROM position pb JOIN stock sb ON sb.stock_id = pb.stock_id
                WHERE pb.buy_coinbase_order_id IS NULL
                AND pb.buy_filled_price IS NULL
                AND sb.trading_disabled IS NOT TRUE), 0)
-- 2026-10-05 (#2): real cost of this order incl. fee pad (was clip dollars).
  >= eff.cost_with_fee
AND v_pause_buys = 'false'
-- Average-down TRIGGER (unchanged on purpose, 2026-10-07): price x 1.011
-- below the most recent fill. This is the "has price dropped below my last
-- buy" test, not the order price -- the order is priced by plan/fin above.
AND TRUNC(s.price::numeric * 1.011, s.price_rounding::integer) < sized.last_filled_price
AND s.trading_disabled IS NOT TRUE
-- 2026-10-07: never average down into a stablecoin (stock.is_stablecoin,
-- price-behavior flag set near the top of this procedure).
AND s.is_stablecoin IS NOT TRUE
AND NOT EXISTS (
    SELECT 1 FROM position existing
    WHERE existing.stock_id = sized.stock_id
    AND existing.period_type = sized.period_type
    AND existing.buy_order_id IS NOT NULL
    AND existing.buy_filled_price IS NULL
)
-- Book gates (2026-10-05, were index.js placement-time checks):
--   spread:    only judged when bulk_best_bid_ask is fresh; then a missing
--              coin / one-sided quote (spread_pct NULL) fails the <= test.
--   imbalance: fresh snapshot not ask-heavy (>= threshold; was > -0.4 here
--              and >= -0.4 in index.js -- now one rule). NULL = allow.
--   thin ask:  near-ask notional >= order cost (eff.cost_usd, i.e. shares x
--              limit, same notional index.js used) * multiple. NULL = allow.
-- 2026-10-07: these are filters only. The bid-heavy +0.2 preference and
-- imbalance DESC were removed from the ORDER BY below (priority only).
AND (NOT v_bba_fresh OR bba.spread_pct <= v_book_max_spread_pct)
AND (book.imbalance IS NULL OR book.imbalance >= v_book_skip_imbalance)
AND (book.near_ask_usd IS NULL OR book.near_ask_usd >= eff.cost_usd * v_book_min_ask_notional_mult)
-- 2026-10-05 (#3) trigger must already be above price: only create the
-- row when price is under the final stop (2026-10-07: fin.stop_price after
-- the below-lowest-paid rule; was addcap.cap_stop). Not held = no limit.
AND s.price::numeric < CASE WHEN paid.min_paid IS NOT NULL THEN fin.stop_price
                            ELSE 'Infinity'::numeric END
-- 2026-10-05 (#11) Coinbase minimum order size: base size >= base_min_size
-- (stock.min_shares) and quote size (shares x effective limit) >=
-- quote_min_size (stock.min_price). NULL minimum = no limit.
AND plan.shares > 0
AND plan.shares >= COALESCE(s.min_shares, 0)
AND eff.cost_usd >= COALESCE(s.min_price, 0)
-- 2026-10-07: priority DESC only (s = stock here). Was: bid-heavy book
-- first, then imbalance DESC, then priority.
ORDER BY
    s.priority DESC NULLS LAST
LIMIT 1;

-- Initial sell stop, floored at a breakeven price unconditionally — a
-- position must never be sold at a net loss, underwater or not. The floor
-- is NOT raw buy_filled_price: profit is (sell_price*shares - sell_fee) -
-- (buy_price*shares + buy_fee), so selling at exactly buy_filled_price
-- still loses both fees. This expression solves for the sell price where
-- post-fee proceeds exactly cover total cost, using this position's own
-- realized buy-side fee rate as the estimate for the sell-side fee
-- (falling back to config.fee_percent / 100 when the buy fee is unknown).
-- LATERAL can't be used
-- here since UPDATE's target table isn't a FROM-list item it can see, so
-- the formula is inlined directly instead of computed once via a join.
-- When underwater this floor makes the stop land above current market,
-- which Coinbase will reject at placement time; processSellOrders() must
-- not respond to that rejection by substituting a lower (loss-making)
-- price — it should leave the position unprotected and retry with fresh
-- preview data next cycle until price recovers enough for this floor to
-- clear.
--
-- Happy-path sell target sits ABOVE fee breakeven by config.sell_net_cushion
-- (default 0.015 = +1.5% net after fees). Fee floor is still the no-loss
-- minimum; cushion multiplies that floor so closes book real cents instead
-- of $0 scrapes. sell_stop_price keeps the extra 1.01 vs sell_price so the
-- stop-limit has a trigger gap (LSETH stranding bug). Volatility branch is
-- unchanged and still wins via GREATEST when spot is strong enough.
-- Cushion lives in config.sell_net_cushion so it can be tuned without a
-- procedure edit.
UPDATE position
SET sell_stop_price = GREATEST(
        CEIL(
            (position.buy_filled_price::numeric
                * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), v_fee_percent / 100))
                / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), v_fee_percent / 100)))
                * (1 + v_sell_net_cushion)
                * 1.01
            * POWER(10::numeric, stock.price_rounding::int)
        ) / POWER(10::numeric, stock.price_rounding::int),
        TRUNC(stock.price::numeric * CASE position.period_type
            WHEN 'day'   THEN LEAST(0.99, GREATEST(0.90, 1 - pat.std_dev::numeric / 200))
            WHEN 'month' THEN LEAST(0.97, GREATEST(0.75, 1 - pat.std_dev::numeric / 200))
            WHEN 'year'  THEN LEAST(0.95, GREATEST(0.60, 1 - pat.std_dev::numeric / 200))
        END, stock.price_rounding::int)
    ),
    sell_price = GREATEST(
        CEIL(
            (position.buy_filled_price::numeric
                * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), v_fee_percent / 100))
                / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), v_fee_percent / 100)))
                * (1 + v_sell_net_cushion)
            * POWER(10::numeric, stock.price_rounding::int)
        ) / POWER(10::numeric, stock.price_rounding::int),
        TRUNC(stock.price::numeric * (CASE position.period_type
            WHEN 'day'   THEN LEAST(0.99, GREATEST(0.90, 1 - pat.std_dev::numeric / 200))
            WHEN 'month' THEN LEAST(0.97, GREATEST(0.75, 1 - pat.std_dev::numeric / 200))
            WHEN 'year'  THEN LEAST(0.95, GREATEST(0.60, 1 - pat.std_dev::numeric / 200))
        END - 0.01), stock.price_rounding::int)
    )
FROM stock
JOIN price_aggregate_total pat ON stock.stock_id = pat.stock_id
JOIN vw_signal d
  ON d.stock_id = stock.stock_id
 AND d.period_type = 'day'
WHERE position.stock_id = stock.stock_id
AND pat.period_type = position.period_type
AND position.buy_filled_price IS NOT NULL
AND position.sell_price IS NULL
-- Sell stays unpriced until today is stronger than this coin's usual day,
-- the mirror of the buy dip filter (current day change below the day
-- average). The sell price is still written only once.
AND d.current_change_percent > d.historical_avg_change_percent
-- Estimated profit, from buy_filled_price and buy_fee alone: at the
-- fee-adjusted floor price (same CEIL(...) breakeven formula as above),
-- proceeds after an estimated sell fee (same buy-side fee rate, falling
-- back to config.fee_percent / 100) must exceed total cost (buy_filled_price * shares +
-- buy_fee). Uses only known buy-side values, not current market price.
AND (
    (CEIL(
        (position.buy_filled_price::numeric
            * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), v_fee_percent / 100))
            / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), v_fee_percent / 100)))
        * POWER(10::numeric, stock.price_rounding::int)
    ) / POWER(10::numeric, stock.price_rounding::int))
    * position.shares::numeric
    * (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), v_fee_percent / 100))
    - (position.buy_filled_price::numeric * position.shares::numeric + COALESCE(position.buy_fee::numeric, 0))
) > 0;
-- NOTE: the UPDATE above can never price a period_type 'listing' bag: it
-- joins price_aggregate_total on pat.period_type = position.period_type
-- (only day / month / year rows exist) and needs a vw_signal day row, which
-- a brand-new coin does not have. Listing bags get the block below instead.

-- 2026-10-07 LISTING SELL PRICING (Theodore; PONS-USD position 1391 sat
-- filled with no sell price because of the joins noted above). A filled
-- listing snipe bag gets its sell priced ONCE, from its own settled buy:
--   sell_price      = fee breakeven * (1 + config.sell_net_cushion), rounded UP
--   sell_stop_price = fee breakeven * (1 + sell_net_cushion) * 1.01, rounded UP
-- Fee breakeven = buy_filled_price * (1 + r) / (1 - r), r = this bag's own
-- buy fee rate (buy_fee / (buy_filled_price * shares)), falling back to
-- config.fee_percent / 100 -- the SAME formula and rounding as the UPDATE
-- above, minus its price-history / day-signal requirements and its
-- volatility branch (a new coin has no history). Same "never sell at a net
-- loss" profit check. The sell itself is unchanged: processSellOrders
-- places the normal STOP_DOWN stop-limit on position.name (<COIN>-USD, also
-- for a bag bought on <COIN>-USDC -- same coin wallet) once the price is
-- above sell_stop_price, and vw_edit_orders sell branch 1 trails the stop
-- up (fixed 0.99 ratio) because listing bags are included there.
UPDATE position
SET sell_stop_price =
        CEIL(
            (position.buy_filled_price::numeric
                * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), v_fee_percent / 100))
                / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), v_fee_percent / 100)))
                * (1 + v_sell_net_cushion)
                * 1.01
            * POWER(10::numeric, stock.price_rounding::int)
        ) / POWER(10::numeric, stock.price_rounding::int),
    sell_price =
        CEIL(
            (position.buy_filled_price::numeric
                * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), v_fee_percent / 100))
                / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), v_fee_percent / 100)))
                * (1 + v_sell_net_cushion)
            * POWER(10::numeric, stock.price_rounding::int)
        ) / POWER(10::numeric, stock.price_rounding::int)
FROM stock
WHERE position.stock_id = stock.stock_id
AND position.period_type = 'listing'
AND position.buy_filled_price IS NOT NULL
AND position.sell_price IS NULL
AND stock.price_rounding IS NOT NULL
-- Same profit check as the UPDATE above: at the rounded fee breakeven,
-- proceeds after an estimated sell fee (same buy-side fee rate) must exceed
-- total cost (buy_filled_price * shares + buy_fee).
AND (
    (CEIL(
        (position.buy_filled_price::numeric
            * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), v_fee_percent / 100))
            / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), v_fee_percent / 100)))
        * POWER(10::numeric, stock.price_rounding::int)
    ) / POWER(10::numeric, stock.price_rounding::int))
    * position.shares::numeric
    * (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), v_fee_percent / 100))
    - (position.buy_filled_price::numeric * position.shares::numeric + COALESCE(position.buy_fee::numeric, 0))
) > 0;

-- Refresh stale buy candidates: a pending buy that has never gotten a
-- Coinbase order ID keeps its original buy_stop_price forever, since
-- nothing else ever touches it (the remake logic in vw_edit_orders only
-- applies once a position has SOME coinbase_order_id, pending or filled).
-- If the market moves up past that stop before the order is ever
-- successfully placed, every attempt fails with
-- PREVIEW_STOP_PRICE_BELOW_LAST_TRADE_PRICE (the stop needs room above
-- current price to trigger) -- and since the "clear error_message" step
-- below resets it every cycle, it just retries the same doomed price
-- forever (confirmed stuck this way on OCEAN-USD for 4 days). Recompute
-- using the same cash-scaled stop gap a fresh pick uses, off current price
-- instead of the stale signal-time price.
UPDATE position
SET buy_stop_price = TRUNC(stock.price::numeric * (1 + v_gap), stock.price_rounding::integer),
    buy_price = TRUNC(stock.price::numeric * (1 + v_gap) * 1.01, stock.price_rounding::integer)
FROM stock
-- 2026-10-07: cash-scaled gap from the ONE shared place (vw_buy_stop_gap:
-- buy_stop_base_pct/100 * sqrt(equity / free USD), USD only, no max).
-- Replaces the inline 1 + 0.02 * (equity / free USD) of 2026-10-05.
-- (gap: v_gap, assigned once at the top of the run)
WHERE position.stock_id = stock.stock_id
AND position.buy_coinbase_order_id IS NULL
AND position.buy_filled_price IS NULL
-- 2026-10-07: listing rows are plain limits (no stop) -- never re-priced here.
AND position.period_type IS DISTINCT FROM 'listing'
AND stock.price::numeric >= position.buy_stop_price::numeric;

-- 2026-09-27 add-on buy cap: a buy on a coin you already hold must never be
-- priced above your cheapest open bag (OCEAN bag 939 filled at 0.1718 even
-- though bag 926 was bought at 0.1695).
-- 2026-10-07 BELOW-LOWEST-PAID RULE (Theodore) replaces the old math
-- (stop = config.add_buy_cap_ratio 0.99 x cheapest bag, limit 1% above;
-- that config row is left in place but no longer read): an unsent buy whose
-- LIMIT is at/above the lowest buy_filled_price of the coin's open bags gets
-- limit = the largest tick strictly below that price and stop = limit / 1.01
-- rounded down to the tick (fn_buy_below_paid, shared with the inserts and
-- vw_edit_orders). Runs after the stale refresh above, which can raise a
-- trigger again. Only buys not yet sent to Coinbase are touched; live
-- orders follow the same rule on every remake (vw_edit_orders).
UPDATE position p
SET (buy_stop_price, buy_price) = (
        SELECT b.stop_price, b.limit_price
        FROM fn_buy_below_paid(p.buy_stop_price::numeric, p.buy_price::numeric,
                               c.min_fill, s.price_rounding::integer) b
    )
FROM stock s,
     (SELECT stock_id, MIN(buy_filled_price)::numeric AS min_fill
      FROM position
      WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL
      GROUP BY stock_id) c
WHERE p.stock_id = s.stock_id
AND c.stock_id = p.stock_id
AND p.buy_coinbase_order_id IS NULL
AND p.buy_filled_price IS NULL
-- 2026-10-07: listing rows exempt (plain limit, and never on a held coin).
AND p.period_type IS DISTINCT FROM 'listing'
AND s.price_rounding IS NOT NULL
AND p.buy_price::numeric >= c.min_fill;

-- 2026-10-05 (#3) safety net: after the refresh and cap UPDATEs above, an
-- unsent planned row whose trigger is still not above current price cannot
-- be placed (Coinbase needs the stop above market) -- index.js used to wait
-- on these (`s.price < p.buy_stop_price`); now they are deleted so nothing
-- sits. The INSERT gates and clean-up (e) above should already prevent this;
-- this catches rounding edge cases. Same safety guards as the clean-up.
DELETE FROM position p
USING stock s
WHERE s.stock_id = p.stock_id
AND p.buy_coinbase_order_id IS NULL
AND p.buy_filled_price IS NULL
AND p.sell_coinbase_order_id IS NULL
AND NOT EXISTS (
    SELECT 1 FROM bulk_open_orders o WHERE o.client_order_id = p.buy_order_id
)
-- 2026-10-07: listing rows exempt (no stop; a listing limit -- first trade
-- or best ask + cushion -- may legitimately sit below the current price).
AND p.period_type IS DISTINCT FROM 'listing'
AND s.price::numeric >= p.buy_stop_price::numeric;

-- Clear error_message on unfilled buy positions instead of deleting them.
-- 2026-09-25: except permanent rejections. Clearing 'Invalid product_id'
-- every cycle made processBuyOrders retry a delisted coin (LRC-USD) forever;
-- that error can never succeed on retry, so it is left in place and the row
-- stays out of processBuyOrders' `error_message IS NULL` queue.
UPDATE position SET error_message = NULL
WHERE error_message IS NOT NULL
AND buy_coinbase_order_id IS NULL
AND buy_filled_price IS NULL
AND error_message NOT IN ('Invalid product_id');

-- Step 1: match fills for either side of a position (buy or sell).
-- Deliberately does not compute profit here -- that happens fresh in Step 2
-- from position's own stored columns, decoupled from this statement, so a
-- NULL fee here can never silently block the close-out the way it used to.
--
-- 2026-09-25 rewrite (was: UPDATE ... FROM bulk_fills with `bf.fee > 0`):
--  * Source is the permanent `fills` ledger (archived from bulk_fills at the
--    top of this procedure), not bulk_fills. bulk_fills only holds Coinbase's
--    recent-fills window, so a fill whose fee/price wasn't captured in that
--    window (e.g. PAX 468/578) could never be matched again.
--  * Aggregated per order: an order can fill in several partial fills, and
--    UPDATE ... FROM bulk_fills picked ONE arbitrary fill row -- so price was
--    one partial's price and fee was one partial's fee (understated, e.g.
--    MAMO 568 fee 0.00043 vs 0.00188 actual). Now price = size-weighted VWAP
--    across all fills of the order, fee = SUM of all their commissions.
--  * A zero fee is accepted. Coinbase charges $0 on some maker fills (PAX),
--    and the old `fee > 0` test left sell_fee NULL forever, so Step 2 never
--    recorded the close and Step 3 never deleted the row. Because Coinbase
--    can briefly report commission 0 before it settles, a 0 fee is only
--    accepted once the order's last fill is > 15 minutes old.
--  * The fee is finalized only once the order is fully filled (filled size
--    covers position.shares), so a first partial fill can't lock in a
--    partial fee. Fallback: if the order's last fill is > 1 day old, accept
--    whatever filled (a partially-filled-then-cancelled order must not
--    block the close-out forever).
--  * Filled price keeps refreshing to the latest VWAP until the fee is
--    finalized (i.e. while partial fills are still arriving);
--    buy_filled_date is still stamped only on the first match.
--  * Buy and sell aggregates are joined separately (fb / fs) so a position
--    whose buy and sell orders both have fills is updated deterministically
--    in one pass instead of depending on which join row Postgres picks.
WITH f AS (
    SELECT order_id,
           SUM(price * size) / NULLIF(SUM(size), 0) AS vwap,        -- size-weighted avg price over partial fills
           SUM(size)                                AS filled_size, -- total base filled so far
           SUM(fee)                                 AS fee,         -- total commission across partial fills
           MAX(trade_time)                          AS last_fill    -- most recent partial fill
    FROM fills
    GROUP BY order_id
),
m AS (
    SELECT p.position_id,
           fb.vwap AS b_vwap, fs.vwap AS s_vwap,
           -- buy fee is final when: fully filled AND (fee > 0 OR fill settled > 15 min),
           -- or the order simply stopped filling > 1 day ago
           CASE WHEN fb.order_id IS NOT NULL AND (
                    (fb.filled_size >= p.shares::numeric * 0.999
                        AND (fb.fee > 0 OR fb.last_fill < NOW() - INTERVAL '15 minutes'))
                    OR fb.last_fill < NOW() - INTERVAL '1 day')
                THEN fb.fee END AS b_fee_final,
           -- same rule for the sell side
           CASE WHEN fs.order_id IS NOT NULL AND (
                    (fs.filled_size >= p.shares::numeric * 0.999
                        AND (fs.fee > 0 OR fs.last_fill < NOW() - INTERVAL '15 minutes'))
                    OR fs.last_fill < NOW() - INTERVAL '1 day')
                THEN fs.fee END AS s_fee_final
    FROM position p
    LEFT JOIN f fb ON fb.order_id = p.buy_coinbase_order_id
    LEFT JOIN f fs ON fs.order_id = p.sell_coinbase_order_id
    -- only rows that still have something to fill in
    WHERE (fb.order_id IS NOT NULL AND (p.buy_filled_price  IS NULL OR p.buy_fee  IS NULL))
       OR (fs.order_id IS NOT NULL AND (p.sell_filled_price IS NULL OR p.sell_fee IS NULL))
)
UPDATE position
SET buy_filled_price  = CASE WHEN m.b_vwap IS NOT NULL AND position.buy_fee  IS NULL THEN m.b_vwap ELSE position.buy_filled_price END,
    buy_filled_date   = CASE WHEN m.b_vwap IS NOT NULL AND position.buy_filled_price IS NULL THEN NOW() ELSE position.buy_filled_date END,
    buy_fee           = COALESCE(position.buy_fee,  m.b_fee_final),
    sell_filled_price = CASE WHEN m.s_vwap IS NOT NULL AND position.sell_fee IS NULL THEN m.s_vwap ELSE position.sell_filled_price END,
    sell_fee          = COALESCE(position.sell_fee, m.s_fee_final)
FROM m
WHERE position.position_id = m.position_id;

-- Step 1b (2026-10-07, USDC profit sweep): fill in profit_converted_usdc on
-- every fully bought-and-sold position that has all six inputs, i.e. the
-- exact same rows Step 2 is about to record. Same formula as Step 2's
-- profit (which already nets out BOTH fees):
--     (sell_filled_price * shares - sell_fee) - (buy_filled_price * shares + buy_fee)
-- truncated to cents (so we never sweep more than was earned), and a loss
-- is stored as 0 (never negative). Fees are the summed Coinbase commissions
-- of every fill of the buy / sell order (Step 1 above, from the fills
-- ledger). index.js sweepProfitToUsdc() later converts these dollars to
-- USDC. Step 2 only records, and Step 3 only deletes, rows where this is
-- NOT NULL, so a row can never disappear before its amount is filled in.
UPDATE position p
SET profit_converted_usdc = GREATEST(0::numeric, TRUNC((
        (p.sell_filled_price::numeric * p.shares::numeric - p.sell_fee::numeric)
      - (p.buy_filled_price::numeric  * p.shares::numeric + p.buy_fee::numeric))::numeric, 2))
WHERE p.profit_converted_usdc IS NULL
AND p.buy_coinbase_order_id IS NOT NULL
AND p.sell_coinbase_order_id IS NOT NULL
AND p.buy_filled_price IS NOT NULL
AND p.sell_filled_price IS NOT NULL
AND p.buy_fee IS NOT NULL
AND p.sell_fee IS NOT NULL;

-- Step 2: record any fully bought-and-sold position into profit_history,
-- computing profit fresh from position's current buy/sell price and fee
-- columns. Requires every one of buy/sell order_id, buy/sell filled price,
-- and buy/sell fee to actually be populated -- no COALESCE fallback, so a
-- still-missing fee (e.g. not yet settled by Coinbase) correctly holds this
-- position back rather than recording a wrong, understated profit. It'll
-- pick it up automatically once Step 1 finishes backfilling it. Skips
-- anything already recorded, matched on both the buy and sell order_id
-- together.
-- 2026-10-07: also carries profit_converted_usdc over (Step 1b) and only
-- records rows where it is filled in.
-- 2026-10-07: also carries buy_quote_currency (NULL = USD, 'USDC' = listing
-- snipe bought on <COIN>-USDC); profit math is unchanged (USDC = USD 1:1).
INSERT INTO profit_history (stock_id, name, period_type, buy_coinbase_order_id, sell_fills_id, buy_fee, sell_fee, profit, profit_converted_usdc, buy_quote_currency)
SELECT
    p.stock_id, p.name, p.period_type, p.buy_coinbase_order_id, p.sell_coinbase_order_id AS sell_fills_id,
    TRUNC(p.buy_fee::numeric, 2) AS buy_fee,
    TRUNC(p.sell_fee::numeric, 2) AS sell_fee,
    TRUNC(((p.sell_filled_price::numeric * p.shares::numeric - p.sell_fee::numeric)
         - (p.buy_filled_price::numeric * p.shares::numeric + p.buy_fee::numeric))::numeric, 2) AS profit,
    p.profit_converted_usdc,
    p.buy_quote_currency
FROM position p
WHERE p.buy_coinbase_order_id IS NOT NULL
AND p.sell_coinbase_order_id IS NOT NULL
AND p.buy_filled_price IS NOT NULL
AND p.sell_filled_price IS NOT NULL
AND p.buy_fee IS NOT NULL
AND p.sell_fee IS NOT NULL
AND p.profit_converted_usdc IS NOT NULL
AND NOT EXISTS (
    SELECT 1 FROM profit_history ph
    WHERE ph.buy_coinbase_order_id = p.buy_coinbase_order_id AND ph.sell_fills_id = p.sell_coinbase_order_id
);

-- Step 3: delete the position row, but only once it's confirmed recorded in
-- profit_history — never delete on the strength of this statement's own
-- assumptions the way the old combined version did.
-- 2026-10-07: and only once profit_converted_usdc is filled in (Step 1b),
-- so the sweep amount is never lost with the row.
DELETE FROM position p
WHERE p.buy_filled_price IS NOT NULL AND p.sell_filled_price IS NOT NULL
AND p.profit_converted_usdc IS NOT NULL
AND EXISTS (
    SELECT 1 FROM profit_history ph
    WHERE ph.buy_coinbase_order_id = p.buy_coinbase_order_id AND ph.sell_fills_id = p.sell_coinbase_order_id
);

-- 2026-10-05: number each open position per coin (creation_hierarchy).
-- Only rows with sell_price IS NOT NULL are ranked. 1 = cheapest fill
-- (lowest buy_filled_price), then lowest buy_stop_price; NOT the oldest
-- row. Rows with sell_price NULL keep creation_hierarchy NULL (not numbered).
-- "Coin" means stock_id, not period_type, so day/month/year rows share one
-- sequence. Order among ranked rows: buy_filled_price ASC NULLS LAST,
-- buy_stop_price ASC NULLS LAST, position_id ASC (tie-break).
-- Placed here, after every INSERT and DELETE on position in this run
-- (orphan recovery, new and average-down buys, stale-plan expiry, and the
-- Step 3 close-out), so the numbers match the rows that are left.
-- Recomputed every run, so a closed or deleted row makes the rows after it
-- move down. Only rows whose number actually changes are written, so the
-- position_audit trigger does not log an unchanged row every run.
UPDATE position p
SET creation_hierarchy = r.rn
FROM (
    SELECT p_all.position_id,
           ranked.rn
    FROM position p_all
    LEFT JOIN (
        SELECT position_id,
               ROW_NUMBER() OVER (
                   PARTITION BY stock_id
                   ORDER BY buy_filled_price ASC NULLS LAST,
                            buy_stop_price ASC NULLS LAST,
                            position_id ASC
               ) AS rn
        FROM position
        WHERE sell_price IS NOT NULL
    ) ranked ON ranked.position_id = p_all.position_id
) r
WHERE p.position_id = r.position_id
  AND p.creation_hierarchy IS DISTINCT FROM r.rn;

-- Once the position row is gone, its audit history goes with it. The DELETE
-- trigger's snapshot is included, on purpose.
DELETE FROM position_audit AS pa
USING position_audit AS a
LEFT JOIN position AS p ON p.position_id = a.position_id
WHERE pa.audit_id = a.audit_id
  AND p.position_id IS NULL;

-- Prune position_audit records older than a month.
DELETE FROM position_audit WHERE changed_at < NOW() - INTERVAL '1 month';

-- Catch any fill this cycle that no position and no profit_history row
-- claims, before bulk_fills is truncated below and the evidence is gone
-- for good. Checked against both live positions (buy/sell_coinbase_order_id)
-- and already-recorded closes (profit_history.buy_coinbase_order_id /
-- sell_fills_id), so a fill legitimately matched and closed out earlier
-- this same cycle (Step 1-3 above) is correctly excluded, not
-- re-flagged as orphaned. NOT EXISTS against unmatched_fills itself
-- avoids re-logging the same fill every cycle it keeps showing up in
-- Coinbase's recent-fills window.
INSERT INTO unmatched_fills (order_id, trade_id, product_id, side, price, size, fee, trade_time)
SELECT bf.order_id, bf.trade_id, bf.product_id, bf.side, bf.price, bf.size, bf.fee, bf.created_at
FROM bulk_fills bf
WHERE NOT EXISTS (
    SELECT 1 FROM position p
    WHERE p.buy_coinbase_order_id = bf.order_id OR p.sell_coinbase_order_id = bf.order_id
)
AND NOT EXISTS (
    SELECT 1 FROM profit_history ph
    WHERE ph.buy_coinbase_order_id = bf.order_id OR ph.sell_fills_id = bf.order_id
)
AND NOT EXISTS (
    SELECT 1 FROM unmatched_fills uf WHERE uf.order_id = bf.order_id
)
-- 2026-10-06: ETF orders (daily market buy and limit ladder) are tracked in
-- etf_buy, not position, so they are not orphans. Without this every ETF
-- fill logged "ERROR: unmatched fill detected" and tripped the health check.
AND NOT EXISTS (
    SELECT 1 FROM etf_buy eb WHERE eb.coinbase_order_id = bf.order_id
);

TRUNCATE TABLE bulk_stock;
TRUNCATE TABLE bulk_fills;
-- bulk_currency and bulk_open_orders are no longer truncated here -- moved to
-- insertCurrency()/insertOpenOrders() in modules/database.js, immediately
-- before each fresh insert, so these tables hold a continuously-queryable
-- last-cycle snapshot the whole time instead of being emptied the moment
-- this procedure finishes. Needed for vw_position_order_balance_audit to be
-- queryable anytime, not just in the brief window mid-cycle.

END;
$$;
