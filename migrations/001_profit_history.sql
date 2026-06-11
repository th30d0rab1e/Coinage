-- Create profit_history table
CREATE TABLE profit_history (
    profit_history_id SERIAL PRIMARY KEY,
    stock_id INTEGER,
    name TEXT,
    period_type TEXT,
    buy_fills_id TEXT,
    sell_fills_id TEXT,
    buy_fee DOUBLE PRECISION,
    sell_fee DOUBLE PRECISION,
    profit DOUBLE PRECISION,
    date_created TIMESTAMP DEFAULT NOW()
);

-- Change buy_fills_id and sell_fills_id on position to TEXT
ALTER TABLE position
    ALTER COLUMN buy_fills_id TYPE TEXT USING buy_fills_id::TEXT;
