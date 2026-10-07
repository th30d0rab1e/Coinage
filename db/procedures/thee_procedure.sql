CREATE OR REPLACE PROCEDURE public.thee_procedure()
LANGUAGE sql
AS $$

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
-- re-planned each minute only while the snipe window is open).
AND p.period_type IS DISTINCT FROM 'listing'
AND GREATEST(p.date_created, p.last_remade_at, p.buy_placed_at, p.buy_released_at)
    < NOW() - make_interval(hours => COALESCE((SELECT value::int FROM config WHERE key = 'pending_buy_ttl_hours'), 24))
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
--  (e) trigger no longer above price on a coin already held: the add-on cap
--      below (add_buy_cap_ratio, default 0.99 x cheapest open bag) pins the
--      trigger, so once price is at/above that cap the stop-buy cannot be
--      placed (Coinbase needs the stop above market). Uncapped rows are not
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
    (SELECT value FROM config WHERE key = 'pause_buys') IS DISTINCT FROM 'false'
    -- (b) delisted / trading disabled
    OR s.trading_disabled IS TRUE
    -- (c) released by far-buy cash release
    OR p.buy_released_at IS NOT NULL
    -- (d) below Coinbase minimum order size
    OR p.shares IS NULL
    OR p.shares <= 0
    OR p.shares < COALESCE(s.min_shares, 0)
    OR (p.shares * p.buy_price) < COALESCE(s.min_price, 0)
    -- (e) held coin: price at/above the capped trigger
    OR s.price::numeric >= (
        SELECT TRUNC(MIN(f.buy_filled_price)::numeric
                     * COALESCE((SELECT value::numeric FROM config WHERE key = 'add_buy_cap_ratio'), 0.99),
                     s.price_rounding::integer)
        FROM position f
        WHERE f.stock_id = p.stock_id
        AND f.buy_filled_price IS NOT NULL
        AND f.sell_filled_price IS NULL
    )
    -- (f) wide spread (only with fresh best-bid/ask data)
    OR (
        EXISTS (SELECT 1 FROM bulk_best_bid_ask WHERE loaded_at > NOW() - INTERVAL '3 minutes')
        AND COALESCE(
                (SELECT bba.spread_pct FROM bulk_best_bid_ask bba WHERE bba.product_id = s.name),
                'Infinity'::double precision
            ) > COALESCE((SELECT value::double precision FROM config WHERE key = 'book_max_spread_pct'), 0.75)
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
        WHERE fresh_book.imbalance < COALESCE((SELECT value::double precision FROM config WHERE key = 'book_skip_imbalance'), -0.4)
        OR fresh_book.near_ask_usd < (p.shares * p.buy_price)
            * COALESCE((SELECT value::double precision FROM config WHERE key = 'book_min_ask_notional_mult'), 5)
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
           (SELECT available::numeric FROM vw_balance WHERE name = 'USD')
             - COALESCE((SELECT reserve_usd FROM vw_etf_cash_reserve), 0) AS cash_left,
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
-- ===========================================================================
-- Theodore: the snipe window starts when trading ACTUALLY opens, not at
-- Coinbase products.new_at, and lasts config.listing_window_minutes
-- (default 5; "5 minutes, 15 at most" -- change that one config value).
-- Why: a 50-listing study showed trading typically opens ~18h after new_at
-- (only 2/50 traded within 60 min of it), every product carries a non-empty
-- new_at anyway, and the move is front-loaded (minute-1 buys hit +3% within
-- an hour 80% of the time vs 48% at minute 60). The old
-- "new_at within 60 minutes" gate is gone; new_at is now only a candidate
-- filter inside modules/listingWatch.js.
--
-- Window start = listing_watch.trading_open_at, written by index.js
-- (modules/listingWatch.js) BEFORE this procedure each minute: the EARLIER
-- of the pair's first completed trade (Exchange trade_id 1, or first 1-min
-- candle with volume) and the first time the bot saw the launch
-- restrictions cleared. A product first watched after it had already
-- traded gets its real (old) first-trade time, so stale listings never
-- qualify.
--
-- The buy (index.js processBuyOrders sends it as a PLAIN LIMIT, GTC, no
-- stop, no expiry; it rests until it fills or Theodore cancels it):
--   * limit (buy_price) = first trade price * (1 + listing_limit_cushion_pct
--     / 100, default 0.5%), rounded UP to the product's price increment
--     (price_increment, falling back to quote_increment) so the cushion is
--     never lost to rounding.
--   * shares = listing_buy_usd ($1) / limit, rounded UP to base_increment
--     (and at least base_min_size) so the order is >= $1 and clears
--     Coinbase's quote_min_size (usually $1) -- rounding down would land
--     just under $1 and be rejected.
--   * buy_stop_price = NULL: no stop trigger. NULL also keeps the row out of
--     every stop-based path (stale-candidate refresh, add-on cap, safety-net
--     delete, vw_edit_orders remakes, far-buy cash release); each of those
--     also exempts period_type 'listing' explicitly.
--   * Selling: the normal sell code once it fills -- no custom take-profit.

