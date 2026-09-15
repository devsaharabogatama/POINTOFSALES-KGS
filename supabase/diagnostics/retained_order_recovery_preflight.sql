-- SELECT-only, entire file. SETUP absent new RPC is expected before install.
WITH checks AS (
 SELECT 'recovery_dependency' check_name,CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END status,
 jsonb_build_object('present',count(*),'expected',4) details FROM private.kgs_schema_migrations
 WHERE version IN('20260915140000','20260915141000','20260915142000','20260916100000')
 UNION ALL SELECT 'recovery_collision',CASE WHEN to_regprocedure('public.recover_retained_sales_process_order(uuid,bigint,bigint,bigint,uuid)') IS NULL THEN 'SETUP'
 WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260916101000') THEN 'PASS' ELSE 'BLOCKER' END,'{}'::jsonb
 UNION ALL SELECT 'recovery_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,jsonb_build_object('rows',count(*))
 FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
 UNION ALL SELECT 'recovery_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,jsonb_build_object('rows',count(*))
 FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
) SELECT * FROM checks ORDER BY check_name;
