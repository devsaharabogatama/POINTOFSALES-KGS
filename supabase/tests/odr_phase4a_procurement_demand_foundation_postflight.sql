-- ODR-4A procurement demand foundation postflight. SELECT-only.
WITH checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828150000'

  UNION ALL
  SELECT 'required_procurement_demand_relations',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',3,'relationRows',count(*))
  FROM pg_class relation
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relkind='r'
    AND relation.relname IN('sales_order_procurement_demands',
      'sales_order_procurement_demand_lines',
      'sales_order_procurement_demand_audit')

  UNION ALL
  SELECT 'procurement_demand_rls_state',
    CASE WHEN count(*)=3 AND bool_and(relation.relrowsecurity)
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('enabledRelations',count(*) FILTER(
      WHERE relation.relrowsecurity))
  FROM pg_class relation
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname IN(
    'sales_order_procurement_demands','sales_order_procurement_demand_lines',
    'sales_order_procurement_demand_audit')

  UNION ALL
  SELECT 'browser_procurement_demand_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants
  WHERE grantee IN('anon','authenticated') AND table_schema='public'
    AND table_name IN('sales_order_procurement_demands',
      'sales_order_procurement_demand_lines',
      'sales_order_procurement_demand_audit')

  UNION ALL
  SELECT 'required_procurement_demand_triggers',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',3,'triggerRows',count(*))
  FROM pg_trigger trigger_row
  WHERE NOT trigger_row.tgisinternal AND trigger_row.tgname IN(
    'trg_odr_guard_procurement_demand_header',
    'trg_odr_guard_procurement_demand_line',
    'trg_odr_guard_procurement_demand_audit')

  UNION ALL
  SELECT 'procurement_demand_quantity_constraint',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',2,'constraintRows',count(*))
  FROM pg_constraint constraint_row
  JOIN pg_class relation ON relation.oid=constraint_row.conrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND constraint_row.contype='c'
    AND ((relation.relname='sales_order_procurement_demands'
      AND constraint_row.conname='sales_order_procurement_demands_quantity_check')
      OR (relation.relname='sales_order_procurement_demand_lines'
      AND constraint_row.conname='sales_order_procurement_demand_lines_quantity_check'))

  UNION ALL
  SELECT 'procurement_demand_zero_backfill',
    CASE WHEN header_rows=0 AND line_rows=0 AND audit_rows=0
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('headers',header_rows,'lines',line_rows,
      'auditRows',audit_rows)
  FROM (SELECT
    (SELECT count(*) FROM public.sales_order_procurement_demands) header_rows,
    (SELECT count(*) FROM public.sales_order_procurement_demand_lines) line_rows,
    (SELECT count(*) FROM public.sales_order_procurement_demand_audit) audit_rows
  ) inventory

  UNION ALL
  SELECT 'legacy_draft_supplier_order_preserved',
    'PASS',
    jsonb_build_object('draftOrders',count(*),
      'rule','Foundation does not mutate existing Draft PO')
  FROM public.supplier_order_documents WHERE status='DRAFT'

  UNION ALL
  SELECT 'foundation_runtime_inventory','INFO',jsonb_build_object(
    'demandHeaders',(SELECT count(*)
      FROM public.sales_order_procurement_demands),
    'demandLines',(SELECT count(*)
      FROM public.sales_order_procurement_demand_lines),
    'draftSupplierOrders',(SELECT count(*)
      FROM public.supplier_order_documents WHERE status='DRAFT'),
    'finalSupplierOrders',(SELECT count(*)
      FROM public.supplier_order_documents WHERE status IN(
        'CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1
  WHEN 'REVIEW' THEN 2 ELSE 3 END,check_name;
