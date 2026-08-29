-- ODR-4D Draft PO synchronization and final-PO amendment preflight.
-- SAFETY: SELECT-only. No Stock Request, PO, Stock, FIFO or Finance write.
WITH save_order_definition AS (
  SELECT pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.proname='acp5c_save_supplier_order_core'
), managed_request_lines AS (
  SELECT request.company_id,request.id request_id,
    request.requesting_session_id,request_line.id request_line_id,
    request_line.product_id,request_line.requested_base_qty
  FROM public.stock_request_documents request
  JOIN public.stock_request_lines request_line
    ON request_line.company_id=request.company_id
   AND request_line.document_id=request.id
  WHERE request.request_source='SALES_ORDER_RESERVATION'
), allocation_scope AS (
  SELECT request_line.company_id,request_line.request_id,
    request_line.request_line_id,request_line.product_id,
    request_line.requested_base_qty,allocation.id allocation_id,
    allocation.allocated_base_qty,order_line.id order_line_id,
    order_line.document_id order_id,order_line.product_id order_product_id,
    order_line.ordered_base_qty,order_document.status order_status
  FROM managed_request_lines request_line
  LEFT JOIN public.supplier_order_request_allocations allocation
    ON allocation.company_id=request_line.company_id
   AND allocation.stock_request_line_id=request_line.request_line_id
  LEFT JOIN public.supplier_order_lines order_line
    ON order_line.company_id=allocation.company_id
   AND order_line.id=allocation.supplier_order_line_id
  LEFT JOIN public.supplier_order_documents order_document
    ON order_document.company_id=order_line.company_id
   AND order_document.id=order_line.document_id
), draft_order_line_shape AS (
  SELECT order_document.company_id,order_document.id order_id,
    order_line.id order_line_id,order_line.ordered_base_qty,
    COALESCE(sum(allocation.allocated_base_qty),0) allocated_base_qty,
    count(allocation.id) allocation_count,
    count(DISTINCT request_line.document_id) request_count
  FROM public.supplier_order_documents order_document
  JOIN public.supplier_order_lines order_line
    ON order_line.company_id=order_document.company_id
   AND order_line.document_id=order_document.id
  LEFT JOIN public.supplier_order_request_allocations allocation
    ON allocation.company_id=order_line.company_id
   AND allocation.supplier_order_line_id=order_line.id
  LEFT JOIN public.stock_request_lines request_line
    ON request_line.company_id=allocation.company_id
   AND request_line.id=allocation.stock_request_line_id
  WHERE order_document.status='DRAFT'
  GROUP BY order_document.company_id,order_document.id,order_line.id,
    order_line.ordered_base_qty
), checks AS (
  SELECT 'odr_phase4c_dependency'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828170000'

  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')

  UNION ALL
  SELECT 'managed_reservation_request_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_procurement_demands demand
  JOIN public.stock_request_documents request
    ON request.company_id=demand.company_id
   AND request.id=demand.stock_request_document_id
  WHERE request.request_source<>'SALES_ORDER_RESERVATION'
    OR request.requesting_session_id<>demand.cashier_session_id

  UNION ALL
  SELECT 'managed_request_product_allocation_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM allocation_scope
  WHERE allocation_id IS NOT NULL
    AND order_product_id IS DISTINCT FROM product_id

  UNION ALL
  SELECT 'managed_request_overallocation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requestLineCount',count(*))
  FROM (SELECT company_id,request_line_id,requested_base_qty
    FROM allocation_scope GROUP BY company_id,request_line_id,
      requested_base_qty
    HAVING COALESCE(sum(allocated_base_qty),0)>requested_base_qty) invalid_row

  UNION ALL
  SELECT 'managed_request_multiple_draft_po_target',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
    jsonb_build_object('requestLineCount',count(*),
      'resolution','increase remains unallocated when Supplier target is ambiguous')
  FROM (SELECT company_id,request_line_id
    FROM allocation_scope WHERE order_status='DRAFT'
    GROUP BY company_id,request_line_id
    HAVING count(DISTINCT order_id)>1) ambiguous_row

  UNION ALL
  SELECT 'managed_request_final_po_scope',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
    jsonb_build_object('requestLineCount',count(*),
      'rule','final PO stays immutable; shortage delta requires amendment')
  FROM (SELECT company_id,request_line_id
    FROM allocation_scope
    WHERE order_status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
    GROUP BY company_id,request_line_id) final_row

  UNION ALL
  SELECT 'draft_po_mixed_manual_allocation_scope','REVIEW',
    jsonb_build_object(
      'lineCount',count(*),
      'fullyAllocationBacked',count(*) FILTER(
        WHERE ordered_base_qty=allocated_base_qty),
      'partiallyOrUnallocated',count(*) FILTER(
        WHERE ordered_base_qty<>allocated_base_qty),
      'rule','only fully allocation-backed managed quantity is auto-adjustable')
  FROM draft_order_line_shape

  UNION ALL
  SELECT 'confirmed_supplier_order_immutability',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('draftOnlyGuardPresent',count(*)=1)
  FROM save_order_definition
  WHERE definition LIKE '%v_existing.status%'
    AND definition LIKE '%FINAL_SUPPLIER_ORDER_IMMUTABLE%'

  UNION ALL
  SELECT 'supplier_order_request_allocation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requestLineCount',count(*))
  FROM (SELECT request_line.company_id,request_line.id,
      request_line.requested_base_qty
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
     AND order_document.status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
    GROUP BY request_line.company_id,request_line.id,
      request_line.requested_base_qty
    HAVING COALESCE(sum(allocation.allocated_base_qty)
      FILTER(WHERE order_document.id IS NOT NULL),0)
      > request_line.requested_base_qty) invalid_row

  UNION ALL
  SELECT 'draft_po_sync_runtime_state','SETUP',jsonb_build_object(
    'requiredDesign',ARRAY[
      'managed Stock Request quantity follows frozen Session demand',
      'exactly one eligible Draft PO target may absorb a positive delta',
      'ambiguous or final PO target creates amendment notice, not PO mutation',
      'manual and mixed-allocation Draft PO quantity remains operator-owned',
      'all changes are versioned, audited and exact-retry safe'])

  UNION ALL
  SELECT 'draft_po_sync_runtime_inventory','INFO',jsonb_build_object(
    'managedRequests',(SELECT count(DISTINCT request_id)
      FROM managed_request_lines),
    'managedRequestLines',(SELECT count(*) FROM managed_request_lines),
    'managedDraftAllocations',(SELECT count(*) FROM allocation_scope
      WHERE order_status='DRAFT'),
    'managedFinalAllocations',(SELECT count(*) FROM allocation_scope
      WHERE order_status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')),
    'allDraftOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE status='DRAFT'),
    'allFinalOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')),
    'allDraftAllocations',(SELECT count(*)
      FROM public.supplier_order_request_allocations allocation
      JOIN public.supplier_order_lines order_line
        ON order_line.company_id=allocation.company_id
       AND order_line.id=allocation.supplier_order_line_id
      JOIN public.supplier_order_documents order_document
        ON order_document.company_id=order_line.company_id
       AND order_document.id=order_line.document_id
      WHERE order_document.status='DRAFT'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1
  WHEN 'REVIEW' THEN 2 WHEN 'SETUP' THEN 3 ELSE 4 END,check_name;
