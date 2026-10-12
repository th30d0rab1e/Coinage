-- 2026-10-11 (Theodore): revert da7ddee NULL priority as 0.1 on buys.
-- thee_procedure again requires priority > 0 and sorts NULLS LAST / plain DESC.
-- Reload: psql -f db/procedures/thee_procedure.sql

\i db/procedures/thee_procedure.sql