-- Unsent listing row from a previous minute (Coinbase rejected it, e.g.
-- still in auction / cancel-only, or cash was short): drop it so the INSERT
-- below re-plans it with fresh gates -- only while the window is still open.
-- After the window it is simply not re-planned, so nothing sits and blocks
-- the one-listing slot or the ETF gate. Never touches a placed order (same
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

INSERT INTO position (stock_id, name, buy_price, buy_stop_price, shares, date_created, buy_order_id, period_type)
SELECT
    s.stock_id,
    s.name,
    px.limit_price          AS buy_price,       -- plain limit price (no stop)
    NULL                    AS buy_stop_price,  -- no stop trigger at all
    sz.shares               AS shares,          -- ~$1 at the limit price
    NOW()                   AS date_created,
    gen_random_uuid(),
    'listing'
FROM stock s
JOIN bulk_stock bs     ON bs.id = s.name
-- Only products the watcher has a real trading-open time for.
JOIN listing_watch lw  ON lw.product_id = s.name
CROSS JOIN vw_balance b
-- The three tunables (config keys; defaults if a key is missing):
--   listing_window_minutes    = 5    window length after trading_open_at
--   listing_buy_usd           = 1.00 dollars per snipe
--   listing_limit_cushion_pct = 0.5  limit = first trade price + 0.5%
CROSS JOIN LATERAL (
    SELECT COALESCE((SELECT value::numeric FROM config WHERE key = 'listing_window_minutes'), 5)      AS window_minutes,
           COALESCE((SELECT value::numeric FROM config WHERE key = 'listing_buy_usd'), 1.00)         AS buy_usd,
           COALESCE((SELECT value::numeric FROM config WHERE key = 'listing_limit_cushion_pct'), 0.5) AS cushion_pct
) cfg
-- Product increments straight from Coinbase's products payload.
CROSS JOIN LATERAL (
    SELECT NULLIF(COALESCE(NULLIF(bs.json->>'price_increment', ''), NULLIF(bs.json->>'quote_increment', ''))::numeric, 0) AS tick,
           NULLIF(NULLIF(bs.json->>'base_increment', '')::numeric, 0)                                                      AS lot,
           COALESCE(NULLIF(bs.json->>'base_min_size', '')::numeric, 0)                                                     AS base_min,
           COALESCE(NULLIF(bs.json->>'quote_min_size', '')::numeric, 0)                                                    AS quote_min
) inc
-- Limit = first trade price + cushion, rounded UP to the price tick.
CROSS JOIN LATERAL (
    SELECT CEIL(lw.first_trade_price * (1 + cfg.cushion_pct / 100) / inc.tick) * inc.tick AS limit_price
) px
-- Size = $buy_usd at the limit, rounded UP to the base increment, >= base_min_size.
CROSS JOIN LATERAL (
    SELECT GREATEST(CEIL(cfg.buy_usd / px.limit_price / inc.lot) * inc.lot, inc.base_min) AS shares
) sz
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
WHERE b.name = 'USD'
AND (SELECT value FROM config WHERE key = 'pause_buys') = 'false'
AND s.name LIKE '%-USD'
-- Duplicate guards (see the two LEFT JOINs above) -- the PRIMARY guard.
-- DB backstop: partial unique index position_one_listing_per_stock
-- (position(stock_id) WHERE period_type = 'listing'). No ON CONFLICT here on
-- purpose (Theodore): if the backstop ever trips, the unique violation
-- aborts this procedure call for that minute instead of hiding the bug.
AND p.position_id IS NULL
AND ph.profit_history_id IS NULL
-- THE WINDOW: trading opened at most listing_window_minutes ago.
AND lw.trading_open_at IS NOT NULL
AND lw.trading_open_at <= NOW()
AND NOW() - lw.trading_open_at <= cfg.window_minutes * INTERVAL '1 minute'
-- The limit is priced off the first trade, so wait (inside the window)
-- until one exists if the window was opened by "restrictions cleared".
AND lw.first_trade_price > 0
-- Tradable now. limit_only is ALLOWED on purpose: the first minutes after
-- the first trade are normally Coinbase's launch limit-only phase, and a
-- plain limit order is accepted there. Not during the auction, cancel-only
-- or post-only (a taker limit would be rejected).
AND s.trading_disabled IS NOT TRUE
AND COALESCE(bs.trading_disabled, bs.json->>'trading_disabled', 'false') NOT IN ('true', 't', '1')
AND COALESCE(bs.status, bs.json->>'status', '') = 'online'
AND COALESCE(bs.json->>'product_type', 'SPOT') = 'SPOT'
AND COALESCE(bs.json->>'is_disabled', 'false') NOT IN ('true', 't', '1')
AND COALESCE(bs.auction_mode, bs.json->>'auction_mode', 'false') NOT IN ('true', 't', '1')
AND COALESCE(bs.cancel_only, bs.json->>'cancel_only', 'false') NOT IN ('true', 't', '1')
AND COALESCE(bs.post_only, bs.json->>'post_only', 'false') NOT IN ('true', 't', '1')
-- One-coin mutex (unchanged): no other listing bag open -- a resting
-- unfilled listing order or a filled-unsold listing bag both count.
AND NOT EXISTS (
    SELECT 1 FROM position lp
    WHERE lp.period_type = 'listing'
    AND lp.sell_filled_price IS NULL
)
-- Order sanity / Coinbase minimums.
AND inc.tick IS NOT NULL
AND inc.lot IS NOT NULL
AND px.limit_price > 0
AND sz.shares > 0
AND sz.shares * px.limit_price >= inc.quote_min
-- Keep it ~$buy_usd: skip a coin whose base increment / minimum would force
-- a much bigger order (> 1.25x listing_buy_usd).
AND sz.shares * px.limit_price <= cfg.buy_usd * 1.25
-- Cash: free USD must cover the order incl. the ~1.2% taker-fee pad (same
-- pad the other buy gates use). Listing is priority one, so the ETF reserve
-- is not subtracted (index.js skips ETF orders while a listing bag is open).
AND b.available::numeric >= sz.shares * px.limit_price * 1.012
ORDER BY lw.trading_open_at DESC
LIMIT 1;

-- New position: $1 into the highest year-basis-priority coin not already
-- held, gated only on the coin's year-basis trend being positive -- no
-- day-timing signal (recommendation / current-vs-average dip) and no
-- priority floor, since the goal is broad $1 exposure across every coin
-- trending up over the year, ranked by priority, not picking entries by
-- short-term dip timing.
-- Always recorded as period_type 'day' (the existing $1-size bucket), even
-- though the signal driving the pick is the year row. One new position per
-- cycle.
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
    plan.buy_price,
    plan.buy_stop_price,
    plan.shares,
    NOW() AS date_created,
    gen_random_uuid(),
    'day'
FROM vw_signal s
JOIN stock ON s.stock_id = stock.stock_id
CROSS JOIN vw_balance b
CROSS JOIN LATERAL (
    -- Cash-scaled new-buy stop gap: base 2%, stretched by total program
    -- equity / available USD (same components as the equity calc: filled
    -- bags at stock.price, USD available, USD hold in open buys, priced
    -- untracked dust). stop_mult = 1 + 0.02 * (equity / available).
    -- Falls back to 1.02 when available USD is 0/NULL.
    SELECT COALESCE(
        1 + 0.02 * (
            (
                COALESCE((
                    SELECT SUM(p2.shares::numeric * s2.price::numeric)
                    FROM position p2
                    JOIN stock s2 ON s2.stock_id = p2.stock_id
                    WHERE p2.buy_filled_price IS NOT NULL
                    AND p2.sell_filled_price IS NULL
                ), 0)
                + COALESCE((SELECT available::numeric FROM vw_balance WHERE name = 'USD'), 0)
                + COALESCE((SELECT hold::numeric FROM vw_balance WHERE name = 'USD'), 0)
                + COALESCE((
                    SELECT SUM(
                        CASE
                            WHEN a.currency IN ('USDS', 'USD1', 'PAX') THEN a.balance::numeric
                            WHEN st.price IS NOT NULL THEN a.balance::numeric * st.price::numeric
                            ELSE 0
                        END
                    )
                    FROM vw_position_order_balance_audit a
                    LEFT JOIN stock st ON st.name = a.name
                    WHERE a.issue_type = 'untracked_holding'
                ), 0)
            ) / NULLIF((SELECT available::numeric FROM vw_balance WHERE name = 'USD'), 0)
        ),
        1.02
    ) AS stop_mult
) gap
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
-- whether bulk_best_bid_ask is fresh enough to judge spread at all.
CROSS JOIN LATERAL (
    SELECT
        COALESCE((SELECT value::numeric FROM config WHERE key = 'book_max_spread_pct'), 0.75)       AS max_spread_pct,
        COALESCE((SELECT value::numeric FROM config WHERE key = 'book_skip_imbalance'), -0.4)        AS skip_imbalance,
        COALESCE((SELECT value::numeric FROM config WHERE key = 'book_min_ask_notional_mult'), 5)    AS min_ask_mult,
        EXISTS (SELECT 1 FROM bulk_best_bid_ask WHERE loaded_at > NOW() - INTERVAL '3 minutes')     AS bba_fresh
) bookcfg
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
-- 2026-10-05 the order this INSERT will create (formulas unchanged from the
-- old inline SELECT list): trigger = signal close * cash-scaled stop gap,
-- limit 1% above, shares = clip dollars / close.
CROSS JOIN LATERAL (
    SELECT
        TRUNC((s.close::numeric * gap.stop_mult * 1.01), stock.price_rounding::integer) AS buy_price,
        TRUNC((s.close::numeric * gap.stop_mult),        stock.price_rounding::integer) AS buy_stop_price,
        TRUNC(clip.clip_usd / s.close::numeric, stock.share_rounding::integer)          AS shares
) plan
-- 2026-10-05 add-on cap preview: the "add-on buy cap" UPDATE near the end
-- of this procedure pins an unsent buy on a coin already held to
-- add_buy_cap_ratio (default 0.99) x the cheapest open bag (limit 1% above).
-- Computed here so the gates judge the trigger/limit the row will really
-- have. NULLs when the coin has no open filled bag (no cap applies).
CROSS JOIN LATERAL (
    SELECT
        TRUNC(MIN(f.buy_filled_price)::numeric
              * COALESCE((SELECT value::numeric FROM config WHERE key = 'add_buy_cap_ratio'), 0.99),
              stock.price_rounding::integer) AS cap_stop,
        TRUNC(MIN(f.buy_filled_price)::numeric
              * COALESCE((SELECT value::numeric FROM config WHERE key = 'add_buy_cap_ratio'), 0.99) * 1.01,
              stock.price_rounding::integer) AS cap_limit
    FROM position f
    WHERE f.stock_id = s.stock_id
    AND f.buy_filled_price IS NOT NULL
    AND f.sell_filled_price IS NULL
) addcap
-- Effective limit price after the cap (LEAST ignores the NULL cap) and the
-- dollar cost of the order, plain and with the ~1.2% taker-fee pad (1.012,
-- the same pad index.js used for its old per-row cash check).
CROSS JOIN LATERAL (
    SELECT
        plan.shares * LEAST(plan.buy_price, addcap.cap_limit)         AS cost_usd,
        plan.shares * LEAST(plan.buy_price, addcap.cap_limit) * 1.012 AS cost_with_fee
) eff
-- Day row of vw_signal: today's close-vs-yesterday % vs this coin's
-- average historical day-over-day %. Keeps the year-basis priority pick
-- (s.period_type = 'year') but blocks chase entries on hot days (e.g.
-- MSOL up hard today while year signal still says BUY).
JOIN vw_signal d
  ON d.stock_id = s.stock_id
 AND d.period_type = 'day'
WHERE b.name = 'USD'
AND (SELECT value FROM config WHERE key = 'pause_buys') = 'false'
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
AND d.current_change_percent < d.historical_avg_change_percent
AND stock.trading_disabled IS NOT TRUE
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
-- Prefer bid-heavy (+0.2) via ORDER BY below is unchanged.
AND (NOT bookcfg.bba_fresh OR bba.spread_pct <= bookcfg.max_spread_pct)
AND (book.imbalance IS NULL OR book.imbalance >= bookcfg.skip_imbalance)
AND (book.near_ask_usd IS NULL OR book.near_ask_usd >= eff.cost_usd * bookcfg.min_ask_mult)
-- 2026-10-05 (#3) trigger must already be above price: on a coin already
-- held the cap pins the trigger at addcap.cap_stop, so only create the row
-- when price is under it (was: inserted anyway, then index.js waited for
-- price to fall -- the PNG/DOGE/VVV/GFI/QI rows). No cap = no limit here
-- (the refresh UPDATE keeps uncapped triggers above market).
AND stock.price::numeric < COALESCE(addcap.cap_stop, 'Infinity'::numeric)  -- stock.price: s is vw_signal here
-- 2026-10-05 (#11) Coinbase minimum order size: base size >= base_min_size
-- (stock.min_shares) and quote size (shares x effective limit) >=
-- quote_min_size (stock.min_price). NULL minimum = no limit.
AND plan.shares > 0
AND plan.shares >= COALESCE(stock.min_shares, 0)
AND eff.cost_usd >= COALESCE(stock.min_price, 0)
ORDER BY
    CASE WHEN book.imbalance IS NOT NULL AND book.imbalance > 0.2 THEN 0 ELSE 1 END,
    book.imbalance DESC NULLS LAST,
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
    -- 2026-10-05: from the "plan" lateral below (formulas unchanged).
    plan.buy_price,
    plan.buy_stop_price,
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
-- whether bulk_best_bid_ask is fresh enough to judge spread at all.
CROSS JOIN LATERAL (
    SELECT
        COALESCE((SELECT value::numeric FROM config WHERE key = 'book_max_spread_pct'), 0.75)       AS max_spread_pct,
        COALESCE((SELECT value::numeric FROM config WHERE key = 'book_skip_imbalance'), -0.4)        AS skip_imbalance,
        COALESCE((SELECT value::numeric FROM config WHERE key = 'book_min_ask_notional_mult'), 5)    AS min_ask_mult,
        EXISTS (SELECT 1 FROM bulk_best_bid_ask WHERE loaded_at > NOW() - INTERVAL '3 minutes')     AS bba_fresh
) bookcfg
-- 2026-10-05 the order this INSERT will create (formulas unchanged from the
-- old inline SELECT list): trigger 1% above current price, limit 1.1%
-- above, shares = clip dollars / price.
CROSS JOIN LATERAL (
    SELECT
        TRUNC(s.price::numeric * 1.011, s.price_rounding::integer)               AS buy_price,
        TRUNC(s.price::numeric * 1.01,  s.price_rounding::integer)               AS buy_stop_price,
        TRUNC((sized.clip_usd / s.price::numeric), s.share_rounding::integer)    AS shares
) plan
-- 2026-10-05 add-on cap preview: the "add-on buy cap" UPDATE near the end
-- of this procedure pins an unsent buy on a coin already held to
-- add_buy_cap_ratio (default 0.99) x the cheapest open bag (limit 1% above).
-- Computed here so the gates judge the trigger/limit the row will really
-- have. NULLs when the coin has no open filled bag (no cap applies).
CROSS JOIN LATERAL (
    SELECT
        TRUNC(MIN(f.buy_filled_price)::numeric
              * COALESCE((SELECT value::numeric FROM config WHERE key = 'add_buy_cap_ratio'), 0.99),
              s.price_rounding::integer) AS cap_stop,
        TRUNC(MIN(f.buy_filled_price)::numeric
              * COALESCE((SELECT value::numeric FROM config WHERE key = 'add_buy_cap_ratio'), 0.99) * 1.01,
              s.price_rounding::integer) AS cap_limit
    FROM position f
    WHERE f.stock_id = s.stock_id
    AND f.buy_filled_price IS NOT NULL
    AND f.sell_filled_price IS NULL
) addcap
-- Effective limit price after the cap (LEAST ignores the NULL cap) and the
-- dollar cost of the order, plain and with the ~1.2% taker-fee pad (1.012,
-- the same pad index.js used for its old per-row cash check).
CROSS JOIN LATERAL (
    SELECT
        plan.shares * LEAST(plan.buy_price, addcap.cap_limit)         AS cost_usd,
        plan.shares * LEAST(plan.buy_price, addcap.cap_limit) * 1.012 AS cost_with_fee
) eff
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
    - COALESCE((SELECT SUM(pb.shares * pb.buy_price * 1.012)::numeric  -- 2026-10-05: + fee pad
                FROM position pb JOIN stock sb ON sb.stock_id = pb.stock_id
                WHERE pb.buy_coinbase_order_id IS NULL
                AND pb.buy_filled_price IS NULL
                AND sb.trading_disabled IS NOT TRUE), 0)
-- 2026-10-05 (#2): real cost of this order incl. fee pad (was clip dollars).
  >= eff.cost_with_fee
AND (SELECT value FROM config WHERE key = 'pause_buys') = 'false'
AND TRUNC(s.price::numeric * 1.011, s.price_rounding::integer) < sized.last_filled_price
AND s.trading_disabled IS NOT TRUE
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
-- Prefer bid-heavy (+0.2) via ORDER BY below is unchanged.
AND (NOT bookcfg.bba_fresh OR bba.spread_pct <= bookcfg.max_spread_pct)
AND (book.imbalance IS NULL OR book.imbalance >= bookcfg.skip_imbalance)
AND (book.near_ask_usd IS NULL OR book.near_ask_usd >= eff.cost_usd * bookcfg.min_ask_mult)
-- 2026-10-05 (#3) trigger must already be above price: on a coin already
-- held the cap pins the trigger at addcap.cap_stop, so only create the row
-- when price is under it (was: inserted anyway, then index.js waited for
-- price to fall -- the PNG/DOGE/VVV/GFI/QI rows). No cap = no limit here
-- (the refresh UPDATE keeps uncapped triggers above market).
AND s.price::numeric < COALESCE(addcap.cap_stop, 'Infinity'::numeric)
-- 2026-10-05 (#11) Coinbase minimum order size: base size >= base_min_size
-- (stock.min_shares) and quote size (shares x effective limit) >=
-- quote_min_size (stock.min_price). NULL minimum = no limit.
AND plan.shares > 0
AND plan.shares >= COALESCE(s.min_shares, 0)
AND eff.cost_usd >= COALESCE(s.min_price, 0)
ORDER BY
    CASE WHEN book.imbalance IS NOT NULL AND book.imbalance > 0.2 THEN 0 ELSE 1 END,
    book.imbalance DESC NULLS LAST,
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
                * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100))
                / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100)))
                * (1 + COALESCE((SELECT value::numeric FROM config WHERE key = 'sell_net_cushion'), 0.015))
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
                * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100))
                / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100)))
                * (1 + COALESCE((SELECT value::numeric FROM config WHERE key = 'sell_net_cushion'), 0.015))
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
            * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100))
            / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100)))
        * POWER(10::numeric, stock.price_rounding::int)
    ) / POWER(10::numeric, stock.price_rounding::int))
    * position.shares::numeric
    * (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100))
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
SET buy_stop_price = TRUNC(stock.price::numeric * gap.stop_mult, stock.price_rounding::integer),
    buy_price = TRUNC(stock.price::numeric * gap.stop_mult * 1.01, stock.price_rounding::integer)
