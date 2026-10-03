-- Coinbase brokerage portfolios from GET /api/v3/brokerage/portfolios.
-- Not the local portfolio table. That table is an integer account ledger
-- (portfolio_id, account_id, date_created) and its ids are not Coinbase uuids.
-- Reload with the API uuid as the key so the same portfolio upserts in place.
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
