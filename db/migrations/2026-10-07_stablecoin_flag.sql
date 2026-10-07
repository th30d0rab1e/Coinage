-- 2026-10-07: never BUY stablecoins (Theodore).
--
-- Why: the bot had bought USDS, USD1 and PAX like any other coin (they sit at
-- ~$1 and barely move, so they only tie up cash and fees) and later left them
-- as untracked holdings that tripped the hourly health check. Coinbase does
-- not label stablecoins anywhere (no field in the Advanced Trade products
-- API; the Exchange currencies list leaves their category tags empty), so the
-- flag is derived from PRICE BEHAVIOR in the products feed the bot already
-- pulls every minute (price, high_24h, low_24h):
--     price within stablecoin_price_band_pct (3%) of $1, i.e. 0.97 .. 1.03
--     AND (high_24h - low_24h) / price < stablecoin_max_range_pct (2%)
-- On 2026-10-07 live data this matched exactly USDT, USD1, USDS, PAX, DAI out
-- of 404 USD pairs.
--
-- STICKY: thee_procedure only ever sets is_stablecoin = TRUE, it never clears
-- it. A stablecoin can briefly de-peg or spike on thin books (PAX printed
-- $1.83 on 2026-09-27); that day it would fail the rule, and an auto-clear
-- would make it buyable again. To un-flag a coin, set it FALSE by hand.
--
-- Additive only: one column (default false), two config keys.

-- 1) stock.is_stablecoin
ALTER TABLE public.stock
    ADD COLUMN IF NOT EXISTS is_stablecoin boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.stock.is_stablecoin IS
    'TRUE = behaves like a $1 stablecoin (price within config.stablecoin_price_band_pct of $1 and 24h high-low range under config.stablecoin_max_range_pct of price, from the Coinbase products feed). Set by thee_procedure, sticky (never auto-cleared). Every buy INSERT in thee_procedure skips these coins.';

-- 2) config: the two thresholds, in percent (thee_procedure COALESCEs to these
--    same defaults if a key is missing).
INSERT INTO public.config (key, value) VALUES
    ('stablecoin_price_band_pct', '3'),   -- price must be within 3% of $1.00
    ('stablecoin_max_range_pct',  '2')    -- 24h (high - low) / price under 2%
ON CONFLICT (key) DO NOTHING;
