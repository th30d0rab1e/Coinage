-- 2026-10-03: drop etf_buy. Whether an ETF (or anything else) was already
-- bought today is a fills query: side BUY and trade_time on today's
-- America/Chicago date. No replacement ledger.
-- The index and the foreign key to etf drop with the table. etf stays.
-- vw_etf_cash_reserve does not read etf_buy (it is a constant 0).
DROP TABLE IF EXISTS public.etf_buy;
