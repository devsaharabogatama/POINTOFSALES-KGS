-- ODR-3 Delivery Dispatch stock runtime preflight.
-- SAFETY: one SELECT statement; no schema/data mutation.
WITH movement_totals AS (
  SELECT company_id,product_id,warehouse_id,sum(qty_change) qty
  FROM public.stock_movements WHERE movement_status='POSTED'
  GROUP BY company_id,product_id,warehouse_id
), fifo_totals AS (
  SELECT company_id,product_id,warehouse_id,sum(qty_remaining) qty
  FROM public.product_batches
  GROUP BY company_id,product_id,warehouse_id
), function_definition AS (
  SELECT namespace.nspname schema_name,procedure.proname,
    pg_get_function_identity_arguments(procedure.oid) arguments,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname) IN(
    ('public','confirm_pos_sales_order'),('public','update_sales_delivery_status'),
    ('private','acp5e_update_sales_delivery_status_core'))
), checks AS (
  SELECT 'odr_phase2_dependencies'::TEXT check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',2,'ledgerRows',count(*),'requiredVersions',
      ARRAY['20260828100000','20260828110000']) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260828100000','20260828110000')

  UNION ALL
  SELECT 'active_finance_posting_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*)) FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*)) FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')

  UNION ALL
  SELECT 'stock_balance_movement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pairCount',count(*))
  FROM (SELECT COALESCE(stock.company_id,movement.company_id)
    FROM public.product_stocks stock FULL JOIN movement_totals movement
      ON movement.company_id=stock.company_id AND movement.product_id=stock.product_id
     AND movement.warehouse_id=stock.warehouse_id
    WHERE COALESCE(stock.stock_qty,0)<>COALESCE(movement.qty,0)) invalid_pair

  UNION ALL
  SELECT 'positive_stock_fifo_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pairCount',count(*))
  FROM public.product_stocks stock LEFT JOIN fifo_totals fifo
    ON fifo.company_id=stock.company_id AND fifo.product_id=stock.product_id
   AND fifo.warehouse_id=stock.warehouse_id
  WHERE stock.stock_qty>0 AND stock.stock_qty<>COALESCE(fifo.qty,0)

  UNION ALL
  SELECT 'reservation_dispatch_quantity_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_stock_reservation_lines line
  WHERE line.released_base_qty<0 OR line.dispatched_base_qty<0
     OR line.released_base_qty+line.dispatched_base_qty>line.reserved_base_qty

  UNION ALL
  SELECT 'reservation_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('reservationCount',count(*))
  FROM public.sales_stock_reservations reservation
  WHERE reservation.total_reserved_base_qty IS DISTINCT FROM COALESCE((
      SELECT sum(line.reserved_base_qty) FROM public.sales_stock_reservation_lines line
      WHERE line.company_id=reservation.company_id AND line.reservation_id=reservation.id),0)
     OR reservation.total_released_base_qty IS DISTINCT FROM COALESCE((
      SELECT sum(line.released_base_qty) FROM public.sales_stock_reservation_lines line
      WHERE line.company_id=reservation.company_id AND line.reservation_id=reservation.id),0)
     OR reservation.total_dispatched_base_qty IS DISTINCT FROM COALESCE((
      SELECT sum(line.dispatched_base_qty) FROM public.sales_stock_reservation_lines line
      WHERE line.company_id=reservation.company_id AND line.reservation_id=reservation.id),0)

  UNION ALL
  SELECT 'sales_delivery_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphanOrCrossTenantRows',count(*))
  FROM public.sales_delivery_documents delivery
  LEFT JOIN public.sales_headers sale ON sale.company_id=delivery.company_id
    AND sale.id=delivery.sales_id
  LEFT JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=delivery.company_id
    AND invoice.id=delivery.invoice_snapshot_id AND invoice.sales_id=delivery.sales_id
  LEFT JOIN public.warehouses warehouse ON warehouse.company_id=delivery.company_id
    AND warehouse.id=delivery.warehouse_id
  WHERE sale.id IS NULL OR invoice.id IS NULL OR warehouse.id IS NULL

  UNION ALL
  SELECT 'sales_delivery_line_source_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_delivery_lines line
  JOIN public.sales_delivery_documents delivery ON delivery.company_id=line.company_id
    AND delivery.id=line.delivery_document_id
  LEFT JOIN public.sales_details detail ON detail.company_id=line.company_id
    AND detail.id=line.sales_detail_id AND detail.sales_id=delivery.sales_id
  WHERE detail.id IS NULL OR line.product_id<>detail.product_id
     OR line.quantity_base<>detail.quantity_base

  UNION ALL
  SELECT 'legacy_delivery_reservation_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_delivery_documents delivery
  JOIN public.sales_headers sale ON sale.company_id=delivery.company_id
    AND sale.id=delivery.sales_id
  WHERE sale.order_runtime_status<>'LEGACY_POSTED'
    AND NOT EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
      WHERE reservation.company_id=delivery.company_id
        AND reservation.sales_id=delivery.sales_id)

  UNION ALL
  SELECT 'reserved_order_document_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('orderCount',count(*))
  FROM public.sales_stock_reservations reservation
  JOIN public.sales_headers sale ON sale.company_id=reservation.company_id
    AND sale.id=reservation.sales_id
  WHERE reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
    AND (NOT EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
          WHERE invoice.company_id=sale.company_id AND invoice.sales_id=sale.id)
      OR NOT EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
          WHERE delivery.company_id=sale.company_id AND delivery.sales_id=sale.id))

  UNION ALL
  SELECT 'negative_reservation_dispatch_readiness',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('lineCount',count(*))
  FROM public.sales_stock_reservation_lines line
  LEFT JOIN public.pos_negative_stock_policies policy
    ON policy.company_id=line.company_id AND policy.is_active
  WHERE line.shortage_base_qty>0 AND (
    line.negative_policy_version IS NULL OR line.negative_permission_version IS NULL
    OR policy.id IS NULL OR to_regprocedure(
      'private.resolve_pos_negative_stock_provisional_cost(uuid,uuid,uuid)') IS NULL)

  UNION ALL
  SELECT 'delivery_document_direct_write_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('writableRelations',COALESCE(jsonb_agg(name ORDER BY name),'[]'::JSONB))
  FROM (SELECT name FROM (VALUES('sales_delivery_documents'),('sales_delivery_lines'),
      ('sales_stock_reservations'),('sales_stock_reservation_lines'),
      ('product_stocks'),('product_batches'),('stock_movements')) relation(name)
    WHERE has_table_privilege('authenticated','public.'||name,'INSERT,UPDATE,DELETE')) writable

  UNION ALL
  SELECT 'inventory_delivery_permission_state',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',
      COALESCE(jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='inventory.delivery_documents'

  UNION ALL
  SELECT 'current_delivery_dispatch_effect_boundary','REVIEW',jsonb_build_object(
    'requiredCutover','ODR-3 Dispatch must atomically consume reservation, On Hand, FIFO and Movement',
    'routineRows',count(*),
    'stockWritePresent',COALESCE(bool_or(definition LIKE '%product_stocks%'),FALSE),
    'fifoWritePresent',COALESCE(bool_or(definition LIKE '%product_batches%'),FALSE),
    'movementWritePresent',COALESCE(bool_or(definition LIKE '%stock_movements%'),FALSE))
  FROM function_definition WHERE proname='acp5e_update_sales_delivery_status_core'

  UNION ALL
  SELECT 'confirmed_order_document_creation_boundary','REVIEW',jsonb_build_object(
    'requiredCutover','Confirmed Order needs immutable Invoice/SJ snapshots before Dispatch without Finance or stock effect',
    'confirmRoutineRows',count(*),
    'documentCreationPresent',COALESCE(bool_or(definition LIKE '%sales_delivery_documents%'
      AND definition LIKE '%sales_invoice_snapshots%'),FALSE))
  FROM function_definition WHERE proname='confirm_pos_sales_order'

  UNION ALL
  SELECT 'commercial_reservation_lineage_scope','REVIEW',jsonb_build_object(
    'requiredDesign',ARRAY[
      'Delivery commercial lines stay printable and immutable',
      'Dispatch allocations link each commercial line to reservation stock requirements',
      'Bundle dispatch consumes component reservation and never Bundle physical stock'],
    'deliveryLines',count(*),'bundleDeliveryLines',count(*) FILTER(WHERE product.is_bundle),
    'multiRequirementLines',count(*) FILTER(WHERE requirement_count>1))
  FROM (SELECT line.id,line.company_id,line.product_id,
      (SELECT count(*) FROM public.sale_stock_requirements requirement
       WHERE requirement.company_id=line.company_id
         AND requirement.sales_detail_id=line.sales_detail_id) requirement_count
    FROM public.sales_delivery_lines line) line_scope
  JOIN public.products product ON product.company_id=line_scope.company_id
    AND product.id=line_scope.product_id

  UNION ALL
  SELECT 'historical_delivery_cutover_scope','REVIEW',jsonb_build_object(
    'rule','Legacy delivery remains historical and never receives ODR dispatch stock effect',
    'ready',count(*) FILTER(WHERE delivery.status='READY'),
    'dispatched',count(*) FILTER(WHERE delivery.status='DISPATCHED'),
    'delivered',count(*) FILTER(WHERE delivery.status='DELIVERED'),
    'canceled',count(*) FILTER(WHERE delivery.status='CANCELED'))
  FROM public.sales_delivery_documents delivery
  JOIN public.sales_headers sale ON sale.company_id=delivery.company_id
    AND sale.id=delivery.sales_id AND sale.order_runtime_status='LEGACY_POSTED'

  UNION ALL
  SELECT 'dispatch_allocation_schema_state','SETUP',jsonb_build_object(
    'missing',CASE WHEN to_regclass('public.sales_dispatch_allocations') IS NULL
      THEN jsonb_build_array('sales_dispatch_allocations') ELSE '[]'::JSONB END,
    'expected',1)

  UNION ALL
  SELECT 'partial_dispatch_lifecycle_state','SETUP',jsonb_build_object(
    'statusConstraintSupportsPartial',EXISTS(SELECT 1 FROM pg_constraint constraint_row
      JOIN pg_class relation ON relation.oid=constraint_row.conrelid
      JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
      WHERE namespace.nspname='public' AND relation.relname='sales_delivery_documents'
        AND constraint_row.contype='c'
        AND pg_get_constraintdef(constraint_row.oid) LIKE '%PARTIALLY_DISPATCHED%'))

  UNION ALL
  SELECT 'canonical_dispatch_runtime_state','SETUP',jsonb_build_object(
    'missing',COALESCE(jsonb_agg(name ORDER BY name)
      FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB),'expected',count(*))
  FROM (VALUES
    ('public.dispatch_sales_delivery',
      'public.dispatch_sales_delivery(uuid,bigint,uuid,jsonb,text)'),
    ('public.confirm_sales_delivery_received',
      'public.confirm_sales_delivery_received(uuid,bigint,uuid,text)'),
    ('public.get_inventory_delivery_dispatch_workspace',
      'public.get_inventory_delivery_dispatch_workspace(uuid)')
  ) runtime(name,signature)

  UNION ALL
  SELECT 'odr3_runtime_inventory','INFO',jsonb_build_object(
    'reservations',count(DISTINCT reservation.id),
    'openReservations',count(DISTINCT reservation.id) FILTER(WHERE reservation.status='OPEN'),
    'reservationLines',count(line.id),
    'reservedBaseQty',COALESCE(sum(line.reserved_base_qty),0),
    'shortageBaseQty',COALESCE(sum(line.shortage_base_qty),0),
    'deliveryDocuments',(SELECT count(*) FROM public.sales_delivery_documents),
    'deliveryLines',(SELECT count(*) FROM public.sales_delivery_lines))
  FROM public.sales_stock_reservations reservation
  LEFT JOIN public.sales_stock_reservation_lines line
    ON line.company_id=reservation.company_id AND line.reservation_id=reservation.id
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'BACKFILL' THEN 1
  WHEN 'PASS' THEN 2 WHEN 'REVIEW' THEN 3 WHEN 'SETUP' THEN 4 ELSE 5 END,check_name;
