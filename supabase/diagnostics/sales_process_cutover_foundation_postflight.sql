-- SELECT-only verification for 20260909162000.
WITH checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909162000'
  UNION ALL
  SELECT 'required_cutover_relations',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
    abs(5-count(*))::bigint,jsonb_build_object('expected',5,'relationRows',count(*))
  FROM information_schema.tables WHERE table_schema='public' AND table_name IN(
    'company_sales_process_settings','company_sales_process_mode_history',
    'sales_process_cutover_plans','sales_process_cutover_items',
    'sales_process_cutover_audit')
  UNION ALL
  SELECT 'cutover_relation_rls_state',
    CASE WHEN count(*)=5 AND bool_and(class.relrowsecurity) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=5 AND bool_and(class.relrowsecurity) THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('enabledRelations',count(*))
  FROM pg_class class JOIN pg_namespace namespace ON namespace.oid=class.relnamespace
  WHERE namespace.nspname='public' AND class.relname IN(
    'company_sales_process_settings','company_sales_process_mode_history',
    'sales_process_cutover_plans','sales_process_cutover_items',
    'sales_process_cutover_audit') AND class.relrowsecurity
  UNION ALL
  SELECT 'cutover_browser_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants privilege
  WHERE privilege.table_schema='public' AND privilege.table_name IN(
    'company_sales_process_settings','company_sales_process_mode_history',
    'sales_process_cutover_plans','sales_process_cutover_items',
    'sales_process_cutover_audit') AND privilege.grantee IN('anon','authenticated')
  UNION ALL
  SELECT 'required_cutover_private_routines',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,abs(4-count(*))::bigint,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname='private' AND proc.proname IN(
    'classify_sales_process_conversion_candidate',
    'trg_initialize_company_sales_process_setting',
    'trg_guard_company_sales_process_setting','trg_guard_sales_process_history')
  UNION ALL
  SELECT 'cutover_private_runtime_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private' AND privilege.grantee='authenticated'
    AND privilege.privilege_type='EXECUTE' AND privilege.routine_name IN(
      'classify_sales_process_conversion_candidate',
      'trg_initialize_company_sales_process_setting',
      'trg_guard_company_sales_process_setting','trg_guard_sales_process_history')
  UNION ALL
  SELECT 'required_cutover_triggers',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(4-count(*))::bigint,jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger trigger_state WHERE NOT trigger_state.tgisinternal
    AND trigger_state.tgenabled<>'D' AND trigger_state.tgname IN(
      'company_sales_process_settings_guard',
      'company_sales_process_mode_history_immutable',
      'sales_process_cutover_audit_immutable',
      'companies_sales_process_setting_initialize')
  UNION ALL
  SELECT 'company_default_retail_backfill',
    CASE WHEN count(*)=(SELECT count(*) FROM public.companies)
      AND bool_and(active_mode='RETAIL_CONFIRM_INVOICE' AND master_version=1)
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE active_mode<>'RETAIL_CONFIRM_INVOICE' OR master_version<>1)::bigint,
    jsonb_build_object('settingsRows',count(*),'companyRows',(SELECT count(*) FROM public.companies))
  FROM public.company_sales_process_settings
  UNION ALL
  SELECT 'initial_mode_history_reconciliation',
    CASE WHEN count(*)=(SELECT count(*) FROM public.companies)
      AND bool_and(change_type='INITIALIZE' AND source_mode IS NULL
        AND target_mode='RETAIL_CONFIRM_INVOICE') THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE change_type<>'INITIALIZE' OR source_mode IS NOT NULL
      OR target_mode<>'RETAIL_CONFIRM_INVOICE')::bigint,
    jsonb_build_object('historyRows',count(*),'companyRows',(SELECT count(*) FROM public.companies))
  FROM public.company_sales_process_mode_history
  UNION ALL
  SELECT 'zero_cutover_runtime_effect',
    CASE WHEN (SELECT count(*) FROM public.sales_process_cutover_plans)=0
      AND (SELECT count(*) FROM public.sales_process_cutover_items)=0
      AND (SELECT count(*) FROM public.sales_process_cutover_audit)=0
      THEN 'PASS' ELSE 'FAIL' END,
    ((SELECT count(*) FROM public.sales_process_cutover_plans)
      +(SELECT count(*) FROM public.sales_process_cutover_items)
      +(SELECT count(*) FROM public.sales_process_cutover_audit))::bigint,
    jsonb_build_object('plans',(SELECT count(*) FROM public.sales_process_cutover_plans),
      'items',(SELECT count(*) FROM public.sales_process_cutover_items),
      'auditRows',(SELECT count(*) FROM public.sales_process_cutover_audit),
      'rule','Foundation performs no Company switch or document conversion')
  UNION ALL
  SELECT 'cutover_foundation_inventory','INFO',0::bigint,jsonb_build_object(
    'retailSettings',(SELECT count(*) FROM public.company_sales_process_settings
      WHERE active_mode='RETAIL_CONFIRM_INVOICE'),
    'officeSettings',(SELECT count(*) FROM public.company_sales_process_settings
      WHERE active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'),
    'retailOpenReservations',(SELECT count(*) FROM public.sales_stock_reservations
      WHERE status IN('OPEN','PARTIALLY_DISPATCHED')),
    'officeOpenReservations',(SELECT count(*) FROM public.backoffice_sales_reservations
      WHERE status<>'RELEASED'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
