-- Crypto was moved onto Default (local portfolio_id 2).
-- Historical rows were labeled tedTosterone (3) or null. Point them at Default.
-- The portfolio row for tedTosterone (3) stays, because the Coinbase portfolio still exists
-- and a USD hold plus dust did not move. bulk_portfolio is the directory of those
-- Coinbase portfolios, so its own portfolio_id is not rewritten.

UPDATE public.fills SET portfolio_id = 2 WHERE portfolio_id = 3 OR portfolio_id IS NULL;
UPDATE public.position SET portfolio_id = 2 WHERE portfolio_id = 3 OR portfolio_id IS NULL;
UPDATE public.unmatched_fills SET portfolio_id = 2 WHERE portfolio_id = 3 OR portfolio_id IS NULL;
UPDATE public.profit_history SET portfolio_id = 2 WHERE portfolio_id = 3 OR portfolio_id IS NULL;
UPDATE public.bulk_open_orders SET portfolio_id = 2 WHERE portfolio_id = 3 OR portfolio_id IS NULL;
UPDATE public.balance SET portfolio_id = 2 WHERE portfolio_id = 3 OR portfolio_id IS NULL;
