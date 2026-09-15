-- SELECT-only verification for 20260912100000.
WITH checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912100000'
  UNION ALL
  SELECT 'overage_approval_column_contract',CASE WHEN count(*)=8 THEN 'PASS' ELSE 'FAIL' END,
    abs(8-count(*)),jsonb_build_object('expected',8,'present',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND ((table_name='backoffice_sales_delivery_discrepancies' AND column_name='master_version')
      OR (table_name='backoffice_sales_delivery_discrepancy_lines'
        AND column_name IN('approved_unit_price','approved_discount_amount',
          'approved_tax_amount','approved_line_total','commercial_snapshot',
          'commercial_approved_by','commercial_approved_at')))
  UNION ALL
  SELECT 'overage_approval_routine_contract',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(3-count(*)),jsonb_build_object('expected',3,'present',count(*))
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE (n.nspname='public' AND p.oid=to_regprocedure(
      'public.approve_backoffice_sales_delivery_overage(uuid,bigint,uuid,jsonb,text)'))
     OR (n.nspname='private' AND p.oid IN(
      to_regprocedure('private.approve_backoffice_sales_delivery_overage_core(uuid,bigint,uuid,jsonb,text)'),
      to_regprocedure('private.resolve_explicit_sales_tax_rule(uuid,uuid,timestamptz)')))
  UNION ALL
  SELECT 'overage_approval_public_boundary',
    CASE WHEN COALESCE(bool_and(has_function_privilege('authenticated',p.oid,'EXECUTE')),false)
      AND NOT COALESCE(bool_or(has_function_privilege('anon',p.oid,'EXECUTE')),true)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN COALESCE(bool_and(has_function_privilege('authenticated',p.oid,'EXECUTE')),false)
      AND NOT COALESCE(bool_or(has_function_privilege('anon',p.oid,'EXECUTE')),true)
      THEN 0 ELSE 1 END,
    jsonb_build_object('authenticatedExecute',COALESCE(bool_and(
      has_function_privilege('authenticated',p.oid,'EXECUTE')),false),
      'anonExecute',COALESCE(bool_or(has_function_privilege('anon',p.oid,'EXECUTE')),false))
  FROM pg_proc p WHERE p.oid=to_regprocedure(
    'public.approve_backoffice_sales_delivery_overage(uuid,bigint,uuid,jsonb,text)')
  UNION ALL
  SELECT 'overage_approval_sales_admin_contract',
    CASE WHEN position('SALES_ADMIN_REQUIRED' in definition)>0
      AND position('''SALES_ADMIN''' in definition)>0
      AND position('sales.sales_orders' in definition)>0 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('SALES_ADMIN_REQUIRED' in definition)>0
      AND position('''SALES_ADMIN''' in definition)>0
      AND position('sales.sales_orders' in definition)>0 THEN 0 ELSE 1 END,
    jsonb_build_object('requiresSalesAdmin',position('SALES_ADMIN_REQUIRED' in definition)>0,
      'requiresSalesManage',position('sales.sales_orders' in definition)>0)
  FROM (SELECT pg_get_functiondef(to_regprocedure(
    'public.approve_backoffice_sales_delivery_overage(uuid,bigint,uuid,jsonb,text)')) definition) source
  UNION ALL
  SELECT 'overage_approval_private_boundary',
    CASE WHEN count(*) FILTER(WHERE has_function_privilege('authenticated',p.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_function_privilege('authenticated',p.oid,'EXECUTE')),
    jsonb_build_object('authenticatedExecutableRows',count(*) FILTER(
      WHERE has_function_privilege('authenticated',p.oid,'EXECUTE')))
  FROM pg_proc p WHERE p.oid IN(
    to_regprocedure('private.approve_backoffice_sales_delivery_overage_core(uuid,bigint,uuid,jsonb,text)'),
    to_regprocedure('private.resolve_explicit_sales_tax_rule(uuid,uuid,timestamptz)'))
  UNION ALL
  SELECT 'overage_approval_security_contract',
    CASE WHEN p.prosecdef AND p.provolatile='v'
      AND COALESCE(array_to_string(p.proconfig,','),'') LIKE '%search_path=public, pg_temp%'
      AND COALESCE(array_to_string(p.proconfig,','),'') LIKE '%statement_timeout=30s%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN p.prosecdef AND p.provolatile='v'
      AND COALESCE(array_to_string(p.proconfig,','),'') LIKE '%search_path=public, pg_temp%'
      AND COALESCE(array_to_string(p.proconfig,','),'') LIKE '%statement_timeout=30s%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('securityDefiner',p.prosecdef,'volatility',p.provolatile,
      'config',p.proconfig)
  FROM pg_proc p WHERE p.oid=to_regprocedure(
    'public.approve_backoffice_sales_delivery_overage(uuid,bigint,uuid,jsonb,text)')
  UNION ALL
  SELECT 'overage_approval_runtime_inventory','INFO',0,
    jsonb_build_object('approvedLines',count(*) FILTER(WHERE commercial_approval_status='APPROVED'),
      'pendingLines',count(*) FILTER(WHERE commercial_approval_status='PENDING'))
  FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE requested_resolution='ACCEPT_OVERAGE'
)
SELECT check_name,status,violation_rows::bigint,details FROM checks ORDER BY check_name;
