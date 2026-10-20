-- 2026-10-19 (Theodore): stop bot buys of TOPW; holdings kept.
UPDATE etf SET enabled = false WHERE ticker = 'TOPW';
