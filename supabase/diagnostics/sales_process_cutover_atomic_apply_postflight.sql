-- Step 4E/6 SELECT-only postflight.
WITH required_routines(signature) AS (VALUES
  ('private.get_sales_process_cutover_plan_before_atomic_apply(uuid,uuid)'),
  ('private.get_sales_process_cutover_plan_core(uuid,uuid)'),
  ('private.assert_sales_process_root_creation_allowed(uuid,text)'),
  ('private.trg_guard_backoffice_sales_process_creation()'),
  ('private.apply_sales_process_cutover_plan_core(uuid,uuid,uuid,bigint,bigint,uuid)'),
  ('private.submit_pos_offline_sale_before_process_mode_gate(jsonb)'),
  ('private.start_pos_sales_order_revision_before_process_mode_gate(uuid,bigint,uuid,uuid,text)'),
  ('public.submit_pos_offline_sale(jsonb)'),
  ('public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)'),
  ('public.apply_sales_process_cutover_plan(uuid,bigint,bigint,uuid)')
), checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260911130000'
  UNION ALL
  SELECT 'atomic_apply_routine_contract',CASE WHEN count(resolved.signature)=10 THEN 'PASS' ELSE 'FAIL' END,
    (10-count(resolved.signature))::bigint,
    jsonb_build_object('expected',10,'present',count(resolved.signature),
      'missing',COALESCE(jsonb_agg(required.signature) FILTER(WHERE resolved.signature IS NULL),'[]'))
  FROM required_routines required LEFT JOIN LATERAL(
    SELECT required.signature WHERE to_regprocedure(required.signature) IS NOT NULL) resolved ON true
  UNION ALL
  SELECT 'atomic_apply_security_contract',CASE WHEN count(*)=2
      AND bool_and(prosecdef AND provolatile='v'
        AND COALESCE(array_to_string(proconfig,','),'') LIKE '%search_path=public, pg_temp%')
    THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=2 AND bool_and(prosecdef AND provolatile='v'
      AND COALESCE(array_to_string(proconfig,','),'') LIKE '%search_path=public, pg_temp%')
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',count(*),'securityDefiner',bool_and(prosecdef),
      'volatility',jsonb_agg(DISTINCT provolatile),'config',jsonb_agg(DISTINCT proconfig))
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname) IN(
    ('private','apply_sales_process_cutover_plan_core'),
    ('public','apply_sales_process_cutover_plan'))
  UNION ALL
  SELECT 'atomic_apply_rpc_boundary',CASE WHEN anon_rows=0 AND authenticated_rows=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN anon_rows=0 AND authenticated_rows=1 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('anonExecute',anon_rows,'authenticatedExecute',authenticated_rows)
  FROM (SELECT count(*) FILTER(WHERE grantee='anon') anon_rows,
      count(*) FILTER(WHERE grantee='authenticated') authenticated_rows
    FROM information_schema.routine_privileges
    WHERE specific_schema='public' AND routine_name='apply_sales_process_cutover_plan'
      AND privilege_type='EXECUTE') privilege
  UNION ALL
  SELECT 'atomic_apply_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges
  WHERE specific_schema='private' AND grantee IN('anon','authenticated')
    AND routine_name IN('assert_sales_process_root_creation_allowed',
      'get_sales_process_cutover_plan_before_atomic_apply','get_sales_process_cutover_plan_core',
      'apply_sales_process_cutover_plan_core','submit_pos_offline_sale_before_process_mode_gate',
      'start_pos_sales_order_revision_before_process_mode_gate')
  UNION ALL
  SELECT 'backoffice_creation_trigger_contract',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*))::bigint,jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger WHERE tgrelid='public.backoffice_sales_orders'::regclass
    AND tgname='backoffice_sales_process_mode_creation_gate' AND NOT tgisinternal
  UNION ALL
  SELECT 'retail_identity_and_mode_gate_definition',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('matchingRows',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private' AND procedure.proname='trg_guard_sales_process_identity'
    AND pg_get_functiondef(procedure.oid) LIKE '%BACKOFFICE_CUTOVER_SCOPE_IMMUTABLE%'
    AND pg_get_functiondef(procedure.oid) LIKE '%assert_sales_process_root_creation_allowed%'
    AND EXISTS(SELECT 1 FROM pg_trigger trigger
      WHERE trigger.tgrelid='public.sales_headers'::regclass
        AND trigger.tgname='sales_headers_process_identity_guard' AND NOT trigger.tgisinternal
        AND pg_get_triggerdef(trigger.oid) LIKE '%store_id%'
        AND pg_get_triggerdef(trigger.oid) LIKE '%sales_warehouse_id%')
  UNION ALL
  SELECT 'applied_plan_shape',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_process_cutover_plans plan
  WHERE plan.status='APPLIED' AND (plan.applied_by IS NULL OR plan.applied_at IS NULL
    OR NOT EXISTS(SELECT 1 FROM public.company_sales_process_mode_history history
      WHERE history.company_id=plan.company_id AND history.cutover_plan_id=plan.id
        AND history.change_type='SWITCH' AND history.source_mode=plan.source_mode
        AND history.target_mode=plan.target_mode))
  UNION ALL
  SELECT 'applied_item_lineage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_process_cutover_items item
  JOIN public.sales_process_cutover_plans plan ON plan.company_id=item.company_id
    AND plan.id=item.cutover_plan_id AND plan.status='APPLIED'
  WHERE (item.decision='CONVERT' AND (item.item_status<>'APPLIED'
      OR item.target_document_id IS NULL OR item.target_document_no IS NULL))
    OR (item.decision IN('BLOCKED','KEEP_SOURCE') AND (item.item_status<>'KEPT'
      OR item.target_document_id IS NOT NULL))
  UNION ALL
  SELECT 'atomic_apply_runtime_inventory','INFO',0::bigint,
    jsonb_build_object('appliedPlans',(SELECT count(*) FROM public.sales_process_cutover_plans WHERE status='APPLIED'),
      'convertedItems',(SELECT count(*) FROM public.sales_process_cutover_items WHERE item_status='APPLIED'),
      'retainedItems',(SELECT count(*) FROM public.sales_process_cutover_items WHERE item_status='KEPT'),
      'modeSwitches',(SELECT count(*) FROM public.company_sales_process_mode_history WHERE change_type='SWITCH'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
