SELECT 'delivery_return_overlay_migration_ledger' AS check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
  abs(count(*)-1) AS violation_rows,
  jsonb_build_object('ledgerRows',count(*)) AS details
FROM private.kgs_schema_migrations
WHERE version='20261001110000'
UNION ALL
SELECT 'delivery_return_overlay_routine_contract',
  CASE WHEN to_regprocedure(
    'public.get_inventory_delivery_return_overlays(date,date)') IS NOT NULL
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN to_regprocedure(
    'public.get_inventory_delivery_return_overlays(date,date)') IS NULL
    THEN 1 ELSE 0 END,
  jsonb_build_object('present',to_regprocedure(
    'public.get_inventory_delivery_return_overlays(date,date)') IS NOT NULL)
UNION ALL
SELECT 'delivery_return_overlay_permission_contract',
  CASE WHEN has_function_privilege('authenticated',
      'public.get_inventory_delivery_return_overlays(date,date)','EXECUTE')
    AND NOT has_function_privilege('anon',
      'public.get_inventory_delivery_return_overlays(date,date)','EXECUTE')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN has_function_privilege('authenticated',
      'public.get_inventory_delivery_return_overlays(date,date)','EXECUTE')
    AND NOT has_function_privilege('anon',
      'public.get_inventory_delivery_return_overlays(date,date)','EXECUTE')
    THEN 0 ELSE 1 END,
  jsonb_build_object(
    'authenticated',has_function_privilege('authenticated',
      'public.get_inventory_delivery_return_overlays(date,date)','EXECUTE'),
    'anon',has_function_privilege('anon',
      'public.get_inventory_delivery_return_overlays(date,date)','EXECUTE'))
UNION ALL
SELECT 'delivery_return_overlay_source_coverage',
  CASE WHEN count(*) FILTER(WHERE document.source_kind='RETAINED_RETAIL')>0
      AND count(*) FILTER(WHERE document.source_kind='BACKOFFICE')>0
    THEN 'PASS' ELSE 'INFO' END,0,
  jsonb_build_object(
    'retainedRetailReturns',count(*) FILTER(
      WHERE document.source_kind='RETAINED_RETAIL'),
    'backofficeReturns',count(*) FILTER(
      WHERE document.source_kind='BACKOFFICE'))
FROM public.backoffice_sales_returns document
WHERE document.status<>'CANCELED';

