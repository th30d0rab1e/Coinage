-- One-time backfill, 2026-09-25: correct fills/unmatched_fills.trade_time
-- rows written before commit c82a82a (2026-09-08 04:14 CT).
--
-- Before that commit the columns were `timestamp WITHOUT time zone`, so
-- Postgres dropped the 'Z' from Coinbase's UTC trade_time and stored the raw
-- UTC wall clock; converting the column to timestamptz then labelled those
-- digits as America/Chicago -- every pre-cutover fill reads 5 hours late
-- (e.g. a fill at 08:34 CT shows as 13:34-05). c82a82a fixed new rows only.
--
-- Cutover confirmed from the data: last skewed row recorded 2026-09-08
-- 03:59 CT (fill_id 1351403), first correct row recorded 05:04 CT; all 507
-- rows recorded before 04:14 CT are skewed, none after. Spot-checked 4
-- pre-cutover fills against Coinbase getOrderById().last_fill_time: stored
-- wall clock == Coinbase UTC digits in every case.
--
-- Fix: take the stored wall clock (as displayed in America/Chicago) and
-- re-read it as UTC. Both bounds are applied so a re-run can't shift any
-- post-cutover row. NOT idempotent on the pre-cutover rows -- run once.
BEGIN;
UPDATE fills
SET trade_time = (trade_time AT TIME ZONE 'America/Chicago') AT TIME ZONE 'UTC'
WHERE recorded_at < '2026-09-08 04:14'
  AND fill_id <= 1351403;

-- unmatched_fills rows (all 3 detected 8/24-8/31) came from the same bulk_fills path
UPDATE unmatched_fills
SET trade_time = (trade_time AT TIME ZONE 'America/Chicago') AT TIME ZONE 'UTC'
WHERE detected_at < '2026-09-08 04:14';
COMMIT;
