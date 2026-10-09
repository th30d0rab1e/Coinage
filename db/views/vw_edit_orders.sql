-- 2026-10-08 (migrations/2026-10-08_vw_edit_orders_cfg_cte.sql, Theodore):
-- refactor only, NO logic change. Every config value and the
-- vw_buy_stop_gap row are now read ONCE in the WITH block at the top of the
-- view (cfg / gap -- the view's "variables", like the DECLARE block of
-- thee_procedure) instead of repeated inline
-- (SELECT value FROM config WHERE key = ...) subqueries. Defaults are the
-- same COALESCE values as before. Verified before going live: output
-- identical to the old view (EXCEPT both directions = 0 rows), same
-- columns / types / order.
--
-- 2026-10-07: SELL branch 2 adds the "1% trail once above average profit"
-- rule (config.avg_profit); see the comment at that branch. Branch 1 and
-- the BUY branch are unchanged.
-- 2026-10-07 (migrations/2026-10-07_buy_stop_cash_scaled.sql): BUY branch
-- remake multiplier = GREATEST(1 + buy_remake_floor_pct/100, 1 + gap -
-- buy_counter * buy_remake_step_pct/100) with gap from vw_buy_stop_gap, then
-- the below-lowest-paid rule (fn_buy_below_paid). Sell branches unchanged.
-- The note just below about the 0.005 step still holds for SELL remakes;
-- for buys the step is now config buy_remake_step_pct (default 0.5 = 0.005).
--
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
--
-- 2026-10-05 (rev 3) -- remake rules per coin:
--
-- BUY remakes: every open buy bag is eligible. No creation_hierarchy filter
-- on the buy branch (rev 2 removed the earlier = 1 gate and that stays).
--
-- SELL remakes: only creation_hierarchy = 1. Since thee_procedure now ranks
-- creation_hierarchy by buy_filled_price ASC NULLS LAST, then buy_stop_price
-- ASC NULLS LAST, then position_id (1 = cheapest filled bag), filtering on
-- hierarchy 1 replaces the prior inline sell ranking CTE that used the same
-- order. Applied to both sell branches below; if hierarchy-1 does not qualify
-- this cycle (ratchet / profit gates), no other bag of that coin is remade
-- in its place. processRemakeOrders() reads only this view, so these rules
-- cover every remake path.
CREATE OR REPLACE VIEW public.vw_edit_orders AS
-- "Variables": read once here, used by every branch below.
-- cfg is always exactly ONE row (scalar subqueries, no FROM), so
-- CROSS JOIN cfg never adds or removes rows. A missing config key gives the
-- same default the old inline COALESCE gave (avg_profit has no default:
-- missing -> NULL -> the 1% trail rule stays off, as before).
WITH cfg AS (
    SELECT
        COALESCE((SELECT value::numeric FROM config WHERE key = 'buy_remake_floor_pct'), 0.1) AS buy_remake_floor_pct, -- BUY: lowest stop, % over price
        COALESCE((SELECT value::numeric FROM config WHERE key = 'buy_remake_step_pct'), 0.5)  AS buy_remake_step_pct,  -- BUY: % taken off per remake
        COALESCE((SELECT value::numeric FROM config WHERE key = 'fee_percent'), 1.20)         AS fee_percent,          -- SELL: fee % when the bag's own fee is unknown
        (SELECT value::numeric FROM config WHERE key = 'avg_profit')                          AS avg_profit            -- SELL 2: 1% trail threshold
),
-- The cash-scaled buy-stop gap (db/views/vw_buy_stop_gap.sql, the ONE place
-- it is computed). Its own CTE, joined only by the BUY branch exactly like
-- the old CROSS JOIN vw_buy_stop_gap, so the sell branches never depend on it.
gap AS (
    SELECT g.gap FROM vw_buy_stop_gap g
)
-- BUY branch. 2026-10-07 (migrations/2026-10-07_buy_stop_cash_scaled.sql,
-- Theodore): the remake now starts from the same cash-scaled gap as first
-- placement (vw_buy_stop_gap.gap, the ONE shared place) instead of a fixed
-- 5%, and the step / floor come from config:
--   stop_mult = GREATEST(1 + buy_remake_floor_pct/100,
--                        1 + gap - buy_counter * buy_remake_step_pct/100)
--   stop = trunc(price x stop_mult), limit = trunc(price x stop_mult x 1.01)
-- (defaults 0.5 / 0.1 = the old hard-coded 0.005 step and 1.001 floor).
-- Then the below-lowest-paid rule (fn_buy_below_paid, shared with
-- thee_procedure): on a coin with open filled bags the limit must stay
-- below the lowest buy_filled_price, else limit = largest tick below it and
-- stop = limit / 1.01 rounded down. The final stop/limit (bp.*) are what
-- is placed, compared in the ratchet and reported in price_diff.
-- Ratchet unchanged: a remake only ever LOWERS both stop and limit.
-- New guard: the final stop must be above the live price (a stop-buy at or
-- under market is rejected by Coinbase's preview; the below-lowest-paid
-- clamp can produce one when price sits just under the lowest paid).
SELECT p.name,
    p.period_type,
    bp.limit_price AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.buy_coinbase_order_id AS coinbase_order_id,
    p.shares,
    bp.stop_price AS new_stop_price,
    'buy'::text AS order_type,
    trunc(1.0 - s.price::numeric / NULLIF((
        SELECT min(pa.low)::numeric FROM price_aggregate pa
        WHERE pa.stock_id = p.stock_id AND pa.period_type = p.period_type
    ), 0::numeric), 4) AS estimated_profit,
    p.last_remade_at,
    p.buy_counter AS counter,
    ABS(bp.stop_price - p.buy_stop_price::numeric) / NULLIF(s.price::numeric, 0) AS price_diff
