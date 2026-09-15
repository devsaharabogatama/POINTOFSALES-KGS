-- Read-only gate for the Backoffice Invoice client activation.
WITH checks AS (
  SELECT 'migration_dependency' check_name,
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END status,
    5-count(*) violation_rows,
    jsonb_build_object('expected',5,'present',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260909157000','20260909159000','20260909161000','20260910150000','20260910151000')
  UNION ALL
  SELECT 'required_invoice_runtime','PASS',0,
    jsonb_build_object('save',to_regprocedure('public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb)') IS NOT NULL,
      'post',to_regprocedure('public.post_backoffice_sales_invoice(uuid,bigint,uuid)') IS NOT NULL,
      'read',to_regprocedure('public.get_backoffice_sales_invoice(uuid)') IS NOT NULL)
  WHERE to_regprocedure('public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb)') IS NOT NULL
    AND to_regprocedure('public.post_backoffice_sales_invoice(uuid,bigint,uuid)') IS NOT NULL
    AND to_regprocedure('public.get_backoffice_sales_invoice(uuid)') IS NOT NULL
  UNION ALL
  SELECT 'required_invoice_runtime','BLOCKER',1,jsonb_build_object('missing','canonical Invoice routine')
  WHERE to_regprocedure('public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb)') IS NULL
    OR to_regprocedure('public.post_backoffice_sales_invoice(uuid,bigint,uuid)') IS NULL
    OR to_regprocedure('public.get_backoffice_sales_invoice(uuid)') IS NULL
  UNION ALL
  SELECT 'client_activation_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('existing',count(*))
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE (n.nspname,p.proname) IN(('private','backoffice_sales_invoice_ui_snapshot'),
    ('public','get_backoffice_sales_invoice_workspace'),('public','get_backoffice_sales_invoice_ui'))
  UNION ALL
  SELECT 'active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('activeRuns',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('submissions',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY status,check_name;
