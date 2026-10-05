-- 2026-10-05: creation_hierarchy numbers each open position per coin.
-- Only rows with sell_price IS NOT NULL are ranked. 1 = cheapest fill
-- (lowest buy_filled_price), then lowest buy_stop_price; it is NOT the
-- oldest row. Rows with sell_price NULL keep creation_hierarchy NULL.
-- "Coin" is the product (stock_id / name), not period_type, so day,
-- month, and year rows for one coin share a single sequence.
-- Order among ranked rows: buy_filled_price ASC NULLS LAST,
-- buy_stop_price ASC NULLS LAST, then position_id ASC to break ties.
-- (Originally ordered by date_created; switched to price the same day;
-- then limited to sell_price IS NOT NULL. Re-running this file renumbers.)
--
-- thee_procedure recomputes it every run with
-- ROW_NUMBER() OVER (PARTITION BY stock_id ...) only on sell_price IS NOT
-- NULL rows, so a closed or deleted row makes the rows after it move down.
-- Nullable with no default: a row inserted mid-cycle, or one without
-- sell_price, reads NULL until the next run fills it in (or leaves it NULL).
-- The position_audit trigger logs changes to it like any other column.
--
-- Idempotent.

ALTER TABLE public.position
    ADD COLUMN IF NOT EXISTS creation_hierarchy integer;

COMMENT ON COLUMN public.position.creation_hierarchy IS
    'Per-coin sequence of open positions with sell_price set (1 = cheapest fill); NULL when sell_price IS NULL. Order: buy_filled_price ASC NULLS LAST, then buy_stop_price ASC NULLS LAST, then position_id. Recomputed every run by thee_procedure.';

-- First fill, so the column has values before the next procedure run.
-- Same statement as in thee_procedure.
UPDATE public.position p
SET creation_hierarchy = r.rn
FROM (
    SELECT p_all.position_id,
           ranked.rn
    FROM public.position p_all
    LEFT JOIN (
        SELECT position_id,
               ROW_NUMBER() OVER (
                   PARTITION BY stock_id
                   ORDER BY buy_filled_price ASC NULLS LAST,
                            buy_stop_price ASC NULLS LAST,
                            position_id ASC
               ) AS rn
        FROM public.position
        WHERE sell_price IS NOT NULL
    ) ranked ON ranked.position_id = p_all.position_id
) r
WHERE p.position_id = r.position_id
  AND p.creation_hierarchy IS DISTINCT FROM r.rn;
