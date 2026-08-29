-- ODR-3B confirmed-order documents postflight. SELECT-only.
WITH checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828130000'
  UNION ALL
  SELECT 'required_confirmed_order_document_routines',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',4,'routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname IN('private','public') AND (
    (namespace.nspname='private' AND routine.proname IN(
      'build_confirmed_order_invoice_snapshot','ensure_confirmed_order_documents'))
    OR (namespace.nspname='public' AND routine.proname IN(
      'confirm_pos_sales_order','cancel_pos_sales_order')))
  UNION ALL
  SELECT 'order_confirm_provenance_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('constraintRows',count(*))
  FROM pg_constraint constraint_row
  JOIN pg_class relation ON relation.oid=constraint_row.conrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname='sales_invoice_snapshots'
    AND constraint_row.conname='sales_invoice_snapshot_provenance_check'
    AND pg_get_constraintdef(constraint_row.oid) LIKE '%ORDER_CONFIRM%'
  UNION ALL
  SELECT 'confirmed_order_document_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_stock_reservations reservation
  LEFT JOIN public.sales_invoice_snapshots invoice
    ON invoice.company_id=reservation.company_id AND invoice.sales_id=reservation.sales_id
  LEFT JOIN public.sales_delivery_documents delivery
    ON delivery.company_id=reservation.company_id AND delivery.sales_id=reservation.sales_id
      AND delivery.reservation_id=reservation.id
  WHERE invoice.id IS NULL OR delivery.id IS NULL
  UNION ALL
  SELECT 'linked_delivery_line_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('documentCount',count(*))
  FROM public.sales_delivery_documents delivery
  WHERE delivery.reservation_id IS NOT NULL AND NOT EXISTS(
    SELECT 1 FROM public.sales_delivery_lines line
    WHERE line.company_id=delivery.company_id AND line.delivery_document_id=delivery.id)
  UNION ALL
  SELECT 'legacy_dispatch_bypass_quarantined',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('guardedRoutineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE (namespace.nspname='private' AND routine.proname='acp5e_update_sales_delivery_status_core'
      AND pg_get_functiondef(routine.oid) LIKE '%USE_CANONICAL_DISPATCH_RUNTIME%')
    OR (namespace.nspname='public' AND routine.proname='update_sales_delivery_status'
      AND pg_get_functiondef(routine.oid) LIKE '%acp5e_update_sales_delivery_status_core%')
  UNION ALL
  SELECT 'confirmed_order_zero_stock_finance_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_stock_reservations reservation
  JOIN public.sales_headers sale ON sale.company_id=reservation.company_id
    AND sale.id=reservation.sales_id
  WHERE sale.document_status='DRAFT' AND (
    EXISTS(SELECT 1 FROM public.stock_movements movement
      WHERE movement.company_id=sale.company_id AND movement.reference_id=sale.id)
    OR EXISTS(SELECT 1 FROM public.financial_events event
      WHERE event.company_id=sale.company_id AND event.source_id=sale.id))
  UNION ALL
  SELECT 'historical_delivery_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_delivery_documents delivery
  JOIN public.sales_headers sale ON sale.company_id=delivery.company_id
    AND sale.id=delivery.sales_id
  WHERE sale.order_runtime_status='LEGACY_POSTED' AND delivery.reservation_id IS NOT NULL
  UNION ALL
  SELECT 'document_runtime_inventory','INFO',jsonb_build_object(
    'reservations',(SELECT count(*) FROM public.sales_stock_reservations),
    'orderConfirmInvoices',(SELECT count(*) FROM public.sales_invoice_snapshots
      WHERE snapshot_provenance='ORDER_CONFIRM'),
    'linkedDeliveries',(SELECT count(*) FROM public.sales_delivery_documents
      WHERE reservation_id IS NOT NULL),
    'legacyDeliveries',(SELECT count(*) FROM public.sales_delivery_documents
      WHERE reservation_id IS NULL))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
