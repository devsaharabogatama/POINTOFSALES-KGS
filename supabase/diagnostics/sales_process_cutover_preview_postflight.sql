-- SELECT-only verification for 20260909163000.
WITH checks AS (
  SELECT 'migration_ledger'::text check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909163000'
  UNION ALL
  SELECT 'required_cutover_preview_routines',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*))::bigint,jsonb_build_object('routineRows',count(*))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE (namespace.nspname='private' AND proc.proname='get_sales_process_cutover_preview_core')
    OR (namespace.nspname='public' AND proc.proname='get_sales_process_cutover_preview')
  UNION ALL
  SELECT 'cutover_preview_security_contract',
    CASE WHEN count(*)=1 AND bool_and(proc.prosecdef) AND bool_and(proc.provolatile='s')
      AND bool_and(proc.proconfig @> ARRAY['search_path=public, pg_temp','statement_timeout=8s'])
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(proc.prosecdef) AND bool_and(proc.provolatile='s')
      AND bool_and(proc.proconfig @> ARRAY['search_path=public, pg_temp','statement_timeout=8s'])
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',count(*),'securityDefiner',COALESCE(bool_and(proc.prosecdef),false),
      'volatility',max(proc.provolatile::text),'config',max(proc.proconfig::text))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname='public' AND proc.proname='get_sales_process_cutover_preview'
  UNION ALL
  SELECT 'cutover_preview_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE grantee='anon')=0
      AND count(*) FILTER(WHERE grantee='authenticated')=1 THEN 'PASS' ELSE 'FAIL' END,
    (count(*) FILTER(WHERE grantee='anon')
      +abs(1-count(*) FILTER(WHERE grantee='authenticated')))::bigint,
    jsonb_build_object('anonExecute',count(*) FILTER(WHERE grantee='anon'),
      'authenticatedExecute',count(*) FILTER(WHERE grantee='authenticated'))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='public' AND privilege.privilege_type='EXECUTE'
    AND privilege.routine_name='get_sales_process_cutover_preview'
    AND privilege.grantee IN('anon','authenticated')
  UNION ALL
  SELECT 'cutover_preview_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private' AND privilege.privilege_type='EXECUTE'
    AND privilege.routine_name='get_sales_process_cutover_preview_core'
    AND privilege.grantee='authenticated'
  UNION ALL
  SELECT 'cutover_preview_definition_contract',
    CASE WHEN count(*)=1 AND bool_and(
      position('sales_order_revisions' in pg_get_functiondef(proc.oid))>0
      AND position('sales_stock_reservations' in pg_get_functiondef(proc.oid))>0
      AND position('sales_order_procurement_demand_lines' in pg_get_functiondef(proc.oid))>0
      AND position('backoffice_sales_reservations' in pg_get_functiondef(proc.oid))>0
      AND position('backoffice_sales_delivery_receipts' in pg_get_functiondef(proc.oid))>0
      AND position('sales_payment_verification_requests' in pg_get_functiondef(proc.oid))>0
      AND position('sales_payments' in pg_get_functiondef(proc.oid))>0
      AND position('financial_events' in pg_get_functiondef(proc.oid))>0
      AND position('pos_offline_sale_submissions' in pg_get_functiondef(proc.oid))>0)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(
      position('sales_order_revisions' in pg_get_functiondef(proc.oid))>0
      AND position('sales_stock_reservations' in pg_get_functiondef(proc.oid))>0
      AND position('sales_order_procurement_demand_lines' in pg_get_functiondef(proc.oid))>0
      AND position('backoffice_sales_reservations' in pg_get_functiondef(proc.oid))>0
      AND position('backoffice_sales_delivery_receipts' in pg_get_functiondef(proc.oid))>0
      AND position('sales_payment_verification_requests' in pg_get_functiondef(proc.oid))>0
      AND position('sales_payments' in pg_get_functiondef(proc.oid))>0
      AND position('financial_events' in pg_get_functiondef(proc.oid))>0
      AND position('pos_offline_sale_submissions' in pg_get_functiondef(proc.oid))>0)
      THEN 0 ELSE 1 END::bigint,jsonb_build_object('coreRows',count(*),'previewVersion',1)
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname='private' AND proc.proname='get_sales_process_cutover_preview_core'
  UNION ALL
  SELECT 'zero_cutover_preview_write_effect',
    CASE WHEN (SELECT count(*) FROM public.sales_process_cutover_plans)=0
      AND (SELECT count(*) FROM public.sales_process_cutover_items)=0
      AND (SELECT count(*) FROM public.sales_process_cutover_audit)=0 THEN 'PASS' ELSE 'FAIL' END,
    ((SELECT count(*) FROM public.sales_process_cutover_plans)
      +(SELECT count(*) FROM public.sales_process_cutover_items)
      +(SELECT count(*) FROM public.sales_process_cutover_audit))::bigint,
    jsonb_build_object('plans',(SELECT count(*) FROM public.sales_process_cutover_plans),
      'items',(SELECT count(*) FROM public.sales_process_cutover_items),
      'auditRows',(SELECT count(*) FROM public.sales_process_cutover_audit))
  UNION ALL
  SELECT 'cutover_preview_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'retailCompanies',(SELECT count(*) FROM public.company_sales_process_settings
      WHERE active_mode='RETAIL_CONFIRM_INVOICE'),
    'officeCompanies',(SELECT count(*) FROM public.company_sales_process_settings
      WHERE active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'),
    'retailOpenOrders',(SELECT count(*) FROM public.sales_headers WHERE order_runtime_status IN(
      'DRAFT_INPUT','SCHEDULED','CONFIRMED','RESERVED','PARTIALLY_DISPATCHED','DISPATCHED')),
    'officeOpenOrders',(SELECT count(*) FROM public.backoffice_sales_orders
      WHERE status IN('DRAFT','SENT','CONFIRMED') AND fulfillment_status<>'COMPLETED'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
