-- 2026-10-07 (migrations/2026-10-07_buy_stop_cash_scaled.sql): the ONE
-- place the cash-scaled buy-stop gap is computed (Theodore). thee_procedure
-- (signal insert, average-down insert, stale refresh) and vw_edit_orders
-- (buy remake) all read this view, so they cannot disagree.
--
--   gap = buy_stop_base_pct / 100 * sqrt(total_equity / free_usd)
--
--   total_equity = open filled bags at stock.price + USD available + USD hold
--                  + priced untracked dust (USDS / USD1 / PAX at 1:1) --
--                  the same definition as the 2026-10-05 cash-scaled gap
--                  (33cbe3a). USD only: USDC is never counted ("were not
--                  using USDC to buy crypto").
--   free_usd     = vw_balance USD available (after holds of live orders).
--   No maximum on the gap (less free cash = wider stop, without limit).
--   Fallback: free USD 0 / NULL / negative -> computed as if $0.01 were free
--   (the smallest USD amount), so "less cash = wider" still holds and the
--   gap stays finite. At $282 equity that is ~336%; no new buy can be
--   afforded then anyway, and the only-lower remake ratchet leaves live
--   buys where they are.
-- Placement: stop = close (or price) x (1 + gap), limit = stop x 1.01.
-- Remake: multiplier = GREATEST(1 + buy_remake_floor_pct/100,
--                               1 + gap - buy_counter * buy_remake_step_pct/100).
-- Example: equity $282 -> free $2: 23.7%, free $20: 7.5%, free $100: 3.4%.
CREATE OR REPLACE VIEW public.vw_buy_stop_gap AS
WITH cfg AS (
    SELECT COALESCE((SELECT value::numeric FROM config WHERE key = 'buy_stop_base_pct'), 2) AS base_pct
),
cash AS (
    SELECT (SELECT available::numeric FROM vw_balance WHERE name = 'USD') AS free_usd,
           (SELECT hold::numeric      FROM vw_balance WHERE name = 'USD') AS usd_hold
),
eq AS (
    SELECT COALESCE((
               SELECT SUM(p2.shares::numeric * s2.price::numeric)
               FROM position p2
               JOIN stock s2 ON s2.stock_id = p2.stock_id
               WHERE p2.buy_filled_price IS NOT NULL
               AND p2.sell_filled_price IS NULL
           ), 0)
         + COALESCE(cash.free_usd, 0)
         + COALESCE(cash.usd_hold, 0)
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
               AND a.currency <> 'USDC'   -- USDC is never cash for crypto buys
           ), 0) AS total_equity
    FROM cash
)
SELECT eq.total_equity,
       cash.free_usd,
       cfg.base_pct,
       NOT COALESCE(cash.free_usd > 0, FALSE) AS free_usd_fallback,
       cfg.base_pct / 100
         * sqrt(GREATEST(eq.total_equity, 0)
                / CASE WHEN cash.free_usd > 0 THEN cash.free_usd ELSE 0.01 END) AS gap
FROM cfg, cash, eq;

COMMENT ON VIEW public.vw_buy_stop_gap IS
    'Cash-scaled buy-stop gap (one row): buy_stop_base_pct/100 * sqrt(total_equity / free USD); free USD 0/NULL -> $0.01. Read by thee_procedure (placement) and vw_edit_orders (buy remake).';
