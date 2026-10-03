-- 2026-10-03: portfolio_id is the local portfolio table's primary key
-- (portfolio.portfolio_id, integer identity), not the Coinbase uuid.
-- The uuid column on bulk_portfolio stays the API field. Fills, position,
-- and balance keep a nullable portfolio_id and are not backfilled.
-- Existing portfolio rows are not updated or deleted. A Coinbase portfolio
-- with no local row gets a new portfolio row, and that new id is stored
-- on bulk_portfolio. Idempotent.

-- Wrong foreign keys pointed portfolio_id at bulk_portfolio.uuid.
ALTER TABLE public.fills DROP CONSTRAINT IF EXISTS fills_portfolio_id_fkey;
ALTER TABLE public.position DROP CONSTRAINT IF EXISTS position_portfolio_id_fkey;
ALTER TABLE public.balance DROP CONSTRAINT IF EXISTS balance_portfolio_id_fkey;

-- Columns were text so they could hold a Coinbase uuid. They are all null,
-- so the type change does not rewrite business data. Refuse if a value exists.
DO $$
DECLARE
    bad boolean;
BEGIN
    -- Only the text/uuid version is retyped, and only while it is still all null.
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns c
        WHERE c.table_schema = 'public' AND c.column_name = 'portfolio_id'
          AND c.data_type <> 'integer'
          AND c.table_name IN ('fills', 'position', 'balance')
          AND (
              (c.table_name = 'fills' AND EXISTS (SELECT 1 FROM public.fills WHERE portfolio_id IS NOT NULL))
              OR (c.table_name = 'position' AND EXISTS (SELECT 1 FROM public.position WHERE portfolio_id IS NOT NULL))
              OR (c.table_name = 'balance' AND EXISTS (SELECT 1 FROM public.balance WHERE portfolio_id IS NOT NULL))
          )
    ) INTO bad;
    IF bad THEN
        RAISE EXCEPTION 'portfolio_id already has values; not retyping';
    END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'fills'
          AND column_name = 'portfolio_id' AND data_type <> 'integer'
    ) THEN
        ALTER TABLE public.fills ALTER COLUMN portfolio_id TYPE integer USING NULL::integer;
    END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'position'
          AND column_name = 'portfolio_id' AND data_type <> 'integer'
    ) THEN
        ALTER TABLE public.position ALTER COLUMN portfolio_id TYPE integer USING NULL::integer;
    END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'balance'
          AND column_name = 'portfolio_id' AND data_type <> 'integer'
    ) THEN
        ALTER TABLE public.balance ALTER COLUMN portfolio_id TYPE integer USING NULL::integer;
    END IF;
END $$;

ALTER TABLE public.bulk_portfolio
    ADD COLUMN IF NOT EXISTS portfolio_id integer;

-- One new local portfolio row per downloaded Coinbase portfolio that does
-- not already point at one. Does not touch rows already in portfolio.
DO $$
DECLARE
    rec record;
    new_id integer;
BEGIN
    FOR rec IN
        SELECT uuid FROM public.bulk_portfolio WHERE portfolio_id IS NULL ORDER BY uuid
    LOOP
        INSERT INTO public.portfolio DEFAULT VALUES RETURNING portfolio_id INTO new_id;
        UPDATE public.bulk_portfolio SET portfolio_id = new_id WHERE uuid = rec.uuid;
    END LOOP;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'bulk_portfolio_portfolio_id_fkey'
    ) THEN
        ALTER TABLE public.bulk_portfolio
            ADD CONSTRAINT bulk_portfolio_portfolio_id_fkey
            FOREIGN KEY (portfolio_id) REFERENCES public.portfolio (portfolio_id);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'fills_portfolio_id_fkey'
    ) THEN
        ALTER TABLE public.fills
            ADD CONSTRAINT fills_portfolio_id_fkey
            FOREIGN KEY (portfolio_id) REFERENCES public.portfolio (portfolio_id);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'position_portfolio_id_fkey'
    ) THEN
        ALTER TABLE public.position
            ADD CONSTRAINT position_portfolio_id_fkey
            FOREIGN KEY (portfolio_id) REFERENCES public.portfolio (portfolio_id);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'balance_portfolio_id_fkey'
    ) THEN
        ALTER TABLE public.balance
            ADD CONSTRAINT balance_portfolio_id_fkey
            FOREIGN KEY (portfolio_id) REFERENCES public.portfolio (portfolio_id);
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS bulk_portfolio_portfolio_id_uidx
    ON public.bulk_portfolio (portfolio_id);

COMMENT ON COLUMN public.bulk_portfolio.uuid IS
    'API field uuid. The Coinbase portfolio id. Not portfolio.portfolio_id.';
COMMENT ON COLUMN public.bulk_portfolio.portfolio_id IS
    'Local portfolio.portfolio_id for this Coinbase portfolio. Not the Coinbase uuid.';
COMMENT ON COLUMN public.fills.portfolio_id IS
    'Local portfolio.portfolio_id, not the Coinbase portfolio uuid. Null on older fills; not backfilled.';
COMMENT ON COLUMN public.position.portfolio_id IS
    'Local portfolio.portfolio_id, not the Coinbase portfolio uuid. Null on older positions; not backfilled.';
COMMENT ON COLUMN public.balance.portfolio_id IS
    'Local portfolio.portfolio_id, not the Coinbase portfolio uuid. Null until a load sets it.';
