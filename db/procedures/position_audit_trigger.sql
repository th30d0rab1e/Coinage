-- Audit trail for the position table. Every INSERT/DELETE gets one row with
-- a full JSON snapshot of the row; every UPDATE gets one row per column that
-- actually changed (old_value/new_value), so "when did sell_coinbase_order_id
-- get nulled" or similar is a direct, queryable question instead of manual
-- log archaeology. Keyed on position's auto-increment primary key
-- (position_id) only. Written as CREATE ... IF NOT EXISTS / DROP COLUMN IF
-- EXISTS throughout so re-applying this file never drops and recreates the
-- table -- that would destroy accumulated audit history for no reason.
CREATE TABLE IF NOT EXISTS position_audit (
    audit_id BIGSERIAL PRIMARY KEY,
    position_id BIGINT,
    operation TEXT NOT NULL,
    column_name TEXT,
    old_value TEXT,
    new_value TEXT,
    changed_at TIMESTAMP NOT NULL DEFAULT NOW()
);

ALTER TABLE position_audit DROP COLUMN IF EXISTS buy_order_id;

CREATE INDEX IF NOT EXISTS idx_position_audit_position_id ON position_audit (position_id);
CREATE INDEX IF NOT EXISTS idx_position_audit_column_name ON position_audit (column_name);
CREATE INDEX IF NOT EXISTS idx_position_audit_changed_at ON position_audit (changed_at);

CREATE OR REPLACE FUNCTION position_audit_trigger() RETURNS TRIGGER AS $$
DECLARE
    old_json JSONB;
    new_json JSONB;
    key TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO position_audit (position_id, operation, column_name, old_value, new_value)
        VALUES (NEW.position_id, 'INSERT', NULL, NULL, to_jsonb(NEW)::text);
        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO position_audit (position_id, operation, column_name, old_value, new_value)
        VALUES (OLD.position_id, 'DELETE', NULL, to_jsonb(OLD)::text, NULL);
        RETURN OLD;

    ELSIF TG_OP = 'UPDATE' THEN
        old_json := to_jsonb(OLD);
        new_json := to_jsonb(NEW);
        FOR key IN SELECT jsonb_object_keys(new_json) LOOP
            IF old_json -> key IS DISTINCT FROM new_json -> key THEN
                INSERT INTO position_audit (position_id, operation, column_name, old_value, new_value)
                VALUES (NEW.position_id, 'UPDATE', key, old_json ->> key, new_json ->> key);
            END IF;
        END LOOP;
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS position_audit_trg ON position;
CREATE TRIGGER position_audit_trg
AFTER INSERT OR UPDATE OR DELETE ON position
FOR EACH ROW EXECUTE FUNCTION position_audit_trigger();
