-- 2026-09-25: TTL (hours) for planned buys that never got a Coinbase order.
-- thee_procedure deletes such rows once their last activity is older than
-- this. Tunable without a procedure edit; procedure defaults to 24 if absent.
INSERT INTO config (key, value) VALUES ('pending_buy_ttl_hours', '24')
ON CONFLICT (key) DO NOTHING;
