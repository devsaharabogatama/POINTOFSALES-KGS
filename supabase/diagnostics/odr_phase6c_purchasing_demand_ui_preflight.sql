-- ODR-6C.1 Purchasing demand/amendment UI cutover preflight.
-- SAFETY: SELECT-only.
WITH dependency_versions(version) AS (
  VALUES('20260828150000'::TEXT),('20260828160000'),('20260828170000'),
    ('20260828180000'),('20260828190000'),('20260828200000'),
    ('20260828270000'),('20260829090000'),('20260829100000')
),browser_routines AS (
  SELECT procedure.oid,procedure.proname,namespace.nspname,
    pg_get_function_identity_arguments(procedure.oid) arguments
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname IN(
    'get_purchase_supplier_orders','get_purchase_procurement_demands')
),checks AS (
  SELECT 'odr6c1_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(
      dependency.version ORDER BY dependency.version)
      FILTER(WHERE migration.version IS NULL),'[]'::JSONB)) details
  FROM dependency_versions dependency
  LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=dependency.version

  UNION ALL
  SELECT 'canonical_purchasing_workspace_routines',
    CASE WHEN count(*)=2 AND count(*) FILTER(WHERE arguments='')=2
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',2,'routineRows',count(*),
      'routineNames',COALESCE(jsonb_agg(proname ORDER BY proname),'[]'::JSONB))
  FROM browser_routines

  UNION ALL
  SELECT 'purchasing_workspace_rpc_boundary',
    CASE WHEN count(*)=2
      AND count(*) FILTER(WHERE has_function_privilege(
        'authenticated',oid,'EXECUTE'))=2
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineRows',count(*))
  FROM browser_routines

  UNION ALL
  SELECT 'supplier_order_permission_state',
    CASE WHEN count(*)=1 AND min(enforcement_status)='ENFORCED'
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(DISTINCT enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='purchase.supplier_orders'

  UNION ALL
  SELECT 'browser_procurement_planning_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants
  WHERE grantee IN('anon','authenticated') AND table_schema='public'
    AND table_name IN('sales_order_procurement_demands',
      'sales_order_procurement_demand_lines',
      'sales_order_procurement_demand_audit',
      'sales_order_procurement_amendments',
      'sales_order_procurement_amendment_audit')

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
  SELECT 'procurement_demand_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
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
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('lineCount',count(*))
  FROM public.sales_order_procurement_demand_lines demand_line
  JOIN public.sales_stock_reservation_lines reservation_line
    ON reservation_line.company_id=demand_line.company_id
   AND reservation_line.id=demand_line.reservation_line_id
  WHERE demand_line.demand_base_qty<>reservation_line.shortage_base_qty
    OR demand_line.released_base_qty<>
      LEAST(reservation_line.shortage_base_qty,reservation_line.released_base_qty)

  UNION ALL
  SELECT 'active_demand_request_line_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
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
  SELECT 'managed_request_allocation_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
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
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_procurement_amendments amendment
  WHERE amendment.status='OPEN' AND amendment.delta_base_qty IS DISTINCT FROM
    amendment.desired_base_qty-amendment.draft_allocated_base_qty
      -amendment.final_allocated_base_qty
),inventory AS (
  SELECT 'purchasing_demand_ui_scope'::TEXT check_name,'INFO'::TEXT status,
    jsonb_build_object(
      'activeDemands',(SELECT count(*)
        FROM public.sales_order_procurement_demands WHERE status<>'CLOSED'),
      'openDemandBaseQty',(SELECT COALESCE(sum(
          demand_base_qty-released_base_qty),0)
        FROM public.sales_order_procurement_demand_lines
        WHERE demand_base_qty>released_base_qty),
      'managedRequests',(SELECT count(*) FROM public.stock_request_documents
        WHERE request_source='SALES_ORDER_RESERVATION'),
      'draftOrders',(SELECT count(*) FROM public.supplier_order_documents
        WHERE status='DRAFT'),
      'finalOrders',(SELECT count(*) FROM public.supplier_order_documents
        WHERE status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')),
      'openAmendments',(SELECT count(*)
        FROM public.sales_order_procurement_amendments WHERE status='OPEN')) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
