-- SELECT-only verification for 20260910140000.
WITH checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260910140000'
  UNION ALL
  SELECT 'procurement_classifier_definition_contract',
    CASE WHEN count(*)=1
      AND bool_and(pg_get_functiondef(proc.oid) LIKE '%OPEN_PROCUREMENT_MUST_FINISH%')
      AND bool_and(pg_get_functiondef(proc.oid) NOT LIKE '%TRANSFER_PROCUREMENT_LINEAGE%')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1
      AND bool_and(pg_get_functiondef(proc.oid) LIKE '%OPEN_PROCUREMENT_MUST_FINISH%')
      AND bool_and(pg_get_functiondef(proc.oid) NOT LIKE '%TRANSFER_PROCUREMENT_LINEAGE%')
      THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname='private' AND proc.oid=to_regprocedure(
    'private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)')
  UNION ALL
  SELECT 'procurement_classifier_runtime_contract',
    CASE WHEN result->>'decision'='BLOCKED'
      AND result->'blockerCodes' ? 'OPEN_PROCUREMENT_MUST_FINISH'
      AND jsonb_array_length(result->'requirementCodes')=0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN result->>'decision'='BLOCKED'
      AND result->'blockerCodes' ? 'OPEN_PROCUREMENT_MUST_FINISH'
      AND jsonb_array_length(result->'requirementCodes')=0 THEN 0 ELSE 1 END,
    jsonb_build_object('result',result)
  FROM (SELECT private.classify_sales_process_conversion_candidate(
      'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,
      false,false,false,false,false,false,true) result) classifier
  UNION ALL
  SELECT 'pending_revision_classifier_preserved',
    CASE WHEN result->>'decision'='BLOCKED'
      AND result->'blockerCodes' ? 'PENDING_REVISION_MUST_RESOLVE'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN result->>'decision'='BLOCKED'
      AND result->'blockerCodes' ? 'PENDING_REVISION_MUST_RESOLVE' THEN 0 ELSE 1 END,
    jsonb_build_object('result',result)
  FROM (SELECT private.classify_sales_process_conversion_candidate(
      'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,
      false,false,false,false,false,true,false) result) classifier
  UNION ALL
  SELECT 'procurement_classifier_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('browserExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private'
    AND privilege.routine_name='classify_sales_process_conversion_candidate'
    AND privilege.grantee IN('PUBLIC','anon','authenticated')
    AND privilege.privilege_type='EXECUTE'
  UNION ALL
  SELECT 'open_cutover_plan_inventory','INFO',0::bigint,
    jsonb_build_object('openPlans',count(*),
      'rule','Recreate previews after classifier upgrade')
  FROM public.sales_process_cutover_plans
  WHERE status IN('DRAFT','PREVIEWED','APPLYING')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
