-- SELECT-only verification for 20260910110000.
WITH checks AS (
  SELECT 'migration_ledger'::text check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260910110000'
  UNION ALL
  SELECT 'required_persistent_preview_routines',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(4-count(*))::bigint,jsonb_build_object('expected',4,'routineRows',count(*))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE (namespace.nspname='private' AND proc.proname IN(
      'get_sales_process_cutover_plan_core','create_sales_process_cutover_plan_core'))
    OR (namespace.nspname='public' AND proc.proname IN(
      'get_sales_process_cutover_plan','create_sales_process_cutover_plan'))
  UNION ALL
  SELECT 'persistent_preview_security_contract',
    CASE WHEN count(*)=2 AND bool_and(proc.prosecdef)
      AND bool_and(proc.proconfig @> ARRAY['search_path=public, pg_temp'])
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=2 AND bool_and(proc.prosecdef)
      AND bool_and(proc.proconfig @> ARRAY['search_path=public, pg_temp'])
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('publicRoutineRows',count(*),
      'securityDefiner',COALESCE(bool_and(proc.prosecdef),false))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname='public' AND proc.proname IN(
    'get_sales_process_cutover_plan','create_sales_process_cutover_plan')
  UNION ALL
  SELECT 'persistent_preview_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE grantee='anon')=0
      AND count(*) FILTER(WHERE grantee='authenticated')=2 THEN 'PASS' ELSE 'FAIL' END,
    (count(*) FILTER(WHERE grantee='anon')
      +abs(2-count(*) FILTER(WHERE grantee='authenticated')))::bigint,
    jsonb_build_object('anonExecute',count(*) FILTER(WHERE grantee='anon'),
      'authenticatedExecute',count(*) FILTER(WHERE grantee='authenticated'))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='public' AND privilege.privilege_type='EXECUTE'
    AND privilege.routine_name IN('get_sales_process_cutover_plan','create_sales_process_cutover_plan')
    AND privilege.grantee IN('anon','authenticated')
  UNION ALL
  SELECT 'persistent_preview_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private' AND privilege.privilege_type='EXECUTE'
    AND privilege.routine_name IN(
      'get_sales_process_cutover_plan_core','create_sales_process_cutover_plan_core')
    AND privilege.grantee='authenticated'
  UNION ALL
  SELECT 'persistent_preview_version_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('mismatchRows',count(*))
  FROM public.sales_process_cutover_items item
  JOIN public.sales_process_cutover_plans plan
    ON plan.company_id=item.company_id AND plan.id=item.cutover_plan_id
  WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(CASE
      WHEN jsonb_typeof(plan.preview_snapshot->'candidates')='array'
        THEN plan.preview_snapshot->'candidates' ELSE '[]'::jsonb END) candidate
    WHERE candidate->>'sourceDocumentType'=item.source_document_type
      AND candidate->>'sourceDocumentId'=item.source_document_id::text
      AND candidate->>'sourceDocumentNo'=item.source_document_no
      AND candidate->>'sourceStatus'=item.source_status
      AND (candidate->>'sourceMasterVersion')::bigint=item.source_master_version
      AND candidate->>'decision'=item.decision)
  UNION ALL
  SELECT 'persistent_preview_item_count_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('mismatchPlans',count(*))
  FROM public.sales_process_cutover_plans plan
  WHERE plan.status='PREVIEWED' AND (
    jsonb_typeof(plan.preview_snapshot->'candidates') IS DISTINCT FROM 'array'
    OR COALESCE(jsonb_array_length(plan.preview_snapshot->'candidates'),-1)<>
      (SELECT count(*) FROM public.sales_process_cutover_items item
       WHERE item.company_id=plan.company_id AND item.cutover_plan_id=plan.id))
  UNION ALL
  SELECT 'persistent_preview_create_audit_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('missingAuditPlans',count(*))
  FROM public.sales_process_cutover_plans plan
  WHERE plan.status='PREVIEWED' AND NOT EXISTS(
    SELECT 1 FROM public.sales_process_cutover_audit audit
    WHERE audit.company_id=plan.company_id AND audit.cutover_plan_id=plan.id
      AND audit.action='CREATE_PLAN' AND audit.operation_id=plan.operation_id)
  UNION ALL
  SELECT 'persistent_preview_create_core_runtime_contract',
    CASE WHEN count(*)=1 AND bool_and(proc.prosecdef)
      AND bool_and(proc.provolatile='v')
      AND bool_and(proc.proconfig @> ARRAY[
        'search_path=public, pg_temp','statement_timeout=15s'])
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(proc.prosecdef)
      AND bool_and(proc.provolatile='v')
      AND bool_and(proc.proconfig @> ARRAY[
        'search_path=public, pg_temp','statement_timeout=15s'])
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('createCoreRows',count(*),
      'securityDefiner',COALESCE(bool_and(proc.prosecdef),false),
      'volatility',max(proc.provolatile::text),
      'config',max(proc.proconfig::text))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname='private'
    AND proc.proname='create_sales_process_cutover_plan_core'
  UNION ALL
  SELECT 'persistent_preview_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'draftPlans',(SELECT count(*) FROM public.sales_process_cutover_plans WHERE status='DRAFT'),
    'previewedPlans',(SELECT count(*) FROM public.sales_process_cutover_plans WHERE status='PREVIEWED'),
    'plannedItems',(SELECT count(*) FROM public.sales_process_cutover_items WHERE item_status='PLANNED'),
    'auditRows',(SELECT count(*) FROM public.sales_process_cutover_audit))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
