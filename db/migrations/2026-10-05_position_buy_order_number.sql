-- 2026-10-05: buy_order_number numbers each open position per coin.
-- The first open BTC-USD row is 1, the second is 2, and so on.
-- "Coin" is the product (stock_id / name), not period_type, so day,
-- month, and year rows for one coin share a single sequence.
-- Order is date_created ASC, then position_id ASC to break ties.
--
-- thee_procedure recomputes it every run with
-- ROW_NUMBER() OVER (PARTITION BY stock_id ...), so a closed or deleted
-- row makes the rows after it move down. Nullable with no default: a row
-- inserted mid-cycle reads NULL until the next run fills it in.
-- The position_audit trigger logs changes to it like any other column.
--
-- Idempotent.

ALTER TABLE public.position
    ADD COLUMN IF NOT EXISTS buy_order_number integer;

COMMENT ON COLUMN public.position.buy_order_number IS
    'Per-coin sequence of open positions (1 = oldest), by date_created then position_id. Recomputed every run by thee_procedure.';

-- First fill, so the column has values before the next procedure run.
-- Same statement as in thee_procedure.
UPDATE public.position p
SET buy_order_number = r.rn
FROM (
    SELECT position_id,
           ROW_NUMBER() OVER (
               PARTITION BY stock_id
               ORDER BY date_created ASC NULLS LAST, position_id ASC
           ) AS rn
    FROM public.position
) r
WHERE p.position_id = r.position_id
  AND p.buy_order_number IS DISTINCT FROM r.rn;
