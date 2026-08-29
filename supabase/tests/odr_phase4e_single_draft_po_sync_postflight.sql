-- ODR-4E single Draft PO sync postflight. SELECT-only.
WITH routines AS (
  SELECT procedure.oid,namespace.nspname schema_name,
    procedure.proname routine_name,procedure.prosrc definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private' AND procedure.proname IN(
    'sync_managed_request_single_draft_po',
    'odr4e_refresh_procurement_demand_core',
    'refresh_sales_order_procurement_demand')
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828200000'

  UNION ALL
  SELECT 'required_single_draft_po_sync_routines',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',3,'routineRows',count(*)) FROM routines

  UNION ALL
  SELECT 'private_single_draft_po_sync_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM routines WHERE has_function_privilege('authenticated',oid,'EXECUTE')

  UNION ALL
  SELECT 'draft_uom_review_reason_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('constraintRows',count(*))
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid=
      'public.sales_order_procurement_amendments'::regclass
    AND constraint_row.conname='sales_order_procurement_amendments_reason_check'
    AND pg_get_constraintdef(constraint_row.oid)
      LIKE '%DRAFT_UOM_CONVERSION_REQUIRES_REVIEW%'

  UNION ALL
  SELECT 'single_draft_po_sync_definition_contract',
    CASE WHEN count(*)=1 AND bool_and(definition LIKE '%status=''DRAFT''%'
      AND definition LIKE '%UPDATE public.supplier_order_lines%'
      AND definition LIKE '%UPDATE public.supplier_order_request_allocations%'
      AND definition LIKE '%UPDATE public.supplier_order_documents%'
      AND definition NOT LIKE '%UPDATE public.product_stocks%'
      AND definition NOT LIKE '%INSERT INTO public.stock_movements%'
      AND definition NOT LIKE '%INSERT INTO public.financial_events%')
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',count(*))
  FROM routines WHERE routine_name='sync_managed_request_single_draft_po'

  UNION ALL
  SELECT 'open_amendment_quantity_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_procurement_amendments amendment
  WHERE amendment.status='OPEN' AND amendment.delta_base_qty IS DISTINCT FROM
    amendment.desired_base_qty-amendment.draft_allocated_base_qty
      -amendment.final_allocated_base_qty

  UNION ALL
  SELECT 'managed_request_overallocation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
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
    GROUP BY request_line.company_id,request_line.id,
      request_line.requested_base_qty
    HAVING COALESCE(sum(allocation.allocated_base_qty),0)>
      request_line.requested_base_qty) invalid_row

  UNION ALL
  SELECT 'draft_only_supplier_order_sync_audit',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('syncAuditsWithoutDraftBeforeState',count(*))
  FROM public.supplier_order_audit audit
  WHERE audit.after_state ? 'syncRequestLineId'
    AND (audit.before_state->>'status') IS DISTINCT FROM 'DRAFT'
    AND audit.created_at>=COALESCE((SELECT applied_at
      FROM private.kgs_schema_migrations WHERE version='20260828200000'),
      '-infinity'::TIMESTAMPTZ)

  UNION ALL
  SELECT 'draft_po_sync_runtime_inventory','INFO',jsonb_build_object(
    'openAmendments',(SELECT count(*)
      FROM public.sales_order_procurement_amendments WHERE status='OPEN'),
    'resolvedAutoSyncAmendments',(SELECT count(*)
      FROM public.sales_order_procurement_amendments
      WHERE status='RESOLVED' AND resolution_supplier_order_id IS NOT NULL),
    'draftOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE status='DRAFT'),
    'finalOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
