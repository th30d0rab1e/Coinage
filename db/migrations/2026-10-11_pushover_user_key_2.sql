-- Second Pushover recipient (e.g. family) for close alerts.
-- sendProfitNotifications.js also accepts comma-separated keys in
-- pushover_user_key / pushover_user_key_2.
INSERT INTO config (key, value) VALUES ('pushover_user_key_2', '')
ON CONFLICT (key) DO NOTHING;