FROM stock
CROSS JOIN LATERAL (
    -- Cash-scaled new-buy stop gap: base 2%, stretched by total program
    -- equity / available USD (same components as the equity calc: filled
    -- bags at stock.price, USD available, USD hold in open buys, priced
    -- untracked dust). stop_mult = 1 + 0.02 * (equity / available).
    -- Falls back to 1.02 when available USD is 0/NULL.
    SELECT COALESCE(
        1 + 0.02 * (
            (
                COALESCE((
                    SELECT SUM(p2.shares::numeric * s2.price::numeric)
                    FROM position p2
                    JOIN stock s2 ON s2.stock_id = p2.stock_id
                    WHERE p2.buy_filled_price IS NOT NULL
                    AND p2.sell_filled_price IS NULL
                ), 0)
                + COALESCE((SELECT available::numeric FROM vw_balance WHERE name = 'USD'), 0)
                + COALESCE((SELECT hold::numeric FROM vw_balance WHERE name = 'USD'), 0)
                + COALESCE((
                    SELECT SUM(
                        CASE
                            WHEN a.currency IN ('USDS', 'USD1', 'PAX') THEN a.balance::numeric
                            WHEN st.price IS NOT NULL THEN a.balance::numeric * st.price::numeric
                            ELSE 0
                        END
                    )
                    FROM vw_position_order_balance_audit a
                    LEFT JOIN stock st ON st.name = a.name
                    WHERE a.issue_type = 'untracked_holding'
                ), 0)
            ) / NULLIF((SELECT available::numeric FROM vw_balance WHERE name = 'USD'), 0)
        ),
        1.02
    ) AS stop_mult
) gap
WHERE position.stock_id = stock.stock_id
AND position.buy_coinbase_order_id IS NULL
AND position.buy_filled_price IS NULL
-- 2026-10-07: listing rows are plain limits (no stop) -- never re-priced here.
AND position.period_type IS DISTINCT FROM 'listing'
AND stock.price::numeric >= position.buy_stop_price::numeric;

