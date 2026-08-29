-- ODR-4D managed request reconciliation postflight. SELECT-only.
WITH routine_definition AS (
  SELECT procedure.oid,namespace.nspname schema_name,
    procedure.proname routine_name,procedure.prosrc definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname) IN(
    ('private','reconcile_session_procurement_request'),
    ('private','odr4d_refresh_procurement_demand_core'),
    ('private','refresh_sales_order_procurement_demand'),
    ('private','odr4d_get_purchase_supplier_orders_core'),
    ('public','get_purchase_supplier_orders'),
    ('public','get_purchase_procurement_demands'))
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828190000'

  UNION ALL
  SELECT 'required_request_reconciliation_routines',
    CASE WHEN count(*)=6 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',6,'routineRows',count(*))
  FROM routine_definition

  UNION ALL
  SELECT 'private_request_reconciliation_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM routine_definition WHERE schema_name='private'
    AND has_function_privilege('authenticated',oid,'EXECUTE')

  UNION ALL
  SELECT 'managed_request_line_activity_state',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='stock_request_lines' AND column_name='is_active'
    AND is_nullable='NO' AND column_default ILIKE '%true%'

  UNION ALL
  SELECT 'reservation_request_active_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
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
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_procurement_demand_lines demand_line
  JOIN public.sales_order_procurement_demands demand
    ON demand.company_id=demand_line.company_id
   AND demand.id=demand_line.demand_id
  LEFT JOIN public.stock_request_lines request_line
    ON request_line.company_id=demand_line.company_id
   AND request_line.id=demand_line.stock_request_line_id
  WHERE demand.stock_request_document_id IS NOT NULL
    AND demand_line.demand_base_qty>demand_line.released_base_qty
    AND (request_line.id IS NULL OR NOT request_line.is_active
      OR request_line.document_id<>demand.stock_request_document_id
      OR request_line.product_id<>demand_line.stock_product_id)

  UNION ALL
  SELECT 'open_amendment_quantity_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_procurement_amendments amendment
  WHERE amendment.status='OPEN' AND amendment.delta_base_qty IS DISTINCT FROM
    amendment.desired_base_qty-amendment.draft_allocated_base_qty
      -amendment.final_allocated_base_qty

  UNION ALL
  SELECT 'request_reconciliation_exact_operation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT company_id,demand_id,idempotency_key
    FROM public.sales_order_procurement_demand_audit
    WHERE action='DRAFT_PO_SYNC'
    GROUP BY company_id,demand_id,idempotency_key HAVING count(*)>1) duplicate_row

  UNION ALL
  SELECT 'request_reconciliation_no_po_mutation',
    CASE WHEN count(*)=1 AND bool_and(
      definition NOT LIKE '%UPDATE public.supplier_order_documents%'
      AND definition NOT LIKE '%INSERT INTO public.supplier_order_documents%'
      AND definition NOT LIKE '%DELETE FROM public.supplier_order_documents%'
      AND definition NOT LIKE '%UPDATE public.supplier_order_lines%'
      AND definition NOT LIKE '%INSERT INTO public.supplier_order_lines%'
      AND definition NOT LIKE '%DELETE FROM public.supplier_order_lines%'
      AND definition NOT LIKE '%UPDATE public.supplier_order_request_allocations%'
      AND definition NOT LIKE '%INSERT INTO public.supplier_order_request_allocations%'
      AND definition NOT LIKE '%DELETE FROM public.supplier_order_request_allocations%')
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',count(*))
  FROM routine_definition WHERE schema_name='private'
    AND routine_name='reconcile_session_procurement_request'

  UNION ALL
  SELECT 'legacy_supplier_order_inventory','INFO',jsonb_build_object(
    'draftOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE status='DRAFT'),
    'finalOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')),
    'openAmendments',(SELECT count(*)
      FROM public.sales_order_procurement_amendments WHERE status='OPEN'),
    'inactiveManagedRequestLines',(SELECT count(*)
      FROM public.stock_request_lines line
      JOIN public.stock_request_documents request
        ON request.company_id=line.company_id AND request.id=line.document_id
      WHERE request.request_source='SALES_ORDER_RESERVATION'
        AND NOT line.is_active))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
