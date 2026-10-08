-- 2026-10-08 DIP-BUY maintenance list (Theodore, voice call 2026-10-08;
-- db/migrations/2026-10-08_dip_buy.sql). One row per LIVE dip-buy order
-- (position.buy_source = 'dip_buy', plain limit BUY resting on Coinbase)
-- that index.js processDipBuys() must act on this minute:
--   'gone'   : the order is no longer in the open-orders snapshot
--              (bulk_open_orders) and no fill is recorded -- cancelled
--              outside the bot or expired. processDipBuys() asks Coinbase for
--              the real status and only then removes the row (or keeps a
--              partial fill as the position). Waits 3 minutes after
--              placement because an order placed this run is not in the
--              snapshot yet.
--   'ttl'    : the order has rested longer than config.dip_buy_ttl_hours
--              (default 24), measured from position.date_created so a remake
--              does not extend it. Cancel + delete the row; the coin is then
--              free for a fresh dip buy on the next run.
--   'remake' : the market moved up -- the resting limit is more than
--              config.dip_buy_remake_pct (default 4) below the current price.
--              Cancel; the row stays with buy_coinbase_order_id NULL and
--              thee_procedure re-prices it to current x (1 - dip_buy_gap_pct
--              /100) on the next run, then processBuyOrders re-places it.
-- Only orders with NO fill at all are listed: once anything fills,
-- thee_procedure sets buy_filled_price and the row is a normal position.
-- Deliberately NOT gated on config.dip_buy_enabled: if the switch is turned
-- off while dip orders rest, they still wind down through these paths.
-- With no dip rows (always the case until the switch is first turned on)
-- the view is empty and processDipBuys() does nothing.
CREATE OR REPLACE VIEW public.vw_dip_buy_actions AS
SELECT a.position_id, a.buy_order_id, a.name, a.buy_coinbase_order_id,
       a.shares, a.buy_price, a.market, a.date_created, a.action
FROM (
    SELECT p.position_id, p.buy_order_id, p.name, p.buy_coinbase_order_id,
           p.shares, p.buy_price, s.price AS market, p.date_created,
           CASE
               -- not open on Coinbase any more (and nothing filled, see WHERE)
               WHEN o.order_id IS NULL THEN 'gone'
               -- rested too long: cancel and free the coin
               WHEN p.date_created < NOW() - make_interval(hours => cfg.ttl_hours) THEN 'ttl'
               -- limit now more than remake_pct below the market: re-place
               WHEN p.buy_price::numeric < s.price::numeric * (1 - cfg.remake_pct / 100) THEN 'remake'
           END AS action
    FROM position p
    JOIN stock s ON s.stock_id = p.stock_id
    CROSS JOIN LATERAL (
        SELECT COALESCE((SELECT value::int     FROM config WHERE key = 'dip_buy_ttl_hours'), 24)  AS ttl_hours,
               COALESCE((SELECT value::numeric FROM config WHERE key = 'dip_buy_remake_pct'), 4)  AS remake_pct
    ) cfg
    LEFT JOIN bulk_open_orders o ON o.order_id = p.buy_coinbase_order_id
    WHERE p.buy_source = 'dip_buy'
    AND p.buy_coinbase_order_id IS NOT NULL      -- a live (sent) order
    AND p.buy_filled_price IS NULL               -- not a position yet
    AND p.sell_coinbase_order_id IS NULL
    AND COALESCE(o.filled_size, 0) = 0           -- nothing filled per the snapshot
    AND NOT EXISTS (SELECT 1 FROM fills f WHERE f.order_id = p.buy_coinbase_order_id)
    -- 'gone' needs the order to be older than this run's snapshot
    AND (o.order_id IS NOT NULL OR p.buy_placed_at < NOW() - INTERVAL '3 minutes')
) a
WHERE a.action IS NOT NULL;
