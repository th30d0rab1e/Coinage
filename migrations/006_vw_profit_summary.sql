-- vw_profit_summary: all-time profit/avg/trades by period_type vs current day/month/year
DROP VIEW IF EXISTS vw_profit_summary;

CREATE VIEW vw_profit_summary AS
SELECT
    period_type,
    COUNT(*)                                                                                        AS total_trades,
    ROUND(SUM(profit)::numeric, 2)                                                                  AS all_time_profit,
    ROUND(AVG(profit)::numeric, 2)                                                                  AS all_time_avg,
    COUNT(*)  FILTER (WHERE date_created::date = CURRENT_DATE)                                      AS today_trades,
    ROUND(COALESCE(SUM(profit) FILTER (WHERE date_created::date = CURRENT_DATE),            0)::numeric, 2) AS today_profit,
    ROUND(AVG(profit) FILTER (WHERE date_created::date = CURRENT_DATE)::numeric,                   2) AS today_avg,
    COUNT(*)  FILTER (WHERE date_trunc('month', date_created) = date_trunc('month', NOW()))         AS month_trades,
    ROUND(COALESCE(SUM(profit) FILTER (WHERE date_trunc('month', date_created) = date_trunc('month', NOW())), 0)::numeric, 2) AS month_profit,
    ROUND(AVG(profit) FILTER (WHERE date_trunc('month', date_created) = date_trunc('month', NOW()))::numeric, 2) AS month_avg,
    COUNT(*)  FILTER (WHERE date_trunc('year',  date_created) = date_trunc('year',  NOW()))         AS year_trades,
    ROUND(COALESCE(SUM(profit) FILTER (WHERE date_trunc('year',  date_created) = date_trunc('year',  NOW())),  0)::numeric, 2) AS year_profit,
    ROUND(AVG(profit) FILTER (WHERE date_trunc('year',  date_created) = date_trunc('year',  NOW()))::numeric,  2) AS year_avg
FROM profit_history
GROUP BY period_type
ORDER BY period_type;
