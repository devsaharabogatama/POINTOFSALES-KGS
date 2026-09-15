-- SELECT-only postflight for Step 4/6.5C4. Run the entire file.
WITH routine AS (
  SELECT p.oid,p.prosecdef,p.provolatile,p.proconfig,pg_get_functiondef(p.oid) definition
  FROM pg_proc p WHERE p.oid=to_regprocedure(
    'public.get_backoffice_sales_discrepancy_workspace(uuid,uuid)')
), approval AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'public.approve_backoffice_sales_delivery_overage(uuid,bigint,uuid,jsonb,text)')) definition
), checks AS (
  SELECT 'c4_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912133000'
  UNION ALL SELECT 'c4_read_model_runtime_contract',
    CASE WHEN count(*)=1 AND bool_and(prosecdef AND provolatile='s'
      AND proconfig @> ARRAY['search_path=public, pg_temp','statement_timeout=15s']) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(prosecdef AND provolatile='s'
      AND proconfig @> ARRAY['search_path=public, pg_temp','statement_timeout=15s']) THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*),'securityDefiner',coalesce(bool_and(prosecdef),false),
      'volatility',min(provolatile),'config',min(proconfig::text)) FROM routine
  UNION ALL SELECT 'c4_read_model_definition_contract',
    CASE WHEN count(*)=1 AND bool_and(position('sales.backoffice_orders' in definition)>0
      AND position('inventory.delivery_documents' in definition)>0
      AND position('productUoms' in definition)>0 AND position('taxRules' in definition)>0) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(position('sales.backoffice_orders' in definition)>0
      AND position('inventory.delivery_documents' in definition)>0
      AND position('productUoms' in definition)>0 AND position('taxRules' in definition)>0) THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*)) FROM routine
  UNION ALL SELECT 'c4_sales_role_parity_contract',
    CASE WHEN position('''SALES''' in definition)>0 AND position('''SALES_ADMIN''' in definition)>0 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('''SALES''' in definition)>0 AND position('''SALES_ADMIN''' in definition)>0 THEN 0 ELSE 1 END,
    jsonb_build_object('salesRole',position('''SALES''' in definition)>0,
      'salesAdminRole',position('''SALES_ADMIN''' in definition)>0) FROM approval
  UNION ALL SELECT 'c4_rpc_boundary',
    CASE WHEN has_function_privilege('anon',oid,'EXECUTE')=false
      AND has_function_privilege('authenticated',oid,'EXECUTE') THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN has_function_privilege('anon',oid,'EXECUTE')=false
      AND has_function_privilege('authenticated',oid,'EXECUTE') THEN 0 ELSE 1 END,
    jsonb_build_object('anonExecute',has_function_privilege('anon',oid,'EXECUTE'),
      'authenticatedExecute',has_function_privilege('authenticated',oid,'EXECUTE')) FROM routine
  UNION ALL SELECT 'c4_tenant_relation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*)) FROM public.backoffice_sales_delivery_discrepancy_lines line
    LEFT JOIN public.backoffice_sales_delivery_discrepancies header
      ON header.company_id=line.company_id AND header.id=line.discrepancy_id
    WHERE header.id IS NULL OR header.company_id<>line.company_id
  UNION ALL SELECT 'c4_runtime_inventory','INFO',0,
    jsonb_build_object('cases',(SELECT count(*) FROM public.backoffice_sales_delivery_discrepancies),
      'pendingSales',(SELECT count(*) FROM public.backoffice_sales_delivery_discrepancies WHERE status='PENDING_SALES_APPROVAL'),
      'pendingWarehouse',(SELECT count(*) FROM public.backoffice_sales_delivery_discrepancies WHERE status='PENDING_WAREHOUSE_RESOLUTION'))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
