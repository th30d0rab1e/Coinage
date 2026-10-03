-- Undo the portfolio-id work from 2026-10-03. These columns and tables did not
-- exist before that work. portfolio_id is removed rather than left as text.
-- The darthtlc account deletion stays. Account.email stays. Portfolio row 1 stays.
-- Rows 2 and 3 were inserted for Default and tedTosterone during that work, so they go.

ALTER TABLE public.fills DROP CONSTRAINT IF EXISTS fills_portfolio_id_fkey;
ALTER TABLE public.position DROP CONSTRAINT IF EXISTS position_portfolio_id_fkey;
ALTER TABLE public.balance DROP CONSTRAINT IF EXISTS balance_portfolio_id_fkey;
ALTER TABLE public.unmatched_fills DROP CONSTRAINT IF EXISTS unmatched_fills_portfolio_id_fkey;
ALTER TABLE public.profit_history DROP CONSTRAINT IF EXISTS profit_history_portfolio_id_fkey;
ALTER TABLE public.bulk_open_orders DROP CONSTRAINT IF EXISTS bulk_open_orders_portfolio_id_fkey;
ALTER TABLE public.bulk_portfolio DROP CONSTRAINT IF EXISTS bulk_portfolio_portfolio_id_fkey;
ALTER TABLE public.portfolio DROP CONSTRAINT IF EXISTS portfolio_account_id_fkey;

ALTER TABLE public.fills DROP COLUMN IF EXISTS portfolio_id;
ALTER TABLE public.position DROP COLUMN IF EXISTS portfolio_id;
ALTER TABLE public.unmatched_fills DROP COLUMN IF EXISTS portfolio_id;
ALTER TABLE public.profit_history DROP COLUMN IF EXISTS portfolio_id;
ALTER TABLE public.bulk_open_orders DROP COLUMN IF EXISTS portfolio_id;

DROP TABLE IF EXISTS public.balance;
DROP TABLE IF EXISTS public.bulk_portfolio;

DELETE FROM public.portfolio WHERE portfolio_id IN (2, 3);

-- etf_buy is recreated from db/tables/etf_buy.sql. The email delete stays.
DELETE FROM public.account WHERE email = 'darthtlc@gmail.com';
