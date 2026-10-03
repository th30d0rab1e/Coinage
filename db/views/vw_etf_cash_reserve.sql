-- USD to hold back from NEW crypto buys while the equity session is open
-- and today's ETF buys are still unfilled. Zero when equity_session_open
-- is not 'true' (weekend full close, holiday, outside the normal session,
-- or "order queueing is not available"), so crypto is not blocked and cash
-- is not reserved.
CREATE OR REPLACE VIEW public.vw_etf_cash_reserve AS
SELECT COALESCE(
    CASE
        WHEN (SELECT value FROM public.config WHERE key = 'equity_session_open') = 'true'
        THEN (
            SELECT SUM(e.quote_usd)
            FROM public.etf e
            WHERE e.enabled
            AND NOT EXISTS (
                SELECT 1
                FROM public.etf_buy b
                WHERE b.ticker = e.ticker
                  AND b.chicago_date = (timezone('America/Chicago', now()))::date
                  AND b.filled
            )
        )
        ELSE 0
    END
, 0)::numeric AS reserve_usd;

COMMENT ON VIEW public.vw_etf_cash_reserve IS
    'Unfilled ETF quote USD to keep away from new crypto buys. 0 when the equity session is closed.';
