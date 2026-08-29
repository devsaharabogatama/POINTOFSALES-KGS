-- ODR-1 Order, reservation, Dispatch, procurement, and Finance preflight.
-- SAFETY: SELECT-only. This file never mutates schema or business data.

WITH runtime_definition AS (
  SELECT namespace.nspname schema_name,procedure.proname routine_name,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname IN('public','private')
), movement_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_change),0) qty
  FROM public.stock_movements
  GROUP BY company_id,product_id,warehouse_id
), fifo_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_remaining),0) qty
  FROM public.product_batches
  GROUP BY company_id,product_id,warehouse_id
), planned_relations(relation_name) AS (
  VALUES
    ('sales_stock_reservations'),
    ('sales_stock_reservation_lines'),
    ('sales_dispatch_allocations'),
    ('sales_order_procurement_demands'),
    ('sales_order_procurement_demand_lines'),
    ('sales_payment_verification_requests')
), checks AS (
  SELECT 'active_finance_posting_queue'::TEXT check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('runCount',count(*)) details
  FROM public.finance_posting_queue_runs run
  WHERE run.status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions submission
  WHERE submission.status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')

  UNION ALL
  SELECT 'stock_balance_movement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pairCount',count(*))
  FROM (SELECT COALESCE(stock.company_id,movement.company_id)
    FROM public.product_stocks stock
    FULL JOIN movement_totals movement
      ON movement.company_id=stock.company_id
     AND movement.product_id=stock.product_id
     AND movement.warehouse_id=stock.warehouse_id
    WHERE COALESCE(stock.stock_qty,0)<>COALESCE(movement.qty,0)) invalid_pair

  UNION ALL
  SELECT 'positive_stock_fifo_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pairCount',count(*))
  FROM public.product_stocks stock
  LEFT JOIN fifo_totals fifo
    ON fifo.company_id=stock.company_id AND fifo.product_id=stock.product_id
   AND fifo.warehouse_id=stock.warehouse_id
  WHERE stock.stock_qty>0 AND stock.stock_qty<>COALESCE(fifo.qty,0)

  UNION ALL
  SELECT 'draft_sale_zero_final_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('saleCount',count(*))
  FROM public.sales_headers sale
  WHERE sale.document_status='DRAFT' AND (
    EXISTS(SELECT 1 FROM public.stock_movements movement
      WHERE movement.company_id=sale.company_id
        AND movement.reference_id=sale.id)
    OR EXISTS(SELECT 1 FROM public.financial_events event
      WHERE event.company_id=sale.company_id
        AND (event.source_id=sale.id OR event.root_sales_id=sale.id))
    OR EXISTS(SELECT 1 FROM public.finance_journals journal
      JOIN public.financial_events event
        ON event.company_id=journal.company_id
       AND event.id=journal.financial_event_id
      WHERE event.company_id=sale.company_id
        AND (event.source_id=sale.id OR event.root_sales_id=sale.id)))

  UNION ALL
  SELECT 'sales_delivery_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphanOrCrossTenantRows',count(*))
  FROM public.sales_delivery_documents delivery
  LEFT JOIN public.sales_headers sale
    ON sale.company_id=delivery.company_id AND sale.id=delivery.sales_id
  LEFT JOIN public.sales_invoice_snapshots invoice
    ON invoice.company_id=delivery.company_id
   AND invoice.id=delivery.invoice_snapshot_id
  WHERE sale.id IS NULL OR invoice.id IS NULL

  UNION ALL
  SELECT 'sales_delivery_line_source_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_delivery_lines delivery_line
  JOIN public.sales_delivery_documents delivery
    ON delivery.company_id=delivery_line.company_id
   AND delivery.id=delivery_line.delivery_document_id
  LEFT JOIN public.sales_details sale_line
    ON sale_line.company_id=delivery_line.company_id
   AND sale_line.id=delivery_line.sales_detail_id
   AND sale_line.sales_id=delivery.sales_id
  WHERE sale_line.id IS NULL
     OR sale_line.product_id<>delivery_line.product_id
     OR sale_line.quantity_base<>delivery_line.quantity_base

  UNION ALL
  SELECT 'supplier_order_request_allocation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requestLineCount',count(*))
  FROM (SELECT request_line.company_id,request_line.id
    FROM public.stock_request_lines request_line
    LEFT JOIN public.supplier_order_request_allocations allocation
      ON allocation.company_id=request_line.company_id
     AND allocation.stock_request_line_id=request_line.id
    LEFT JOIN public.supplier_order_lines order_line
      ON order_line.company_id=allocation.company_id
     AND order_line.id=allocation.supplier_order_line_id
    LEFT JOIN public.supplier_order_documents order_document
      ON order_document.company_id=order_line.company_id
     AND order_document.id=order_line.document_id
     AND order_document.status IN(
       'CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
    GROUP BY request_line.company_id,request_line.id,
      request_line.requested_base_qty
    HAVING COALESCE(sum(allocation.allocated_base_qty)
      FILTER(WHERE order_document.id IS NOT NULL),0)
      > request_line.requested_base_qty) invalid_line

  UNION ALL
  SELECT 'negative_session_request_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT company_id,requesting_session_id
    FROM public.stock_request_documents
    WHERE request_source='NEGATIVE_STOCK_SESSION_CLOSE'
    GROUP BY company_id,requesting_session_id HAVING count(*)>1) duplicate

  UNION ALL
  SELECT 'current_pos_post_final_effect_boundary','REVIEW',
    jsonb_build_object(
      'stockBalanceWritePresent',COALESCE(bool_or(
        definition LIKE '%product_stocks%'),FALSE),
      'stockMovementWritePresent',COALESCE(bool_or(
        definition LIKE '%stock_movements%'),FALSE),
      'fifoWritePresent',COALESCE(bool_or(
        definition LIKE '%product_batches%'),FALSE),
      'requiredCutover','ODR-2 confirms reservation only; ODR-3 Dispatch owns stock final effect')
  FROM runtime_definition
  WHERE routine_name LIKE 'post_pos_sale%'

  UNION ALL
  SELECT 'current_delivery_dispatch_effect_boundary','REVIEW',
    jsonb_build_object(
      'stockBalanceWritePresent',COALESCE(bool_or(
        definition LIKE '%product_stocks%'),FALSE),
      'stockMovementWritePresent',COALESCE(bool_or(
        definition LIKE '%stock_movements%'),FALSE),
      'fifoWritePresent',COALESCE(bool_or(
        definition LIKE '%product_batches%'),FALSE),
      'requiredCutover','ODR-3 adds atomic reservation, On Hand, FIFO and Movement consumption')
  FROM runtime_definition
  WHERE schema_name='private'
    AND routine_name='acp5e_update_sales_delivery_status_core'

  UNION ALL
  SELECT 'current_automatic_document_source_boundary','REVIEW',
    jsonb_build_object(
      'postedSaleGuardPresent',COALESCE(bool_or(
        definition LIKE '%document_status%POSTED%'),FALSE),
      'requiredCutover','Invoice and Delivery creation must follow confirmed order snapshots without preserving early stock or journal effects')
  FROM runtime_definition
  WHERE schema_name='private' AND routine_name='ensure_sales_documents'

  UNION ALL
  SELECT 'current_session_shortage_source_boundary','REVIEW',
    jsonb_build_object(
      'negativeAllocationSourcePresent',COALESCE(bool_or(
        definition LIKE '%negative_stock_sale_allocations%'),FALSE),
      'sessionRequestSourcePresent',COALESCE(bool_or(
        definition LIKE '%NEGATIVE_STOCK_SESSION_CLOSE%'),FALSE),
      'requiredCutover','ODR-4 demand is derived from open reservation shortage and retains Session identity')
  FROM runtime_definition
  WHERE schema_name='private'
    AND routine_name='ensure_negative_session_stock_request'

  UNION ALL
  SELECT 'confirmed_supplier_order_immutability',
    CASE WHEN COALESCE(bool_or(
      definition LIKE '%FINAL_SUPPLIER_ORDER_IMMUTABLE%'
      OR definition LIKE '%SUPPLIER_ORDER_NOT_DRAFT%'),FALSE)
      THEN 'PASS' ELSE 'REVIEW' END,
    jsonb_build_object(
      'draftOnlyGuardPresent',COALESCE(bool_or(
        definition LIKE '%FINAL_SUPPLIER_ORDER_IMMUTABLE%'
        OR definition LIKE '%SUPPLIER_ORDER_NOT_DRAFT%'),FALSE),
      'contract','Only Draft PO may be synchronized; confirmed PO changes require delta or amendment')
  FROM runtime_definition
  WHERE routine_name IN('save_supplier_order','acp5c_save_supplier_order_core')

  UNION ALL
  SELECT 'planned_odr_schema_state','SETUP',
    jsonb_build_object('expectedCandidateRelations',count(*),
      'existing',COALESCE(jsonb_agg(relation_name ORDER BY relation_name)
        FILTER(WHERE to_regclass('public.'||relation_name) IS NOT NULL),
        '[]'::JSONB),
      'missing',COALESCE(jsonb_agg(relation_name ORDER BY relation_name)
        FILTER(WHERE to_regclass('public.'||relation_name) IS NULL),
        '[]'::JSONB))
  FROM planned_relations

  UNION ALL
  SELECT 'browser_delivery_write_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('directWriteRelations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name),'[]'::JSONB))
  FROM (SELECT relation_name FROM (VALUES
      ('sales_delivery_documents'),('sales_delivery_lines')) relation(relation_name)
    WHERE has_table_privilege('authenticated','public.'||relation_name,
      'INSERT,UPDATE,DELETE')) writable

  UNION ALL
  SELECT 'historical_sale_cutover_inventory','INFO',jsonb_build_object(
    'draftSales',count(*) FILTER(WHERE document_status='DRAFT'),
    'postedSales',count(*) FILTER(WHERE document_status='POSTED'),
    'scheduledDrafts',count(*) FILTER(WHERE document_status='DRAFT'
      AND order_timing_mode='SCHEDULED'),
    'deliverySales',(SELECT count(DISTINCT sales_id)
      FROM public.sales_delivery_documents),
    'dispatchedDeliveries',(SELECT count(*)
      FROM public.sales_delivery_documents WHERE status='DISPATCHED'),
    'deliveredDeliveries',(SELECT count(*)
      FROM public.sales_delivery_documents WHERE status='DELIVERED'))
  FROM public.sales_headers

  UNION ALL
  SELECT 'procurement_cutover_inventory','INFO',jsonb_build_object(
    'negativeSessionRequests',count(*) FILTER(
      WHERE request_source='NEGATIVE_STOCK_SESSION_CLOSE'),
    'manualRequests',count(*) FILTER(WHERE request_source='MANUAL'),
    'openRequests',count(*) FILTER(WHERE status IN(
      'DRAFT','SUBMITTED','ORDERED','PARTIALLY_RECEIVED')),
    'draftSupplierOrders',(SELECT count(*)
      FROM public.supplier_order_documents WHERE status='DRAFT'),
    'confirmedSupplierOrders',(SELECT count(*)
      FROM public.supplier_order_documents WHERE status='CONFIRMED'),
    'partiallyReceivedSupplierOrders',(SELECT count(*)
      FROM public.supplier_order_documents WHERE status='PARTIALLY_RECEIVED'))
  FROM public.stock_request_documents

  UNION ALL
  SELECT 'finance_cutover_inventory','INFO',jsonb_build_object(
    'financialEvents',(SELECT count(*) FROM public.financial_events),
    'holdEvents',(SELECT count(*) FROM public.financial_events
      WHERE status='HOLD'),
    'postedEvents',(SELECT count(*) FROM public.financial_events
      WHERE status='POSTED'),
    'postedJournals',(SELECT count(*) FROM public.finance_journals
      WHERE status='POSTED'),
    'openExceptions',(SELECT count(*) FROM public.finance_posting_exceptions
      WHERE status<>'RESOLVED'),
    'salePaymentLegs',(SELECT count(*) FROM public.sales_payments))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status
  WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 WHEN 'REVIEW' THEN 2
  WHEN 'SETUP' THEN 3 ELSE 4 END,check_name;
