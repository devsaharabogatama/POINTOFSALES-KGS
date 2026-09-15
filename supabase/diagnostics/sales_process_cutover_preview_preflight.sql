-- SELECT-only preflight for 20260909163000.
WITH checks AS (
  SELECT 'cutover_foundation_dependency'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909162000'
  UNION ALL
  SELECT 'required_cutover_foundation_relations',
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END,abs(5-count(*))::bigint,
    jsonb_build_object('expected',5,'relationRows',count(*))
  FROM information_schema.tables WHERE table_schema='public' AND table_name IN(
    'company_sales_process_settings','company_sales_process_mode_history',
    'sales_process_cutover_plans','sales_process_cutover_items','sales_process_cutover_audit')
  UNION ALL
  SELECT 'required_cutover_preview_source_relations',
    CASE WHEN count(*)=18 THEN 'PASS' ELSE 'BLOCKER' END,abs(18-count(*))::bigint,
    jsonb_build_object('expected',18,'relationRows',count(*))
  FROM information_schema.tables WHERE table_schema='public' AND table_name IN(
    'company_features','pos_offline_sale_submissions','finance_posting_queue_runs',
    'sales_headers','sales_stock_reservations','sales_delivery_documents',
    'sales_dispatch_financial_effects','financial_events',
    'sales_payment_verification_requests','sales_payments','sales_invoice_snapshots',
    'sales_order_revisions','sales_order_procurement_demand_lines',
    'backoffice_sales_orders','backoffice_sales_reservations',
    'backoffice_sales_delivery_orders','backoffice_sales_delivery_receipts',
    'backoffice_sales_invoices')
  UNION ALL
  SELECT 'company_setting_coverage',
    CASE WHEN count(*)=(SELECT count(*) FROM public.companies) THEN 'PASS' ELSE 'BLOCKER' END,
    abs((SELECT count(*) FROM public.companies)-count(*))::bigint,
    jsonb_build_object('settingsRows',count(*),'companyRows',(SELECT count(*) FROM public.companies))
  FROM public.company_sales_process_settings
  UNION ALL
  SELECT 'preview_routine_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('collisionRows',count(*))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE (namespace.nspname='private' AND proc.proname='get_sales_process_cutover_preview_core')
    OR (namespace.nspname='public' AND proc.proname='get_sales_process_cutover_preview')
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'INFO' END,0::bigint,
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'behavior_fixture_company',
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('eligibleCompanies',count(*))
  FROM (SELECT DISTINCT setting.company_id
    FROM public.company_sales_process_settings setting
    JOIN public.companies company ON company.id=setting.company_id AND company.status='ACTIVE'
    JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
    JOIN public.warehouses warehouse ON warehouse.company_id=company.id
      AND warehouse.is_active AND warehouse.is_sale_source
      AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
    JOIN public.customers customer ON customer.company_id=company.id AND customer.is_active) fixture
  UNION ALL
  SELECT 'cutover_source_inventory','INFO',0::bigint,jsonb_build_object(
    'retailOpen',(SELECT count(*) FROM public.sales_headers WHERE order_runtime_status IN(
      'DRAFT_INPUT','SCHEDULED','CONFIRMED','RESERVED','PARTIALLY_DISPATCHED','DISPATCHED')),
    'retailPendingRevision',(SELECT count(*) FROM public.sales_order_revisions WHERE status='PENDING'),
    'retailOpenProcurement',(SELECT count(*) FROM public.sales_order_procurement_demand_lines
      WHERE status IN('OPEN','REQUESTED','ORDERED','AMENDMENT_REQUIRED')),
    'officeOpen',(SELECT count(*) FROM public.backoffice_sales_orders
      WHERE status IN('DRAFT','SENT','CONFIRMED') AND fulfillment_status<>'COMPLETED'),
    'nonterminalOffline',(SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
