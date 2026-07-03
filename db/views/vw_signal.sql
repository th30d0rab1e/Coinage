CREATE OR REPLACE VIEW public.vw_signal AS
SELECT s.name,
    s.stock_id,
    pa.period_type,
    pa.period_date,
    period_score.cnt AS period_count,
    period_score.prices,
    pa.open,
    pa.close,
    pa.high,
    pa.low,
    pa.avg_price,
    trunc(pat.avg_change_percent::numeric, 2) AS historical_avg_change_percent,
    trunc(pat.std_dev::numeric, 2) AS std_dev,
    trunc(pat.std_dev_upper_bound::numeric, 2) AS std_dev_upper_bound,
    trunc(pat.std_dev_lower_bound::numeric, 2) AS std_dev_lower_bound,
    trunc(pac.change_percent::numeric, 2) AS current_change_percent,
    trunc(((pac.change_percent - pat.avg_change_percent) / NULLIF(pat.std_dev, 0::double precision))::numeric, 2) AS signal,
    trunc((period_score.cnt::double precision * pat.avg_change_percent / NULLIF(pat.std_dev, 0::double precision))::numeric, 2) AS score,
    trunc((period_score.cnt::double precision * pat.avg_change_percent / NULLIF(pat.std_dev, 0::double precision) * abs((pac.change_percent - pat.avg_change_percent) / NULLIF(pat.std_dev, 0::double precision)))::numeric, 2) AS priority,
    CASE
        WHEN ((pac.change_percent - pat.avg_change_percent) / NULLIF(pat.std_dev, 0::double precision)) < 0::double precision THEN 'BUY'::text
        WHEN ((pac.change_percent - pat.avg_change_percent) / NULLIF(pat.std_dev, 0::double precision)) > 0::double precision THEN 'SELL'::text
        ELSE 'HOLD'::text
    END AS recommendation
FROM price_aggregate pa
JOIN price_aggregate_comparison pac ON pa.price_aggregate_id = pac.after_id
JOIN stock s ON s.stock_id = pa.stock_id
JOIN price_aggregate_total pat ON pa.stock_id = pat.stock_id AND pa.period_type = pat.period_type
JOIN (
    SELECT price_aggregate.stock_id,
        price_aggregate.period_type,
        count(1) AS cnt,
        string_agg(trunc(price_aggregate.close::numeric, 2)::text, ','::text ORDER BY price_aggregate.period_date) AS prices
    FROM price_aggregate
    GROUP BY price_aggregate.stock_id, price_aggregate.period_type
) period_score ON pa.stock_id = period_score.stock_id AND pa.period_type = period_score.period_type
WHERE pa.period_type = 'day'::text AND pa.period_date = now()::date
   OR pa.period_type = 'month'::text AND pa.period_date = date_trunc('month'::text, now())::date
   OR pa.period_type = 'year'::text AND pa.period_date = date_trunc('year'::text, now())::date
ORDER BY pa.period_type DESC,
    trunc((period_score.cnt::double precision * pat.avg_change_percent / NULLIF(pat.std_dev, 0::double precision) * abs((pac.change_percent - pat.avg_change_percent) / NULLIF(pat.std_dev, 0::double precision)))::numeric, 2) DESC NULLS LAST;
