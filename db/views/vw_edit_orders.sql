-- Per-remake tightening step is 0.005 (0.5 percentage point of price per
-- remake, on both buy_counter and sell_counter) -- raised from 0.001 on
-- 2026-09-15 per user request, to close the stop-to-price gap 5x faster
-- per remake.
--
-- Ordering is last_remade_at ASC NULLS FIRST, price_diff DESC: whichever
-- order has gone longest without being touched gets fixed first (never-
-- remade rows, NULL, count as most overdue), with price_diff only breaking
-- ties among rows that are equally overdue. This guarantees every position
-- cycles through eventually instead of the most-drifted one perpetually
-- winning -- price_diff alone (even as a percentage, not a raw dollar
-- amount) still let one position dominate indefinitely if its drift kept
-- being the largest every cycle.
-- last_remade_at is only stamped by processRemakeOrders() on an actual
-- successful remake -- initial order placement (processBuyOrders() /
-- processSellOrders()) doesn't touch it, so a brand-new order still counts
-- as never-remade (NULLS FIRST) until it's actually been through this path.
--
-- SELL limit price is frozen at p.sell_price and never recomputed here --
-- only new_stop_price changes on a sell remake. sell_price is set exactly
-- once, in thee_procedure()'s "Initial sell stop" block, from the
-- position's own settled buy_filled_price/buy_fee (the correct fee-adjusted
-- breakeven floor, or better). A limit sell can never fill worse than its
-- limit, so once that limit is genuinely correct, freezing it makes a
-- below-cost sale structurally impossible regardless of what any later
-- remake or daily-profit pass computes. Before this, the limit was
-- recomputed fresh off live price on every remake (guarded only by a
-- "new limit > live sell_price" ratchet) -- confirmed on PUMP-USD: a
-- separate code path (processDailyProfit()) independently recomputed its
-- own floor from what should have been the same settled buy data and got
-- 0.003699 instead of the correct 0.003782, producing a real -$0.02 loss
-- on a position the no-loss rule was supposed to make impossible to lose
-- on. Freezing the limit at the one value already proven correct removes
-- every later recomputation opportunity for that kind of drift to matter.
-- (Separately: a sell used to also carry a 4th branch, non-daily, dropped
-- here, that deliberately loosened a stop back down whenever it drifted
-- more than 1% above a fresh volatility-based calculation -- meant to give
-- a tight stop room to breathe, but its actual effect was giving back
-- already-locked-in profit on any ordinary pullback. Confirmed on BLZ-USD:
-- peaked at a 0.01303 stop (locked $0.41), then that branch walked it back
-- down to 0.01257 ($0.34) over several remakes as price merely dipped, not
-- reversed.)
CREATE OR REPLACE VIEW public.vw_edit_orders AS
SELECT p.name,
    p.period_type,
    trunc(s.price::numeric * bal.stop_mult * 1.01, s.price_rounding) AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.buy_coinbase_order_id AS coinbase_order_id,
    p.shares,
    trunc(s.price::numeric * bal.stop_mult, s.price_rounding) AS new_stop_price,
    'buy'::text AS order_type,
    trunc(1.0 - s.price::numeric / NULLIF((
        SELECT min(pa.low)::numeric FROM price_aggregate pa
        WHERE pa.stock_id = p.stock_id AND pa.period_type = p.period_type
    ), 0::numeric), 4) AS estimated_profit,
    p.last_remade_at,
    p.buy_counter AS counter,
    ABS(trunc(s.price::numeric * bal.stop_mult, s.price_rounding) - p.buy_stop_price::numeric) / NULLIF(s.price::numeric, 0) AS price_diff
FROM position p
JOIN stock s ON p.stock_id = s.stock_id
CROSS JOIN LATERAL (
    SELECT GREATEST(1.001, 1.05 - p.buy_counter::numeric * 0.005) AS stop_mult
) bal
WHERE p.buy_coinbase_order_id IS NOT NULL
AND p.buy_filled_price IS NULL
AND p.buy_stop_price > trunc(s.price::numeric * bal.stop_mult, s.price_rounding)::double precision
AND p.buy_price > trunc(s.price::numeric * bal.stop_mult * 1.01, s.price_rounding)::double precision

