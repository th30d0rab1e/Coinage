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
    p.buy_counter AS counter
FROM position p
JOIN stock s ON p.stock_id = s.stock_id
CROSS JOIN LATERAL (
    SELECT GREATEST(1.001, LEAST(1.05,
        1.01 + 0.04 * (1.0 -
            COALESCE((SELECT b.available::numeric FROM vw_balance b WHERE b.name = 'USD'::text), 0::numeric) /
            NULLIF(
                COALESCE((SELECT b.available::numeric FROM vw_balance b WHERE b.name = 'USD'::text), 0::numeric) +
                COALESCE((SELECT sum(p2.buy_price * p2.shares)::numeric FROM position p2 WHERE p2.buy_coinbase_order_id IS NOT NULL AND p2.buy_filled_price IS NULL), 0::numeric),
                0::numeric
            )
        ) - p.buy_counter::numeric * 0.001
    )) AS stop_mult
) bal
WHERE p.buy_coinbase_order_id IS NOT NULL
AND p.buy_filled_price IS NULL
AND p.buy_stop_price > trunc(s.price::numeric * bal.stop_mult, s.price_rounding)::double precision

UNION ALL

SELECT p.name,
    p.period_type,
    trunc(s.price::numeric * (0.99 + p.sell_counter::numeric * 0.001) * 0.99, s.price_rounding) AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.sell_coinbase_order_id AS coinbase_order_id,
    p.shares,
    trunc(s.price::numeric * (0.99 + p.sell_counter::numeric * 0.001), s.price_rounding) AS new_stop_price,
    'sell'::text AS order_type,
    trunc((s.price::numeric * (0.99 + p.sell_counter::numeric * 0.001) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit,
    p.sell_counter AS counter
FROM position p
JOIN stock s ON p.stock_id = s.stock_id
WHERE p.sell_coinbase_order_id IS NOT NULL
AND p.sell_filled_price IS NULL
AND p.daily_sell = true
AND p.sell_stop_price < trunc(s.price::numeric * (0.99 + p.sell_counter::numeric * 0.001), s.price_rounding)::double precision
AND (
    trunc(s.price::numeric * (0.99 + p.sell_counter::numeric * 0.001) * 0.99, s.price_rounding)::numeric
    * p.shares::numeric
    * (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), 0.012))
    - (p.buy_filled_price::numeric * p.shares::numeric + COALESCE(p.buy_fee::numeric, 0))
) > 0

UNION ALL

SELECT p.name,
    p.period_type,
    GREATEST(breakeven.floor_price, trunc(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.001) * 0.99, s.price_rounding)) AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.sell_coinbase_order_id AS coinbase_order_id,
    p.shares,
    GREATEST(breakeven.floor_price, trunc(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.001), s.price_rounding)) AS new_stop_price,
    'sell'::text AS order_type,
    trunc((GREATEST(breakeven.floor_price, trunc(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.001), s.price_rounding)) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit,
    p.sell_counter AS counter
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
-- Floor at a breakeven price, not raw buy_filled_price: profit also has to
-- cover both fees, so the floor is buy_filled_price grossed up by this
-- position's own realized buy-side fee rate (used as the sell-fee
-- estimate), falling back to 1.2% if the buy fee is unknown.
CROSS JOIN LATERAL (
    SELECT CEIL(
        (p.buy_filled_price::numeric
            * (1 + COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), 0.012))
            / (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), 0.012)))
        * POWER(10::numeric, s.price_rounding::int)
    ) / POWER(10::numeric, s.price_rounding::int) AS floor_price
) breakeven
WHERE p.sell_coinbase_order_id IS NOT NULL
AND p.sell_filled_price IS NULL
AND p.daily_sell = false
AND p.sell_stop_price < GREATEST(breakeven.floor_price, trunc(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.001), s.price_rounding))::double precision
AND (
    GREATEST(breakeven.floor_price, trunc(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.001) * 0.99, s.price_rounding))
    * p.shares::numeric
    * (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), 0.012))
    - (p.buy_filled_price::numeric * p.shares::numeric + COALESCE(p.buy_fee::numeric, 0))
) > 0

UNION ALL

SELECT p.name,
    p.period_type,
    GREATEST(breakeven.floor_price, trunc(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.001) * 0.99, s.price_rounding)) AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.sell_coinbase_order_id AS coinbase_order_id,
    p.shares,
    GREATEST(breakeven.floor_price, trunc(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.001), s.price_rounding)) AS new_stop_price,
    'sell'::text AS order_type,
    trunc((GREATEST(breakeven.floor_price, trunc(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.001), s.price_rounding)) - p.buy_filled_price::numeric) * p.shares::numeric, 2) AS estimated_profit,
    p.sell_counter AS counter
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
CROSS JOIN LATERAL (
    SELECT CEIL(
        (p.buy_filled_price::numeric
            * (1 + COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), 0.012))
            / (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), 0.012)))
        * POWER(10::numeric, s.price_rounding::int)
    ) / POWER(10::numeric, s.price_rounding::int) AS floor_price
) breakeven
WHERE p.sell_coinbase_order_id IS NOT NULL
AND p.sell_filled_price IS NULL
AND p.daily_sell = false
AND p.sell_stop_price > trunc(s.price::numeric * (vol.stop_ratio + 0.01 + p.sell_counter::numeric * 0.001), s.price_rounding)::double precision
AND (
    GREATEST(breakeven.floor_price, trunc(s.price::numeric * (vol.stop_ratio + p.sell_counter::numeric * 0.001) * 0.99, s.price_rounding))
    * p.shares::numeric
    * (1 - COALESCE(NULLIF(p.buy_fee::numeric, 0) / NULLIF(p.buy_filled_price::numeric * p.shares::numeric, 0), 0.012))
    - (p.buy_filled_price::numeric * p.shares::numeric + COALESCE(p.buy_fee::numeric, 0))
) > 0
ORDER BY 10 DESC;
