-- 2026-10-07 (migrations/2026-10-07_buy_stop_cash_scaled.sql): the
-- "below lowest paid" rule for crypto buys (Theodore). A buy on a coin that
-- has open filled bags must have its LIMIT price strictly below the lowest
-- buy_filled_price among those bags -- at placement and on every remake.
--
-- Input: the computed stop and limit, the lowest paid price of the coin's
-- open bags (NULL = coin not held) and stock.price_rounding (tick =
-- 10^-price_rounding, the same tick every TRUNC in thee_procedure uses).
-- Output:
--   * not held (p_min_paid NULL) or limit already below the lowest paid:
--     stop and limit unchanged.
--   * otherwise: limit = the largest tick strictly below the lowest paid,
--     stop = limit / 1.01 rounded DOWN to the tick (so stop < limit).
-- Callers: thee_procedure (signal insert, average-down insert, add-on
-- UPDATE, planned-row clean-up (e)) and vw_edit_orders (buy remake), so the
-- rule lives in one place. Replaces the old add_buy_cap_ratio (0.99 x
-- cheapest bag) stop math; that config row is left in place but unused.
-- Listing rows never call this (they are plain limits on coins not held).
CREATE OR REPLACE FUNCTION public.fn_buy_below_paid(
    p_stop numeric, p_limit numeric, p_min_paid numeric, p_rounding integer)
RETURNS TABLE (stop_price numeric, limit_price numeric)
LANGUAGE sql IMMUTABLE
AS $fn$
    SELECT CASE WHEN p_min_paid IS NULL OR p_limit < p_min_paid THEN p_stop
                -- ROUND(.., p_rounding) only sets the scale (the value is
                -- already on the tick) so the price prints as e.g. 0.00985,
                -- exactly like TRUNC(.., price_rounding) elsewhere.
                ELSE ROUND(FLOOR(cap.lim / 1.01 / cap.tick) * cap.tick, p_rounding) END,
           CASE WHEN p_min_paid IS NULL OR p_limit < p_min_paid THEN p_limit
                ELSE ROUND(cap.lim, p_rounding) END
    FROM (
        SELECT power(10::numeric, -p_rounding) AS tick,
               -- largest k * tick strictly below p_min_paid
               (CEIL(p_min_paid / power(10::numeric, -p_rounding)) - 1) * power(10::numeric, -p_rounding) AS lim
    ) cap
$fn$;

COMMENT ON FUNCTION public.fn_buy_below_paid(numeric, numeric, numeric, integer) IS
    'Below-lowest-paid rule for crypto buys: if limit >= lowest open-bag buy_filled_price, limit = largest tick below it and stop = limit/1.01 rounded down; else unchanged. Used by thee_procedure and vw_edit_orders.';
