-- SELECT-only postflight for Inventory Delivery date filter.
WITH checks AS(
  SELECT 'migration_ledger' AS check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
    jsonb_build_object('ledgerRows',count(*)) AS details
  FROM private.kgs_schema_migrations WHERE version='20260824120000'
  UNION ALL
  SELECT 'delivery_date_filter_runtime',
    CASE WHEN count(*)=1 AND bool_and(routine.prosecdef)
      AND bool_and(lower(routine.prosrc) LIKE '%invalid_delivery_date_range%')
      AND bool_and(lower(routine.prosrc) LIKE '%at time zone v_timezone%')
      AND bool_and(lower(routine.prosrc) LIKE '%p_date_from%')
      AND bool_and(lower(routine.prosrc) LIKE '%p_date_to%')
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname='get_inventory_delivery_documents'
    AND pg_get_function_identity_arguments(routine.oid)='p_date_from date, p_date_to date'
  UNION ALL
  SELECT 'delivery_no_argument_compatibility',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname='get_inventory_delivery_documents'
    AND pg_get_function_identity_arguments(routine.oid)=''
  UNION ALL
  SELECT 'delivery_date_filter_rpc_boundary',
    CASE WHEN NOT has_function_privilege('anon',
        'public.get_inventory_delivery_documents(date,date)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.get_inventory_delivery_documents(date,date)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object(
      'anonExecutable',has_function_privilege('anon',
        'public.get_inventory_delivery_documents(date,date)','EXECUTE'),
      'authenticatedExecutable',has_function_privilege('authenticated',
        'public.get_inventory_delivery_documents(date,date)','EXECUTE'))
  UNION ALL
  SELECT 'delivery_document_runtime_inventory','INFO',jsonb_build_object(
    'documents',count(*),'companies',count(DISTINCT company_id),
    'earliestDate',min(COALESCE(scheduled_at,created_at)),
    'latestDate',max(COALESCE(scheduled_at,created_at)))
  FROM public.sales_delivery_documents
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
