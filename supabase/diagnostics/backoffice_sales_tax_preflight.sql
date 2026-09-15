-- Read-only guard for Backoffice Quotation/SO canonical sales-tax integration.
WITH checks(check_name,status,details) AS (
  SELECT 'migration_dependencies',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',4,'rows',count(*))
  FROM private.kgs_schema_migrations
  WHERE version IN ('20260723070000','20260729070000','20260908121000','20260909100000')
  UNION ALL
  SELECT 'canonical_tax_routines',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',2,'rows',count(*))
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='private' AND p.proname IN('resolve_product_tax_rule','calculate_tax_group')
  UNION ALL
  SELECT 'existing_backoffice_documents',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'rule','Tax semantic correction requires zero pilot documents')
  FROM public.backoffice_sales_orders
  UNION ALL
  SELECT 'active_finance_posting_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*)) FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
)
SELECT * FROM checks ORDER BY CASE status WHEN 'BLOCKER' THEN 1 ELSE 2 END,check_name;
