-- Every COMPLETED USD (fiat) deposit into and withdrawal out of this
-- Coinbase account, i.e. real money moved between the bank and Coinbase.
-- Why: lets the DB answer "how much have I actually put in / taken out"
-- (net invested capital) next to profit_history, without re-reading
-- Coinbase statements.
--
-- Two writers, both GET-only against Coinbase and both
-- INSERT ... ON CONFLICT (type, amount, date) DO NOTHING:
--   * index.js every minute via modules/usdTransferSync.js (new transfers).
--   * node scripts/exportUsdDeposits.js --load-db (full history backfill;
--     safe to re-run any time, e.g. after the bot was down).
-- Dedupe is the UNIQUE (type, amount, date) constraint, so the table stays
-- 4 columns. date is always the Coinbase deposit/withdrawal RECORD's
-- created_at (not the ledger transaction's, which differs by seconds), so
-- both writers produce the identical key for the same transfer. Two real
-- transfers of the same type and amount in the same microsecond are not
-- a realistic case. Canceled / failed transfers are never inserted.
-- Excluded: crypto sends/receives, internal portfolio-to-portfolio moves,
-- and old Coinbase Pro exchange_deposit/withdrawal hops.
--
-- amount is always positive; type says the direction.
-- date follows the DB convention for timestamp without time zone columns
-- (date_created, created_at = now() with DB timezone America/Chicago):
-- Chicago local time.
CREATE TABLE IF NOT EXISTS public.usd_transfer (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    type    text NOT NULL CHECK (type IN ('deposit', 'withdrawal')),
    amount  numeric(14,2) NOT NULL,
    date    timestamp without time zone NOT NULL,
    CONSTRAINT usd_transfer_type_amount_date_key UNIQUE (type, amount, date)
);

COMMENT ON TABLE public.usd_transfer IS
    'Completed USD deposits/withdrawals between the bank and Coinbase (net invested capital). Inserted each minute by index.js (modules/usdTransferSync.js) and backfilled by node scripts/exportUsdDeposits.js --load-db. UNIQUE (type, amount, date) dedupes.';
COMMENT ON COLUMN public.usd_transfer.type IS
    'deposit = money in from the bank, withdrawal = money out to the bank.';
COMMENT ON COLUMN public.usd_transfer.amount IS
    'USD, always positive. Direction comes from type.';
COMMENT ON COLUMN public.usd_transfer.date IS
    'When Coinbase created the deposit/withdrawal, America/Chicago local time (same convention as date_created / created_at).';
