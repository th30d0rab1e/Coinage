-- portfolio.account_id already existed with no foreign key.
-- This ties it to account.account_id. Existing rows stay valid because account 1 is present
-- and rows 2 and 3 are set to that same account below. Portfolio 1 is not updated.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'portfolio_account_id_fkey'
    ) THEN
        ALTER TABLE public.portfolio
            ADD CONSTRAINT portfolio_account_id_fkey
            FOREIGN KEY (account_id) REFERENCES public.account (account_id);
    END IF;
END $$;

-- Default (2) and tedTosterone (3) belong to account 1. No other portfolio row is changed.
UPDATE public.portfolio
SET account_id = 1
WHERE portfolio_id IN (2, 3);
