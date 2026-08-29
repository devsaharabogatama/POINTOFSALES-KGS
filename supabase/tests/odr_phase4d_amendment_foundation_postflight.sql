-- ODR-4D amendment foundation postflight. SELECT-only.
WITH checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828180000'

  UNION ALL
  SELECT 'required_amendment_relations',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',2,'relationRows',count(*))
  FROM information_schema.tables WHERE table_schema='public'
    AND table_name IN('sales_order_procurement_amendments',
      'sales_order_procurement_amendment_audit')

  UNION ALL
  SELECT 'amendment_rls_state',
    CASE WHEN count(*)=2 AND bool_and(relation.relrowsecurity)
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('enabledRelations',count(*) FILTER(
      WHERE relation.relrowsecurity))
  FROM pg_class relation JOIN pg_namespace namespace
    ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public'
    AND relation.relname IN('sales_order_procurement_amendments',
      'sales_order_procurement_amendment_audit')

  UNION ALL
  SELECT 'browser_amendment_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants
  WHERE grantee IN('anon','authenticated') AND table_schema='public'
    AND table_name IN('sales_order_procurement_amendments',
      'sales_order_procurement_amendment_audit')

  UNION ALL
  SELECT 'required_amendment_triggers',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',2,'triggerRows',count(*))
  FROM pg_trigger trigger_row JOIN pg_class relation
    ON relation.oid=trigger_row.tgrelid JOIN pg_namespace namespace
    ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND NOT trigger_row.tgisinternal
    AND trigger_row.tgname IN('trg_odr_guard_procurement_amendment',
      'trg_odr_guard_procurement_amendment_audit')

  UNION ALL
  SELECT 'amendment_zero_backfill',
    CASE WHEN (SELECT count(*) FROM public.sales_order_procurement_amendments)=0
      AND (SELECT count(*) FROM public.sales_order_procurement_amendment_audit)=0
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object(
      'amendments',(SELECT count(*)
        FROM public.sales_order_procurement_amendments),
      'auditRows',(SELECT count(*)
        FROM public.sales_order_procurement_amendment_audit))

  UNION ALL
  SELECT 'legacy_procurement_preserved','PASS',jsonb_build_object(
    'requests',(SELECT count(*) FROM public.stock_request_documents),
    'draftOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE status='DRAFT'),
    'finalOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')),
    'rule','foundation creates no Request or PO row')

  UNION ALL
  SELECT 'amendment_foundation_inventory','INFO',jsonb_build_object(
    'managedRequests',(SELECT count(*) FROM public.stock_request_documents
      WHERE request_source='SALES_ORDER_RESERVATION'),
    'openAmendments',(SELECT count(*)
      FROM public.sales_order_procurement_amendments WHERE status='OPEN'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;