FROM position p
JOIN stock s ON p.stock_id = s.stock_id
CROSS JOIN gap g
CROSS JOIN cfg  -- one-row "variables" (see WITH at the top)
CROSS JOIN LATERAL (
    SELECT GREATEST(
               1 + cfg.buy_remake_floor_pct / 100,
               1 + g.gap - p.buy_counter::numeric
                   * cfg.buy_remake_step_pct / 100
           ) AS stop_mult
) bal
-- Lowest price paid among this coin's open filled bags (NULL = not held).
LEFT JOIN LATERAL (
    SELECT MIN(f.buy_filled_price)::numeric AS min_paid
    FROM position f
    WHERE f.stock_id = p.stock_id
    AND f.buy_filled_price IS NOT NULL
    AND f.sell_filled_price IS NULL
) paid ON TRUE
CROSS JOIN LATERAL fn_buy_below_paid(
    trunc(s.price::numeric * bal.stop_mult, s.price_rounding),
    trunc(s.price::numeric * bal.stop_mult * 1.01, s.price_rounding),
    paid.min_paid,
    s.price_rounding
) bp
WHERE p.buy_coinbase_order_id IS NOT NULL
AND p.buy_filled_price IS NULL
-- 2026-10-07: never remake (cancel + re-create as a stop-limit) a listing
-- buy. It is a plain GTC limit that rests until it fills or Theodore
-- cancels it by hand. Its NULL buy_stop_price already fails the next line;
-- this makes the exemption explicit.
AND p.period_type IS DISTINCT FROM 'listing'
-- 2026-10-08: never remake a DIP-BUY order here either (plain limit, NULL
-- buy_stop_price, so the next line already fails; explicit for clarity).
-- Dip orders have their own remake / TTL rules: vw_dip_buy_actions +
-- index.js processDipBuys().
AND p.buy_source IS DISTINCT FROM 'dip_buy'
-- only-lower ratchet (both stop and limit must drop)
AND p.buy_stop_price > bp.stop_price::double precision
AND p.buy_price > bp.limit_price::double precision
-- the new stop must sit above the live price (see header)
AND bp.stop_price > s.price::numeric

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
CROSS JOIN cfg  -- one-row "variables" (see WITH at the top)
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
        * (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), cfg.fee_percent / 100))
        - (p.buy_filled_price::numeric * p.shares::numeric + COALESCE(p.buy_fee::numeric, 0)) AS net_at_new_stop
) pr
WHERE p.sell_coinbase_order_id IS NOT NULL
AND p.sell_filled_price IS NULL
-- 2026-10-07: listing snipe bags trail here too (fixed 0.99 base ratio):
-- branch 2 needs a price_aggregate_total row for the bag's period_type,
-- which never exists for 'listing' (and a new coin has no history).
AND (p.daily_sell = true OR p.period_type = 'listing')
-- Ratchet: only ever move the stop UP (now against the capped value).
AND p.sell_stop_price < ns.new_stop::double precision
-- FIX 2 guard: never place a stop below its own frozen limit.
AND ns.new_stop >= p.sell_price::numeric
-- FIX 1: profit gate at the NEW stop, not the old limit.
AND pr.net_at_new_stop > 0
AND pr.net_at_new_stop > (SELECT COALESCE(AVG(profit), 0) FROM profit_history WHERE period_type = p.period_type)
-- Only the cheapest open bag per coin (creation_hierarchy ranks by fill).
AND p.creation_hierarchy = 1

UNION ALL

