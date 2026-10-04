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
--
-- 2026-09-28 -- two fixes to the SELL branches only (buy branch untouched):
--
-- FIX 1 (profit gate used the OLD limit): the sell WHERE clause gated a
-- remake on net profit computed at p.sell_price -- the frozen original
-- limit, which never changes. So a bag whose original limit nets less than
-- the period's average profit_history.profit (~$0.02 for 'day') could NEVER
-- be remade upward, no matter how far price rose. Confirmed on PUMP-USD
-- (position 1033): limit 0.004566 nets ~$0.015 (< $0.020 avg), price had
-- run to ~0.00492 (would net ~$0.09 at a new stop) and the stop sat stuck
-- at 0.004612. The gate (both the > 0 and the > avg checks) and
-- estimated_profit are now computed at the NEW stop price this branch
-- would actually place (ns.new_stop below, after FIX 2's cap).
-- Why the stop and not the limit: index.js processRemakeOrders() sends
-- order_price (= frozen p.sell_price) as the limit and new_stop_price as
-- the stop, unchanged. Once the stop triggers, the limit sell fills at the
-- market (~the stop), with p.sell_price only as the worst-case floor.
-- That floor was already set at breakeven-or-better by thee_procedure()
-- and is still never recomputed here, so no-loss protection is unchanged.
-- estimated_profit is now the same fee-adjusted NET figure the gate uses
-- (it used to be gross (sell_price - buy_filled_price) * shares).
--
-- FIX 2 (spike cap -- stop must stay below market): new_stop_price was
-- GREATEST(sell_price, trunc(price * (ratio + counter*0.005))). With
-- sell_counter climbing, ratio + counter*0.005 can reach >= 1.0, putting a
-- sell STOP at/above the live price; Coinbase then cancels it ("Price
-- protection point was breached") -- confirmed on PAX-USD (position 566).
-- It is now capped at trunc(price * 0.995, price_rounding), i.e. always at
-- least 0.5% under the live price:
--   LEAST(GREATEST(sell_price, trunc(price*(ratio+counter*0.005))),
--         trunc(price*0.995))
-- The capped value is computed ONCE per branch in a CROSS JOIN LATERAL
-- (ns.new_stop) and reused everywhere -- new_stop_price, price_diff, the
-- "sell_stop_price < new stop" ratchet, and the profit gate -- so they can
-- never disagree. Because the cap can pull the stop below the frozen limit
-- when price sits under sell_price/0.995, an extra guard
-- (ns.new_stop >= p.sell_price) keeps a stop from ever being placed below
-- its own limit (the ratchet already implies this whenever the current
-- stop is >= sell_price, which thee_procedure guarantees; this just makes
-- it explicit).
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

-- SELL branch 1 of 2: daily_sell = true, fixed 0.99 base ratio.
SELECT p.name,
    p.period_type,
    -- Limit stays frozen (see header). Only the stop moves.
    p.sell_price AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.sell_coinbase_order_id AS coinbase_order_id,
    p.shares,
    -- FIX 2: capped new stop (computed once in the "ns" lateral below).
    ns.new_stop AS new_stop_price,
    'sell'::text AS order_type,
    -- FIX 1: net profit at the NEW stop (was gross at the old frozen limit).
    trunc(pr.net_at_new_stop, 2) AS estimated_profit,
    p.last_remade_at,
    p.sell_counter AS counter,
    ABS(ns.new_stop - p.sell_stop_price::numeric) / NULLIF(s.price::numeric, 0) AS price_diff
FROM position p
JOIN stock s ON p.stock_id = s.stock_id
-- FIX 2: the one place the new stop is calculated for this branch.
-- Old: GREATEST(sell_price, trunc(price * (0.99 + counter*0.005)))
-- New: same, but LEAST'd against trunc(price * 0.995) so the stop is
--      always at least 0.5% under market (never at/above -> no Coinbase
--      "Price protection point was breached" cancel).
CROSS JOIN LATERAL (
    SELECT LEAST(
        GREATEST(p.sell_price::numeric, trunc(s.price::numeric * (0.99 + p.sell_counter::numeric * 0.005), s.price_rounding)),
        trunc(s.price::numeric * 0.995, s.price_rounding)
    ) AS new_stop
) ns
-- FIX 1: fee-adjusted net profit if the order sells at the NEW stop
-- (previously computed at p.sell_price, the frozen old limit). Sell fee is
-- assumed at the same rate as the buy fee (config.fee_percent / 100 when unknown).
CROSS JOIN LATERAL (
    SELECT ns.new_stop
        * p.shares::numeric
        * (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100))
        - (p.buy_filled_price::numeric * p.shares::numeric + COALESCE(p.buy_fee::numeric, 0)) AS net_at_new_stop
) pr
WHERE p.sell_coinbase_order_id IS NOT NULL
AND p.sell_filled_price IS NULL
AND p.daily_sell = true
-- Ratchet: only ever move the stop UP (now against the capped value).
AND p.sell_stop_price < ns.new_stop::double precision
-- FIX 2 guard: never place a stop below its own frozen limit.
AND ns.new_stop >= p.sell_price::numeric
-- FIX 1: profit gate at the NEW stop, not the old limit.
AND pr.net_at_new_stop > 0
AND pr.net_at_new_stop > (SELECT COALESCE(AVG(profit), 0) FROM profit_history WHERE period_type = p.period_type)

UNION ALL

-- SELL branch 2 of 2: daily_sell = false, volatility-based base ratio.
SELECT p.name,
    p.period_type,
    -- Limit stays frozen (see header). Only the stop moves.
    p.sell_price AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.sell_coinbase_order_id AS coinbase_order_id,
    p.shares,
    -- FIX 2: capped new stop (computed once in the "ns" lateral below).
    ns.new_stop AS new_stop_price,
    'sell'::text AS order_type,
    -- FIX 1: net profit at the NEW stop (was gross at the old frozen limit).
    trunc(pr.net_at_new_stop, 2) AS estimated_profit,
    p.last_remade_at,
    p.sell_counter AS counter,
    ABS(ns.new_stop - p.sell_stop_price::numeric) / NULLIF(s.price::numeric, 0) AS price_diff
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
-- FIX 2: the one place the new stop is calculated for this branch.
-- Old: GREATEST(sell_price, trunc(price * (stop_ratio + counter*0.005)))
-- New: same, but LEAST'd against trunc(price * 0.995) so the stop is
--      always at least 0.5% under market (never at/above -> no Coinbase
--      "Price protection point was breached" cancel, as on PAX-USD 566).
CROSS JOIN LATERAL (
    SELECT LEAST(
        GREATEST(p.sell_price::numeric, trunc(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.005), s.price_rounding)),
        trunc(s.price::numeric * 0.995, s.price_rounding)
    ) AS new_stop
) ns
-- FIX 1: fee-adjusted net profit if the order sells at the NEW stop
-- (previously computed at p.sell_price, the frozen old limit).
CROSS JOIN LATERAL (
    SELECT ns.new_stop
        * p.shares::numeric
        * (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20) / 100))
        - (p.buy_filled_price::numeric * p.shares::numeric + COALESCE(p.buy_fee::numeric, 0)) AS net_at_new_stop
) pr
WHERE p.sell_coinbase_order_id IS NOT NULL
AND p.sell_filled_price IS NULL
AND p.daily_sell = false
-- Ratchet: only ever move the stop UP (now against the capped value).
AND p.sell_stop_price < ns.new_stop::double precision
-- FIX 2 guard: never place a stop below its own frozen limit.
AND ns.new_stop >= p.sell_price::numeric
-- FIX 1: profit gate at the NEW stop, not the old limit.
AND pr.net_at_new_stop > 0
AND pr.net_at_new_stop > (SELECT COALESCE(AVG(profit), 0) FROM profit_history WHERE period_type = p.period_type)
ORDER BY last_remade_at ASC NULLS FIRST, price_diff DESC;
