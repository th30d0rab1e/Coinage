-- 2026-10-12 (Theodore): "Deposit cleared" Pushover alert (modules/depositClearedAlerts.js).
-- cleared_notified_at = when we alerted that this deposit's funds became
-- available to trade (NULL = not yet). Deposits older than 14 days and all
-- withdrawals are stamped now so history never alerts.
ALTER TABLE public.usd_transfer ADD COLUMN IF NOT EXISTS cleared_notified_at timestamp without time zone;
COMMENT ON COLUMN public.usd_transfer.cleared_notified_at IS
    'When the "deposit cleared" Pushover alert was sent (Coinbase USD available >= amount). NULL = pending. See modules/depositClearedAlerts.js.';
UPDATE public.usd_transfer SET cleared_notified_at = now()
 WHERE cleared_notified_at IS NULL AND (type <> 'deposit' OR date <= now() - interval '14 days');
-- Deposits already spent by the bot (before 38) are clearly cleared; stamp them too.
UPDATE public.usd_transfer SET cleared_notified_at = now()
 WHERE cleared_notified_at IS NULL AND id < 38;
-- Kill switch (same pattern as the other pushover_* switches).
INSERT INTO config (key, value) SELECT 'pushover_deposit_alerts', 'true'
 WHERE NOT EXISTS (SELECT 1 FROM config WHERE key = 'pushover_deposit_alerts');
