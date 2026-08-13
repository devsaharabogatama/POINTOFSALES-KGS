-- ACP-5G postflight: Bundle effective permission enforcement.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH expected_relations(relation_name) AS (
  VALUES ('product_bundle_items'),('product_bundle_master_audit')
), expected_routines(signature) AS (
  VALUES ('public.get_sales_bundles(boolean)'),
    ('public.get_bundle_availability(uuid,uuid)'),
    ('public.save_bundle_with_components(uuid,bigint,text,text,uuid,uuid,numeric,text,text,boolean,jsonb)')
), guarded_routines AS (
  SELECT procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure WHERE procedure.oid IN(
    to_regprocedure('public.get_sales_bundles(boolean)'),
    to_regprocedure('public.get_bundle_availability(uuid,uuid)'),
    to_regprocedure('public.save_bundle_with_components(uuid,bigint,text,text,uuid,uuid,numeric,text,text,boolean,jsonb)'))
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*) FILTER(WHERE version<>'20260813040000') violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813040000'

  UNION ALL
  SELECT 'bundle_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE enforcement_status<>'ENFORCED'),
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog WHERE permission_key='sales.bundles'

  UNION ALL
  SELECT 'required_bundle_routines',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE to_regprocedure(signature) IS NULL),
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(signature ORDER BY signature)
        FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB))
  FROM expected_routines

  UNION ALL
  SELECT 'bundle_runtime_permission_hooks',
    CASE WHEN count(*)=3 AND count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%'
      AND definition ILIKE '%sales.bundles%')=3
      THEN 'PASS' ELSE 'FAIL' END,
    3-count(*) FILTER(WHERE definition ILIKE
      '%acp_require_permission_capability%'
      AND definition ILIKE '%sales.bundles%'),
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        AND definition ILIKE '%sales.bundles%'))
  FROM guarded_routines

  UNION ALL
  SELECT 'browser_bundle_table_boundary',
    CASE WHEN count(*) FILTER(WHERE readable OR writable)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE readable OR writable),
    jsonb_build_object('readable',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE readable),'[]'::JSONB),'writable',COALESCE(
      jsonb_agg(relation_name) FILTER(WHERE writable),'[]'::JSONB))
  FROM (SELECT relation_name,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'SELECT') readable,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'INSERT,UPDATE,DELETE') writable FROM expected_relations) privilege_state

  UNION ALL
  SELECT 'private_bundle_core_boundary',
    CASE WHEN count(*)=2 AND count(*) FILTER(WHERE
      has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE')),
    jsonb_build_object('core_rows',count(*),'core_names',COALESCE(
      jsonb_agg(procedure.proname ORDER BY procedure.proname),'[]'::JSONB))
  FROM pg_proc procedure WHERE procedure.pronamespace='private'::regnamespace
    AND procedure.proname IN('acp5g_save_bundle_with_components_core',
      'acp5g_get_bundle_availability_core')

  UNION ALL
  SELECT 'public_bundle_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE procedure.oid IS NULL)=0
      AND count(*) FILTER(WHERE procedure.oid IS NOT NULL AND
        NOT has_function_privilege('authenticated',procedure.oid,'EXECUTE'))=0
      AND count(*) FILTER(WHERE procedure.oid IS NOT NULL AND
        has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE procedure.oid IS NULL OR
      NOT has_function_privilege('authenticated',procedure.oid,'EXECUTE') OR
      has_function_privilege('anon',procedure.oid,'EXECUTE')),
    jsonb_build_object('expected',count(*))
  FROM expected_routines expected
  LEFT JOIN pg_proc procedure ON procedure.oid=to_regprocedure(expected.signature)

  UNION ALL
  SELECT 'active_bundle_component_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('bundle_count',count(*))
  FROM public.products bundle WHERE bundle.is_active AND bundle.is_bundle
    AND NOT EXISTS(SELECT 1 FROM public.product_bundle_items item
      WHERE item.company_id=bundle.company_id AND item.bundle_id=bundle.id)

  UNION ALL
  SELECT 'bundle_virtual_stock_contract',
    CASE WHEN sum(row_count)=0 THEN 'PASS' ELSE 'FAIL' END,sum(row_count),
    jsonb_build_object('stock_rows',sum(row_count) FILTER(WHERE source='stock'),
      'movement_rows',sum(row_count) FILTER(WHERE source='movement'),
      'fifo_rows',sum(row_count) FILTER(WHERE source='fifo'))
  FROM (
    SELECT 'stock' source,count(*) row_count FROM public.product_stocks stock
    JOIN public.products bundle ON bundle.company_id=stock.company_id
      AND bundle.id=stock.product_id AND bundle.is_bundle
    UNION ALL SELECT 'movement',count(*) FROM public.stock_movements movement
    JOIN public.products bundle ON bundle.company_id=movement.company_id
      AND bundle.id=movement.product_id AND bundle.is_bundle
    UNION ALL SELECT 'fifo',count(*) FROM public.product_batches batch
    JOIN public.products bundle ON bundle.company_id=batch.company_id
      AND bundle.id=batch.product_id AND bundle.is_bundle
  ) physical_state

  UNION ALL
  SELECT 'posted_bundle_allocation_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('requirement_count',count(*))
  FROM public.sale_stock_requirements requirement
  JOIN public.sales_headers sale ON sale.company_id=requirement.company_id
    AND sale.id=requirement.sales_id AND sale.document_status='POSTED'
  JOIN public.products bundle ON bundle.company_id=requirement.company_id
    AND bundle.id=requirement.commercial_product_id AND bundle.is_bundle
  LEFT JOIN public.bundle_sale_allocations allocation
    ON allocation.company_id=requirement.company_id
   AND allocation.stock_requirement_id=requirement.id
  WHERE allocation.id IS NULL

  UNION ALL
  SELECT 'bundle_runtime_inventory','INFO',0,
    jsonb_build_object('bundles',(SELECT count(*) FROM public.products
      WHERE is_bundle),'active_bundles',(SELECT count(*) FROM public.products
      WHERE is_bundle AND is_active),'component_rows',(SELECT count(*)
      FROM public.product_bundle_items),'sale_allocations',(SELECT count(*)
      FROM public.bundle_sale_allocations),'override_rows',(SELECT count(*)
      FROM public.user_company_permission_overrides
      WHERE permission_key='sales.bundles'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
