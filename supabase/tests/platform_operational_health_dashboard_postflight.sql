-- Platform Operational Health Dashboard postflight.
-- SAFETY: SELECT-only.
WITH routine AS (
  SELECT procedure.oid,procedure.prosecdef,procedure.provolatile,
    procedure.proconfig,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname='get_platform_operational_health'
    AND pg_get_function_identity_arguments(procedure.oid)=''
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260901090000'

  UNION ALL
  SELECT 'platform_health_routine_state',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*))
  FROM routine
  WHERE definition~'private_is_super_admin'
    AND definition~'SUPER_ADMIN_REQUIRED'
    AND definition~'refreshMode' AND definition~'MANUAL'

  UNION ALL
  SELECT 'platform_health_security_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('securityDefiner',COALESCE(bool_or(prosecdef),FALSE),
      'volatility',max(provolatile::TEXT),
      'config',COALESCE(jsonb_agg(proconfig),'[]'::JSONB))
  FROM routine
  HAVING bool_and(prosecdef) AND bool_and(provolatile='s')
    AND bool_and(proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[])
    AND bool_and(proconfig @> ARRAY['statement_timeout=8s']::TEXT[])

  UNION ALL
  SELECT 'platform_health_rpc_boundary',
    CASE WHEN NOT has_function_privilege('anon',
        'public.get_platform_operational_health()','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.get_platform_operational_health()','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN NOT has_function_privilege('anon',
        'public.get_platform_operational_health()','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.get_platform_operational_health()','EXECUTE')
      THEN 0 ELSE 1 END,
    jsonb_build_object(
      'anonExecute',has_function_privilege('anon',
        'public.get_platform_operational_health()','EXECUTE'),
      'authenticatedExecute',has_function_privilege('authenticated',
        'public.get_platform_operational_health()','EXECUTE'))

  UNION ALL
  SELECT 'platform_health_trigger_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger trigger_state
  WHERE NOT trigger_state.tgisinternal
    AND pg_get_triggerdef(trigger_state.oid)~*'operational_health'

  UNION ALL
  SELECT 'platform_health_runtime_inventory','INFO',0,jsonb_build_object(
    'companies',(SELECT count(*) FROM public.companies),
    'openCashierSessions',(SELECT count(*) FROM public.cashier_sessions
      WHERE status='OPEN'),
    'activeFinanceQueues',(SELECT count(*)
      FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')),
    'openFinanceExceptions',(SELECT count(*)
      FROM public.finance_posting_exceptions WHERE status<>'RESOLVED'),
    'openReservations',(SELECT count(*) FROM public.sales_stock_reservations
      WHERE status IN('OPEN','PARTIALLY_DISPATCHED')),
    'openNegativeAllocations',(SELECT count(*)
      FROM public.negative_stock_sale_allocations WHERE reconciled_at IS NULL))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
