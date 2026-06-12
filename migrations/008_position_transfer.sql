-- Add transfer_amount (20% of profit) and transfer_complete flag to position
-- thee_procedure sets transfer_amount on sell fill; DELETE is gated until transfer_complete = true
ALTER TABLE position
    ADD COLUMN transfer_amount  NUMERIC,
    ADD COLUMN transfer_complete BOOLEAN DEFAULT FALSE;
