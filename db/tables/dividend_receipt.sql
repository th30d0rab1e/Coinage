-- 2026-10-11: dividends (and any other positive equity cash credit) that
-- Coinbase actually paid into Cash (USD) / USDC. One row per Coinbase v2
-- ledger transaction (coinbase_txn_id UNIQUE = never stored twice).
-- Writer: modules/dividendAlerts.js (every 5 minutes from index.js).
-- Coinbase gives amount + time but NO ticker: ticker/rate/ex/pay dates are
-- matched from Alpaca's cash_dividend calendar against ETFs held on the
-- ex-date. kind = 'dividend' when matched (or Coinbase labels it a
-- dividend), 'equity_credit' when nothing matched.
CREATE TABLE IF NOT EXISTS public.dividend_receipt (
    dividend_receipt_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    coinbase_txn_id      text NOT NULL UNIQUE,
    currency             text NOT NULL,          -- USD or USDC (account credited)
    ledger_type          text NOT NULL,          -- e.g. simple_equity_settlement
    amount               numeric NOT NULL,       -- cash received (> 0)
    received_at          timestamptz NOT NULL,   -- Coinbase created_at
    kind                 text NOT NULL,          -- dividend | equity_credit
    ticker               text,                   -- matched ETF, NULL if unknown
    rate                 numeric,                -- $/share from the calendar
    est_shares           numeric,                -- shares held before ex_date (from fills)
    ex_date              date,
    pay_date             date,
    match_note           text,                   -- how the ticker was chosen
    pushover_notified_at timestamptz,            -- alert claimed/sent; NULL = pending
    created_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS dividend_receipt_pushover_unsent
    ON public.dividend_receipt (dividend_receipt_id)
 WHERE pushover_notified_at IS NULL;
