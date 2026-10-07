-- 2026-10-07: sweep realized trading profit from USD into USDC (Theodore).
--
-- What it does: every close records how much of its profit should be moved
-- to USDC (position.profit_converted_usdc, carried into
-- profit_history.profit_converted_usdc when the row moves). index.js
-- sweepProfitToUsdc() runs each minute after thee_procedure: once the
-- unswept total reaches config.usdc_sweep_min_usd it converts exactly that
-- many dollars USD -> USDC (modules/convert.js: quote, sanity check,
-- commit, poll), logs the attempt in usdc_convert, and on success stamps the
-- swept profit_history rows with usdc_convert_id. Until a row is swept, the
-- buy gates in thee_procedure and the ETF plan treat its profit as reserved
-- (vw_usdc_sweep_reserve), so the bot does not spend it.
--
-- Why USDC: the bot only spends USD (vw_balance name = 'USD'), so profit
-- parked in USDC is out of the trading loop. It stays cash (1:1, convertible
-- back any time with scripts/convert.js usdc-to-usd).
--
-- Additive only. Existing profit_history rows keep profit_converted_usdc
-- NULL, so they are never swept: only closes from this migration on count.

-- 1) Log of every sweep attempt. Created first because profit_history
--    references it.
--    status:
--      pending   = row inserted, commit NOT sent yet (safe to fail later)
--      submitted = commit call sent to Coinbase; outcome must come from
--                  Coinbase (never auto-failed unless Coinbase says so)
--      success   = Coinbase reported TRADE_STATUS_COMPLETED
--      failed    = refused / errored / canceled; profit rows NOT stamped,
--                  so the next minute retries them
CREATE TABLE IF NOT EXISTS public.usdc_convert (
    id                 serial PRIMARY KEY,
    amount_usd         numeric NOT NULL,             -- exact USD sent (sum of the swept rows)
    usdc_received      numeric,                      -- USDC credited, from Coinbase's trade
    coinbase_trade_id  text,                         -- convert trade id from the quote
    status             text NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending', 'submitted', 'success', 'failed')),
    error              text,
    profit_history_ids integer[] NOT NULL,           -- exactly which rows this attempt covers
    created_at         timestamptz NOT NULL DEFAULT now(),
    completed_at       timestamptz
);

-- At most ONE unfinished sweep at a time (second guard after the advisory
-- lock in index.js): a cycle that overlaps the previous one cannot insert a
-- second pending/submitted row, so the same profit can never be swept twice.
CREATE UNIQUE INDEX IF NOT EXISTS usdc_convert_one_open
    ON public.usdc_convert ((true))
    WHERE status IN ('pending', 'submitted');

-- 2) Per-close amount to sweep. NULL = not computed yet (thee_procedure
--    will not move/delete a closed position until it is filled in).
ALTER TABLE public.position
    ADD COLUMN IF NOT EXISTS profit_converted_usdc numeric;
ALTER TABLE public.profit_history
    ADD COLUMN IF NOT EXISTS profit_converted_usdc numeric;

-- 3) Which sweep took this row's profit (NULL = not swept yet).
ALTER TABLE public.profit_history
    ADD COLUMN IF NOT EXISTS usdc_convert_id integer REFERENCES public.usdc_convert (id);

CREATE INDEX IF NOT EXISTS profit_history_unswept
    ON public.profit_history (profit_history_id)
    WHERE usdc_convert_id IS NULL AND profit_converted_usdc > 0;

COMMENT ON COLUMN public.position.profit_converted_usdc IS
    'Net profit to sweep to USDC: GREATEST(0, TRUNC((sell_filled_price*shares - sell_fee) - (buy_filled_price*shares + buy_fee), 2)). Fees are the summed fill commissions. Losses = 0. Set by thee_procedure; the close-out waits for it.';
COMMENT ON COLUMN public.profit_history.profit_converted_usdc IS
    'Copied from position at close. Swept to USDC by index.js sweepProfitToUsdc().';
COMMENT ON COLUMN public.profit_history.usdc_convert_id IS
    'usdc_convert row that swept this profit to USDC. NULL = still waiting (counted by vw_usdc_sweep_reserve).';

-- 4) Config: kill switch and minimum sweep size. Coinbase accepted a $0.25
--    USD->USDC quote on 2026-10-07, so its convert minimum is below $1 and
--    $1.00 is the binding minimum.
INSERT INTO public.config (key, value) VALUES
    ('usdc_sweep_enabled', 'true'),
    ('usdc_sweep_min_usd', '1.00')
ON CONFLICT (key) DO NOTHING;
