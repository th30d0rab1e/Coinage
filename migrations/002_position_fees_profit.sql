-- Add fee and profit tracking columns to position
ALTER TABLE position
    ADD COLUMN buy_fee DOUBLE PRECISION,
    ADD COLUMN sell_fee DOUBLE PRECISION,
    ADD COLUMN profit DOUBLE PRECISION,
    ADD COLUMN buy_fills_id TEXT;
