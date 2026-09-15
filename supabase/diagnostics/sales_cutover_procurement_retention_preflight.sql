-- Run whole file; SELECT only. No repair or production mutation.
WITH checks AS(
 SELECT 'retention_dependency' check_name,CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915140000') THEN 'PASS' ELSE 'BLOCKER' END status,
 jsonb_build_object('requiredVersion','20260915140000') details
 UNION ALL SELECT 'open_cutover_previews',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,jsonb_build_object('rows',count(*))
 FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING')
 UNION ALL SELECT 'active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,jsonb_build_object('rows',count(*))
 FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
 UNION ALL SELECT 'nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,jsonb_build_object('rows',count(*))
 FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
 UNION ALL SELECT 'retention_installation',CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915141000') THEN 'INFO' ELSE 'SETUP' END,
 jsonb_build_object('version','20260915141000','note','Do not rerun installed migration')
)SELECT * FROM checks ORDER BY check_name;

