CREATE OR REPLACE VIEW public.vw_balance AS
SELECT s.name,
    s.stock_id,
    bc.balance,
    bc.hold,
    bc.available,
    s.price * bc.balance AS price_balance,
    s.price * bc.available AS price_available,
    s.price * bc.hold AS price_hold,
    bc.balance * s.price AS value
FROM bulk_currency bc
JOIN stock s ON concat(bc.currency, '-USD') = s.name
UNION
SELECT bc.currency AS name,
    NULL::integer AS stock_id,
    bc.balance,
    bc.hold,
    bc.available,
    0 AS price_balance,
    0 AS price_available,
    0 AS price_hold,
    bc.balance AS value
FROM bulk_currency bc
WHERE bc.currency = ANY (ARRAY['USD'::text, 'USDC'::text]);
