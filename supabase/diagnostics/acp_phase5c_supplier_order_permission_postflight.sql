-- ACP-5C postflight: Supplier Order permission enforcement closure.
-- SAFETY: SELECT-only aggregate checks.

WITH required_public_routines(routine_name) AS (
  VALUES ('get_purchase_supplier_orders'),
    ('get_pos_stock_request_workspace'),
    ('get_pos_goods_receipt_supplier_orders'),
    ('get_pos_purchase_return_order_references'),
    ('close_stock_request'),('cancel_stock_request'),
    ('save_supplier_order'),('confirm_supplier_order'),
    ('cancel_supplier_order')
), public_routines AS (
  SELECT procedure.oid,procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname IN(SELECT routine_name FROM required_public_routines)
), expected_relations(relation_name) AS (
  VALUES ('stock_request_documents'),('stock_request_lines'),
    ('supplier_order_documents'),('supplier_order_lines'),
    ('supplier_order_request_allocations'),('stock_request_audit'),
    ('supplier_order_audit')
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::BIGINT violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813000000'

  UNION ALL
  SELECT 'supplier_order_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED'
      AND supported_capabilities @> ARRAY[
        'VIEW','CREATE_DRAFT','EDIT_DRAFT','POST','CANCEL_FINAL']::TEXT[])
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED'
      AND supported_capabilities @> ARRAY[
        'VIEW','CREATE_DRAFT','EDIT_DRAFT','POST','CANCEL_FINAL']::TEXT[])
      THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='purchase.supplier_orders'

  UNION ALL
  SELECT 'required_supplier_order_routines',
    CASE WHEN count(DISTINCT proname)=(SELECT count(*)
      FROM required_public_routines) THEN 'PASS' ELSE 'FAIL' END,
    abs((SELECT count(*) FROM required_public_routines)
      -count(DISTINCT proname))::BIGINT,
    jsonb_build_object('expected',(SELECT count(*)
      FROM required_public_routines),'routine_names',COALESCE(
      jsonb_agg(DISTINCT proname ORDER BY proname),'[]'::JSONB))
  FROM public_routines

  UNION ALL
  SELECT 'supplier_order_capability_hooks',
    CASE WHEN count(DISTINCT proname) FILTER(WHERE
      definition ILIKE '%purchase.supplier_orders%'
      AND definition ILIKE '%acp_require_permission_capability%')=6
      THEN 'PASS' ELSE 'FAIL' END,
    abs(6-count(DISTINCT proname) FILTER(WHERE
      definition ILIKE '%purchase.supplier_orders%'
      AND definition ILIKE '%acp_require_permission_capability%'))::BIGINT,
    jsonb_build_object('hooked_routines',COALESCE(jsonb_agg(DISTINCT proname
      ORDER BY proname) FILTER(WHERE
        definition ILIKE '%purchase.supplier_orders%'
        AND definition ILIKE '%acp_require_permission_capability%'),
      '[]'::JSONB))
  FROM public_routines

  UNION ALL
  SELECT 'cashier_narrow_read_contract',
    CASE WHEN count(DISTINCT proname)=3 AND bool_and(
      definition ILIKE '%cashier_sessions%'
      AND definition ILIKE '%status%OPEN%') THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(DISTINCT proname)=3 AND bool_and(
      definition ILIKE '%cashier_sessions%'
      AND definition ILIKE '%status%OPEN%') THEN 0 ELSE 1 END,
    jsonb_build_object('routine_rows',count(*))
  FROM public_routines WHERE proname IN(
    'get_pos_stock_request_workspace','get_pos_goods_receipt_supplier_orders',
    'get_pos_purchase_return_order_references')

  UNION ALL
  SELECT 'browser_supplier_order_table_boundary',
    CASE WHEN count(*) FILTER(WHERE readable OR writable)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE readable OR writable),
    jsonb_build_object('readable',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE readable),'[]'::JSONB),'writable',COALESCE(
      jsonb_agg(relation_name) FILTER(WHERE writable),'[]'::JSONB))
  FROM (SELECT expected.relation_name,
      has_table_privilege('authenticated',format('public.%I',expected.relation_name),
        'SELECT') readable,
      has_table_privilege('authenticated',format('public.%I',expected.relation_name),
        'INSERT,UPDATE,DELETE') writable
    FROM expected_relations expected) privilege_state

  UNION ALL
  SELECT 'browser_supplier_order_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE NOT has_function_privilege(
      'authenticated',oid,'EXECUTE'))=0
      AND count(*) FILTER(WHERE has_function_privilege(
        'anon',oid,'EXECUTE'))=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE NOT has_function_privilege(
      'authenticated',oid,'EXECUTE') OR has_function_privilege(
        'anon',oid,'EXECUTE')),
    jsonb_build_object('routine_rows',count(*))
  FROM public_routines

  UNION ALL
  SELECT 'private_supplier_order_core_boundary',
    CASE WHEN count(*)=5 AND count(*) FILTER(WHERE
      has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=5 AND count(*) FILTER(WHERE
      has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 0 ELSE 1 END,
    jsonb_build_object('core_rows',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private' AND procedure.proname IN(
    'acp5c_close_stock_request_core','acp5c_cancel_stock_request_core',
    'acp5c_save_supplier_order_core','acp5c_confirm_supplier_order_core',
    'acp5c_cancel_supplier_order_core')

  UNION ALL
  SELECT 'supplier_order_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('row_count',count(*))
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
  SELECT 'supplier_order_line_allocation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('line_count',count(*))
  FROM (SELECT line.id,line.ordered_base_qty,
      COALESCE(sum(allocation.allocated_base_qty),0) allocated_base_qty
    FROM public.supplier_order_lines line
    JOIN public.supplier_order_documents document
      ON document.company_id=line.company_id AND document.id=line.document_id
    LEFT JOIN public.supplier_order_request_allocations allocation
      ON allocation.company_id=line.company_id
     AND allocation.supplier_order_line_id=line.id
    WHERE document.status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
    GROUP BY line.id,line.ordered_base_qty
    HAVING COALESCE(sum(allocation.allocated_base_qty),0)<>line.ordered_base_qty
  ) invalid_line

  UNION ALL
  SELECT 'supplier_order_zero_final_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('effect_rows',count(*))
  FROM (SELECT movement.id FROM public.stock_movements movement
    WHERE lower(movement.reference_table) IN(
      'supplier_order_documents','supplier_order_document','supplier_order')
    UNION ALL
    SELECT event.id FROM public.financial_events event
    WHERE lower(event.source_table) IN(
      'supplier_order_documents','supplier_order_document','supplier_order')
  ) unexpected_effect
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
