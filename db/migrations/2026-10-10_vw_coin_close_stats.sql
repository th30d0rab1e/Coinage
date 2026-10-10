-- 2026-10-10 (Theodore): live per-coin close scoreboard.
-- Creates vw_coin_close_stats (closes, avg profit per close, fill-to-close
-- ratio, ranked best-first). Definition and column docs live in
-- db/views/vw_coin_close_stats.sql; this migration just applies it.
\ir ../views/vw_coin_close_stats.sql
