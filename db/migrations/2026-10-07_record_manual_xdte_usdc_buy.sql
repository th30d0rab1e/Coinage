-- 2026-10-07: record Theodore's MANUAL XDTE buy in etf_buy, at his request,
-- so the bot tracks it like its own ETF buys. Not placed by the bot: he
-- bought it by hand in Coinbase Advanced (order_placement_source
-- RETAIL_ADVANCED) on the XDTE USDC product, before the USDC ETF build.
--
-- Values come from Coinbase, not the log (GET /orders/historical/{id} and
-- /orders/historical/fills?order_ids=..., read 2026-10-07):
--   order 44e758fd-1759-450e-9cc2-4098f3a7de1b, client b5688760-77c6-48da-ba93-da5ec2bb0081
--   product 7b3c77e8... (XDTE, quote USDC), MARKET IOC quote_size 3.17
--   FILLED: filled_size 0.08193 shares, filled_value 3.17 USDC,
--   average_filled_price 38.6877, total_fees 0,
--   created 2026-10-07 15:22:53.106888Z (10:22:53 AM CT), one fill at 15:22:53.458Z.
--   NOTE: the fill's "size 3.17" is the quote amount (size_in_quote = true),
--   i.e. $3.17 for 0.08193 shares -- not 3.17 shares / ~$122.
--   The USDC wallet ledger shows "simple_equity_settlement -3.17 USDC" at
--   15:22:55Z and USD stayed $0.70, so this USDC-product order was paid in USDC.
--
-- Recorded exactly like placeEtfMarket/recordEtfAttempt records a filled
-- daily market buy (order_type 'market', status 'FILLED', filled true,
-- quote_usd = filled quote, fill_price = VWAP, error_message NULL,
-- base_size / closed_at NULL as on bot market rows), plus quote_currency
-- 'USDC' and product_id = the USDC product.
-- Effects: XDTE's daily $1 market buy for 2026-10-07 counts as done (this
-- $3.17 replaces it, so no extra market buy today); the limit ladder steps
-- from this fill (latestBuyFill reads both XDTE product ids); the
-- unmatched-fill check skips orders on etf_buy (it had already stopped
-- re-logging after the first 90 s; unmatched_fills row 350 is kept as history).
-- Idempotent: inserts nothing if the order id is already on etf_buy.

BEGIN;

INSERT INTO public.etf_buy
    (ticker, chicago_date, quote_usd, filled, closed_session, coinbase_order_id, client_order_id,
     error_message, dip_price, fill_price, order_type, status, created_at, quote_currency, product_id)
SELECT 'XDTE', DATE '2026-10-07', 3.17, true, false,
       '44e758fd-1759-450e-9cc2-4098f3a7de1b', 'b5688760-77c6-48da-ba93-da5ec2bb0081',
       NULL, NULL, 38.6877, 'market', 'FILLED',
       -- created_at is CT wall time (timestamp without time zone), like bot rows.
       TIMESTAMP '2026-10-07 10:22:53.106888',
       'USDC', '7b3c77e81cb825c72408c4911cf1c686c80acac42ae09b9b53e02e2f2d711075'
WHERE NOT EXISTS (
    SELECT 1 FROM public.etf_buy WHERE coinbase_order_id = '44e758fd-1759-450e-9cc2-4098f3a7de1b'
);

COMMIT;
