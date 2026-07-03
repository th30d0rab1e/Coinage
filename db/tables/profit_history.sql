CREATE TABLE IF NOT EXISTS public.profit_history (
    profit_history_id      integer PRIMARY KEY DEFAULT nextval('profit_history_profit_history_id_seq'),
    stock_id               integer,
    name                   text,
    period_type            text,
    buy_coinbase_order_id  text,
    sell_fills_id          text,
    buy_fee                double precision,
    sell_fee               double precision,
    profit                 double precision,
    date_created           timestamp without time zone DEFAULT now()
);
