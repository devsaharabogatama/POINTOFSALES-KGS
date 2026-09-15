-- SELECT-only postflight for Step 4/6.1.
WITH checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260911164000'
  UNION ALL
  SELECT 'required_discrepancy_relations',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(4-count(*)),jsonb_build_object('relationRows',count(*),'expected',4)
  FROM pg_class rel JOIN pg_namespace ns ON ns.oid=rel.relnamespace
  WHERE ns.nspname='public' AND rel.relname IN(
    'backoffice_sales_delivery_discrepancies','backoffice_sales_delivery_discrepancy_lines',
    'backoffice_sales_discrepancy_operations','backoffice_sales_discrepancy_audit')
  UNION ALL
  SELECT 'required_discrepancy_routines',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(3-count(*)),jsonb_build_object('routineRows',count(*),'expected',3)
  FROM pg_proc proc JOIN pg_namespace ns ON ns.oid=proc.pronamespace
  WHERE ns.nspname='private' AND proc.proname IN(
    'classify_backoffice_sales_discrepancy',
    'validate_backoffice_sales_receipt_disposition_payload',
    'trg_guard_backoffice_sales_discrepancy_history')
  UNION ALL
  SELECT 'discrepancy_rls_state',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(4-count(*)),jsonb_build_object('enabledRelations',count(*))
  FROM pg_class rel JOIN pg_namespace ns ON ns.oid=rel.relnamespace
  WHERE ns.nspname='public' AND rel.relrowsecurity AND rel.relname IN(
    'backoffice_sales_delivery_discrepancies','backoffice_sales_delivery_discrepancy_lines',
    'backoffice_sales_discrepancy_operations','backoffice_sales_discrepancy_audit')
  UNION ALL
  SELECT 'discrepancy_browser_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants
  WHERE table_schema='public' AND grantee IN('PUBLIC','anon','authenticated')
    AND table_name IN('backoffice_sales_delivery_discrepancies',
      'backoffice_sales_delivery_discrepancy_lines',
      'backoffice_sales_discrepancy_operations','backoffice_sales_discrepancy_audit')
  UNION ALL
  SELECT 'discrepancy_private_execution_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('browserExecutableRows',count(*))
  FROM information_schema.routine_privileges
  WHERE routine_schema='private' AND grantee IN('PUBLIC','anon','authenticated')
    AND routine_name IN('classify_backoffice_sales_discrepancy',
      'validate_backoffice_sales_receipt_disposition_payload',
      'trg_guard_backoffice_sales_discrepancy_history')
  UNION ALL
  SELECT 'legacy_clean_receipt_compatibility',
    CASE WHEN to_regprocedure('public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NOT NULL
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regprocedure('public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NOT NULL
      THEN 0 ELSE 1 END,
    jsonb_build_object('legacyWrapperPreserved',to_regprocedure(
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NOT NULL)
  UNION ALL
  SELECT 'discrepancy_runtime_inventory','INFO',0,
    jsonb_build_object('cases',count(*),'openCases',count(*) FILTER(
      WHERE status NOT IN('RESOLVED','CANCELED')))
  FROM public.backoffice_sales_delivery_discrepancies
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY check_name;
