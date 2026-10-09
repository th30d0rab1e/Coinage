-- 2026-10-08: vw_edit_orders reads its config values once, at the top.
-- Approved by Theodore 2026-10-08 ("can the view use variables at the top
-- instead of cross join?" -> "yes").
--
-- What changes (db/views/vw_edit_orders.sql), REFACTOR ONLY:
--   * New WITH block at the top of the view:
--       cfg -- one row: buy_remake_floor_pct (default 0.1),
--              buy_remake_step_pct (default 0.5), fee_percent (default
--              1.20), avg_profit (no default, NULL when missing). These are
--              the same COALESCE defaults the inline lookups used.
--       gap -- the vw_buy_stop_gap row (gap only).
--   * BUY branch: CROSS JOIN gap + cfg instead of CROSS JOIN vw_buy_stop_gap
--     and two inline config subqueries.
--   * SELL branches 1 and 2: CROSS JOIN cfg instead of three inline
--     fee_percent subqueries and one avg_profit subquery.
--
-- Unchanged on purpose: every formula, filter, ratchet, gate, ORDER BY,
-- and the output columns (same 13 names / types / order). The per-period
-- AVG(profit_history.profit) gate stays inline (it depends on each row's
-- period_type, so it is not a single "variable").
--
-- Verified before applying (one REPEATABLE READ snapshot, temp views,
-- rolled back):
--   * live view vs new: 0 rows each way (EXCEPT ALL) -- 0 rows qualified
--     at that moment, so also:
--   * old vs new with the ratchet / profit gates / order-id filters
--     removed from both: 210 rows each (23 buy, 187 sell), 0 diff rows
--     either way (EXCEPT ALL).
--   * live view definition == db/views/vw_edit_orders.sql before the edit.
--   * columns: 13 vs 13, 0 name/type/position mismatches.
BEGIN;

\ir ../views/vw_edit_orders.sql

COMMIT;
