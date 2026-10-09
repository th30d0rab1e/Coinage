-- 2026-10-08: vw_edit_orders' cfg CTE reads the config table ONCE.
-- Requested by Theodore 2026-10-08 ("why dont you just use the table once
-- and select what you want?"), follow-up to 2026-10-08_vw_edit_orders_cfg_cte.sql.
--
-- What changes (db/views/vw_edit_orders.sql), REFACTOR ONLY:
--   * cfg was one scalar subquery per key:
--       COALESCE((SELECT value::numeric FROM config WHERE key = '...'), default)
--     It is now a single scan of config, filtered to the four keys, with
--     each key pivoted into its own column:
--       COALESCE(MAX(value) FILTER (WHERE key = '...')::numeric, default)
--   * config.key is the primary key, so each FILTER sees at most one value
--     and MAX returns exactly that value (same as the old subquery).
--   * One-row guarantee kept: an aggregate with no GROUP BY always returns
--     exactly one row, even if none of the keys exist (every MAX is NULL and
--     the same COALESCE defaults apply), so CROSS JOIN cfg never adds or
--     removes rows.
--
-- Unchanged on purpose: the defaults (0.1 / 0.5 / 1.20 / avg_profit no
-- default), the gap CTE, every formula, filter, ratchet, gate, ORDER BY,
-- and the output columns (same 13 names / types / order).
--
-- Verified before applying (one REPEATABLE READ snapshot, temp views,
-- rolled back):
--   * live view definition == db/views/vw_edit_orders.sql before the edit.
--   * live view vs new: 0 rows each way (EXCEPT ALL); 0 rows qualified at
--     that moment, so also:
--   * old vs new with the ratchet / profit gates / order-id / hierarchy
--     filters removed from both: 226 rows each (16 buy, 210 sell), 0 diff
--     rows either way (EXCEPT ALL).
--   * columns: 13 vs 13, 0 name/type/position mismatches.
--   * cfg with no matching keys: still 1 row, defaults applied.
BEGIN;

\ir ../views/vw_edit_orders.sql

COMMIT;
