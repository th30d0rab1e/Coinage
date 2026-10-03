-- Thin cash row. Created because no relation named balance existed.
-- vw_balance stays a view: it prices bulk_currency joined to stock and is
-- not this table. Columns match the cash fields bulk_currency already stores.
CREATE TABLE IF NOT EXISTS public.balance (
    balance_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    portfolio_id text REFERENCES public.bulk_portfolio (uuid),
    currency     text,
    available    double precision,
    hold         double precision,
    balance      double precision,
    updated_at   timestamp without time zone
);

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
