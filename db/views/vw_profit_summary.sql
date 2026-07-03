CREATE OR REPLACE VIEW public.vw_profit_summary AS
SELECT period_type,
    count(*) AS total_trades,
    round(sum(profit)::numeric, 2) AS all_time_profit,
    round(avg(profit)::numeric, 2) AS all_time_avg,
    count(*) FILTER (WHERE date_created::date = CURRENT_DATE) AS today_trades,
    round(COALESCE(sum(profit) FILTER (WHERE date_created::date = CURRENT_DATE), 0::double precision)::numeric, 2) AS today_profit,
    round(avg(profit) FILTER (WHERE date_created::date = CURRENT_DATE)::numeric, 2) AS today_avg,
    count(*) FILTER (WHERE date_trunc('month'::text, date_created) = date_trunc('month'::text, now())) AS month_trades,
    round(COALESCE(sum(profit) FILTER (WHERE date_trunc('month'::text, date_created) = date_trunc('month'::text, now())), 0::double precision)::numeric, 2) AS month_profit,
    round(avg(profit) FILTER (WHERE date_trunc('month'::text, date_created) = date_trunc('month'::text, now()))::numeric, 2) AS month_avg,
    count(*) FILTER (WHERE date_trunc('year'::text, date_created) = date_trunc('year'::text, now())) AS year_trades,
    round(COALESCE(sum(profit) FILTER (WHERE date_trunc('year'::text, date_created) = date_trunc('year'::text, now())), 0::double precision)::numeric, 2) AS year_profit,
    round(avg(profit) FILTER (WHERE date_trunc('year'::text, date_created) = date_trunc('year'::text, now()))::numeric, 2) AS year_avg
FROM profit_history
GROUP BY period_type
ORDER BY period_type;
