--
-- PostgreSQL database dump
--

\restrict rpjvAVeU3J5gTuUgl7pKdq5w1a0KT4K9B4ZuYbB8z9kfnH9iNzudraKBztJ9uoN

-- Dumped from database version 17.9 (Homebrew)
-- Dumped by pg_dump version 17.9 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: aggregate(); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.aggregate()
    LANGUAGE sql
    AS $$
--Delete
DELETE FROM price_history
WHERE date_created < NOW() - INTERVAL '25 hours';

DELETE FROM price_aggregate
WHERE period_date < NOW() - INTERVAL '31 days'
AND period_type = 'day';

DELETE FROM price_aggregate
WHERE period_date < NOW() - INTERVAL '13 months'
AND period_type = 'month';


--Insert

INSERT INTO price_history(stock_id, price, date_created)
SELECT stock_id, price, now()
FROM stock;

INSERT INTO price_aggregate (stock_id, period_type, period_date, open, close, high, low, avg_price)
SELECT stock_id, 'day', DATE_TRUNC('day', NOW())::DATE,
    MIN(price), MAX(price), MAX(price), MIN(price), AVG(price)
FROM stock
WHERE NOT EXISTS (
    SELECT 1 FROM price_aggregate pa
    WHERE pa.stock_id = stock.stock_id
    AND pa.period_type = 'day'
    AND pa.period_date = DATE_TRUNC('day', NOW())::DATE
)
GROUP BY stock_id

UNION ALL

SELECT stock_id, 'month', DATE_TRUNC('month', NOW())::DATE,
    MIN(open), MAX(close), MAX(high), MIN(low), AVG(avg_price)
FROM price_aggregate
WHERE period_type = 'day'
AND period_date >= NOW() - INTERVAL '30 days'
AND NOT EXISTS (
    SELECT 1 FROM price_aggregate pa
    WHERE pa.stock_id = price_aggregate.stock_id
    AND pa.period_type = 'month'
    AND pa.period_date = DATE_TRUNC('month', NOW())::DATE
)
GROUP BY stock_id

UNION ALL

SELECT stock_id, 'year', DATE_TRUNC('year', NOW())::DATE,
    MIN(open), MAX(close), MAX(high), MIN(low), AVG(avg_price)
FROM price_aggregate
WHERE period_type = 'month'
AND period_date >= NOW() - INTERVAL '12 months'
AND NOT EXISTS (
    SELECT 1 FROM price_aggregate pa
    WHERE pa.stock_id = price_aggregate.stock_id
    AND pa.period_type = 'year'
    AND pa.period_date = DATE_TRUNC('year', NOW())::DATE
)
GROUP BY stock_id;

--Update
UPDATE price_aggregate pa
SET
    open = s.open,
    close = s.close,
    high = s.max_price,
    low = s.min_price,
    avg_price = s.avg_price
