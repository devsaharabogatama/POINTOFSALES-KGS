-- ODR-4C Session demand -> managed Stock Request postflight. SELECT-only.
WITH routine_definition AS (
  SELECT procedure.oid,namespace.nspname schema_name,
    procedure.proname routine_name,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname) IN(
    ('private','ensure_session_procurement_stock_request'),
    ('private','odr4c_close_cashier_session_legacy'),
    ('public','close_cashier_session'))
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828170000'

  UNION ALL
  SELECT 'required_session_request_routines',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',3,'routineRows',count(*))
  FROM routine_definition

  UNION ALL
  SELECT 'private_session_request_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM routine_definition WHERE schema_name='private'
    AND has_function_privilege('authenticated',oid,'EXECUTE')

  UNION ALL
  SELECT 'cashier_close_stock_request_hook',
    CASE WHEN count(*)=1 AND bool_and(
      definition LIKE '%ensure_session_procurement_stock_request%')
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',count(*))
  FROM routine_definition WHERE schema_name='public'
    AND routine_name='close_cashier_session'

  UNION ALL
  SELECT 'reservation_request_source_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('constraintRows',count(*))
  FROM pg_constraint constraint_row
  JOIN pg_class relation ON relation.oid=constraint_row.conrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public'
    AND relation.relname='stock_request_documents'
    AND constraint_row.conname='stock_request_documents_source_check'
    AND pg_get_constraintdef(constraint_row.oid)
      LIKE '%SALES_ORDER_RESERVATION%'

  UNION ALL
  SELECT 'reservation_request_session_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT company_id,requesting_session_id
    FROM public.stock_request_documents
    WHERE request_source='SALES_ORDER_RESERVATION'
    GROUP BY company_id,requesting_session_id HAVING count(*)>1) duplicate_row

  UNION ALL
  SELECT 'procurement_demand_request_header_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_procurement_demands demand
  LEFT JOIN public.stock_request_documents request
    ON request.company_id=demand.company_id
   AND request.id=demand.stock_request_document_id
  WHERE demand.stock_request_document_id IS NOT NULL
    AND (request.id IS NULL
      OR request.request_source<>'SALES_ORDER_RESERVATION'
      OR request.requesting_session_id<>demand.cashier_session_id
      OR request.status NOT IN('SUBMITTED','ORDERED','PARTIALLY_RECEIVED',
        'RECEIVED','CLOSED'))

  UNION ALL
  SELECT 'procurement_demand_request_line_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_procurement_demand_lines demand_line
  LEFT JOIN public.stock_request_lines request_line
    ON request_line.company_id=demand_line.company_id
   AND request_line.id=demand_line.stock_request_line_id
  LEFT JOIN public.sales_order_procurement_demands demand
    ON demand.company_id=demand_line.company_id
   AND demand.id=demand_line.demand_id
  WHERE demand_line.stock_request_line_id IS NOT NULL
    AND (request_line.id IS NULL
      OR request_line.document_id<>demand.stock_request_document_id
      OR request_line.product_id<>demand_line.stock_product_id)

  UNION ALL
  SELECT 'reservation_request_quantity_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('documentCount',count(*))
  FROM public.stock_request_documents request
  WHERE request.request_source='SALES_ORDER_RESERVATION'
    AND (request.line_count IS DISTINCT FROM (SELECT count(*)
        FROM public.stock_request_lines line
        WHERE line.company_id=request.company_id
          AND line.document_id=request.id AND line.is_active)
      OR request.requested_total_base_qty IS DISTINCT FROM COALESCE((
        SELECT sum(line.requested_base_qty)
        FROM public.stock_request_lines line
        WHERE line.company_id=request.company_id
          AND line.document_id=request.id AND line.is_active),0))

  UNION ALL
  SELECT 'supplier_order_preserved','PASS',jsonb_build_object(
    'draftOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE status='DRAFT'),
    'finalOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')),
    'rule','ODR-4C creates Stock Request only and never synchronizes PO')

  UNION ALL
  SELECT 'session_request_runtime_inventory','INFO',jsonb_build_object(
    'reservationRequests',(SELECT count(*)
      FROM public.stock_request_documents
      WHERE request_source='SALES_ORDER_RESERVATION'),
    'linkedDemands',(SELECT count(*)
      FROM public.sales_order_procurement_demands
      WHERE stock_request_document_id IS NOT NULL),
    'linkedDemandLines',(SELECT count(*)
      FROM public.sales_order_procurement_demand_lines
      WHERE stock_request_line_id IS NOT NULL))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