UNION ALL

SELECT p.name,
    p.period_type,
    p.sell_price AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.sell_coinbase_order_id AS coinbase_order_id,
    p.shares,
    GREATEST(p.sell_price::numeric, trunc(s.price::numeric * (0.99 + p.sell_counter::numeric * 0.005), s.price_rounding)) AS new_stop_price,
    'sell'::text AS order_type,
    trunc((p.sell_price::numeric - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit,
    p.last_remade_at,
    p.sell_counter AS counter,
    ABS(GREATEST(p.sell_price::numeric, trunc(s.price::numeric * (0.99 + p.sell_counter::numeric * 0.005), s.price_rounding)) - p.sell_stop_price::numeric) / NULLIF(s.price::numeric, 0) AS price_diff
FROM position p
JOIN stock s ON p.stock_id = s.stock_id
WHERE p.sell_coinbase_order_id IS NOT NULL
AND p.sell_filled_price IS NULL
AND p.daily_sell = true
AND p.sell_stop_price < GREATEST(p.sell_price::numeric, trunc(s.price::numeric * (0.99 + p.sell_counter::numeric * 0.005), s.price_rounding))::double precision
AND (
    p.sell_price::numeric
    * p.shares::numeric
    * (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), 0.012))
    - (p.buy_filled_price::numeric * p.shares::numeric + COALESCE(p.buy_fee::numeric, 0))
) > 0
AND (
    p.sell_price::numeric
    * p.shares::numeric
    * (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), 0.012))
    - (p.buy_filled_price::numeric * p.shares::numeric + COALESCE(p.buy_fee::numeric, 0))
) > (SELECT COALESCE(AVG(profit), 0) FROM profit_history WHERE period_type = p.period_type)

UNION ALL

SELECT p.name,
    p.period_type,
    p.sell_price AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.sell_coinbase_order_id AS coinbase_order_id,
    p.shares,
    GREATEST(p.sell_price::numeric, trunc(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.005), s.price_rounding)) AS new_stop_price,
    'sell'::text AS order_type,
    trunc((p.sell_price::numeric - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit,
    p.last_remade_at,
    p.sell_counter AS counter,
    ABS(GREATEST(p.sell_price::numeric, trunc(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.005), s.price_rounding)) - p.sell_stop_price::numeric) / NULLIF(s.price::numeric, 0) AS price_diff
FROM position p
JOIN stock s ON p.stock_id = s.stock_id
JOIN price_aggregate_total pat ON p.stock_id = pat.stock_id AND p.period_type = pat.period_type
CROSS JOIN LATERAL (
    SELECT CASE p.period_type
        WHEN 'day'::text   THEN LEAST(0.99, GREATEST(0.90, 1::numeric - pat.std_dev::numeric / 200::numeric))
        WHEN 'month'::text THEN LEAST(0.97, GREATEST(0.75, 1::numeric - pat.std_dev::numeric / 200::numeric))
        WHEN 'year'::text  THEN LEAST(0.95, GREATEST(0.60, 1::numeric - pat.std_dev::numeric / 200::numeric))
        ELSE NULL::numeric
    END AS stop_ratio
) vol
WHERE p.sell_coinbase_order_id IS NOT NULL
AND p.sell_filled_price IS NULL
AND p.daily_sell = false
AND p.sell_stop_price < GREATEST(p.sell_price::numeric, trunc(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.005), s.price_rounding))::double precision
AND (
    p.sell_price::numeric
    * p.shares::numeric
    * (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), 0.012))
    - (p.buy_filled_price::numeric * p.shares::numeric + COALESCE(p.buy_fee::numeric, 0))
) > 0
AND (
    p.sell_price::numeric
    * p.shares::numeric
    * (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), 0.012))
    - (p.buy_filled_price::numeric * p.shares::numeric + COALESCE(p.buy_fee::numeric, 0))
) > (SELECT COALESCE(AVG(profit), 0) FROM profit_history WHERE period_type = p.period_type)
ORDER BY last_remade_at ASC NULLS FIRST, price_diff DESC;
