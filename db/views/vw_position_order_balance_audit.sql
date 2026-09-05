-- Cross-checks position against bulk_open_orders (Coinbase's actual open
-- orders) and bulk_currency (Coinbase's actual held balances), refreshed
-- every cycle, to surface exactly the kind of mismatch this account has hit
-- repeatedly: a position pointing at an order Coinbase no longer considers
-- open (ghost order -- confirmed on 00-USD, BTC-USD, and 32 others, some
-- stuck 10+ days), and a real held balance with no position tracking it at
-- all (confirmed on AAVE-USD, ORCA-USD, XLM-USD -- non-trade-origin credits
-- the bot has no record of and therefore can never place a sell order for).
--
-- bulk_currency and bulk_open_orders are refreshed once per cycle by
-- insertCurrency()/insertOpenOrders() in modules/database.js (truncate +
-- insert, atomic) -- this view is safe to query anytime, not just mid-cycle.
CREATE OR REPLACE VIEW public.vw_position_order_balance_audit AS

-- A position thinks it has a live buy order; Coinbase disagrees.
SELECT
    'ghost_buy_order'::text AS issue_type,
    p.name,
    p.buy_coinbase_order_id AS order_id,
    NULL::text AS currency,
    NULL::double precision AS balance,
    'position ' || p.position_id || ' references buy order ' || p.buy_coinbase_order_id
        || ' which is not in bulk_open_orders' AS detail
FROM position p
WHERE p.buy_coinbase_order_id IS NOT NULL
AND p.buy_filled_price IS NULL
AND NOT EXISTS (SELECT 1 FROM bulk_open_orders o WHERE o.order_id = p.buy_coinbase_order_id)

UNION ALL

-- Same, sell side.
SELECT
    'ghost_sell_order'::text,
    p.name,
    p.sell_coinbase_order_id,
    NULL::text,
    NULL::double precision,
    'position ' || p.position_id || ' references sell order ' || p.sell_coinbase_order_id
        || ' which is not in bulk_open_orders'
FROM position p
WHERE p.sell_coinbase_order_id IS NOT NULL
AND p.sell_filled_price IS NULL
AND NOT EXISTS (SELECT 1 FROM bulk_open_orders o WHERE o.order_id = p.sell_coinbase_order_id)

UNION ALL

-- Coinbase actually holds a real balance of this coin; no open (bought, not
-- yet sold) position accounts for it at all.
SELECT
    'untracked_holding'::text,
    bc.currency || '-USD',
    NULL::text,
    bc.currency,
    bc.balance,
    'bulk_currency shows ' || bc.balance || ' ' || bc.currency
        || ' held with no matching open position'
FROM bulk_currency bc
WHERE bc.currency NOT IN ('USD', 'USDC')
AND bc.balance > 0
AND NOT EXISTS (
    SELECT 1 FROM position p
    WHERE p.name = bc.currency || '-USD'
    AND p.buy_filled_price IS NOT NULL
    AND p.sell_filled_price IS NULL
)

UNION ALL

-- Coinbase has a real open order; no position references it at all (the
-- reverse of ghost_buy_order/ghost_sell_order -- e.g. an order placed
-- manually on the website that the bot never recorded).
SELECT
    'orphaned_coinbase_order'::text,
    o.product_id,
    o.order_id,
    NULL::text,
    NULL::double precision,
    'bulk_open_orders has ' || o.side || ' order ' || o.order_id || ' for ' || o.product_id
        || ' not referenced by any position'
FROM bulk_open_orders o
WHERE NOT EXISTS (
    SELECT 1 FROM position p
    WHERE p.buy_coinbase_order_id = o.order_id OR p.sell_coinbase_order_id = o.order_id
);
