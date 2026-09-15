-- Backoffice Quotation/Sales Order isolated foundation postflight. READ ONLY.
WITH expected_relations(object_name) AS (
  VALUES
    ('backoffice_sales_orders'),
    ('backoffice_sales_order_lines'),
    ('backoffice_sales_order_operations'),
    ('backoffice_sales_order_audit')
),
results AS (
  SELECT
    'migration_ledger'::text AS check_name,
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END::text AS status,
    abs(count(*) - 1)::bigint AS violation_rows,
    jsonb_build_object('ledgerRows',count(*)) AS details
  FROM private.kgs_schema_migrations
  WHERE version = '20260908110000'

  UNION ALL

  SELECT
    'required_order_relations',
    CASE WHEN count(*) FILTER (WHERE to_regclass('public.'||object_name) IS NOT NULL) = 4
      THEN 'PASS' ELSE 'BLOCKER' END,
    (4 - count(*) FILTER (WHERE to_regclass('public.'||object_name) IS NOT NULL))::bigint,
    jsonb_build_object(
      'expected',4,
      'relationRows',count(*) FILTER (WHERE to_regclass('public.'||object_name) IS NOT NULL)
    )
  FROM expected_relations

  UNION ALL

  SELECT
    'order_foundation_rls_state',
    CASE WHEN count(*) = 4 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(4 - count(*))::bigint,
    jsonb_build_object('expected',4,'enabledRelations',count(*))
  FROM pg_class relation
  JOIN pg_namespace relation_schema ON relation_schema.oid = relation.relnamespace
  WHERE relation_schema.nspname = 'public'
    AND relation.relname IN (SELECT object_name FROM expected_relations)
    AND relation.relrowsecurity

  UNION ALL

  SELECT
    'browser_order_table_boundary',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants
  WHERE table_schema = 'public'
    AND table_name IN (SELECT object_name FROM expected_relations)
    AND grantee IN ('anon','authenticated')

  UNION ALL

  SELECT
    'order_history_trigger_contract',
    CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(2 - count(*))::bigint,
    jsonb_build_object('expected',2,'triggerRows',count(*))
  FROM pg_trigger trigger_row
  JOIN pg_class relation ON relation.oid = trigger_row.tgrelid
  JOIN pg_namespace relation_schema ON relation_schema.oid = relation.relnamespace
  WHERE relation_schema.nspname = 'public'
    AND relation.relname IN (
      'backoffice_sales_order_operations',
      'backoffice_sales_order_audit'
    )
    AND trigger_row.tgname IN (
      'backoffice_sales_order_operations_immutable',
      'backoffice_sales_order_audit_immutable'
    )
    AND trigger_row.tgenabled <> 'D'

  UNION ALL

  SELECT
    'backoffice_sales_feature_default_off',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,
    jsonb_build_object('enabledCompanies',count(*))
  FROM public.company_features
  WHERE feature_code = 'backoffice_delivered_qty_sales_enabled'
    AND is_enabled

  UNION ALL

  SELECT
    'foundation_zero_transaction_effect',
    CASE WHEN
      (SELECT count(*) FROM public.backoffice_sales_orders) = 0
      AND (SELECT count(*) FROM public.backoffice_sales_order_lines) = 0
      AND (SELECT count(*) FROM public.backoffice_sales_order_operations) = 0
      AND (SELECT count(*) FROM public.backoffice_sales_order_audit) = 0
      THEN 'PASS' ELSE 'BLOCKER' END,
    (
      (SELECT count(*) FROM public.backoffice_sales_orders)
      + (SELECT count(*) FROM public.backoffice_sales_order_lines)
      + (SELECT count(*) FROM public.backoffice_sales_order_operations)
      + (SELECT count(*) FROM public.backoffice_sales_order_audit)
    )::bigint,
    jsonb_build_object(
      'orders',(SELECT count(*) FROM public.backoffice_sales_orders),
      'lines',(SELECT count(*) FROM public.backoffice_sales_order_lines),
      'operations',(SELECT count(*) FROM public.backoffice_sales_order_operations),
      'auditRows',(SELECT count(*) FROM public.backoffice_sales_order_audit),
      'reservations',(SELECT count(*) FROM public.sales_stock_reservations),
      'deliveryDocuments',(SELECT count(*) FROM public.sales_delivery_documents),
      'invoiceSnapshots',(SELECT count(*) FROM public.sales_invoice_snapshots),
      'financeEvents',(SELECT count(*) FROM public.financial_events),
      'stockMovements',(SELECT count(*) FROM public.stock_movements)
    )
)
SELECT check_name,status,violation_rows,details
FROM results
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
