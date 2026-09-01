-- Platform Operational Health Dashboard preflight.
-- SAFETY: SELECT-only. No Company, transaction, stock, Finance, or audit row
-- is changed by this diagnostic.

WITH required_relations(schema_name,relation_name) AS (
  VALUES
    ('public','companies'),
    ('public','cashier_sessions'),
    ('public','finance_posting_queue_runs'),
    ('public','finance_posting_exceptions'),
    ('public','master_import_jobs'),
    ('public','pos_offline_sale_submissions'),
    ('public','sales_stock_reservations'),
    ('public','sales_delivery_documents'),
    ('public','sales_order_procurement_demands'),
    ('public','sales_payment_verification_requests'),
    ('public','financial_events'),
    ('public','negative_stock_sale_allocations'),
    ('public','inventory_cost_adjustment_sources')
), missing_relations AS (
  SELECT relation_name
  FROM required_relations
  WHERE to_regclass(format('%I.%I',schema_name,relation_name)) IS NULL
), required_columns(relation_name,column_name) AS (
  VALUES
    ('companies','id'),('companies','company_code'),
    ('companies','company_name'),('companies','status'),
    ('cashier_sessions','company_id'),('cashier_sessions','status'),
    ('cashier_sessions','opened_at'),
    ('finance_posting_queue_runs','company_id'),
    ('finance_posting_queue_runs','status'),
    ('finance_posting_queue_runs','updated_at'),
    ('finance_posting_exceptions','company_id'),
    ('finance_posting_exceptions','status'),
    ('finance_posting_exceptions','created_at'),
    ('financial_events','company_id'),('financial_events','status'),
    ('master_import_jobs','company_id'),('master_import_jobs','status'),
    ('master_import_jobs','updated_at'),
    ('pos_offline_sale_submissions','company_id'),
    ('pos_offline_sale_submissions','status'),
    ('pos_offline_sale_submissions','updated_at'),
    ('sales_stock_reservations','company_id'),
    ('sales_stock_reservations','status'),
    ('sales_stock_reservations','updated_at'),
    ('sales_delivery_documents','company_id'),
    ('sales_delivery_documents','reservation_id'),
    ('sales_delivery_documents','status'),
    ('sales_delivery_documents','dispatched_at'),
    ('sales_delivery_documents','created_at'),
    ('sales_order_procurement_demands','company_id'),
    ('sales_order_procurement_demands','status'),
    ('sales_order_procurement_demands','updated_at'),
    ('sales_payment_verification_requests','company_id'),
    ('sales_payment_verification_requests','status'),
    ('sales_payment_verification_requests','requested_at'),
    ('negative_stock_sale_allocations','company_id'),
    ('negative_stock_sale_allocations','reconciled_at'),
    ('negative_stock_sale_allocations','shortage_base_qty'),
    ('negative_stock_sale_allocations','replenished_base_qty'),
    ('inventory_cost_adjustment_sources','company_id'),
    ('inventory_cost_adjustment_sources','status')
), missing_columns AS (
  SELECT required.relation_name,required.column_name
  FROM required_columns required
  WHERE NOT EXISTS(SELECT 1 FROM information_schema.columns column_state
    WHERE column_state.table_schema='public'
      AND column_state.table_name=required.relation_name
      AND column_state.column_name=required.column_name)
), checks AS (
  SELECT 'platform_health_dependencies'::TEXT check_name,
    CASE WHEN count(*)=6 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',6,'ledgerRows',count(*),
      'requiredVersions',ARRAY[
        '20260810210000','20260828100000','20260828120000',
        '20260828150000','20260828240000','20260831120000']) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260810210000','20260828100000','20260828120000',
    '20260828150000','20260828240000','20260831120000')

  UNION ALL
  SELECT 'platform_health_relation_state',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('missing',COALESCE(jsonb_agg(relation_name),
      '[]'::JSONB),'expected',13)
  FROM missing_relations

  UNION ALL
  SELECT 'platform_health_column_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('missing',COALESCE(jsonb_agg(jsonb_build_object(
      'relation',relation_name,'column',column_name)
      ORDER BY relation_name,column_name),'[]'::JSONB),
      'expected',(SELECT count(*) FROM required_columns))
  FROM missing_columns

  UNION ALL
  SELECT 'platform_health_guard_routine',
    CASE WHEN to_regprocedure('public.private_is_super_admin(uuid)') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineExists',to_regprocedure(
      'public.private_is_super_admin(uuid)') IS NOT NULL)

  UNION ALL
  SELECT 'platform_health_super_admin_identity',
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('linkedSuperAdmins',count(*))
  FROM public.profiles profile
  WHERE profile.role::TEXT='super_admin'

  UNION ALL
  SELECT 'platform_health_runtime_state','SETUP',jsonb_build_object(
    'rpcExists',to_regprocedure(
      'public.get_platform_operational_health()') IS NOT NULL,
    'requiredDesign',ARRAY[
      'Super Admin only across all Companies',
      'read-only aggregate without trigger or automatic repair',
      'manual refresh and bounded issue metadata without PII',
      'failure isolated from POS and Backoffice operational mutation'])

  UNION ALL
  SELECT 'platform_health_inventory','INFO',jsonb_build_object(
    'companies',(SELECT count(*) FROM public.companies),
    'activeCompanies',(SELECT count(*) FROM public.companies
      WHERE status='ACTIVE'),
    'openCashierSessions',(SELECT count(*) FROM public.cashier_sessions
      WHERE status='OPEN'),
    'activeFinanceQueues',(SELECT count(*)
      FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')),
    'openFinanceExceptions',(SELECT count(*)
      FROM public.finance_posting_exceptions WHERE status<>'RESOLVED'),
    'openReservations',(SELECT count(*) FROM public.sales_stock_reservations
      WHERE status IN('OPEN','PARTIALLY_DISPATCHED')),
    'pendingPayments',(SELECT count(*)
      FROM public.sales_payment_verification_requests WHERE status='PENDING'),
    'openNegativeAllocations',(SELECT count(*)
      FROM public.negative_stock_sale_allocations WHERE reconciled_at IS NULL))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2
  WHEN 'SETUP' THEN 3 ELSE 4 END,check_name;
