-- ODR-6C.1 Purchasing demand/amendment UI closing postflight.
-- SAFETY: SELECT-only.
WITH checks AS (
  SELECT 'active_finance_posting_queue'::TEXT check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END status,
    count(*) violation_rows,jsonb_build_object('runCount',count(*)) details
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'procurement_demand_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('demandCount',count(*))
  FROM public.sales_order_procurement_demands demand
  WHERE demand.total_demand_base_qty IS DISTINCT FROM COALESCE((
      SELECT sum(line.demand_base_qty)
      FROM public.sales_order_procurement_demand_lines line
      WHERE line.company_id=demand.company_id AND line.demand_id=demand.id),0)
    OR demand.total_released_base_qty IS DISTINCT FROM COALESCE((
      SELECT sum(line.released_base_qty)
      FROM public.sales_order_procurement_demand_lines line
      WHERE line.company_id=demand.company_id AND line.demand_id=demand.id),0)

  UNION ALL
  SELECT 'procurement_demand_reservation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('lineCount',count(*))
  FROM public.sales_order_procurement_demand_lines demand_line
  JOIN public.sales_stock_reservation_lines reservation_line
    ON reservation_line.company_id=demand_line.company_id
   AND reservation_line.id=demand_line.reservation_line_id
  WHERE demand_line.demand_base_qty<>reservation_line.shortage_base_qty
    OR demand_line.released_base_qty<>
      LEAST(reservation_line.shortage_base_qty,reservation_line.released_base_qty)

  UNION ALL
  SELECT 'reservation_request_active_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('documentCount',count(*))
  FROM public.stock_request_documents request
  WHERE request.request_source='SALES_ORDER_RESERVATION'
    AND (request.line_count IS DISTINCT FROM (SELECT count(*)
        FROM public.stock_request_lines line
        WHERE line.company_id=request.company_id AND line.document_id=request.id
          AND line.is_active)
      OR request.requested_total_base_qty IS DISTINCT FROM COALESCE((
        SELECT sum(line.requested_base_qty)
        FROM public.stock_request_lines line
        WHERE line.company_id=request.company_id AND line.document_id=request.id
          AND line.is_active),0))

  UNION ALL
  SELECT 'active_demand_request_line_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_procurement_demand_lines demand_line
  JOIN public.sales_order_procurement_demands demand
    ON demand.company_id=demand_line.company_id AND demand.id=demand_line.demand_id
  LEFT JOIN public.stock_request_lines request_line
    ON request_line.company_id=demand_line.company_id
   AND request_line.id=demand_line.stock_request_line_id
  WHERE demand.stock_request_document_id IS NOT NULL
    AND demand_line.demand_base_qty>demand_line.released_base_qty
    AND (request_line.id IS NULL OR NOT request_line.is_active
      OR request_line.document_id<>demand.stock_request_document_id
      OR request_line.product_id<>demand_line.stock_product_id)

  UNION ALL
  SELECT 'managed_request_overallocation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('requestLineCount',count(*))
  FROM (SELECT request_line.company_id,request_line.id,
      request_line.requested_base_qty
    FROM public.stock_request_lines request_line
    JOIN public.stock_request_documents request
      ON request.company_id=request_line.company_id
     AND request.id=request_line.document_id
    LEFT JOIN public.supplier_order_request_allocations allocation
      ON allocation.company_id=request_line.company_id
     AND allocation.stock_request_line_id=request_line.id
    WHERE request.request_source='SALES_ORDER_RESERVATION'
      AND request_line.is_active
    GROUP BY request_line.company_id,request_line.id,
      request_line.requested_base_qty
    HAVING COALESCE(sum(allocation.allocated_base_qty),0)>
      request_line.requested_base_qty) invalid

  UNION ALL
  SELECT 'open_amendment_quantity_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_procurement_amendments amendment
  WHERE amendment.status='OPEN' AND amendment.delta_base_qty IS DISTINCT FROM
    amendment.desired_base_qty-amendment.draft_allocated_base_qty
      -amendment.final_allocated_base_qty

  UNION ALL
  SELECT 'final_supplier_order_sync_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('auditRows',count(*))
  FROM public.supplier_order_audit audit
  WHERE audit.after_state ? 'syncRequestLineId'
    AND (audit.before_state->>'status') IS DISTINCT FROM 'DRAFT'

  UNION ALL
  SELECT 'browser_procurement_planning_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants
  WHERE grantee IN('anon','authenticated') AND table_schema='public'
    AND table_name IN('sales_order_procurement_demands',
      'sales_order_procurement_demand_lines',
      'sales_order_procurement_demand_audit',
      'sales_order_procurement_amendments',
      'sales_order_procurement_amendment_audit')
),inventory AS (
  SELECT 'purchasing_demand_ui_inventory'::TEXT check_name,'INFO'::TEXT status,
    0::BIGINT violation_rows,jsonb_build_object(
      'activeDemands',(SELECT count(*)
        FROM public.sales_order_procurement_demands WHERE status<>'CLOSED'),
      'openDemandLines',(SELECT count(*)
        FROM public.sales_order_procurement_demand_lines
        WHERE demand_base_qty>released_base_qty),
      'managedRequests',(SELECT count(*) FROM public.stock_request_documents
        WHERE request_source='SALES_ORDER_RESERVATION'),
      'draftOrders',(SELECT count(*) FROM public.supplier_order_documents
        WHERE status='DRAFT'),
      'openAmendments',(SELECT count(*)
        FROM public.sales_order_procurement_amendments WHERE status='OPEN'),
      'resolvedAutoSyncAmendments',(SELECT count(*)
        FROM public.sales_order_procurement_amendments
        WHERE status='RESOLVED' AND resolution_supplier_order_id IS NOT NULL)) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
