-- 2026-10-03: Coinbase portfolios, plus a nullable local portfolio_id on
-- fills, position, and balance. portfolio_id is portfolio.portfolio_id
-- (integer identity), not the Coinbase uuid. The uuid column is the API
-- field. Existing fills and positions stay null. Nothing is backfilled.
-- Idempotent. 2026-10-03_portfolio_id_local.sql corrects a first version
-- that pointed these foreign keys at bulk_portfolio.uuid.

CREATE TABLE IF NOT EXISTS public.bulk_portfolio (
    uuid            text PRIMARY KEY,
    name            text,
    type            text,
    deleted         boolean,
    subaccount_uuid text,
    -- Local portfolio.portfolio_id. Not the Coinbase uuid (that is uuid).
    portfolio_id    integer REFERENCES public.portfolio (portfolio_id),
    loaded_at       timestamp without time zone NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.bulk_portfolio IS
    'Coinbase List Portfolios snapshot. Not the local portfolio table.';
COMMENT ON COLUMN public.bulk_portfolio.uuid IS
    'API field uuid. The Coinbase portfolio id. Not portfolio.portfolio_id.';
COMMENT ON COLUMN public.bulk_portfolio.portfolio_id IS
    'Local portfolio.portfolio_id for this Coinbase portfolio. Not the Coinbase uuid.';
COMMENT ON COLUMN public.bulk_portfolio.name IS
    'API field name. Display name returned by List Portfolios.';
COMMENT ON COLUMN public.bulk_portfolio.type IS
    'API field type. How Coinbase classifies the portfolio (DEFAULT, CONSUMER).';
COMMENT ON COLUMN public.bulk_portfolio.deleted IS
    'API field deleted. True when Coinbase has marked the portfolio deleted.';
COMMENT ON COLUMN public.bulk_portfolio.subaccount_uuid IS
    'API field subaccount_uuid. Empty when this portfolio is not a subaccount.';
COMMENT ON COLUMN public.bulk_portfolio.loaded_at IS
    'When this row was last upserted from the portfolios API. Not a Coinbase field.';

-- Coinbase portfolio uuid. Nullable so rows that predate this column stay valid.
-- Not backfilled. Foreign key is safe because every existing value is null.
ALTER TABLE public.fills ADD COLUMN IF NOT EXISTS portfolio_id integer;
ALTER TABLE public.position ADD COLUMN IF NOT EXISTS portfolio_id integer;

COMMENT ON COLUMN public.fills.portfolio_id IS
    'Local portfolio.portfolio_id, not the Coinbase portfolio uuid. Null on older fills; not backfilled.';
COMMENT ON COLUMN public.position.portfolio_id IS
    'Local portfolio.portfolio_id, not the Coinbase portfolio uuid. Null on older positions; not backfilled.';

DO $$
BEGIN
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
END $$;

-- No relation named balance existed (vw_balance is a view and is not replaced).
CREATE TABLE IF NOT EXISTS public.balance (
    balance_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    portfolio_id integer,
    currency     text,
    available    double precision,
    hold         double precision,
    balance      double precision,
    updated_at   timestamp without time zone
);

ALTER TABLE public.balance ADD COLUMN IF NOT EXISTS portfolio_id integer;

COMMENT ON TABLE public.balance IS
    'Cash by currency. Not vw_balance, which is a priced view of bulk_currency.';
COMMENT ON COLUMN public.balance.balance_id IS
    'Surrogate key. Identity so inserts do not have to supply it.';
COMMENT ON COLUMN public.balance.portfolio_id IS
    'Local portfolio.portfolio_id, not the Coinbase portfolio uuid. Null until a load sets it.';
COMMENT ON COLUMN public.balance.currency IS
    'Asset code, same meaning as bulk_currency.currency (USD, USDC, a coin).';
COMMENT ON COLUMN public.balance.available IS
    'Spendable amount, same meaning as bulk_currency.available.';
COMMENT ON COLUMN public.balance.hold IS
    'Amount on hold, same meaning as bulk_currency.hold.';
COMMENT ON COLUMN public.balance.balance IS
    'Total amount, same meaning as bulk_currency.balance.';
COMMENT ON COLUMN public.balance.updated_at IS
    'When this cash row was last written. Not filled by the portfolio load.';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'balance_portfolio_id_fkey'
    ) THEN
        ALTER TABLE public.balance
            ADD CONSTRAINT balance_portfolio_id_fkey
            FOREIGN KEY (portfolio_id) REFERENCES public.portfolio (portfolio_id);
    END IF;
END $$;

-- Email was not on account. Nullable so the existing account row stays valid.
ALTER TABLE public.account ADD COLUMN IF NOT EXISTS email text;

COMMENT ON COLUMN public.account.email IS
    'Email for this account. Nullable so the original row did not need a value.';

-- The darthtlc row was added, then removed on purpose. Re-running must not recreate it.
-- Only that email is deleted. Account 1 has a null email, so it is not matched.
DELETE FROM public.account
WHERE email = 'darthtlc@gmail.com';
