-- vw_coin_close_stats — LIVE per-coin close scoreboard (Theodore, 2026-10-10).
--
-- A plain view (not a digest/table): every SELECT recomputes from the live
-- tables, so it is always current and was populated from day one of history.
--
-- Sources
--   profit_history  one row per CLOSED bag (buy filled + sell filled), written
--                   by the bot when a sell fills. Full history since 2026-06-08.
--   position        bags still OPEN. A bag is a filled-but-unsold bag when
--                   buy_filled_price IS NOT NULL AND sell_filled_price IS NULL.
--                   Unfilled buy orders (buy_filled_price NULL) are NOT fills.
--   fills           Coinbase fill log, used only for the buy fill time
--                   (hold time). Not every older close has its buy order in
--                   fills, so avg_hours_to_close covers matched closes only.
--
-- Why not count "fills" from the fills table? fills only holds ~70% of the
-- buy orders behind profit_history and also contains ETF / manual buys, so
-- closed + open bags is the most accurate count of bot buy fills per coin.
--
-- Columns
--   coin                 product name, e.g. 'ORCA-USD' (all period_types combined)
--   rank                 1 = best performer (see ORDER BY below)
--   closes               closed bags (profit_history rows)
--   avg_profit           average $ profit per close
--   total_profit         sum of $ profit across all closes (= closes * avg_profit)
--   open_bags            filled bags still waiting to sell
--   fills                bot buy fills = closes + open_bags
--   fill_to_close_ratio  closes / fills, 0..1. 1.00 = every bag that filled has
--                        closed; low = coin tends to leave bags stuck underwater
--   profit_per_fill      total_profit / fills — expected $ per buy fill,
--                        penalises coins that fill often but rarely close
--   open_cost            $ tied up in open bags (shares * buy_filled_price)
--   closes_30d / profit_30d / avg_profit_30d   same metrics, last 30 days
--   closes_today         closes since local midnight
--   avg_hours_to_close   mean hours from buy fill to close (matched closes only)
--   last_close           timestamp of the most recent close
--
-- Ranking (built into rank + ORDER BY)
--   1. coins with >= 3 closes first (sample-size floor, so one lucky close
--      does not top the board)
--   2. total_profit DESC (closes * avg_profit: rewards coins that both close
--      often and pay well)
--   3. fill_to_close_ratio DESC as tie-break
-- Callers can re-rank, e.g. ORDER BY profit_30d DESC or profit_per_fill DESC.
CREATE OR REPLACE VIEW public.vw_coin_close_stats AS
WITH buy_fill_time AS (
    -- first fill time per buy order (an order can fill in several pieces)
    SELECT order_id, min(trade_time) AS filled_at
    FROM fills
    WHERE side = 'BUY'
    GROUP BY order_id
),
closed AS (
    SELECT ph.name AS coin,
        count(*) AS closes,
        avg(ph.profit) AS avg_profit,
        sum(ph.profit) AS total_profit,
        count(*) FILTER (WHERE ph.date_created >= now() - interval '30 days') AS closes_30d,
        sum(ph.profit) FILTER (WHERE ph.date_created >= now() - interval '30 days') AS profit_30d,
        count(*) FILTER (WHERE ph.date_created::date = CURRENT_DATE) AS closes_today,
        avg(EXTRACT(epoch FROM (ph.date_created::timestamptz - bft.filled_at)) / 3600.0)
            FILTER (WHERE bft.filled_at IS NOT NULL AND ph.date_created::timestamptz > bft.filled_at) AS avg_hours_to_close,
        max(ph.date_created) AS last_close
    FROM profit_history ph
    LEFT JOIN buy_fill_time bft ON bft.order_id = ph.buy_coinbase_order_id
    GROUP BY ph.name
),
open_bags AS (
    SELECT p.name AS coin,
        count(*) AS open_bags,
        sum(p.shares * p.buy_filled_price) AS open_cost
    FROM position p
    WHERE p.buy_filled_price IS NOT NULL
      AND p.sell_filled_price IS NULL
    GROUP BY p.name
),
combined AS (
    SELECT COALESCE(c.coin, o.coin) AS coin,
        COALESCE(c.closes, 0) AS closes,
        c.avg_profit,
        COALESCE(c.total_profit, 0) AS total_profit,
        COALESCE(o.open_bags, 0) AS open_bags,
        COALESCE(c.closes, 0) + COALESCE(o.open_bags, 0) AS fills,
        COALESCE(o.open_cost, 0) AS open_cost,
        COALESCE(c.closes_30d, 0) AS closes_30d,
        COALESCE(c.profit_30d, 0) AS profit_30d,
        COALESCE(c.closes_today, 0) AS closes_today,
        c.avg_hours_to_close,
        c.last_close
    FROM closed c
    FULL JOIN open_bags o ON o.coin = c.coin
)
SELECT
    row_number() OVER (
        ORDER BY (closes >= 3) DESC, total_profit DESC,
                 closes::numeric / NULLIF(fills, 0) DESC NULLS LAST, coin
    ) AS rank,
    coin,
    closes,
    round(avg_profit::numeric, 4) AS avg_profit,
    round(total_profit::numeric, 2) AS total_profit,
    open_bags,
    fills,
    round(closes::numeric / NULLIF(fills, 0), 2) AS fill_to_close_ratio,
    round((total_profit / NULLIF(fills, 0))::numeric, 4) AS profit_per_fill,
    round(open_cost::numeric, 2) AS open_cost,
    closes_30d,
    round(profit_30d::numeric, 2) AS profit_30d,
    round((profit_30d / NULLIF(closes_30d, 0))::numeric, 4) AS avg_profit_30d,
    closes_today,
    round(avg_hours_to_close::numeric, 1) AS avg_hours_to_close,
    last_close
FROM combined
ORDER BY rank;
