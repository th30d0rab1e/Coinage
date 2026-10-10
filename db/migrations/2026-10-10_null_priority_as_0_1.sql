-- 2026-10-10 (Theodore): thee_procedure treats NULL priority as 0.1 at read
-- time (COALESCE(priority, 0.1)) in the buy filters (initial buy s.priority > 0,
-- dip buy st.priority > 0) and in every priority sort (initial buy, listing
-- buy, cash-walk ROW_NUMBER, dip-buy WINDOW). NULLs now sort as 0.1 instead of
-- NULLS LAST / NULLS FIRST. stock.priority itself is unchanged: the year-row
-- copy still writes NULL when there is no year row; no data UPDATE.
\ir ../procedures/thee_procedure.sql
