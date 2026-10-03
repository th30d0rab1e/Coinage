-- 2026-10-03: Coinbase portfolios, plus a nullable portfolio uuid on the
-- tables that will eventually say which portfolio a fill, position, or
-- cash row came from. Existing rows stay null. Nothing is backfilled.
-- Idempotent. The local portfolio table is untouched: its integer
-- portfolio_id is not a Coinbase uuid, so these columns do not reference it.

CREATE TABLE IF NOT EXISTS public.bulk_portfolio (
    uuid            text PRIMARY KEY,
    name            text,
    type            text,
    deleted         boolean,
    subaccount_uuid text,
    loaded_at       timestamp without time zone NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.bulk_portfolio IS
    'Coinbase List Portfolios snapshot. Not the local portfolio table.';
COMMENT ON COLUMN public.bulk_portfolio.uuid IS
    'API field uuid. Coinbase portfolio id and primary key.';
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
ALTER TABLE public.fills ADD COLUMN IF NOT EXISTS portfolio_id text;
ALTER TABLE public.position ADD COLUMN IF NOT EXISTS portfolio_id text;

COMMENT ON COLUMN public.fills.portfolio_id IS
    'Coinbase portfolio uuid (bulk_portfolio.uuid), not local portfolio.portfolio_id. Null on older fills; not backfilled.';
COMMENT ON COLUMN public.position.portfolio_id IS
    'Coinbase portfolio uuid (bulk_portfolio.uuid), not local portfolio.portfolio_id. Null on older positions; not backfilled.';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'fills_portfolio_id_fkey'
    ) THEN
        ALTER TABLE public.fills
            ADD CONSTRAINT fills_portfolio_id_fkey
            FOREIGN KEY (portfolio_id) REFERENCES public.bulk_portfolio (uuid);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'position_portfolio_id_fkey'
    ) THEN
        ALTER TABLE public.position
            ADD CONSTRAINT position_portfolio_id_fkey
            FOREIGN KEY (portfolio_id) REFERENCES public.bulk_portfolio (uuid);
    END IF;
END $$;

-- No relation named balance existed (vw_balance is a view and is not replaced).
CREATE TABLE IF NOT EXISTS public.balance (
    balance_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    portfolio_id text,
    currency     text,
    available    double precision,
    hold         double precision,
    balance      double precision,
    updated_at   timestamp without time zone
);

ALTER TABLE public.balance ADD COLUMN IF NOT EXISTS portfolio_id text;

COMMENT ON TABLE public.balance IS
    'Cash by currency. Not vw_balance, which is a priced view of bulk_currency.';
COMMENT ON COLUMN public.balance.balance_id IS
    'Surrogate key. Identity so inserts do not have to supply it.';
COMMENT ON COLUMN public.balance.portfolio_id IS
    'Coinbase portfolio uuid (bulk_portfolio.uuid), not local portfolio.portfolio_id. Null until a load sets it.';
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
            FOREIGN KEY (portfolio_id) REFERENCES public.bulk_portfolio (uuid);
    END IF;
END $$;

-- Email was not on account. Nullable so the existing account row stays valid.
ALTER TABLE public.account ADD COLUMN IF NOT EXISTS email text;

COMMENT ON COLUMN public.account.email IS
    'Email for this account. Nullable so the original row did not need a value.';

-- One row for this address. Re-running does not insert a second one.
-- date_created is left null: the column is nullable and has no default to override.
INSERT INTO public.account (email)
SELECT 'darthtlc@gmail.com'
WHERE NOT EXISTS (
    SELECT 1 FROM public.account WHERE email = 'darthtlc@gmail.com'
);