FROM (
         SELECT DISTINCT ON (stock_id)
    stock_id,
    FIRST_VALUE(price) OVER (PARTITION BY stock_id ORDER BY price_history_id ASC) AS open,
    LAST_VALUE(price) OVER (PARTITION BY stock_id ORDER BY price_history_id ASC ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS close,
    MIN(price) OVER (PARTITION BY stock_id) AS min_price,
    MAX(price) OVER (PARTITION BY stock_id) AS max_price,
    AVG(price) OVER (PARTITION BY stock_id) AS avg_price
FROM price_history
WHERE date_created = DATE_TRUNC('day', NOW())::DATE
ORDER BY stock_id
) s
WHERE pa.stock_id = s.stock_id
AND pa.period_type = 'day'
AND pa.period_date = DATE_TRUNC('day', NOW())::DATE;

UPDATE price_aggregate pa
SET
    open = s.open,
    close = s.close,
    high = s.high,
    low = s.low,
    avg_price = s.avg_price
FROM (
    SELECT stock_id,
        (ARRAY_AGG(open ORDER BY period_date ASC))[1] AS open,
        (ARRAY_AGG(close ORDER BY period_date DESC))[1] AS close,
        MAX(high) AS high,
        MIN(low) AS low,
        AVG(avg_price) AS avg_price
    FROM price_aggregate
    WHERE period_type = 'day'
    AND period_date >= NOW() - INTERVAL '30 days'
    GROUP BY stock_id
) s
WHERE pa.stock_id = s.stock_id
AND pa.period_type = 'month'
AND pa.period_date = DATE_TRUNC('month', NOW())::DATE;

UPDATE price_aggregate pa
SET
    open = s.open,
    close = s.close,
    high = s.high,
    low = s.low,
    avg_price = s.avg_price
FROM (
    SELECT stock_id,
        (ARRAY_AGG(open ORDER BY period_date ASC))[1] AS open,
        (ARRAY_AGG(close ORDER BY period_date DESC))[1] AS close,
        MAX(high) AS high,
        MIN(low) AS low,
        AVG(avg_price) AS avg_price
    FROM price_aggregate
    WHERE period_type = 'month'
    AND period_date >= NOW() - INTERVAL '12 months'
    GROUP BY stock_id
) s
WHERE pa.stock_id = s.stock_id
AND pa.period_type = 'year'
AND pa.period_date = DATE_TRUNC('year', NOW())::DATE;


--comparison
INSERT INTO price_aggregate_comparison (before_id, after_id, change_percent)
SELECT 
    pa_before.price_aggregate_id AS before_id,
    pa_after.price_aggregate_id AS after_id,      
    ((pa_after.close - pa_before.close) / pa_before.close) * 100 AS change_percent
FROM price_aggregate pa_before
JOIN price_aggregate pa_after 
    ON pa_before.stock_id = pa_after.stock_id
    AND pa_before.period_type = pa_after.period_type
    AND (
        (pa_before.period_type = 'day' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 day')
        OR
        (pa_before.period_type = 'year' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 year')
        OR
        (pa_before.period_type = 'month' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 month'))
LEFT JOIN price_aggregate_comparison pac
    ON pa_before.price_aggregate_id = pac.before_id
    AND pa_after.price_aggregate_id = pac.after_id 
WHERE pac.price_aggregate_comparison_id IS NULL;

UPDATE price_aggregate_comparison pac
SET change_percent = ((pa_after.close - pa_before.close) / pa_before.close) * 100
FROM price_aggregate pa_before
JOIN price_aggregate pa_after
    ON pa_before.stock_id = pa_after.stock_id
    AND pa_before.period_type = pa_after.period_type
    AND (
        (pa_before.period_type = 'day' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 day')
        OR
        (pa_before.period_type = 'year' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 year')
        OR
        (pa_before.period_type = 'month' AND pa_after.period_date = pa_before.period_date + INTERVAL '1 month'))
WHERE pac.before_id = pa_before.price_aggregate_id
AND pac.after_id = pa_after.price_aggregate_id;

--totals
INSERT INTO price_aggregate_total (stock_id, period_type, avg_change_percent)
SELECT 
    pa.stock_id,
    pa.period_type,
    AVG(pac.change_percent) AS avg_change_percent
FROM price_aggregate_comparison pac
JOIN price_aggregate pa ON pa.price_aggregate_id = pac.before_id
LEFT JOIN price_aggregate_total pat
    ON pa.stock_id = pat.stock_id
    AND pa.period_type = pat.period_type
WHERE pat.price_aggregate_total_id IS NULL
GROUP BY pa.stock_id, pa.period_type;

UPDATE price_aggregate_total pat
SET 
    avg_change_percent = x.avg_change_percent,
    std_dev = x.std_dev,
    std_dev_upper_bound = x.avg_change_percent + (2 * x.std_dev),
    std_dev_lower_bound = x.avg_change_percent - (2 * x.std_dev)
FROM (
    SELECT 
        pa.stock_id,
        pa.period_type,
        AVG(pac.change_percent) AS avg_change_percent,
        STDDEV(pac.change_percent) AS std_dev
    FROM price_aggregate_comparison pac
    JOIN price_aggregate pa ON pa.price_aggregate_id = pac.before_id
    GROUP BY pa.stock_id, pa.period_type
) x
WHERE pat.stock_id = x.stock_id
AND pat.period_type = x.period_type;
$$;


--
-- Name: insert_aggregate(); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.insert_aggregate()
    LANGUAGE sql
    AS $$
INSERT INTO price_aggregate (stock_id, period_type, period_date, low, high, open, close, avg_price)
SELECT 
    bs.stock_id,
    'year' AS period_type,
    DATE_TRUNC('year', TO_TIMESTAMP(bs.start))::DATE AS period_date,
    MIN(bs.low) AS low,
    MAX(bs.high) AS high,
    (ARRAY_AGG(bs.open ORDER BY start ASC))[1] AS open,
    (ARRAY_AGG(bs.close ORDER BY start DESC))[1] AS close,
    AVG(bs.close) AS avg_price
FROM bulk_historical bs
LEFT JOIN price_aggregate pa
     ON bs.stock_id = pa.stock_id
     AND pa.period_type = 'year'
     AND pa.period_date = DATE_TRUNC('year', TO_TIMESTAMP(bs.start))::DATE
WHERE pa.price_aggregate_id IS NULL
GROUP BY bs.stock_id, DATE_TRUNC('year', TO_TIMESTAMP(bs.start))
ORDER BY stock_id, period_date;

INSERT INTO price_aggregate (stock_id, period_type, period_date, low, high, open, close, avg_price)
SELECT 
    bs.stock_id,
    'month' AS period_type,
    DATE_TRUNC('month', TO_TIMESTAMP(bs.start))::DATE AS period_date,
    MIN(bs.low) AS low,
    MAX(bs.high) AS high,
    (ARRAY_AGG(bs.open ORDER BY start ASC))[1] AS open,
    (ARRAY_AGG(bs.close ORDER BY start DESC))[1] AS close,
    AVG(bs.close) AS avg_price
FROM bulk_historical bs
LEFT JOIN price_aggregate pa
     ON bs.stock_id = pa.stock_id
     AND pa.period_type = 'month'
     AND pa.period_date = DATE_TRUNC('month', TO_TIMESTAMP(bs.start))::DATE
WHERE pa.price_aggregate_id IS NULL
GROUP BY bs.stock_id, DATE_TRUNC('month', TO_TIMESTAMP(bs.start))
ORDER BY stock_id, period_date;

UPDATE stock s SET historical_finished = 1::bit
FROM bulk_historical bh
WHERE s.stock_id = bh.stock_id;

TRUNCATE TABLE bulk_historical;
$$;


--
-- Name: thee_procedure(); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.thee_procedure()
    LANGUAGE sql
    AS $$

INSERT INTO stock (name, date_created)
SELECT bs.id, NOW()
FROM bulk_stock bs
LEFT JOIN stock s ON bs.id = s.name
WHERE s.stock_id IS NULL
AND bs.id LIKE '%-USD';

UPDATE stock
SET price = bs.price::DOUBLE PRECISION,
    share_rounding = CASE
        WHEN (bs.json->>'base_increment') LIKE '%.%'
        THEN length(bs.json->>'base_increment') - position('.' IN bs.json->>'base_increment')
        ELSE 0
    END,
    price_rounding = CASE
        WHEN (bs.json->>'quote_increment') LIKE '%.%'
        THEN length(bs.json->>'quote_increment') - position('.' IN bs.json->>'quote_increment')
        ELSE 0
    END,
    max_shares = (bs.json->>'base_max_size')::double precision,
    min_shares = (bs.json->>'base_min_size')::double precision,
    max_price = (bs.json->>'quote_max_size')::double precision,
    min_price = (bs.json->>'quote_min_size')::double precision
FROM bulk_stock bs
WHERE stock.name = bs.id
AND bs.id LIKE '%-USD'
AND bs.price != '';

INSERT INTO position (stock_id, name, buy_price, buy_stop_price, shares, date_created, buy_order_id, period_type)
SELECT s.stock_id, s.name,
    TRUNC((s.close::numeric * bal.stop_mult * 1.01), stock.price_rounding::integer) AS buy_price,
    TRUNC((s.close::numeric * bal.stop_mult),        stock.price_rounding::integer) AS buy_stop_price,
    CASE
        WHEN s.period_type = 'day'   THEN TRUNC((1.00   / s.close)::numeric, stock.share_rounding::integer)
        WHEN s.period_type = 'month' THEN TRUNC((10.00  / s.close)::numeric, stock.share_rounding::integer)
        WHEN s.period_type = 'year'  THEN TRUNC((100.00 / s.close)::numeric, stock.share_rounding::integer)
        ELSE 0
    END AS shares,
    NOW() AS date_created,
    gen_random_uuid(),
    s.period_type
FROM vw_signal s
JOIN stock ON s.stock_id = stock.stock_id
CROSS JOIN vw_balance b
CROSS JOIN LATERAL (
    SELECT GREATEST(1.01::numeric, LEAST(1.05::numeric,
        1.01 + 0.04 * (1.0 -
            b.available::numeric /
            NULLIF(
                b.available::numeric + COALESCE((
                    SELECT SUM(p2.buy_price * p2.shares)
                    FROM position p2
                    WHERE p2.buy_coinbase_order_id IS NOT NULL
                    AND p2.buy_filled_price IS NULL
                ), 0)::numeric,
                0
            )
        )
    )) AS stop_mult
) bal
LEFT JOIN vw_position p ON s.stock_id = p.stock_id AND s.period_type = p.period_type
WHERE b.name = 'USD'
AND (SELECT value FROM config WHERE key = 'pause_buys') = 'false'
AND (
    (b.available > 1.00  AND s.period_type = 'day')
    OR (b.available > 10.00 AND s.period_type = 'month')
    OR (b.available > 100.00 AND s.period_type = 'year')
)
AND (s.close < p.min_buy_filled_price OR p.max_buy_coinbase_order_id IS NULL)
AND recommendation = 'BUY'
AND s.signal < -1
AND historical_avg_change_percent > 0
AND COALESCE(p.cnt, 0) < 10
LIMIT 1;

UPDATE position
SET buy_filled_price = bf.price,
    buy_fee = bf.fee
FROM bulk_fills bf
WHERE position.buy_coinbase_order_id = bf.order_id
AND position.buy_filled_price IS NULL;

WITH sell_fills AS (
    UPDATE position
    SET sell_filled_price = bf.price,
        sell_fee = bf.fee,
        profit = TRUNC(((bf.price * position.shares - bf.fee) - (position.buy_filled_price * position.shares + position.buy_fee))::numeric, 2)
    FROM bulk_fills bf
    WHERE position.sell_coinbase_order_id = bf.order_id
    AND position.sell_filled_price IS NULL
    RETURNING position.stock_id, position.name, position.period_type,
              position.buy_coinbase_order_id, bf.order_id AS sell_fills_id,
              TRUNC(position.buy_fee::numeric, 2) AS buy_fee,
              TRUNC(bf.fee::numeric, 2) AS sell_fee,
              TRUNC(((bf.price * position.shares - bf.fee) - (position.buy_filled_price * position.shares + position.buy_fee))::numeric, 2) AS profit
),
insert_history AS (
    INSERT INTO profit_history (stock_id, name, period_type, buy_coinbase_order_id, sell_fills_id, buy_fee, sell_fee, profit)
    SELECT stock_id, name, period_type, buy_coinbase_order_id, sell_fills_id, buy_fee, sell_fee, profit
    FROM sell_fills
)
DELETE FROM position
WHERE buy_order_id IN (
    SELECT p.buy_order_id
    FROM position p
    JOIN bulk_fills bf ON p.sell_coinbase_order_id = bf.order_id
    WHERE p.sell_filled_price IS NOT NULL
    AND p.profit IS NOT NULL
);

UPDATE position
SET sell_stop_price = CASE position.period_type
        WHEN 'day'   THEN TRUNC(stock.price::numeric * 0.97, stock.price_rounding::int)
        WHEN 'month' THEN TRUNC(stock.price::numeric * 0.90, stock.price_rounding::int)
        WHEN 'year'  THEN TRUNC(stock.price::numeric * 0.75, stock.price_rounding::int)
    END,
    sell_price = CASE position.period_type
        WHEN 'day'   THEN TRUNC(stock.price::numeric * 0.96, stock.price_rounding::int)
        WHEN 'month' THEN TRUNC(stock.price::numeric * 0.89, stock.price_rounding::int)
        WHEN 'year'  THEN TRUNC(stock.price::numeric * 0.74, stock.price_rounding::int)
    END
FROM stock
WHERE position.stock_id = stock.stock_id
AND position.buy_filled_price IS NOT NULL
AND position.sell_price IS NULL;

--Delete bad records
DELETE FROM position WHERE error_message IS NOT NULL AND buy_coinbase_order_id IS NULL;

TRUNCATE TABLE bulk_stock;
TRUNCATE TABLE bulk_fills;
TRUNCATE TABLE bulk_currency;
TRUNCATE TABLE bulk_open_orders;

$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: stock; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stock (
    stock_id integer NOT NULL,
    name text,
    date_created date,
    price double precision,
    historical_finished bit(1),
    historical_last_date date,
    score bigint,
    price_movement text,
    max_shares double precision,
    min_shares double precision,
    min_price double precision,
    max_price double precision,
    share_rounding integer,
    price_rounding integer
);


--
-- Name: Stock_StockID_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.stock ALTER COLUMN stock_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public."Stock_StockID_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: account; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account (
    account_id integer NOT NULL,
    date_created timestamp without time zone
);


--
-- Name: account_account_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.account ALTER COLUMN account_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.account_account_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: bulk_currency; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bulk_currency (
    bulk_currency_id integer NOT NULL,
    id text,
    currency text,
    balance double precision,
    hold double precision,
    available double precision,
    profile_id text,
    trading_enabled text
);


--
-- Name: bulk_currency_bulk_currency_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bulk_currency_bulk_currency_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bulk_currency_bulk_currency_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bulk_currency_bulk_currency_id_seq OWNED BY public.bulk_currency.bulk_currency_id;


--
-- Name: bulk_fills; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bulk_fills (
    bulk_fills_id integer NOT NULL,
    created_at timestamp without time zone,
    trade_id text,
    product_id text,
    order_id text,
    profile_id text,
    liquidity text,
    price double precision,
    size double precision,
    fee double precision,
    side text,
    settled text
);


--
-- Name: bulk_fills_bulk_fills_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bulk_fills_bulk_fills_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bulk_fills_bulk_fills_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bulk_fills_bulk_fills_id_seq OWNED BY public.bulk_fills.bulk_fills_id;


--
-- Name: bulk_historical; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bulk_historical (
    stock_id integer,
    start bigint,
    low double precision,
    high double precision,
    open double precision,
    close double precision,
    volume double precision
);


--
-- Name: bulk_open_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bulk_open_orders (
    bulk_open_orders_id integer NOT NULL,
    order_id text,
    product_id text,
    user_id text,
    order_configuration json,
    side text,
    client_order_id text,
    status text,
    time_in_force text,
    created_time timestamp without time zone,
    completion_percentage double precision,
    filled_size double precision,
    average_filled_price double precision,
    fee text,
    number_of_fills integer,
    filled_value double precision,
    pending_cancel boolean,
    size_in_quote boolean,
    total_fees double precision,
    size_inclusive_of_fees boolean,
    total_value_after_fees double precision,
    trigger_status text,
    order_type text,
    reject_reason text,
    settled boolean,
    product_type text,
    reject_message text,
    cancel_message text,
    order_placement_source text,
    outstanding_hold_amount double precision,
    is_liquidation boolean,
    last_fill_time timestamp without time zone,
    edit_history json,
    leverage text,
    margin_type text,
    retail_portfolio_id text,
    originating_order_id text,
    attached_order_id text,
    attached_order_configuration json,
    current_pending_replace json,
    commission_detail_total json,
    workable_size text,
    workable_size_completion_pct text,
    product_details json,
    cost_basis_method text,
    displayed_order_config text,
    equity_trading_session text,
    prediction_side text,
    last_update_time timestamp without time zone
);


--
-- Name: bulk_open_orders_bulk_open_orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bulk_open_orders_bulk_open_orders_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bulk_open_orders_bulk_open_orders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bulk_open_orders_bulk_open_orders_id_seq OWNED BY public.bulk_open_orders.bulk_open_orders_id;


--
-- Name: bulk_stock; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bulk_stock (
    bulk_stock_id integer NOT NULL,
    id text,
    quote_increment text,
    base_increment text,
    min_market_funds text,
    trading_disabled text,
    post_only text,
    cancel_only text,
    system text,
    price text,
    "json" json
);


--
-- Name: bulk_stock_bulk_stock_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bulk_stock_bulk_stock_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bulk_stock_bulk_stock_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bulk_stock_bulk_stock_id_seq OWNED BY public.bulk_stock.bulk_stock_id;


--
-- Name: config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.config (
    key text NOT NULL,
    value text NOT NULL
);


--
-- Name: portfolio; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.portfolio (
    portfolio_id integer NOT NULL,
    account_id integer,
    date_created timestamp without time zone
);


--
-- Name: portfolio_portfolio_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.portfolio ALTER COLUMN portfolio_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.portfolio_portfolio_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: position; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."position" (
    stock_id integer,
    name text,
    shares double precision,
    date_created timestamp without time zone,
    error_message text,
    period_type text,
    buy_filled_price double precision,
    buy_price double precision,
    sell_price double precision,
    buy_order_id text,
    sell_order_id text,
    buy_coinbase_order_id text,
    sell_coinbase_order_id text,
    buy_stop_price double precision,
    sell_stop_price double precision,
    sell_filled_price double precision,
    buy_fee double precision,
    sell_fee double precision,
    profit double precision,
    daily_sell boolean DEFAULT false NOT NULL,
    sell_counter integer DEFAULT 0 NOT NULL,
    buy_counter integer DEFAULT 0 NOT NULL
);


--
-- Name: price_aggregate; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.price_aggregate (
    price_aggregate_id integer NOT NULL,
    stock_id integer,
    period_type text,
    period_date date,
    open double precision,
    close double precision,
    high double precision,
    low double precision,
    avg_price double precision
);


--
-- Name: price_aggregate_comparison; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.price_aggregate_comparison (
    price_aggregate_comparison_id integer NOT NULL,
    before_id integer,
    after_id integer,
    change_percent double precision
);


--
-- Name: price_aggregate_comparison_price_aggregate_comparison_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.price_aggregate_comparison ALTER COLUMN price_aggregate_comparison_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.price_aggregate_comparison_price_aggregate_comparison_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: price_aggregate_total; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.price_aggregate_total (
    price_aggregate_total_id integer NOT NULL,
    stock_id integer,
    period_type text,
    avg_change_percent double precision,
    std_dev double precision,
    std_dev_upper_bound double precision,
    std_dev_lower_bound double precision
);


--
-- Name: price_aggregate_total_price_aggregate_total_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.price_aggregate_total ALTER COLUMN price_aggregate_total_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.price_aggregate_total_price_aggregate_total_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: price_aggregates_price_aggregate_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.price_aggregates_price_aggregate_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: price_aggregates_price_aggregate_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.price_aggregates_price_aggregate_id_seq OWNED BY public.price_aggregate.price_aggregate_id;


--
-- Name: price_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.price_history (
    price_history_id integer NOT NULL,
    stock_id integer,
    price double precision,
    date_created date
);


--
-- Name: price_history_price_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.price_history ALTER COLUMN price_history_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.price_history_price_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: profit_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profit_history (
    profit_history_id integer NOT NULL,
    stock_id integer,
    name text,
    period_type text,
    buy_coinbase_order_id text,
    sell_fills_id text,
    buy_fee double precision,
    sell_fee double precision,
    profit double precision,
    date_created timestamp without time zone DEFAULT now()
);


--
-- Name: profit_history_profit_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.profit_history_profit_history_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: profit_history_profit_history_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.profit_history_profit_history_id_seq OWNED BY public.profit_history.profit_history_id;


--
-- Name: vw_balance; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_balance AS
 SELECT s.name,
    s.stock_id,
    bc.balance,
    bc.hold,
    bc.available,
    (s.price * bc.balance) AS price_balance,
    (s.price * bc.available) AS price_available,
    (s.price * bc.hold) AS price_hold,
    (bc.balance * s.price) AS value
   FROM (public.bulk_currency bc
     JOIN public.stock s ON ((concat(bc.currency, '-USD') = s.name)))
UNION
 SELECT bc.currency AS name,
    NULL::integer AS stock_id,
    bc.balance,
    bc.hold,
    bc.available,
    0 AS price_balance,
    0 AS price_available,
    0 AS price_hold,
    bc.balance AS value
   FROM public.bulk_currency bc
  WHERE (bc.currency = ANY (ARRAY['USD'::text, 'USDC'::text]));


--
-- Name: vw_edit_orders; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_edit_orders AS
 SELECT p.name,
    p.period_type,
    trunc((((s.price)::numeric * bal.stop_mult) * 1.01), s.price_rounding) AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.buy_coinbase_order_id AS coinbase_order_id,
    p.shares,
    trunc(((s.price)::numeric * bal.stop_mult), s.price_rounding) AS new_stop_price,
    'buy'::text AS order_type,
    trunc((1.0 - ((s.price)::numeric / NULLIF(( SELECT (min(pa.low))::numeric AS min
           FROM public.price_aggregate pa
          WHERE ((pa.stock_id = p.stock_id) AND (pa.period_type = p.period_type))), (0)::numeric))), 4) AS estimated_profit,
    p.buy_counter AS counter
   FROM ((public."position" p
     JOIN public.stock s ON ((p.stock_id = s.stock_id)))
     CROSS JOIN LATERAL ( SELECT GREATEST(1.001, LEAST(1.05, ((1.01 + (0.04 * (1.0 - (COALESCE(( SELECT (b.available)::numeric AS available
                   FROM public.vw_balance b
                  WHERE (b.name = 'USD'::text)), (0)::numeric) / NULLIF((COALESCE(( SELECT (b.available)::numeric AS available
                   FROM public.vw_balance b
                  WHERE (b.name = 'USD'::text)), (0)::numeric) + COALESCE(( SELECT (sum((p2.buy_price * p2.shares)))::numeric AS sum
                   FROM public."position" p2
                  WHERE ((p2.buy_coinbase_order_id IS NOT NULL) AND (p2.buy_filled_price IS NULL))), (0)::numeric)), (0)::numeric))))) - ((p.buy_counter)::numeric * 0.001)))) AS stop_mult) bal)
  WHERE ((p.buy_coinbase_order_id IS NOT NULL) AND (p.buy_filled_price IS NULL) AND (p.buy_stop_price > (trunc(((s.price)::numeric * bal.stop_mult), s.price_rounding))::double precision))
UNION ALL
 SELECT p.name,
    p.period_type,
    trunc((((s.price)::numeric * (0.99 + ((p.sell_counter)::numeric * 0.001))) * 0.99), s.price_rounding) AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.sell_coinbase_order_id AS coinbase_order_id,
    p.shares,
    trunc(((s.price)::numeric * (0.99 + ((p.sell_counter)::numeric * 0.001))), s.price_rounding) AS new_stop_price,
    'sell'::text AS order_type,
    trunc(((((s.price)::numeric * (0.99 + ((p.sell_counter)::numeric * 0.001))) - (p.buy_filled_price)::numeric) * (p.shares)::numeric), 2) AS estimated_profit,
    p.sell_counter AS counter
   FROM (public."position" p
     JOIN public.stock s ON ((p.stock_id = s.stock_id)))
  WHERE ((p.sell_coinbase_order_id IS NOT NULL) AND (p.sell_filled_price IS NULL) AND (p.daily_sell = true) AND (p.sell_stop_price < (trunc(((s.price)::numeric * (0.99 + ((p.sell_counter)::numeric * 0.001))), s.price_rounding))::double precision))
UNION ALL
 SELECT p.name,
    p.period_type,
    trunc((((s.price)::numeric * (0.97 + ((p.sell_counter)::numeric * 0.001))) * 0.99), s.price_rounding) AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.sell_coinbase_order_id AS coinbase_order_id,
    p.shares,
    trunc(((s.price)::numeric * (0.97 + ((p.sell_counter)::numeric * 0.001))), s.price_rounding) AS new_stop_price,
    'sell'::text AS order_type,
    trunc(((((s.price)::numeric * (0.97 + ((p.sell_counter)::numeric * 0.001))) - (p.buy_filled_price)::numeric) * (p.shares)::numeric), 2) AS estimated_profit,
    p.sell_counter AS counter
   FROM (public."position" p
     JOIN public.stock s ON ((p.stock_id = s.stock_id)))
  WHERE ((p.sell_coinbase_order_id IS NOT NULL) AND (p.sell_filled_price IS NULL) AND (p.period_type = 'day'::text) AND (p.daily_sell = false) AND (p.sell_stop_price < (trunc(((s.price)::numeric * (0.97 + ((p.sell_counter)::numeric * 0.001))), s.price_rounding))::double precision))
UNION ALL
 SELECT p.name,
    p.period_type,
    trunc((((s.price)::numeric * (0.97 + ((p.sell_counter)::numeric * 0.001))) * 0.99), s.price_rounding) AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.sell_coinbase_order_id AS coinbase_order_id,
    p.shares,
    trunc(((s.price)::numeric * (0.97 + ((p.sell_counter)::numeric * 0.001))), s.price_rounding) AS new_stop_price,
    'sell'::text AS order_type,
    trunc(((((s.price)::numeric * (0.97 + ((p.sell_counter)::numeric * 0.001))) - (p.buy_filled_price)::numeric) * (p.shares)::numeric), 2) AS estimated_profit,
    p.sell_counter AS counter
   FROM (public."position" p
     JOIN public.stock s ON ((p.stock_id = s.stock_id)))
  WHERE ((p.sell_coinbase_order_id IS NOT NULL) AND (p.sell_filled_price IS NULL) AND (p.period_type = 'day'::text) AND (p.daily_sell = false) AND (p.sell_stop_price > (trunc(((s.price)::numeric * (0.98 + ((p.sell_counter)::numeric * 0.001))), s.price_rounding))::double precision))
UNION ALL
 SELECT p.name,
    p.period_type,
    trunc((((s.price)::numeric * (0.90 + ((p.sell_counter)::numeric * 0.001))) * 0.99), s.price_rounding) AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.sell_coinbase_order_id AS coinbase_order_id,
    p.shares,
    trunc(((s.price)::numeric * (0.90 + ((p.sell_counter)::numeric * 0.001))), s.price_rounding) AS new_stop_price,
    'sell'::text AS order_type,
    trunc(((((s.price)::numeric * (0.90 + ((p.sell_counter)::numeric * 0.001))) - (p.buy_filled_price)::numeric) * (p.shares)::numeric), 2) AS estimated_profit,
    p.sell_counter AS counter
   FROM (public."position" p
     JOIN public.stock s ON ((p.stock_id = s.stock_id)))
  WHERE ((p.sell_coinbase_order_id IS NOT NULL) AND (p.sell_filled_price IS NULL) AND (p.period_type = 'month'::text) AND (p.daily_sell = false) AND (p.sell_stop_price < (trunc(((s.price)::numeric * (0.90 + ((p.sell_counter)::numeric * 0.001))), s.price_rounding))::double precision))
UNION ALL
 SELECT p.name,
    p.period_type,
    trunc((((s.price)::numeric * (0.90 + ((p.sell_counter)::numeric * 0.001))) * 0.99), s.price_rounding) AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.sell_coinbase_order_id AS coinbase_order_id,
    p.shares,
    trunc(((s.price)::numeric * (0.90 + ((p.sell_counter)::numeric * 0.001))), s.price_rounding) AS new_stop_price,
    'sell'::text AS order_type,
    trunc(((((s.price)::numeric * (0.90 + ((p.sell_counter)::numeric * 0.001))) - (p.buy_filled_price)::numeric) * (p.shares)::numeric), 2) AS estimated_profit,
    p.sell_counter AS counter
   FROM (public."position" p
     JOIN public.stock s ON ((p.stock_id = s.stock_id)))
  WHERE ((p.sell_coinbase_order_id IS NOT NULL) AND (p.sell_filled_price IS NULL) AND (p.period_type = 'month'::text) AND (p.daily_sell = false) AND (p.sell_stop_price > (trunc(((s.price)::numeric * (0.91 + ((p.sell_counter)::numeric * 0.001))), s.price_rounding))::double precision))
UNION ALL
 SELECT p.name,
    p.period_type,
    trunc((((s.price)::numeric * (0.75 + ((p.sell_counter)::numeric * 0.001))) * 0.99), s.price_rounding) AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.sell_coinbase_order_id AS coinbase_order_id,
    p.shares,
    trunc(((s.price)::numeric * (0.75 + ((p.sell_counter)::numeric * 0.001))), s.price_rounding) AS new_stop_price,
    'sell'::text AS order_type,
    trunc(((((s.price)::numeric * (0.75 + ((p.sell_counter)::numeric * 0.001))) - (p.buy_filled_price)::numeric) * (p.shares)::numeric), 2) AS estimated_profit,
    p.sell_counter AS counter
   FROM (public."position" p
     JOIN public.stock s ON ((p.stock_id = s.stock_id)))
  WHERE ((p.sell_coinbase_order_id IS NOT NULL) AND (p.sell_filled_price IS NULL) AND (p.period_type = 'year'::text) AND (p.daily_sell = false) AND (p.sell_stop_price < (trunc(((s.price)::numeric * (0.75 + ((p.sell_counter)::numeric * 0.001))), s.price_rounding))::double precision))
UNION ALL
 SELECT p.name,
    p.period_type,
    trunc((((s.price)::numeric * (0.75 + ((p.sell_counter)::numeric * 0.001))) * 0.99), s.price_rounding) AS order_price,
    s.price AS price_now,
    p.buy_order_id,
    p.sell_coinbase_order_id AS coinbase_order_id,
    p.shares,
    trunc(((s.price)::numeric * (0.75 + ((p.sell_counter)::numeric * 0.001))), s.price_rounding) AS new_stop_price,
    'sell'::text AS order_type,
    trunc(((((s.price)::numeric * (0.75 + ((p.sell_counter)::numeric * 0.001))) - (p.buy_filled_price)::numeric) * (p.shares)::numeric), 2) AS estimated_profit,
    p.sell_counter AS counter
   FROM (public."position" p
     JOIN public.stock s ON ((p.stock_id = s.stock_id)))
  WHERE ((p.sell_coinbase_order_id IS NOT NULL) AND (p.sell_filled_price IS NULL) AND (p.period_type = 'year'::text) AND (p.daily_sell = false) AND (p.sell_stop_price > (trunc(((s.price)::numeric * (0.76 + ((p.sell_counter)::numeric * 0.001))), s.price_rounding))::double precision))
  ORDER BY 10 DESC;


--
-- Name: vw_latest_fills; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_latest_fills AS
 SELECT s.stock_id,
    s.name,
    bfs.bulk_fills_id AS sell_id,
    bfs.order_id AS sell_order,
    bfs.created_at AS sell_date,
    bfs.price AS sell_price,
    bfs.size AS sell_size,
    bfs.fee AS sell_fee,
    (bfs.price * bfs.size) AS sell_value,
    bfb.bulk_fills_id AS buy_id,
    bfb.order_id AS buy_order,
    bfb.created_at AS buy_date,
    bfb.price AS buy_price,
    bfb.size AS buy_size,
    bfb.fee AS buy_fee,
    (bfb.price * bfb.size) AS buy_value
   FROM ((((public.stock s
     LEFT JOIN ( SELECT bulk_fills.product_id,
            bulk_fills.side,
            max(bulk_fills.bulk_fills_id) AS max_id
           FROM public.bulk_fills
          WHERE (bulk_fills.side = 'SELL'::text)
          GROUP BY bulk_fills.product_id, bulk_fills.side) max_sell ON ((s.name = max_sell.product_id)))
     LEFT JOIN public.bulk_fills bfs ON ((max_sell.max_id = bfs.bulk_fills_id)))
     LEFT JOIN ( SELECT bulk_fills.product_id,
            bulk_fills.side,
            max(bulk_fills.bulk_fills_id) AS max_id
           FROM public.bulk_fills
          WHERE (bulk_fills.side = 'BUY'::text)
          GROUP BY bulk_fills.product_id, bulk_fills.side) max_buy ON ((s.name = max_sell.product_id)))
     LEFT JOIN public.bulk_fills bfb ON ((max_buy.max_id = bfb.bulk_fills_id)));


--
-- Name: vw_position; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_position AS
 SELECT stock_id,
    name,
    period_type,
    count(1) AS cnt,
    sum(shares) AS sum_shares,
    max(buy_price) AS max_buy_price,
    min(buy_price) AS min_buy_price,
    sum((buy_price * shares)) AS sum_buy_value,
    max(buy_order_id) AS max_buy_order_id,
    min(buy_order_id) AS min_buy_order_id,
    max(buy_coinbase_order_id) AS max_buy_coinbase_order_id,
    min(buy_coinbase_order_id) AS min_buy_coinbase_order_id,
    max(buy_filled_price) AS max_buy_filled_price,
        CASE
            WHEN bool_or((buy_filled_price IS NULL)) THEN NULL::double precision
            ELSE min(buy_filled_price)
        END AS min_buy_filled_price,
    min(buy_stop_price) AS min_buy_stop_price,
    max(buy_stop_price) AS max_buy_stop_price,
    min(date_created) AS min_date_created,
    max(date_created) AS max_date_created
   FROM public."position"
  GROUP BY stock_id, name, period_type;


--
-- Name: vw_profit_summary; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_profit_summary AS
 SELECT period_type,
    count(*) AS total_trades,
    round((sum(profit))::numeric, 2) AS all_time_profit,
    round((avg(profit))::numeric, 2) AS all_time_avg,
    count(*) FILTER (WHERE ((date_created)::date = CURRENT_DATE)) AS today_trades,
    round((COALESCE(sum(profit) FILTER (WHERE ((date_created)::date = CURRENT_DATE)), (0)::double precision))::numeric, 2) AS today_profit,
    round((avg(profit) FILTER (WHERE ((date_created)::date = CURRENT_DATE)))::numeric, 2) AS today_avg,
    count(*) FILTER (WHERE (date_trunc('month'::text, date_created) = date_trunc('month'::text, now()))) AS month_trades,
    round((COALESCE(sum(profit) FILTER (WHERE (date_trunc('month'::text, date_created) = date_trunc('month'::text, now()))), (0)::double precision))::numeric, 2) AS month_profit,
    round((avg(profit) FILTER (WHERE (date_trunc('month'::text, date_created) = date_trunc('month'::text, now()))))::numeric, 2) AS month_avg,
    count(*) FILTER (WHERE (date_trunc('year'::text, date_created) = date_trunc('year'::text, now()))) AS year_trades,
    round((COALESCE(sum(profit) FILTER (WHERE (date_trunc('year'::text, date_created) = date_trunc('year'::text, now()))), (0)::double precision))::numeric, 2) AS year_profit,
    round((avg(profit) FILTER (WHERE (date_trunc('year'::text, date_created) = date_trunc('year'::text, now()))))::numeric, 2) AS year_avg
   FROM public.profit_history
  GROUP BY period_type
  ORDER BY period_type;


--
-- Name: vw_rsi; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_rsi AS
 WITH price_changes AS (
         SELECT price_aggregate.stock_id,
            price_aggregate.period_type,
            price_aggregate.period_date,
            price_aggregate.close,
            lag(price_aggregate.close) OVER (PARTITION BY price_aggregate.stock_id, price_aggregate.period_type ORDER BY price_aggregate.period_date) AS prev_close
           FROM public.price_aggregate
        ), gains_losses AS (
         SELECT price_changes.stock_id,
            price_changes.period_type,
            price_changes.period_date,
            GREATEST((price_changes.close - price_changes.prev_close), (0)::double precision) AS gain,
            GREATEST((price_changes.prev_close - price_changes.close), (0)::double precision) AS loss,
            row_number() OVER (PARTITION BY price_changes.stock_id, price_changes.period_type ORDER BY price_changes.period_date DESC) AS rn
           FROM price_changes
          WHERE (price_changes.prev_close IS NOT NULL)
        ), rsi_calc AS (
         SELECT gains_losses.stock_id,
            gains_losses.period_type,
            avg(gains_losses.gain) AS avg_gain,
            avg(gains_losses.loss) AS avg_loss
           FROM gains_losses
          WHERE (gains_losses.rn <= 14)
          GROUP BY gains_losses.stock_id, gains_losses.period_type
        )
 SELECT stock_id,
    period_type,
    round((
        CASE
            WHEN (avg_loss = (0)::double precision) THEN (100)::double precision
            ELSE ((100)::double precision - ((100.0)::double precision / ((1)::double precision + (avg_gain / avg_loss))))
        END)::numeric, 2) AS rsi
   FROM rsi_calc;


--
-- Name: vw_signal; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_signal AS
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
    trunc((pat.avg_change_percent)::numeric, 2) AS historical_avg_change_percent,
    trunc((pat.std_dev)::numeric, 2) AS std_dev,
    trunc((pat.std_dev_upper_bound)::numeric, 2) AS std_dev_upper_bound,
    trunc((pat.std_dev_lower_bound)::numeric, 2) AS std_dev_lower_bound,
    trunc((pac.change_percent)::numeric, 2) AS current_change_percent,
    trunc((((pac.change_percent - pat.avg_change_percent) / NULLIF(pat.std_dev, (0)::double precision)))::numeric, 2) AS signal,
    trunc(((((period_score.cnt)::double precision * pat.avg_change_percent) / NULLIF(pat.std_dev, (0)::double precision)))::numeric, 2) AS score,
    trunc((((((period_score.cnt)::double precision * pat.avg_change_percent) / NULLIF(pat.std_dev, (0)::double precision)) * abs(((pac.change_percent - pat.avg_change_percent) / NULLIF(pat.std_dev, (0)::double precision)))))::numeric, 2) AS priority,
        CASE
            WHEN (((pac.change_percent - pat.avg_change_percent) / NULLIF(pat.std_dev, (0)::double precision)) < (0)::double precision) THEN 'BUY'::text
            WHEN (((pac.change_percent - pat.avg_change_percent) / NULLIF(pat.std_dev, (0)::double precision)) > (0)::double precision) THEN 'SELL'::text
            ELSE 'HOLD'::text
        END AS recommendation
   FROM ((((public.price_aggregate pa
     JOIN public.price_aggregate_comparison pac ON ((pa.price_aggregate_id = pac.after_id)))
     JOIN public.stock s ON ((s.stock_id = pa.stock_id)))
     JOIN public.price_aggregate_total pat ON (((pa.stock_id = pat.stock_id) AND (pa.period_type = pat.period_type))))
     JOIN ( SELECT price_aggregate.stock_id,
            price_aggregate.period_type,
            count(1) AS cnt,
            string_agg((trunc((price_aggregate.close)::numeric, 2))::text, ','::text ORDER BY price_aggregate.period_date) AS prices
           FROM public.price_aggregate
          GROUP BY price_aggregate.stock_id, price_aggregate.period_type) period_score ON (((pa.stock_id = period_score.stock_id) AND (pa.period_type = period_score.period_type))))
  WHERE (((pa.period_type = 'day'::text) AND (pa.period_date = (now())::date)) OR ((pa.period_type = 'month'::text) AND (pa.period_date = (date_trunc('month'::text, now()))::date)) OR ((pa.period_type = 'year'::text) AND (pa.period_date = (date_trunc('year'::text, now()))::date)))
  ORDER BY pa.period_type DESC, (trunc((((((period_score.cnt)::double precision * pat.avg_change_percent) / NULLIF(pat.std_dev, (0)::double precision)) * abs(((pac.change_percent - pat.avg_change_percent) / NULLIF(pat.std_dev, (0)::double precision)))))::numeric, 2)) DESC NULLS LAST;


--
-- Name: bulk_currency bulk_currency_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_currency ALTER COLUMN bulk_currency_id SET DEFAULT nextval('public.bulk_currency_bulk_currency_id_seq'::regclass);


--
-- Name: bulk_fills bulk_fills_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_fills ALTER COLUMN bulk_fills_id SET DEFAULT nextval('public.bulk_fills_bulk_fills_id_seq'::regclass);


--
-- Name: bulk_open_orders bulk_open_orders_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_open_orders ALTER COLUMN bulk_open_orders_id SET DEFAULT nextval('public.bulk_open_orders_bulk_open_orders_id_seq'::regclass);


--
-- Name: bulk_stock bulk_stock_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_stock ALTER COLUMN bulk_stock_id SET DEFAULT nextval('public.bulk_stock_bulk_stock_id_seq'::regclass);


--
-- Name: price_aggregate price_aggregate_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_aggregate ALTER COLUMN price_aggregate_id SET DEFAULT nextval('public.price_aggregates_price_aggregate_id_seq'::regclass);


--
-- Name: profit_history profit_history_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profit_history ALTER COLUMN profit_history_id SET DEFAULT nextval('public.profit_history_profit_history_id_seq'::regclass);


--
-- Name: stock Stock_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock
    ADD CONSTRAINT "Stock_pkey" PRIMARY KEY (stock_id);


--
-- Name: account account_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_pkey PRIMARY KEY (account_id);


--
-- Name: bulk_currency bulk_currency_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_currency
    ADD CONSTRAINT bulk_currency_pkey PRIMARY KEY (bulk_currency_id);


--
-- Name: bulk_fills bulk_fills_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_fills
    ADD CONSTRAINT bulk_fills_pkey PRIMARY KEY (bulk_fills_id);


--
-- Name: bulk_open_orders bulk_open_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_open_orders
    ADD CONSTRAINT bulk_open_orders_pkey PRIMARY KEY (bulk_open_orders_id);


--
-- Name: bulk_stock bulk_stock_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bulk_stock
    ADD CONSTRAINT bulk_stock_pkey PRIMARY KEY (bulk_stock_id);


--
-- Name: config config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.config
    ADD CONSTRAINT config_pkey PRIMARY KEY (key);


--
-- Name: portfolio portfolio_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.portfolio
    ADD CONSTRAINT portfolio_pkey PRIMARY KEY (portfolio_id);


--
-- Name: price_aggregate_comparison price_aggregate_comparison_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_aggregate_comparison
    ADD CONSTRAINT price_aggregate_comparison_pkey PRIMARY KEY (price_aggregate_comparison_id);


--
-- Name: price_aggregate_total price_aggregate_total_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_aggregate_total
    ADD CONSTRAINT price_aggregate_total_pkey PRIMARY KEY (price_aggregate_total_id);


--
-- Name: price_aggregate price_aggregates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_aggregate
    ADD CONSTRAINT price_aggregates_pkey PRIMARY KEY (price_aggregate_id);


--
-- Name: price_history price_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_history
    ADD CONSTRAINT price_history_pkey PRIMARY KEY (price_history_id);


--
-- Name: profit_history profit_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profit_history
    ADD CONSTRAINT profit_history_pkey PRIMARY KEY (profit_history_id);


--
-- PostgreSQL database dump complete
--

\unrestrict rpjvAVeU3J5gTuUgl7pKdq5w1a0KT4K9B4ZuYbB8z9kfnH9iNzudraKBztJ9uoN

