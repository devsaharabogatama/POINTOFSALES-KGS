-- Clone only. Launch holder, then contender within 8 seconds of lock acquisition.
-- No business rows written; locks automatically release on rollback.
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended(id::text,20260911130000)),
 pg_advisory_xact_lock(hashtextextended(id::text||':sales-process-cutover',0))
FROM public.companies WHERE status='ACTIVE' ORDER BY id LIMIT 1;
SELECT pg_sleep(8);
ROLLBACK;
