-- Postflight: selected Supplier Order export.
WITH checks AS (
  SELECT 'selected_supplier_order_export_routine' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('routineRows',count(*)) details
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname='export_purchase_supplier_orders'
    AND pg_get_function_identity_arguments(routine.oid)='p_document_ids uuid[]'
  UNION ALL
  SELECT 'legacy_supplier_order_export_preserved',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname='export_purchase_supplier_orders'
    AND pg_get_function_identity_arguments(routine.oid)=''
  UNION ALL
  SELECT 'selected_supplier_order_export_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE has_function_privilege('anon',routine.oid,'EXECUTE'))=0
      AND count(*) FILTER(WHERE has_function_privilege('authenticated',routine.oid,'EXECUTE'))=1
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object(
      'anonRows',count(*) FILTER(WHERE has_function_privilege('anon',routine.oid,'EXECUTE')),
      'authenticatedRows',count(*) FILTER(WHERE has_function_privilege('authenticated',routine.oid,'EXECUTE')))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname='export_purchase_supplier_orders'
    AND pg_get_function_identity_arguments(routine.oid)='p_document_ids uuid[]'
  UNION ALL
  SELECT 'selected_supplier_order_export_contract',
    CASE WHEN pg_get_functiondef(routine.oid) LIKE '%cardinality(p_document_ids)>100%'
      AND pg_get_functiondef(routine.oid) LIKE '%document.id=ANY(p_document_ids)%'
      AND pg_get_functiondef(routine.oid) LIKE '%SUPPLIER_ORDER_EXPORT_NOT_FOUND_OR_ACCESS_DENIED%'
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',1)
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname='export_purchase_supplier_orders'
    AND pg_get_function_identity_arguments(routine.oid)='p_document_ids uuid[]'
  UNION ALL
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('ledgerRows',count(*)) FROM private.kgs_schema_migrations
  WHERE version='20260820130000'
)
SELECT check_name,status,details FROM checks ORDER BY
  CASE status WHEN 'FAIL' THEN 0 ELSE 1 END,check_name;
