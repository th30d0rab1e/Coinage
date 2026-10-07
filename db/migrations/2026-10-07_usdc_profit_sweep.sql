-- 2026-10-07: sweep realized trading profit from USD into USDC (Theodore).
--
-- What it does: every close records how much of its profit should be moved
-- to USDC (position.profit_converted_usdc, carried into
-- profit_history.profit_converted_usdc when the row moves). index.js
-- sweepProfitToUsdc() runs each minute after thee_procedure: once the
-- unswept total reaches config.usdc_sweep_min_usd it converts exactly that
-- many dollars USD -> USDC (modules/convert.js: quote, sanity check,
-- commit, poll). The conversion state lives directly on the swept
-- profit_history rows (no separate log table, per Theodore):
--
--   usdc_convert_status   NULL        = not swept yet
--                         'pending'   = claimed by an in-flight conversion
--                         'completed' = Coinbase reported the convert done
--                         'failed'    = attempt failed; retried next minute
--                                       (its trade is re-checked first)
--   usdc_convert_trade_id Coinbase convert trade id of the latest attempt.
--                         Written right BEFORE the commit is sent, so
--                         pending + trade id = commit sent (or about to be).
--   usdc_converted_at     when Coinbase confirmed the convert (completed)
--
-- Until a row is 'completed', the buy gates in thee_procedure and the ETF
-- plan treat its profit as reserved (vw_usdc_sweep_reserve), so the bot
-- does not spend it.
--
-- Why USDC: the bot only spends USD (vw_balance name = 'USD'), so profit
-- parked in USDC is out of the trading loop. It stays cash (1:1, convertible
-- back any time with scripts/convert.js usdc-to-usd).
--
-- Additive. Existing profit_history rows keep profit_converted_usdc NULL,
-- so they are never swept: only closes from this migration on count.

-- 0) Clean-up of the first version of this migration (applied briefly on
--    2026-10-07 08:08 CT, never used: 0 rows). It had a separate
--    usdc_convert log table and a profit_history.usdc_convert_id link;
--    Theodore asked for the state on profit_history instead. The view is
--    dropped first because it read usdc_convert_id; it is recreated from
--    db/views/vw_usdc_sweep_reserve.sql. No-ops on a fresh database.
DROP VIEW IF EXISTS public.vw_usdc_sweep_reserve;
DROP INDEX IF EXISTS public.profit_history_unswept;
ALTER TABLE public.profit_history DROP COLUMN IF EXISTS usdc_convert_id;
DROP TABLE IF EXISTS public.usdc_convert;

-- 1) Per-close amount to sweep. NULL = not computed yet (thee_procedure
--    will not move/delete a closed position until it is filled in).
ALTER TABLE public.position
    ADD COLUMN IF NOT EXISTS profit_converted_usdc numeric;
ALTER TABLE public.profit_history
    ADD COLUMN IF NOT EXISTS profit_converted_usdc numeric;

-- 2) Conversion state on profit_history.
ALTER TABLE public.profit_history
    ADD COLUMN IF NOT EXISTS usdc_convert_status   text,
    ADD COLUMN IF NOT EXISTS usdc_convert_trade_id text,
    ADD COLUMN IF NOT EXISTS usdc_converted_at     timestamptz;

ALTER TABLE public.profit_history
    DROP CONSTRAINT IF EXISTS profit_history_usdc_convert_status_check;
ALTER TABLE public.profit_history
    ADD CONSTRAINT profit_history_usdc_convert_status_check
    CHECK (usdc_convert_status IS NULL
           OR usdc_convert_status IN ('pending', 'completed', 'failed'));

-- Rows the sweep still has to move (everything not completed).
CREATE INDEX IF NOT EXISTS profit_history_usdc_unswept
    ON public.profit_history (profit_history_id)
    WHERE profit_converted_usdc > 0
    AND usdc_convert_status IS DISTINCT FROM 'completed';

COMMENT ON COLUMN public.position.profit_converted_usdc IS
    'Net profit to sweep to USDC: GREATEST(0, TRUNC((sell_filled_price*shares - sell_fee) - (buy_filled_price*shares + buy_fee), 2)). Fees are the summed fill commissions. Losses = 0. Set by thee_procedure; the close-out waits for it.';
COMMENT ON COLUMN public.profit_history.profit_converted_usdc IS
    'Copied from position at close. Swept to USDC by index.js sweepProfitToUsdc().';
COMMENT ON COLUMN public.profit_history.usdc_convert_status IS
    'USDC sweep state: NULL = not swept yet, pending = in an in-flight convert, completed = converted, failed = retried next minute.';
COMMENT ON COLUMN public.profit_history.usdc_convert_trade_id IS
    'Coinbase convert trade id of the latest sweep attempt (set just before commit).';
COMMENT ON COLUMN public.profit_history.usdc_converted_at IS
    'When Coinbase confirmed the USD -> USDC convert for this row.';

-- 3) Config: kill switch and minimum sweep size. Coinbase accepted a $0.25
--    USD->USDC quote on 2026-10-07, so its convert minimum is below $1 and
--    $1.00 is the binding minimum.
INSERT INTO public.config (key, value) VALUES
    ('usdc_sweep_enabled', 'true'),
    ('usdc_sweep_min_usd', '1.00')
ON CONFLICT (key) DO NOTHING;
