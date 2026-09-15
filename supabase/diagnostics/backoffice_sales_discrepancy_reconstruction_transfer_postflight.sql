-- SELECT-only postflight for Step 4/6.5C1.
WITH definition AS (
  SELECT p.prosecdef,p.provolatile,pg_get_functiondef(p.oid) body
  FROM pg_proc p WHERE p.oid=
    'private.post_backoffice_sales_discrepancy_transfer(uuid,bigint,uuid,uuid)'::regprocedure
), checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912122000'
  UNION ALL
  SELECT 'reconstruction_helper_security_contract',
    CASE WHEN prosecdef AND provolatile='v'
      AND body LIKE '%allow_negative_stock%' AND body LIKE '%backoffice_negative_stock_allocations%'
      AND body LIKE '%stock_transfer_fifo_allocations%' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN prosecdef AND provolatile='v'
      AND body LIKE '%allow_negative_stock%' AND body LIKE '%backoffice_negative_stock_allocations%'
      AND body LIKE '%stock_transfer_fifo_allocations%' THEN 0 ELSE 1 END,
    jsonb_build_object('securityDefiner',prosecdef,'volatility',provolatile,
      'warehousePolicy',body LIKE '%allow_negative_stock%',
      'negativeLineage',body LIKE '%backoffice_negative_stock_allocations%',
      'fifoLineage',body LIKE '%stock_transfer_fifo_allocations%') FROM definition
  UNION ALL
  SELECT 'reconstruction_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges
  WHERE specific_schema='private'
    AND routine_name='post_backoffice_sales_discrepancy_transfer'
    AND grantee IN('anon','authenticated') AND privilege_type='EXECUTE'
  UNION ALL
  SELECT 'reconstruction_public_resolver_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('publicResolverRows',count(*)) FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname LIKE '%discrepancy%resolve%'
  UNION ALL
  SELECT 'reconstruction_runtime_inventory','INFO',0,
    jsonb_build_object('pendingOverage',count(*) FILTER(WHERE discrepancy_type='OVERAGE'),
      'pendingWrongItem',count(*) FILTER(WHERE discrepancy_type='WRONG_ITEM'))
  FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE discrepancy_type IN('OVERAGE','WRONG_ITEM') AND warehouse_resolution_status='PENDING'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
