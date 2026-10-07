-- 2026-10-07: buy ETFs with USDC where Coinbase allows it (Theodore:
-- "lets mark which stocks can use usdc. And the ones we can use usdc with
-- will use it. and the ones that cant will buy with usd.").
--
-- Why this works: Coinbase lists most equities twice in
-- GET /api/v3/brokerage/products?product_type=EQUITY, once quoted in USD
-- (etf.product_id, alias = '') and once quoted in USDC whose alias field
-- points at the USD product (same unified order book, like BTC-USDC ->
-- BTC-USD). An order sent on the USDC product id is paid in USDC; an order on
-- the USD product id is paid in USD. There is no "pay with" option on the
-- order itself -- the product id picks the currency.
--
-- What this migration does:
--   1. etf.usdc_product_id: the USDC-quoted product id per ticker, or NULL
--      when Coinbase has no USDC version (TOPW, checked twice 2026-10-07
--      across all 16,380 EQUITY products). NULL = buy with USD as before.
--   2. etf_buy.quote_currency / etf_buy.product_id: which currency paid for
--      each attempt and which product id the order went to, so a USDC buy can
--      be verified later (USDC available drops and product_id = usdc id).
--      Rows before this migration stay NULL (they were all USD).
--   3. config.etf_usdc_fallback_usd = 'true': when a USDC-capable ETF is due
--      but spendable USDC is short, buy it on the USD product with USD instead
--      (so ETF buying does not stall while USDC is near $0). 'false' = skip
--      that ETF this minute instead.
--
-- Each id below was verified 2026-10-07 with GET /api/v3/brokerage/products/{id}:
-- product_type EQUITY, quote_currency_id USDC, ticker matches, alias equals
-- that ticker's current etf.product_id (USD), not disabled / view-only /
-- cancel-only, fractionable, not liquidate_only, $1 fractional minimum.
-- The UPDATE re-checks the USD id too, so a ticker whose USD product id ever
-- changed is left NULL (USD) instead of being paired with a stale USDC id.

BEGIN;

ALTER TABLE public.etf ADD COLUMN IF NOT EXISTS usdc_product_id text;

COMMENT ON COLUMN public.etf.usdc_product_id IS
    'USDC-quoted EQUITY product id for this ticker (its alias = product_id). When set, index.js buys on this id and pays with USDC (falls back to product_id / USD when USDC is short and config.etf_usdc_fallback_usd = true). NULL = Coinbase has no USDC version; buy with USD.';

UPDATE public.etf AS e
SET usdc_product_id = v.usdc_id
FROM (VALUES
    ('BLOX', 'b00c6138f30e9f64073251d311d38324de73a36acfd22867427b293adc143d3c', 'a913301d95c37471be8f8945b05724718eefc66900c02992641dd3e0f76af146'),
    ('CHPY', '6aa416c41dd7b2ecfc474bc5d269d526fc3895f51c492b4116f4a63101665dde', '800af25dfaeb6d71d43a1033f67c2f225d674e58f272e4815a7aa9ba8205ac7c'),
    ('YBTC', '4ca13a26f0e64dadd796f2fe82d931adf81732b6bd95a267cba0623a8a03e263', 'c4f0ef739dbfc626d7be04f892aeb6fb647c605d481d5df042c48e720ac2b770'),
    ('SPCX', 'd0484aeacc93f88a18b0431b8d2aac6efededa3b203ff4b55c72b64805aa5a2e', 'ed1f01897dcd14d8e9a30890288cfd1c547dcbe5072a64f236111d8dc7a4a238'),
    ('TSLW', 'c14a9c069c5b045e2fbff2f79d2cd08884a1ebec246add36b1f34261f0970d8d', '2a2a7875834e6fcdc58dfccdd9ae7d2043562e5bd92813f4e5e8ce577e6780bd'),
    ('XDTE', '3bfc825072c7a8645061361abb3e4bc6ca1752223580e3acbe603b6a02a42bd2', '7b3c77e81cb825c72408c4911cf1c686c80acac42ae09b9b53e02e2f2d711075')
    -- TOPW (b05be8d4...): no USDC product on Coinbase -> stays NULL (USD).
) AS v (ticker, usd_id, usdc_id)
WHERE e.ticker = v.ticker
  AND e.product_id = v.usd_id;

ALTER TABLE public.etf_buy ADD COLUMN IF NOT EXISTS quote_currency text;
ALTER TABLE public.etf_buy ADD COLUMN IF NOT EXISTS product_id text;

COMMENT ON COLUMN public.etf_buy.quote_currency IS
    'Currency that paid for this attempt: USD (etf.product_id) or USDC (etf.usdc_product_id). NULL on rows before 2026-10-07 (all USD).';
COMMENT ON COLUMN public.etf_buy.product_id IS
    'Coinbase product id the order was sent to (the USD or the USDC product of the ticker). NULL on rows before 2026-10-07 (all etf.product_id).';

INSERT INTO public.config (key, value) VALUES ('etf_usdc_fallback_usd', 'true')
ON CONFLICT (key) DO NOTHING;

COMMIT;
