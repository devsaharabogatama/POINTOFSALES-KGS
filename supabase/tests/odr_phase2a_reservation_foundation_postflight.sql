-- ODR-2A foundation postflight. SAFETY: SELECT-only.
WITH checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828100000'
  UNION ALL
  SELECT 'required_reservation_relations',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',3,'relationRows',count(*))
  FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname IN(
    'sales_stock_reservations','sales_stock_reservation_lines','sales_stock_reservation_audit')
  UNION ALL
  SELECT 'required_sales_order_columns',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',5,'columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public' AND table_name='sales_headers'
    AND column_name IN('order_runtime_status','confirmed_at','confirmed_by',
      'confirmation_idempotency_key','reservation_version')
  UNION ALL
  SELECT 'historical_order_classification',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('rowCount',count(*)) FROM public.sales_headers
  WHERE (document_status='POSTED' AND order_runtime_status<>'LEGACY_POSTED')
     OR (document_status='CANCELED' AND order_runtime_status<>'CANCELED')
     OR (document_status='DRAFT' AND order_runtime_status NOT IN('DRAFT_INPUT','SCHEDULED'))
  UNION ALL
  SELECT 'reservation_zero_backfill',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('reservationRows',count(*)) FROM public.sales_stock_reservations
  UNION ALL
  SELECT 'browser_reservation_write_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('writableRelations',COALESCE(jsonb_agg(name),'[]'::JSONB))
  FROM (SELECT name FROM (VALUES('sales_stock_reservations'),
      ('sales_stock_reservation_lines'),('sales_stock_reservation_audit')) item(name)
    WHERE has_table_privilege('authenticated','public.'||name,'INSERT,UPDATE,DELETE')) writable
  UNION ALL
  SELECT 'reservation_rls_state',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('enabledRelations',count(*)) FROM pg_class relation
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relrowsecurity
    AND relation.relname IN('sales_stock_reservations','sales_stock_reservation_lines',
      'sales_stock_reservation_audit')
  UNION ALL
  SELECT 'sales_order_permission_shadow',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog WHERE permission_key='sales.sales_orders'
    AND enforcement_status='SHADOW'
  UNION ALL
  SELECT 'foundation_runtime_inventory','INFO',jsonb_build_object(
    'draftInput',count(*) FILTER(WHERE order_runtime_status='DRAFT_INPUT'),
    'scheduled',count(*) FILTER(WHERE order_runtime_status='SCHEDULED'),
    'legacyPosted',count(*) FILTER(WHERE order_runtime_status='LEGACY_POSTED'),
    'canceled',count(*) FILTER(WHERE order_runtime_status='CANCELED'))
  FROM public.sales_headers
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
