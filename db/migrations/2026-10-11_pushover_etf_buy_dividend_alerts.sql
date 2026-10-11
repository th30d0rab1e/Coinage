-- 2026-10-11: Pushover alerts for confirmed ETF buy fills and for dividends
-- received (Theodore). Uses the same pushover_app_token / pushover_user_key
-- / pushover_user_key_2 as the profit-close alerts.
--   modules/sendEtfBuyNotifications.js  -> etf_buy.pushover_notified_at
--   modules/dividendAlerts.js           -> dividend_receipt (new table)
-- Additive only; nothing that places/cancels orders reads these columns.

-- ETF buys --------------------------------------------------------------
ALTER TABLE etf_buy ADD COLUMN IF NOT EXISTS pushover_notified_at timestamptz;
-- Live Coinbase equity session the order was placed in (written by
-- index.js from 2026-10-11 on; NULL on older rows).
ALTER TABLE etf_buy ADD COLUMN IF NOT EXISTS equity_session text;
COMMENT ON COLUMN etf_buy.pushover_notified_at IS
    'When the Pushover "ETF Buy" alert for this fill was claimed/sent. NULL = not sent yet (sent once the fill is confirmed).';
COMMENT ON COLUMN etf_buy.equity_session IS
    'Coinbase equity session at placement (EQUITY_TRADING_SESSION_NORMAL / PRE_MARKET / AFTER_HOURS / OVERNIGHT). NULL before 2026-10-11.';
-- Every existing row counts as already notified: no flood of old buys.
UPDATE etf_buy SET pushover_notified_at = now() WHERE pushover_notified_at IS NULL;
CREATE INDEX IF NOT EXISTS etf_buy_pushover_unsent
    ON etf_buy (etf_buy_id) WHERE pushover_notified_at IS NULL;

-- Dividends -------------------------------------------------------------
\i db/tables/dividend_receipt.sql

-- Config: kill switches on (Theodore asked for both), and the cut-off so
-- receipts found on the first sync (already paid before today) are stored
-- but not alerted.
INSERT INTO config (key, value) VALUES
    ('pushover_etf_buy_alerts', 'true'),
    ('pushover_dividend_alerts', 'true'),
    ('dividend_alerts_since', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'))
ON CONFLICT (key) DO NOTHING;