-- SELL branch 2 of 2: daily_sell = false, volatility-based base ratio.
-- 2026-10-07 "1% TRAIL ONCE ABOVE AVERAGE PROFIT" (Theodore): if selling
-- at trunc(price * 0.99) would net more than config.avg_profit (all-time
-- AVG(profit_history.profit), refreshed by thee_procedure each run), the new
-- stop is trunc(price * 0.99) -- a tight 1% trail instead of the wider
-- volatility ratio (0.90-0.99 for day bags). Net = proceeds at that stop
-- after an estimated sell fee minus cost incl. the buy fee, with the SAME
-- fee math as pr below. Otherwise the existing trailing math is unchanged.
-- Never looser than the existing math (GREATEST), the frozen limit and every
-- existing guard (ratchet up only, stop >= limit, <= price * 0.995, hierarchy
-- 1) still apply; the period-average profit gate is waived only when the
-- rule fires (it already requires net > config.avg_profit).
-- Branch 1 (daily_sell / listing) does NOT get it: its stop is already
-- >= trunc(price * 0.99) (0.99 base ratio + 0.005 per remake, capped at
-- 0.995), so the rule could only match or loosen it there.
-- 2026-10-07: never serves period_type 'listing' bags -- the
-- price_aggregate_total join below has no 'listing' rows; listing bags
-- trail in branch 1 instead. The explicit filter just makes that visible.
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
CROSS JOIN cfg  -- one-row "variables" (see WITH at the top)
CROSS JOIN LATERAL (
    SELECT CASE p.period_type
        WHEN 'day'::text   THEN LEAST(0.99, GREATEST(0.90, 1::numeric - pat.std_dev::numeric / 200::numeric))
        WHEN 'month'::text THEN LEAST(0.97, GREATEST(0.75, 1::numeric - pat.std_dev::numeric / 200::numeric))
        WHEN 'year'::text  THEN LEAST(0.95, GREATEST(0.60, 1::numeric - pat.std_dev::numeric / 200::numeric))
        ELSE NULL::numeric
    END AS stop_ratio
) vol
-- 2026-10-07 1% trail rule inputs: the candidate stop trunc(price * 0.99)
-- (same price_rounding as every stop here), the net profit if the bag sold
-- there (proceeds x (1 - fee rate) - (buy_filled_price x shares + buy_fee);
-- fee rate = this bag's buy fee rate, else config.fee_percent / 100 -- the
-- same estimate pr uses), and whether that beats config.avg_profit. A
-- missing avg_profit row makes rule_on NULL -> existing math.
CROSS JOIN LATERAL (
    SELECT t.stop99,
           t.stop99 * p.shares::numeric
             * (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), cfg.fee_percent / 100))
             - (p.buy_filled_price::numeric * p.shares::numeric + COALESCE(p.buy_fee::numeric, 0)) AS net99,
           cfg.avg_profit AS avg_profit
    FROM (SELECT trunc(s.price::numeric * 0.99, s.price_rounding) AS stop99) t
) r99
CROSS JOIN LATERAL (
    SELECT r99.net99 > r99.avg_profit AS rule_on
) rule
-- FIX 2: the one place the new stop is calculated for this branch.
-- Old: GREATEST(sell_price, trunc(price * (stop_ratio + counter*0.005)))
-- New: same, but LEAST'd against trunc(price * 0.995) so the stop is
--      always at least 0.5% under market (never at/above -> no Coinbase
--      "Price protection point was breached" cancel, as on PAX-USD 566).
-- 2026-10-07: when rule.rule_on, GREATEST(trunc(price * 0.99), that value)
-- -- the 1% trail, or the existing value if remakes already pushed it
-- higher. Both are <= trunc(price * 0.995), so the cap still holds.
CROSS JOIN LATERAL (
    SELECT CASE WHEN rule.rule_on
                THEN GREATEST(r99.stop99, ex.existing_stop)
                ELSE ex.existing_stop
           END AS new_stop
    FROM (
        SELECT LEAST(
            GREATEST(p.sell_price::numeric, trunc(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.005), s.price_rounding)),
            trunc(s.price::numeric * 0.995, s.price_rounding)
        ) AS existing_stop
    ) ex
) ns
-- FIX 1: fee-adjusted net profit if the order sells at the NEW stop
-- (previously computed at p.sell_price, the frozen old limit).
CROSS JOIN LATERAL (
    SELECT ns.new_stop
        * p.shares::numeric
        * (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), cfg.fee_percent / 100))
        - (p.buy_filled_price::numeric * p.shares::numeric + COALESCE(p.buy_fee::numeric, 0)) AS net_at_new_stop
) pr
WHERE p.sell_coinbase_order_id IS NOT NULL
AND p.sell_filled_price IS NULL
AND p.daily_sell = false
AND p.period_type IS DISTINCT FROM 'listing'
-- Ratchet: only ever move the stop UP (now against the capped value).
AND p.sell_stop_price < ns.new_stop::double precision
-- FIX 2 guard: never place a stop below its own frozen limit.
AND ns.new_stop >= p.sell_price::numeric
-- FIX 1: profit gate at the NEW stop, not the old limit.
AND pr.net_at_new_stop > 0
-- 2026-10-07: the period-average gate is skipped when the 1% trail rule
-- fired (net at the new stop >= net99 > config.avg_profit already).
AND (rule.rule_on IS TRUE
     OR pr.net_at_new_stop > (SELECT COALESCE(AVG(profit), 0) FROM profit_history WHERE period_type = p.period_type))
-- Only the cheapest open bag per coin (creation_hierarchy ranks by fill).
AND p.creation_hierarchy = 1
ORDER BY last_remade_at ASC NULLS FIRST, price_diff DESC;
