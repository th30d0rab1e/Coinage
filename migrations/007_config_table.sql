-- config table: key/value store for runtime bot settings
CREATE TABLE config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

INSERT INTO config (key, value) VALUES ('pause_buys', 'false');
