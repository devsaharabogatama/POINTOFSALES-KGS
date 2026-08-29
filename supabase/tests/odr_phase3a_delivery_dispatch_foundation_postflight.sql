-- ODR-3A Delivery dispatch foundation postflight. SELECT-only.
WITH checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828120000'
  UNION ALL
  SELECT 'required_dispatch_schema',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',4,'columnRows',count(*))
  FROM information_schema.columns
  WHERE table_schema='public' AND (
    (table_name='sales_delivery_documents' AND column_name IN(
      'reservation_id','dispatch_version','total_dispatched_base_qty'))
    OR (table_name='sales_dispatch_allocations' AND column_name='id'))
  UNION ALL
  SELECT 'partial_dispatch_lifecycle',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('constraintRows',count(*))
  FROM pg_constraint constraint_row
  JOIN pg_class relation ON relation.oid=constraint_row.conrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname='sales_delivery_documents'
    AND constraint_row.conname='sales_delivery_document_status_check'
    AND pg_get_constraintdef(constraint_row.oid) LIKE '%PARTIALLY_DISPATCHED%'
  UNION ALL
  SELECT 'browser_dispatch_allocation_write_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('writableRelations',COALESCE(jsonb_agg(table_name)
      FILTER(WHERE table_name IS NOT NULL),'[]'::JSONB))
  FROM information_schema.role_table_grants
  WHERE grantee='authenticated' AND table_schema='public'
    AND table_name='sales_dispatch_allocations'
    AND privilege_type IN('INSERT','UPDATE','DELETE','TRUNCATE')
  UNION ALL
  SELECT 'legacy_delivery_reservation_zero_backfill',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_delivery_documents WHERE reservation_id IS NOT NULL
  UNION ALL
  SELECT 'dispatch_allocation_zero_backfill',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_dispatch_allocations
  UNION ALL
  SELECT 'stock_balance_movement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('pairCount',count(*))
  FROM (
    SELECT stock.company_id,stock.warehouse_id,stock.product_id
    FROM public.product_stocks stock
    LEFT JOIN LATERAL (SELECT movement.balance_after_base_qty
      FROM public.stock_movements movement
      WHERE movement.company_id=stock.company_id
        AND movement.warehouse_id=stock.warehouse_id
        AND movement.product_id=stock.product_id
      ORDER BY movement.posted_at DESC,movement.id DESC LIMIT 1) latest ON TRUE
    WHERE latest.balance_after_base_qty IS NOT NULL
      AND stock.stock_qty IS DISTINCT FROM latest.balance_after_base_qty
  ) invalid
  UNION ALL
  SELECT 'foundation_runtime_inventory','INFO',jsonb_build_object(
    'legacyDeliveries',(SELECT count(*) FROM public.sales_delivery_documents),
    'linkedDeliveries',(SELECT count(*) FROM public.sales_delivery_documents
      WHERE reservation_id IS NOT NULL),
    'dispatchAllocations',(SELECT count(*) FROM public.sales_dispatch_allocations),
    'openReservations',(SELECT count(*) FROM public.sales_stock_reservations
      WHERE status IN('OPEN','PARTIALLY_DISPATCHED')))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
