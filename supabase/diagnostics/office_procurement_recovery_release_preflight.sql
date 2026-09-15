-- SELECT-only prerequisite check for the WHOLE atomic six-migration release.
-- SETUP means not installed, not a waived blocker. Run entire file.
WITH deps(signature) AS (VALUES
 ('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)'),
 ('private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)'),
 ('private.reconcile_session_procurement_request(uuid,uuid,uuid,uuid)'),
 ('private.sync_managed_request_single_draft_po(uuid,uuid,uuid,uuid)'),
 ('private.acp_require_permission_capability(uuid,text,text)')),
checks AS (
 SELECT 'base_ledger' check_name,CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
 jsonb_build_object('present',count(*),'expected',2) details FROM private.kgs_schema_migrations
 WHERE version IN ('20260828190000','20260911130000')
 UNION ALL SELECT 'base_routines',CASE WHEN bool_and(to_regprocedure(signature) IS NOT NULL) THEN 'PASS' ELSE 'BLOCKER' END,
 jsonb_build_object('missing',COALESCE(jsonb_agg(signature) FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::jsonb)) FROM deps
 UNION ALL SELECT 'open_cutover_plans',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,jsonb_build_object('rows',count(*))
 FROM public.sales_process_cutover_plans WHERE status IN ('DRAFT','PREVIEWED','APPLYING')
 UNION ALL SELECT 'active_finance',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,jsonb_build_object('rows',count(*))
 FROM public.finance_posting_queue_runs WHERE status IN ('PREVIEWED','APPROVED','PROCESSING')
 UNION ALL SELECT 'active_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,jsonb_build_object('rows',count(*))
 FROM public.pos_offline_sale_submissions WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION')
 UNION ALL SELECT 'release_installation',CASE WHEN count(*)=6 THEN 'PASS' WHEN count(*)=0 THEN 'SETUP' ELSE 'REVIEW' END,
 jsonb_build_object('installed',count(*),'expected',6,'partialRule','Bundle may resume only if its exact guards and final runtime verification pass')
 FROM private.kgs_schema_migrations WHERE version IN ('20260915140000','20260915141000','20260915142000','20260916100000','20260916101000','20260916102000')
 UNION ALL SELECT 'unledgered_lineage_collision',CASE WHEN to_regclass('public.sales_cutover_procurement_links') IS NOT NULL
 AND NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915140000') THEN 'BLOCKER' ELSE 'PASS' END,'{}'::jsonb
 UNION ALL SELECT 'unledgered_recovery_collision',CASE WHEN to_regprocedure('public.recover_retained_sales_process_order(uuid,bigint,bigint,bigint,uuid)') IS NOT NULL
 AND NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260916101000') THEN 'BLOCKER' ELSE 'PASS' END,'{}'::jsonb
 UNION ALL SELECT 'environment_identity','INFO',jsonb_build_object('database',current_database(),'server',inet_server_addr(),'user',current_user,'capturedAt',clock_timestamp(),'projectRefNotProvedByThisQuery',true)
) SELECT * FROM checks ORDER BY check_name;

