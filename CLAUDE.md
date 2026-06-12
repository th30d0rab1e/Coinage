# Coinbase Bot — Session Setup

## On every session start, register these cron jobs:

### 1. 30-minute health check
```
cron: */30 * * * *
durable: true
prompt:
You are monitoring a Coinbase trading bot. Working directory: /Volumes/2TBSSD/theodorecrossX/Library/Mobile Documents/com~apple~CloudDocs/Coinbase tedTosterone

Run all of these checks:

1. psql -U theodorecross -d coinbase -c "SELECT period_type, COUNT(*) AS open, ROUND(AVG((sell_stop_price/NULLIF(buy_filled_price,0)-1)*100)::numeric,2) AS avg_pct_from_stop FROM position WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL GROUP BY period_type;"

2. psql -U theodorecross -d coinbase -c "SELECT value FROM config WHERE key = 'pause_buys';"

3. psql -U theodorecross -d coinbase -c "SELECT * FROM vw_profit_summary;"

4. Read the last 60 lines of outputLog.txt and extract any lines containing ERROR, FAILED, or error (case-insensitive) from the past 30 minutes.

Then apply these rules:
- If any period_type has avg_pct_from_stop < 2.0 AND pause_buys = 'false': run psql -U theodorecross -d coinbase -c "UPDATE config SET value='true' WHERE key='pause_buys';" then send a push notification: "Coinbase bot: pause_buys ON — positions near stop loss"
- If pause_buys = 'true' AND all period_types have avg_pct_from_stop >= 5.0: run psql to set pause_buys='false', send push: "Coinbase bot: pause_buys cleared — conditions recovered"
- If there are any ERROR/FAILED log lines from the past 30 minutes: send a push notification summarizing them in under 180 characters
- If nothing is wrong, do not send any notification
```

### 2. Daily 8:03am report
```
cron: 3 8 * * *
durable: true
prompt:
You are generating a daily report for a Coinbase trading bot. Working directory: /Volumes/2TBSSD/theodorecrossX/Library/Mobile Documents/com~apple~CloudDocs/Coinbase tedTosterone

Run these queries:

1. psql -U theodorecross -d coinbase -c "SELECT * FROM vw_profit_summary;"

2. psql -U theodorecross -d coinbase -c "SELECT name, period_type, ROUND(buy_filled_price::numeric,4) AS bought_at, ROUND(sell_stop_price::numeric,4) AS stop, ROUND(((sell_stop_price/NULLIF(buy_filled_price,0))-1)*100::numeric,2) AS pct_from_stop, shares FROM position WHERE buy_filled_price IS NOT NULL AND sell_filled_price IS NULL ORDER BY period_type, pct_from_stop ASC;"

3. psql -U theodorecross -d coinbase -c "SELECT * FROM config;"

4. Read the last 200 lines of outputLog.txt and extract all ERROR/FAILED lines from the past 24 hours.

Then compose and send an email to darthtlc@gmail.com with:
- Subject: "Coinbase Bot Report — [today's date]"
- Body:
  * Profit summary table (all_time_profit, today_profit, month_profit per period_type)
  * Open positions table with % from stop, sorted worst-first
  * Config status (pause_buys value)
  * Errors/failures from the log (or "None" if clean)
  * One sentence bottom line: overall health assessment

After sending, send a push notification: "Coinbase daily report sent to darthtlc@gmail.com"
```

## Database
- Host: localhost, DB: coinbase, User: theodorecross
- Dump schema: `/opt/homebrew/opt/postgresql@17/bin/pg_dump -U theodorecross -d coinbase --schema-only --no-owner --no-acl -f schema.sql`
- Every DDL change must be saved to `migrations/NNN_description.sql`, schema.sql regenerated, and both committed to git

## Git
- Remote: git@github.com:th30d0rab1e/Coinage.git
- Branch: main
