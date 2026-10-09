-- 2026-10-08: cash-scaled buy-stop gap counts USD ON HOLD in open orders.
-- Approved by Theodore 2026-10-08 ("i want it to use cash available that
-- are on open orders too").
--
-- What changes (db/views/vw_buy_stop_gap.sql, the ONE place the gap lives):
--   before: gap = buy_stop_base_pct/100 * sqrt(total_equity / USD available)
--   after:  gap = buy_stop_base_pct/100 * sqrt(total_equity / (USD available + USD hold))
-- Why: money sitting in pending buys was counted as "no cash", so after a
-- deposit was spread over pending buys the gap exploded. At the time of the
-- change: available $1.71, hold $101.88, equity $366.04 -> 29.2% before,
-- ~3.76% after.
--
-- Unchanged on purpose:
--   * USDC is still never cash for crypto buys (not in equity, not in the gap).
--   * total_equity definition unchanged (filled bags + USD available + USD
--     hold + priced untracked dust).
--   * $0.01 fallback when available + hold is 0 / NULL / negative; no max.
--   * thee_procedure's cash-affordability checks still use spendable USD
--     available (vw_balance.available) -- only the gap's cash input changed.
--
-- Effect on live pending buys: vw_edit_orders (buy remake) reads this view.
-- Its ratchet only ever LOWERS a stop, so pending buys whose stop sits above
-- price x (1 + new gap - buy_counter x step) get remade lower on the next
-- runs; buys already below that are left alone.
--
-- The view keeps its existing columns (CREATE OR REPLACE cannot reorder
-- them; vw_edit_orders depends on it) and appends usd_hold, gap_cash_usd,
-- gap_cash_fallback.
BEGIN;

\ir ../views/vw_buy_stop_gap.sql

COMMIT;
