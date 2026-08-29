-- ODR-4 Procurement demand and Draft-PO synchronization preflight.
-- SAFETY: SELECT-only. No schema, data, grant, policy, or routine mutation.

WITH required_versions(version) AS (
  VALUES ('20260828100000'),('20260828110000'),('20260828120000'),
    ('20260828130000'),('20260828140000')
), planned_relations(relation_name) AS (
  VALUES ('sales_order_procurement_demands'),
    ('sales_order_procurement_demand_lines')
), routine_definition AS (
  SELECT namespace.nspname schema_name,procedure.proname routine_name,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname IN('public','private')
    AND procedure.proname IN('save_supplier_order',
      'acp5c_save_supplier_order_core','ensure_negative_session_stock_request',
      'close_cashier_session')
), open_shortage AS (
  SELECT line.company_id,line.id reservation_line_id,line.sales_id,
    sale.session_id,sale.store_id,line.warehouse_id,line.stock_product_id,
    GREATEST(line.shortage_base_qty-line.released_base_qty-
      line.dispatched_base_qty,0) open_shortage_base_qty
  FROM public.sales_stock_reservation_lines line
  JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=line.company_id
   AND reservation.id=line.reservation_id
  JOIN public.sales_headers sale
    ON sale.company_id=line.company_id AND sale.id=line.sales_id
  WHERE reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
    AND line.shortage_base_qty>line.released_base_qty+line.dispatched_base_qty
), checks AS (
  SELECT 'odr_phase4_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(required.version ORDER BY required.version)
        FILTER(WHERE migration.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required
  LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=required.version

  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs run
  WHERE run.status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions submission
  WHERE submission.status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')

  UNION ALL
  SELECT 'open_shortage_session_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM open_shortage shortage
  LEFT JOIN public.cashier_sessions session
    ON session.company_id=shortage.company_id
   AND session.id=shortage.session_id
  WHERE session.id IS NULL OR session.store_id<>shortage.store_id
    OR session.sales_warehouse_id<>shortage.warehouse_id

  UNION ALL
  SELECT 'open_shortage_quantity_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM open_shortage shortage
  WHERE shortage.open_shortage_base_qty<=0

  UNION ALL
  SELECT 'negative_session_request_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT company_id,requesting_session_id
    FROM public.stock_request_documents
    WHERE request_source='NEGATIVE_STOCK_SESSION_CLOSE'
    GROUP BY company_id,requesting_session_id HAVING count(*)>1) duplicate_group

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
  SELECT 'draft_supplier_order_allocation_scope','REVIEW',
    jsonb_build_object(
      'draftOrders',count(DISTINCT order_document.id),
      'requestLines',count(DISTINCT allocation.stock_request_line_id),
      'allocationRows',count(allocation.id),
      'allocatedBaseQty',COALESCE(sum(allocation.allocated_base_qty),0),
      'requiredCutover','Draft PO allocations are mutable planning scope and must be reconciled by ODR-4 synchronization before final confirmation')
  FROM public.supplier_order_documents order_document
  JOIN public.supplier_order_lines order_line
    ON order_line.company_id=order_document.company_id
   AND order_line.document_id=order_document.id
  JOIN public.supplier_order_request_allocations allocation
    ON allocation.company_id=order_line.company_id
   AND allocation.supplier_order_line_id=order_line.id
  WHERE order_document.status='DRAFT'

  UNION ALL
  SELECT 'confirmed_supplier_order_immutability',
    CASE WHEN COALESCE(bool_or(definition LIKE '%FINAL_SUPPLIER_ORDER_IMMUTABLE%'
      OR definition LIKE '%SUPPLIER_ORDER_NOT_DRAFT%'),FALSE)
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('draftOnlyGuardPresent',COALESCE(bool_or(
      definition LIKE '%FINAL_SUPPLIER_ORDER_IMMUTABLE%'
      OR definition LIKE '%SUPPLIER_ORDER_NOT_DRAFT%'),FALSE),
      'contract','Only Draft PO may be synchronized; final PO requires delta or amendment')
  FROM routine_definition
  WHERE routine_name IN('save_supplier_order','acp5c_save_supplier_order_core')

  UNION ALL
  SELECT 'supplier_order_allocation_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.supplier_order_request_allocations allocation
  LEFT JOIN public.supplier_order_lines order_line
    ON order_line.company_id=allocation.company_id
   AND order_line.id=allocation.supplier_order_line_id
  LEFT JOIN public.stock_request_lines request_line
    ON request_line.company_id=allocation.company_id
   AND request_line.id=allocation.stock_request_line_id
  WHERE order_line.id IS NULL OR request_line.id IS NULL
    OR order_line.product_id<>request_line.product_id

  UNION ALL
  SELECT 'procurement_browser_write_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('directWriteRelations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name),'[]'::JSONB))
  FROM (SELECT relation_name FROM (VALUES
      ('stock_request_documents'),('stock_request_lines'),
      ('supplier_order_documents'),('supplier_order_lines'),
      ('supplier_order_request_allocations'),('sales_stock_reservations'),
      ('sales_stock_reservation_lines')) relation(relation_name)
    WHERE has_table_privilege('authenticated','public.'||relation_name,
      'INSERT,UPDATE,DELETE')) writable

  UNION ALL
  SELECT 'supplier_order_permission_state',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='purchase.supplier_orders'

  UNION ALL
  SELECT 'current_shortage_request_source_boundary','REVIEW',
    jsonb_build_object(
      'negativeAllocationSourcePresent',COALESCE(bool_or(
        definition LIKE '%negative_stock_sale_allocations%'),FALSE),
      'reservationSourcePresent',COALESCE(bool_or(
        definition LIKE '%sales_stock_reservation_lines%'),FALSE),
      'requiredCutover','ODR-4 derives mutable session demand from open reservation shortage; legacy posted-negative requests remain historical')
  FROM routine_definition
  WHERE routine_name='ensure_negative_session_stock_request'

  UNION ALL
  SELECT 'procurement_demand_schema_state','SETUP',jsonb_build_object(
    'missing',COALESCE(jsonb_agg(relation_name ORDER BY relation_name)
      FILTER(WHERE to_regclass('public.'||relation_name) IS NULL),'[]'::JSONB),
    'existing',COALESCE(jsonb_agg(relation_name ORDER BY relation_name)
      FILTER(WHERE to_regclass('public.'||relation_name) IS NOT NULL),'[]'::JSONB),
    'expected',count(*))
  FROM planned_relations

  UNION ALL
  SELECT 'procurement_demand_runtime_state','SETUP',jsonb_build_object(
    'requiredDesign',ARRAY[
      'one canonical demand group per Company Store Warehouse Cashier Session',
      'atomic reservation shortage delta with exact retry and optimistic version',
      'Draft PO synchronization only',
      'confirmed or received PO uses additive delta or amendment notice',
      'session close freezes identity but not lawful later reconciliation'])

  UNION ALL
  SELECT 'open_reservation_shortage_inventory','INFO',jsonb_build_object(
    'companies',count(DISTINCT company_id),
    'sessions',count(DISTINCT session_id),
    'sales',count(DISTINCT sales_id),
    'lines',count(*),
    'products',count(DISTINCT (company_id,stock_product_id)),
    'openShortageBaseQty',COALESCE(sum(open_shortage_base_qty),0))
  FROM open_shortage

  UNION ALL
  SELECT 'procurement_runtime_inventory','INFO',jsonb_build_object(
    'manualRequests',count(*) FILTER(WHERE request_source='MANUAL'),
    'negativeSessionRequests',count(*) FILTER(
      WHERE request_source='NEGATIVE_STOCK_SESSION_CLOSE'),
    'openRequests',count(*) FILTER(WHERE status IN(
      'DRAFT','SUBMITTED','ORDERED','PARTIALLY_RECEIVED')),
    'draftSupplierOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE status='DRAFT'),
    'confirmedSupplierOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE status='CONFIRMED'),
    'partiallyReceivedSupplierOrders',(SELECT count(*)
      FROM public.supplier_order_documents WHERE status='PARTIALLY_RECEIVED'),
    'receivedSupplierOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE status='RECEIVED'),
    'requestAllocations',(SELECT count(*)
      FROM public.supplier_order_request_allocations))
  FROM public.stock_request_documents
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1
  WHEN 'REVIEW' THEN 2 WHEN 'SETUP' THEN 3 ELSE 4 END,check_name;
