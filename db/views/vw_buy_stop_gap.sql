-- 2026-10-07 (migrations/2026-10-07_buy_stop_cash_scaled.sql): the ONE
-- place the cash-scaled buy-stop gap is computed (Theodore). thee_procedure
-- (signal insert, average-down insert, stale refresh) and vw_edit_orders
-- (buy remake) all read this view, so they cannot disagree.
--
--   gap = buy_stop_base_pct / 100 * sqrt(total_equity / gap_cash_usd)
--
--   total_equity = open filled bags at stock.price + USD available + USD hold
--                  + priced untracked dust (USDS / USD1 / PAX at 1:1) --
--                  the same definition as the 2026-10-05 cash-scaled gap
--                  (33cbe3a). USD only: USDC is never counted ("were not
--                  using USDC to buy crypto").
--   gap_cash_usd = vw_balance USD available + USD hold.
--                  2026-10-08 (migrations/2026-10-08_buy_stop_gap_cash_incl_hold.sql,
--                  Theodore): the gap's cash now INCLUDES the USD on hold in
--                  open orders (pending buys), not just available. Before,
--                  every dollar parked in pending buys counted as "no cash"
--                  and blew the gap up (e.g. $1.71 available + $101.88 hold,
--                  equity $366 -> 29.2%; now ~3.8%). USDC still excluded.
--                  This is ONLY the gap's input: the affordability checks in
--                  thee_procedure still use spendable USD available.
--   free_usd     = vw_balance USD available (after holds of live orders);
--                  informational only since 2026-10-08, not used in the gap.
--   No maximum on the gap (less cash = wider stop, without limit).
--   Fallback: gap_cash_usd 0 / NULL / negative -> computed as if $0.01 were
--   there (the smallest USD amount), so "less cash = wider" still holds and
--   the gap stays finite (gap_cash_fallback = true). At $282 equity that is
--   ~336%; no new buy can be afforded then anyway, and the only-lower remake
--   ratchet leaves live buys where they are.
-- Placement: stop = close (or price) x (1 + gap), limit = stop x 1.01.
-- Remake: multiplier = GREATEST(1 + buy_remake_floor_pct/100,
--                               1 + gap - buy_counter * buy_remake_step_pct/100).
-- Example: equity $366, available $1.71 + hold $101.88 = $103.59
--   -> 2% x sqrt(366 / 103.59) = 3.76%  (available-only would be 29.2%).
--   Equity $282 -> cash $2: 23.7%, cash $20: 7.5%, cash $100: 3.4%.
-- Columns: total_equity, free_usd, base_pct, free_usd_fallback (legacy:
-- available <= 0 / NULL, informational), gap, usd_hold, gap_cash_usd,
-- gap_cash_fallback. New columns are appended at the end because
-- CREATE OR REPLACE VIEW cannot reorder/rename columns (vw_edit_orders
-- depends on this view).
CREATE OR REPLACE VIEW public.vw_buy_stop_gap AS
WITH cfg AS (
    SELECT COALESCE((SELECT value::numeric FROM config WHERE key = 'buy_stop_base_pct'), 2) AS base_pct
),
cash AS (
    SELECT (SELECT available::numeric FROM vw_balance WHERE name = 'USD') AS free_usd,
           (SELECT hold::numeric      FROM vw_balance WHERE name = 'USD') AS usd_hold
),
-- 2026-10-08: the gap's cash = USD available + USD on hold in open orders
-- (NULL only when both are missing -> $0.01 fallback below).
gc AS (
    SELECT CASE WHEN cash.free_usd IS NULL AND cash.usd_hold IS NULL THEN NULL
                ELSE COALESCE(cash.free_usd, 0) + COALESCE(cash.usd_hold, 0)
           END AS gap_cash_usd
    FROM cash
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
       -- 2026-10-08: divide by available + hold (gc.gap_cash_usd), not
       -- available only; $0.01 when that sum is 0 / NULL / negative.
       cfg.base_pct / 100
         * sqrt(GREATEST(eq.total_equity, 0)
                / CASE WHEN gc.gap_cash_usd > 0 THEN gc.gap_cash_usd ELSE 0.01 END) AS gap,
       cash.usd_hold,
       gc.gap_cash_usd,
       NOT COALESCE(gc.gap_cash_usd > 0, FALSE) AS gap_cash_fallback
FROM cfg, cash, gc, eq;

COMMENT ON VIEW public.vw_buy_stop_gap IS
    'Cash-scaled buy-stop gap (one row): buy_stop_base_pct/100 * sqrt(total_equity / (USD available + USD hold)); USDC excluded; cash 0/NULL -> $0.01; no max (2026-10-08: hold included). Read by thee_procedure (placement) and vw_edit_orders (buy remake). Affordability checks do NOT use this.';
