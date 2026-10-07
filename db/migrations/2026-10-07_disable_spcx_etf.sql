-- 2026-10-07: take SPCX (SpaceX common stock) out of the bot's ETF buying.
-- Theodore: "can we take out spcx from the etf's?"
--
-- Reversible disable, not a delete: etf.enabled already exists and every
-- ETF code path reads only enabled rows --
--   index.js buildEtfPlan()        SELECT ... FROM etf WHERE enabled  (no daily
--                                  market buy, no new ladder limit, no ETF reserve)
--   modules/alpacaMarketData.js    SELECT ticker FROM etf WHERE enabled  (stops the
--                                  per-minute IEX price sync into stock.price for SPCX)
-- The etf row, its product ids, and all etf_buy history are kept (etf_buy
-- has a FK to etf.ticker, so the row must stay anyway).
--
-- Not affected on purpose:
--   * SPCX shares already held stay where they are (nothing sells ETFs).
--   * A resting SPCX limit already on etf_buy (status OPEN) is still walked
--     by index.js syncEtfLimitOrders(), which reads OPEN rows for every
--     ticker: a fill is still recorded, and the bot's own TTL still cancels
--     it at etf_buy.expires_at. Nothing re-places or remakes it, because
--     new placements only come from enabled rows.
--   * vw_position_order_balance_audit keeps recognizing that open order by
--     its id on an unfilled etf_buy row, so it is not flagged as untracked.
--     Equity shares are not in bulk_currency, so the audit never lists ETF
--     holdings either way.
--
-- Re-enable: UPDATE public.etf SET enabled = true WHERE ticker = 'SPCX';

BEGIN;

UPDATE public.etf SET enabled = false WHERE ticker = 'SPCX';

COMMENT ON COLUMN public.etf.enabled IS
    'false = the bot neither buys this ticker (no daily market buy, no new ladder limit) nor syncs its IEX price. History and any already-resting limit stay tracked. SPCX disabled 2026-10-07 at Theodore''s request; re-enable with UPDATE etf SET enabled = true.';

COMMIT;
