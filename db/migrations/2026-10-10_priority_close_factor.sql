-- 2026-10-10 (Theodore): blend close reliability into vw_signal priority.
-- priority = years x (avg_change_percent / std_dev) x |signal| x close_factor
-- close_factor = GREATEST(COALESCE(vw_coin_close_stats.fill_to_close_ratio, 1.0), 0.1)
-- Joined on stock_id, so vw_coin_close_stats gains a stock_id column (appended
-- last). Applies to every period_type row of vw_signal; thee_procedure copies
-- the year row onto stock.priority unchanged, and keeps its priority > 0 filter
-- and highest-priority-first buy pick. Order matters: stats view first.
\ir ../views/vw_coin_close_stats.sql
\ir ../views/vw_signal.sql
