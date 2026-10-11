-- 2026-10-11: Pushover profit alerts, ported from the old CoinbasePro bot
-- (sendNotifications.js + MSSQL proc SendNotifications) per Theodore.
--
-- What it does: after every close is written to profit_history,
-- modules/sendProfitNotifications.js (called at the end of index.js main())
-- pushes one Pushover message per NEW close (coin, profit, buy/sell price,
-- shares, buy/sell time, live USD + USDC balance) and stamps the row here so
-- it is never sent twice.
--
-- Additive only: one nullable column, one partial index, three config rows.
-- Nothing in thee_procedure / buys / sells / remakes / ETF reads any of it.

-- When this close's Pushover alert was claimed/sent. NULL = not sent yet.
ALTER TABLE profit_history
    ADD COLUMN IF NOT EXISTS pushover_notified_at TIMESTAMPTZ NULL;

-- Backfill: every close that already exists is marked as notified so turning
-- this on does NOT flood the phone with ~1,200 historical closes. Only closes
-- recorded after this migration get an alert.
UPDATE profit_history
   SET pushover_notified_at = now()
 WHERE pushover_notified_at IS NULL;

-- Small partial index: the per-minute "what is unsent?" lookup only ever
-- touches the handful of rows still NULL.
CREATE INDEX IF NOT EXISTS profit_history_pushover_unsent
    ON profit_history (profit_history_id)
 WHERE pushover_notified_at IS NULL;

-- Config:
--   pushover_profit_alerts  'true' / 'false' kill switch (default 'false'
--                           here; flipped to 'true' once both keys are set).
--   pushover_app_token      Pushover application API token  (secret: lives
--   pushover_user_key       Pushover user key                in the DB only,
--                                                            never in git)
-- Empty value = not configured; the module then skips quietly.
INSERT INTO config (key, value) VALUES
    ('pushover_profit_alerts', 'false'),
    ('pushover_app_token', ''),
    ('pushover_user_key', '')
ON CONFLICT (key) DO NOTHING;
