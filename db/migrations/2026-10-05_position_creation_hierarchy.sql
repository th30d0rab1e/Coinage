-- 2026-10-05: creation_hierarchy numbers each open position per coin.
-- 1 = cheapest fill (lowest buy_filled_price), then lowest buy_stop_price;
-- it is NOT the oldest row.
-- "Coin" is the product (stock_id / name), not period_type, so day,
-- month, and year rows for one coin share a single sequence.
-- Order is buy_filled_price ASC NULLS LAST, buy_stop_price ASC NULLS LAST,
-- then position_id ASC to break ties. Unfilled bags sort after filled ones.
-- (Originally ordered by date_created; switched to price the same day.
-- Re-running this file renumbers existing rows.)
--
-- thee_procedure recomputes it every run with
-- ROW_NUMBER() OVER (PARTITION BY stock_id ...), so a closed or deleted
-- row makes the rows after it move down. Nullable with no default: a row
-- inserted mid-cycle reads NULL until the next run fills it in.
-- The position_audit trigger logs changes to it like any other column.
--
-- Idempotent.

ALTER TABLE public.position
    ADD COLUMN IF NOT EXISTS creation_hierarchy integer;

COMMENT ON COLUMN public.position.creation_hierarchy IS
    'Per-coin sequence of open positions (1 = cheapest fill), by buy_filled_price ASC NULLS LAST, then buy_stop_price ASC NULLS LAST, then position_id. Recomputed every run by thee_procedure.';

-- First fill, so the column has values before the next procedure run.
-- Same statement as in thee_procedure.
UPDATE public.position p
SET creation_hierarchy = r.rn
FROM (
    SELECT position_id,
           ROW_NUMBER() OVER (
               PARTITION BY stock_id
               ORDER BY buy_filled_price ASC NULLS LAST,
                        buy_stop_price ASC NULLS LAST,
                        position_id ASC
           ) AS rn
    FROM public.position
) r
WHERE p.position_id = r.position_id
  AND p.creation_hierarchy IS DISTINCT FROM r.rn;