-- 2026-09-27 add-on buy cap: a buy on a coin you already hold must never be
-- priced above your cheapest open bag. Plans use a cash-scaled stop gap (base 2%) and the
-- reset step just above can raise them again, so OCEAN bag 939 filled at
-- 0.1718 even though bag 926 was bought at 0.1695. This caps the trigger at
-- config.add_buy_cap_ratio (default 0.99 = 1% below) times the cheapest open
-- bag, with the limit 1% above that trigger (0.99 * 1.01 = 0.9999, still
-- below the bag). Only buys not yet sent to Coinbase are touched; live orders
-- are only ever lowered by the remake step. processBuyOrders then waits to
-- place a capped buy until price is below its trigger.
UPDATE position p
SET buy_stop_price = TRUNC(c.min_fill * cap.ratio,        s.price_rounding::integer),
    buy_price      = TRUNC(c.min_fill * cap.ratio * 1.01, s.price_rounding::integer)
FROM stock s,
     (SELECT stock_id, MIN(buy_filled_price)::numeric AS min_fill
      FROM position
      WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL
      GROUP BY stock_id) c,
     (SELECT COALESCE((SELECT value::numeric FROM config WHERE key = 'add_buy_cap_ratio'), 0.99) AS ratio) cap
WHERE p.stock_id = s.stock_id
AND c.stock_id = p.stock_id
AND p.buy_coinbase_order_id IS NULL
AND p.buy_filled_price IS NULL
-- 2026-10-07: listing rows exempt (plain limit, and never on a held coin).
AND p.period_type IS DISTINCT FROM 'listing'
AND p.buy_stop_price::numeric > c.min_fill * cap.ratio;

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
-- 2026-10-07: listing rows exempt (no stop; a first-trade-priced limit may
-- legitimately sit below the current price).
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

