-- One-time cleanup, 2026-09-25: LRC-USD was removed from Coinbase's catalog.
-- Position 787 was a planned $1 buy that never got an order (every attempt
-- rejected with 'Invalid product_id') and was retried every minute since 9/18.
-- Pre-checks run before this: 0 LRC fills, 0 unmatched fills, 0 open orders,
-- position 787 never held a buy_coinbase_order_id, 0 LRC balance.
BEGIN;
-- mark the coin disabled now (thee_procedure's new catalog check would also do this next cycle)
UPDATE stock SET trading_disabled = TRUE WHERE name = 'LRC-USD';
-- delete only if still unfilled with no live order (guards against deleting anything real)
DELETE FROM position
WHERE position_id = 787
  AND buy_filled_price IS NULL
  AND buy_coinbase_order_id IS NULL;
COMMIT;
