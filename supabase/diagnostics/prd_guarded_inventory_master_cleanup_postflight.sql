-- PRD guarded Inventory master cleanup postflight.
-- SAFETY: SELECT-only catalog and aggregate checks.

WITH runtime AS (
  SELECT procedure_state.oid,procedure_state.proname,
    pg_get_functiondef(procedure_state.oid) AS definition
  FROM pg_proc procedure_state
  JOIN pg_namespace namespace_state ON namespace_state.oid=procedure_state.pronamespace
  WHERE namespace_state.nspname='public'
    AND procedure_state.proname IN(
      'delete_inventory_uom','delete_inventory_product_category'
    )
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*)<>1 AS violation,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version='20260818090000'

  UNION ALL
  SELECT 'guarded_delete_routine_state',
    CASE WHEN count(*)=2
      AND count(*) FILTER(WHERE definition ILIKE '%inventory.master_data%'
        AND definition ILIKE '%MANAGE%')=2
      THEN 'PASS' ELSE 'FAIL' END,
    NOT(count(*)=2 AND count(*) FILTER(WHERE definition ILIKE '%inventory.master_data%'
      AND definition ILIKE '%MANAGE%')=2),
    jsonb_build_object('routine_rows',count(*),'guarded_rows',count(*) FILTER(
      WHERE definition ILIKE '%inventory.master_data%' AND definition ILIKE '%MANAGE%'))
  FROM runtime

  UNION ALL
  SELECT 'guarded_delete_rpc_boundary',
    CASE WHEN count(*)=2
      AND count(*) FILTER(WHERE has_function_privilege('authenticated',oid,'EXECUTE'))=2
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    NOT(count(*)=2
      AND count(*) FILTER(WHERE has_function_privilege('authenticated',oid,'EXECUTE'))=2
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0),
    jsonb_build_object(
      'routine_rows',count(*),
      'authenticated_rows',count(*) FILTER(WHERE has_function_privilege('authenticated',oid,'EXECUTE')),
      'anon_rows',count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE')))
  FROM runtime

  UNION ALL
  SELECT 'uom_semantic_guard_trigger',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    count(*)<>1,
    jsonb_build_object('trigger_rows',count(*))
  FROM pg_trigger trigger_state
  JOIN pg_class relation ON relation.oid=trigger_state.tgrelid
  JOIN pg_namespace namespace_state ON namespace_state.oid=relation.relnamespace
  WHERE namespace_state.nspname='public' AND relation.relname='uoms'
    AND trigger_state.tgname='trg_prd_guard_used_uom_semantics'
    AND trigger_state.tgenabled<>'D'

  UNION ALL
  SELECT 'inventory_master_delete_audit_contract',
    CASE WHEN count(*)=1 AND COALESCE(bool_and(
      pg_get_constraintdef(constraint_state.oid) ILIKE '%DELETE%'
    ),FALSE) THEN 'PASS' ELSE 'FAIL' END,
    NOT(count(*)=1 AND COALESCE(bool_and(
      pg_get_constraintdef(constraint_state.oid) ILIKE '%DELETE%'
    ),FALSE)),
    jsonb_build_object('constraint_rows',count(*))
  FROM pg_constraint constraint_state
  JOIN pg_class relation ON relation.oid=constraint_state.conrelid
  JOIN pg_namespace namespace_state ON namespace_state.oid=relation.relnamespace
  WHERE namespace_state.nspname='public'
    AND relation.relname='inventory_master_write_audit'
    AND constraint_state.conname='inventory_master_audit_action_check'

  UNION ALL
  SELECT 'inventory_master_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE has_table_privilege(
      'authenticated',format('public.%I',relation_name),'INSERT,UPDATE,DELETE'
    ))=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_table_privilege(
      'authenticated',format('public.%I',relation_name),'INSERT,UPDATE,DELETE'
    ))>0,
    jsonb_build_object('direct_write_relations',COALESCE(jsonb_agg(relation_name) FILTER(
      WHERE has_table_privilege('authenticated',format('public.%I',relation_name),'INSERT,UPDATE,DELETE')
    ),'[]'::JSONB))
  FROM (VALUES('uoms'),('product_categories')) relation(relation_name)

  UNION ALL
  SELECT 'inventory_master_cleanup_inventory','INFO',FALSE,
    jsonb_build_object(
      'uoms',(SELECT count(*) FROM public.uoms),
      'categories',(SELECT count(*) FROM public.product_categories),
      'used_uoms',(SELECT count(DISTINCT uom_id) FROM public.product_uoms),
      'used_categories',(SELECT count(DISTINCT category_id) FROM public.products
        WHERE category_id IS NOT NULL),
      'delete_audit_rows',(SELECT count(*) FROM public.inventory_master_write_audit
        WHERE action='DELETE'))
)
SELECT check_name,status,CASE WHEN violation THEN 1 ELSE 0 END violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

