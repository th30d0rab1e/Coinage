-- These three tables hold trades or orders but had no local portfolio key.
-- portfolio_id is portfolio.portfolio_id (integer), not the Coinbase UUID.
-- Nullable so a row we cannot match stays unset.

ALTER TABLE public.unmatched_fills
    ADD COLUMN IF NOT EXISTS portfolio_id integer;

ALTER TABLE public.profit_history
    ADD COLUMN IF NOT EXISTS portfolio_id integer;

ALTER TABLE public.bulk_open_orders
    ADD COLUMN IF NOT EXISTS portfolio_id integer;

COMMENT ON COLUMN public.unmatched_fills.portfolio_id IS
    'Local portfolio.portfolio_id for this fill. Null when the fill could not be matched to a Coinbase portfolio.';
COMMENT ON COLUMN public.profit_history.portfolio_id IS
    'Local portfolio.portfolio_id for this closed trade. Null when the buy order could not be matched.';
COMMENT ON COLUMN public.bulk_open_orders.portfolio_id IS
    'Local portfolio.portfolio_id. Set from retail_portfolio_id when that UUID is in bulk_portfolio.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'unmatched_fills_portfolio_id_fkey') THEN
        ALTER TABLE public.unmatched_fills
            ADD CONSTRAINT unmatched_fills_portfolio_id_fkey
            FOREIGN KEY (portfolio_id) REFERENCES public.portfolio (portfolio_id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'profit_history_portfolio_id_fkey') THEN
        ALTER TABLE public.profit_history
            ADD CONSTRAINT profit_history_portfolio_id_fkey
            FOREIGN KEY (portfolio_id) REFERENCES public.portfolio (portfolio_id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'bulk_open_orders_portfolio_id_fkey') THEN
        ALTER TABLE public.bulk_open_orders
            ADD CONSTRAINT bulk_open_orders_portfolio_id_fkey
            FOREIGN KEY (portfolio_id) REFERENCES public.portfolio (portfolio_id);
    END IF;
END $$;