-- Step 2: record any fully bought-and-sold position into profit_history,
-- computing profit fresh from position's current buy/sell price and fee
-- columns. Requires every one of buy/sell order_id, buy/sell filled price,
-- and buy/sell fee to actually be populated -- no COALESCE fallback, so a
-- still-missing fee (e.g. not yet settled by Coinbase) correctly holds this
-- position back rather than recording a wrong, understated profit. It'll
-- pick it up automatically once Step 1 finishes backfilling it. Skips
-- anything already recorded, matched on both the buy and sell order_id
-- together.
INSERT INTO profit_history (stock_id, name, period_type, buy_coinbase_order_id, sell_fills_id, buy_fee, sell_fee, profit)
SELECT
    p.stock_id, p.name, p.period_type, p.buy_coinbase_order_id, p.sell_coinbase_order_id AS sell_fills_id,
    TRUNC(p.buy_fee::numeric, 2) AS buy_fee,
    TRUNC(p.sell_fee::numeric, 2) AS sell_fee,
    TRUNC(((p.sell_filled_price::numeric * p.shares::numeric - p.sell_fee::numeric)
         - (p.buy_filled_price::numeric * p.shares::numeric + p.buy_fee::numeric))::numeric, 2) AS profit
FROM position p
WHERE p.buy_coinbase_order_id IS NOT NULL
AND p.sell_coinbase_order_id IS NOT NULL
AND p.buy_filled_price IS NOT NULL
AND p.sell_filled_price IS NOT NULL
AND p.buy_fee IS NOT NULL
AND p.sell_fee IS NOT NULL
AND NOT EXISTS (
    SELECT 1 FROM profit_history ph
    WHERE ph.buy_coinbase_order_id = p.buy_coinbase_order_id AND ph.sell_fills_id = p.sell_coinbase_order_id
);

-- Step 3: delete the position row, but only once it's confirmed recorded in
-- profit_history — never delete on the strength of this statement's own
-- assumptions the way the old combined version did.
DELETE FROM position p
WHERE p.buy_filled_price IS NOT NULL AND p.sell_filled_price IS NOT NULL
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

$$;
