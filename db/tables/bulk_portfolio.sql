-- Coinbase brokerage portfolios from GET /api/v3/brokerage/portfolios.
-- uuid is the API field, the Coinbase portfolio id. It is not the link to
-- the local portfolio table. portfolio_id is portfolio.portfolio_id, an
-- integer identity, and that is the row this download belongs to.
CREATE TABLE IF NOT EXISTS public.bulk_portfolio (
    uuid            text PRIMARY KEY,
    name            text,
    type            text,
    deleted         boolean,
    subaccount_uuid text,
    portfolio_id    integer REFERENCES public.portfolio (portfolio_id),
    loaded_at       timestamp without time zone NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.bulk_portfolio IS
    'Coinbase List Portfolios snapshot. uuid is the Coinbase id. portfolio_id is the local portfolio row.';
COMMENT ON COLUMN public.bulk_portfolio.uuid IS
    'API field uuid. The Coinbase portfolio id. Not portfolio.portfolio_id.';
COMMENT ON COLUMN public.bulk_portfolio.name IS
    'API field name. Display name returned by List Portfolios.';
COMMENT ON COLUMN public.bulk_portfolio.type IS
    'API field type. How Coinbase classifies the portfolio (DEFAULT, CONSUMER).';
COMMENT ON COLUMN public.bulk_portfolio.deleted IS
    'API field deleted. True when Coinbase has marked the portfolio deleted.';
COMMENT ON COLUMN public.bulk_portfolio.subaccount_uuid IS
    'API field subaccount_uuid. Empty when this portfolio is not a subaccount.';
COMMENT ON COLUMN public.bulk_portfolio.portfolio_id IS
    'Local portfolio.portfolio_id for this Coinbase portfolio. Not the Coinbase uuid.';
COMMENT ON COLUMN public.bulk_portfolio.loaded_at IS
    'When this row was last upserted from the portfolios API. Not a Coinbase field.';
