-- 2026-10-11 (Theodore, voice): RSI lives on stock, not price_aggregate.
-- stock.rsi = Wilder RSI(14) from price_aggregate day closes (input only).
-- Undoes 2026-10-11_price_aggregate_rsi.sql: drops price_aggregate.rsi and
-- fn_price_aggregate_rsi, replaced by fn_stock_rsi.

ALTER TABLE stock ADD COLUMN IF NOT EXISTS rsi numeric;

COMMENT ON COLUMN stock.rsi IS
    'Wilder RSI(14) from price_aggregate day closes (period_type=''day'', ordered by period_date), as of the latest day. NULL until the stock has 15 day closes. Filled by aggregate() via fn_stock_rsi(14).';

\i db/procedures/fn_stock_rsi.sql
-- aggregate() no longer references price_aggregate.rsi; reload before the drop.
\i db/procedures/aggregate.sql

ALTER TABLE price_aggregate DROP COLUMN IF EXISTS rsi;
DROP FUNCTION IF EXISTS public.fn_price_aggregate_rsi(integer);

-- Backfill: every stock with 15+ day closes; the rest stay NULL.
UPDATE stock s
SET rsi = r.out_rsi
FROM fn_stock_rsi(14) r
WHERE s.stock_id = r.out_stock_id;
