-- 2026-10-04: ETF dip rules and a cash reserve that crypto planning can see.
--
-- is_special marks BLOX, CHPY, TOPW, and TSLW. They keep the special
-- repeat rule (later same-day buy when price < last fill, all of them
-- in one minute, plus a 2:45-3:00 PM Chicago catch-up). XDTE is inserted
-- as a regular so it does not inherit those rules: its later buy needs
-- a 1% dip, and only one regular is attempted per minute.
--
-- etf_usd_reserve is written by index.js immediately before thee_procedure.
-- It is the quote USD of attempts this run will actually send: session
-- open, dip rules passed, not already filled, and not skipped because
-- Default cash cannot cover them. The view exposes that number. A filled
-- ETF is not included, because its dollars are already out of the USD
-- balance. A skipped-for-cash ETF is not included either, so those
-- dollars are not held back twice.
--
-- Idempotent.

ALTER TABLE public.etf
    ADD COLUMN IF NOT EXISTS is_special boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.etf.is_special IS
    'True for BLOX, CHPY, TOPW, TSLW (special repeat and end-of-session catch-up). False for regulars such as XDTE, which need a 1% dip and only one attempt per minute.';

COMMENT ON COLUMN public.etf.quote_usd IS
    'Quote USD notional for one market buy. Default $1. Not a share count.';

COMMENT ON TABLE public.etf IS
    'Equity ETFs bought on the Coinbase NORMAL session under dip rules. is_special selects the repeat rule.';

UPDATE public.etf
SET is_special = true
WHERE ticker IN ('BLOX', 'CHPY', 'TOPW', 'TSLW');

INSERT INTO public.etf (ticker, product_id, quote_usd, enabled, is_special)
VALUES (
    'XDTE',
    '3bfc825072c7a8645061361abb3e4bc6ca1752223580e3acbe603b6a02a42bd2',
    1,
    true,
    false
)
ON CONFLICT (ticker) DO UPDATE
SET product_id = EXCLUDED.product_id,
    quote_usd = EXCLUDED.quote_usd,
    enabled = EXCLUDED.enabled,
    is_special = EXCLUDED.is_special;

ALTER TABLE public.etf_buy
    ADD COLUMN IF NOT EXISTS dip_price numeric,
    ADD COLUMN IF NOT EXISTS fill_price numeric;

COMMENT ON COLUMN public.etf_buy.dip_price IS
    'Live price the dip rule compared. Null when the attempt did not need a price (no shares held yet, or the special 2:45 PM Chicago catch-up).';

COMMENT ON COLUMN public.etf_buy.fill_price IS
    'Execution price from filled value / filled size. The next same-day dip uses the latest non-null value. Null when size was not returned.';

COMMENT ON TABLE public.etf_buy IS
    'ETF buy attempts. filled = true counts for the Chicago-day dip rules. A closed-market reject or zero fill stays filled = false and does not count.';

-- Absent means no reserve. index.js overwrites this every run.
INSERT INTO public.config (key, value) VALUES ('etf_usd_reserve', '0')
ON CONFLICT (key) DO NOTHING;

-- Not the sum of every enabled quote. That would reserve a ticker the
-- dip rules will skip, and would reserve a ticker already skipped for cash.
CREATE OR REPLACE VIEW public.vw_etf_cash_reserve AS
SELECT COALESCE(
    (SELECT value::numeric FROM public.config WHERE key = 'etf_usd_reserve'),
    0
) AS reserve_usd;

COMMENT ON VIEW public.vw_etf_cash_reserve IS
    'Default USD index.js reserved for this run''s ETF attempts. thee_procedure subtracts it from crypto buy plans. 0 when the equity session is closed or nothing qualifies.';
