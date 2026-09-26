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
    TRUNC((s.close::numeric * 1.05 * 1.01), stock.price_rounding::integer) AS buy_price,
    TRUNC((s.close::numeric * 1.05),        stock.price_rounding::integer) AS buy_stop_price,
    TRUNC((
        (
            SELECT COUNT(*)::numeric
            FROM position open_sz
            WHERE open_sz.stock_id = s.stock_id
            AND open_sz.period_type = 'day'
            AND open_sz.buy_order_id IS NOT NULL
            AND open_sz.sell_filled_price IS NULL
        ) + 1
    ) / s.close::numeric, stock.share_rounding::integer) AS shares,
    NOW() AS date_created,
    gen_random_uuid(),
    'day'
FROM vw_signal s
JOIN stock ON s.stock_id = stock.stock_id
CROSS JOIN vw_balance b
LEFT JOIN position p ON p.stock_id = s.stock_id
    AND p.period_type = 'day'
    AND p.buy_order_id IS NOT NULL
    AND p.buy_filled_price IS NULL
LEFT JOIN LATERAL (
    SELECT bs.imbalance
    FROM book_snapshot bs
    WHERE bs.name = s.name
    ORDER BY bs.date_created DESC
    LIMIT 1
) book ON TRUE
-- Day row of vw_signal: today's close-vs-yesterday % vs this coin's
-- average historical day-over-day %. Keeps the year-basis priority pick
-- (s.period_type = 'year') but blocks chase entries on hot days (e.g.
-- MSOL up hard today while year signal still says BUY).
JOIN vw_signal d
  ON d.stock_id = s.stock_id
 AND d.period_type = 'day'
WHERE b.name = 'USD'
AND (SELECT value FROM config WHERE key = 'pause_buys') = 'false'
AND b.available > (
    SELECT COUNT(*)::numeric
    FROM position open_sz
    WHERE open_sz.stock_id = s.stock_id
    AND open_sz.period_type = 'day'
    AND open_sz.buy_order_id IS NOT NULL
    AND open_sz.sell_filled_price IS NULL
) + 1
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
-- Inventory cap: stop inserting brand-new buy signals when too many filled
-- positions are still open (no sell fill yet). Remakes, sell arming, and
-- processBuyOrders healing of naked pending rows are unaffected — those do
-- not INSERT here. Threshold lives in config.max_open_positions (default 60).
AND (
    SELECT COUNT(*) FROM position open_pos
    WHERE open_pos.buy_filled_price IS NOT NULL
    AND open_pos.sell_filled_price IS NULL
) < COALESCE((SELECT value::int FROM config WHERE key = 'max_open_positions'), 60)
-- Book gate: do not insert a new/add day buy when the latest L2 snapshot is
-- ask-heavy. Prefer bid-heavy (+0.2) via ORDER BY below. NULL snapshot = allow.
AND (book.imbalance IS NULL OR book.imbalance > -0.4)
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
    TRUNC(s.price::numeric * 1.011, s.price_rounding::integer) AS buy_price,
    TRUNC(s.price::numeric * 1.01,  s.price_rounding::integer) AS buy_stop_price,
    TRUNC((sized.clip_usd / s.price::numeric), s.share_rounding::integer) AS shares,
    NOW() AS date_created,
    gen_random_uuid(),
    sized.period_type
FROM sized
JOIN stock s ON s.stock_id = sized.stock_id
CROSS JOIN vw_balance b
LEFT JOIN LATERAL (
    SELECT bs.imbalance
    FROM book_snapshot bs
    WHERE bs.name = s.name
    ORDER BY bs.date_created DESC
    LIMIT 1
) book ON TRUE
WHERE b.name = 'USD'
AND b.available > sized.clip_usd
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
-- Inventory cap: stop inserting brand-new buy signals when too many filled
-- positions are still open (no sell fill yet). Remakes, sell arming, and
-- processBuyOrders healing of naked pending rows are unaffected — those do
-- not INSERT here. Threshold lives in config.max_open_positions (default 60).
AND (
    SELECT COUNT(*) FROM position open_pos
    WHERE open_pos.buy_filled_price IS NOT NULL
    AND open_pos.sell_filled_price IS NULL
) < COALESCE((SELECT value::int FROM config WHERE key = 'max_open_positions'), 60)
AND (book.imbalance IS NULL OR book.imbalance > -0.4)
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
-- (falling back to 1.2% if the buy fee is unknown). LATERAL can't be used
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
                * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012))
                / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012)))
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
                * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012))
                / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012)))
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
WHERE position.stock_id = stock.stock_id
AND pat.period_type = position.period_type
AND position.buy_filled_price IS NOT NULL
AND position.sell_price IS NULL
-- Estimated profit, from buy_filled_price and buy_fee alone: at the
-- fee-adjusted floor price (same CEIL(...) breakeven formula as above),
-- proceeds after an estimated sell fee (same buy-side fee rate, falling
-- back to 1.2%) must exceed total cost (buy_filled_price * shares +
-- buy_fee). Uses only known buy-side values, not current market price.
AND (
    (CEIL(
        (position.buy_filled_price::numeric
            * (1 + COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012))
            / (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012)))
        * POWER(10::numeric, stock.price_rounding::int)
    ) / POWER(10::numeric, stock.price_rounding::int))
    * position.shares::numeric
    * (1 - COALESCE(NULLIF(position.buy_fee::numeric, 0) / NULLIF(position.buy_filled_price::numeric * position.shares::numeric, 0), 0.012))
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
-- using the same flat 5% rule a fresh pick uses, off current price
-- instead of the stale signal-time price.
UPDATE position
SET buy_stop_price = TRUNC(stock.price::numeric * 1.05, stock.price_rounding::integer),
    buy_price = TRUNC(stock.price::numeric * 1.05 * 1.01, stock.price_rounding::integer)
FROM stock
WHERE position.stock_id = stock.stock_id
AND position.buy_coinbase_order_id IS NULL
AND position.buy_filled_price IS NULL
AND stock.price::numeric >= position.buy_stop_price::numeric;

-- Clear error_message on unfilled buy positions instead of deleting them.
UPDATE position SET error_message = NULL
WHERE error_message IS NOT NULL
AND buy_coinbase_order_id IS NULL
AND buy_filled_price IS NULL;

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
