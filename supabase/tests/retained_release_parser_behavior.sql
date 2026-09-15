-- Parser proof only; no business writes. Full migrations were freshly installed individually.
BEGIN;
DO $parser$ BEGIN EXECUTE 'SELECT 1; SELECT 2'; END $parser$;
ROLLBACK;
