-- ACP-5C preflight: Stock Request and Supplier Order permission boundary.
-- SAFETY: one SELECT statement; aggregate metadata only; no business identity.

WITH required_versions(version) AS (
  VALUES ('20260806010000'),('20260812230000')
), expected_relations(relation_name) AS (
  VALUES ('stock_request_documents'),('stock_request_lines'),
    ('supplier_order_documents'),('supplier_order_lines'),
    ('supplier_order_request_allocations'),('stock_request_audit'),
    ('supplier_order_audit')
), mutation_names(routine_name,channel) AS (
  VALUES
    ('save_stock_request','CASHIER_REQUEST'),
    ('submit_stock_request','CASHIER_REQUEST'),
    ('close_stock_request','MANAGEMENT_REQUEST'),
    ('cancel_stock_request','MIXED_REQUEST'),
    ('save_supplier_order','SUPPLIER_ORDER'),
    ('confirm_supplier_order','SUPPLIER_ORDER'),
    ('cancel_supplier_order','SUPPLIER_ORDER')
), mutation_routines AS (
  SELECT procedure.oid,procedure.proname,names.channel,
    pg_get_functiondef(procedure.oid) definition
  FROM mutation_names names
  LEFT JOIN pg_proc procedure ON procedure.proname=names.routine_name
    AND procedure.pronamespace='public'::regnamespace
), checks AS (
  SELECT 'acp_phase5c_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE ledger.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(required.version ORDER BY required.version)
        FILTER(WHERE ledger.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required
  LEFT JOIN private.kgs_schema_migrations ledger
    ON ledger.version=required.version

  UNION ALL
  SELECT 'supplier_order_permission_catalog_state',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE
      enforcement_status='SHADOW' AND is_customizable
      AND view_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'
      ]::TEXT[]
      AND operator_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'
      ]::TEXT[]
      AND approver_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'
      ]::TEXT[]
      AND supported_capabilities @> ARRAY[
        'VIEW','CREATE_DRAFT','EDIT_DRAFT','POST','CANCEL_FINAL'
      ]::TEXT[]
    )=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
        (SELECT to_jsonb(supported_capabilities)
         FROM public.access_permission_catalog
         WHERE permission_key='purchase.supplier_orders'),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='purchase.supplier_orders'

  UNION ALL
  SELECT 'canonical_supplier_order_schema_state',
    CASE WHEN count(*) FILTER(WHERE relation.oid IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
        FILTER(WHERE relation.oid IS NULL),'[]'::JSONB))
  FROM expected_relations expected
  LEFT JOIN pg_class relation ON relation.relname=expected.relation_name
    AND relation.relnamespace='public'::regnamespace

  UNION ALL
  SELECT 'canonical_supplier_order_composed_read_state','SETUP',
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_purchase_supplier_orders()') IS NOT NULL,
      'required_design',jsonb_build_array(
        'guard the Backoffice workspace with purchase.supplier_orders VIEW',
        'return only order/request evidence and narrow Store, Warehouse, Product/UOM, and Supplier references',
        'do not expose Goods Receipt, stock, FIFO, AP, payment, or journal history'))

  UNION ALL
  SELECT 'supplier_order_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticated_read_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE readable),
      '[]'::JSONB),'required_design',jsonb_build_array(
        'replace Backoffice table reads with one VIEW-guarded composed RPC',
        'preserve separate narrow Cashier APIs for Stock Request and Goods Receipt',
        'revoke direct SELECT only after every active browser consumer is migrated'))
  FROM (
    SELECT expected.relation_name,has_table_privilege(
      'authenticated',format('public.%I',expected.relation_name),'SELECT') readable
    FROM expected_relations expected
  ) privilege_state

  UNION ALL
  SELECT 'stock_request_channel_authority_split','REVIEW',
    jsonb_build_object(
      'cashier_routines',jsonb_build_array(
        'save_stock_request','submit_stock_request'),
      'management_routines',jsonb_build_array(
        'close_stock_request','save_supplier_order','confirm_supplier_order',
        'cancel_supplier_order'),
      'mixed_routine','cancel_stock_request',
      'required_design',jsonb_build_array(
        'Cashier Draft/Submit remains limited to own active open session and Store',
        'Backoffice order workspace and manager actions require effective Purchase capability',
        'custom permission may restrict but must never widen Store or Company scope'))

  UNION ALL
  SELECT 'goods_receipt_supplier_order_consumer_scope','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'Goods Receipt Cashier receives only eligible confirmed or partially received orders for its open session Store',
      'Purchase Return and Goods Receipt do not inherit Backoffice Supplier Order authority',
      'client-supplied purpose never bypasses purchase.supplier_orders or Cashier session scope'))

  UNION ALL
  SELECT 'supplier_order_reference_consumer_scope','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'Supplier and Product-Supplier references use the ACP-5B Purchase-specific reference RPC',
      'Product/UOM, Store, and Warehouse references are narrow and authorized by Supplier Order VIEW',
      'Supplier Order users do not require Contacts Supplier or Inventory Master management access'))

  UNION ALL
  SELECT 'supplier_order_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routine_rows',count(*) FILTER(WHERE oid IS NOT NULL),
      'hooked_rows',count(*) FILTER(WHERE oid IS NOT NULL
        AND definition ILIKE '%acp_require_permission_capability%'
        AND definition ILIKE '%purchase.supplier_orders%'),
      'supplier_order_routines',COALESCE(jsonb_agg(DISTINCT proname ORDER BY proname)
        FILTER(WHERE oid IS NOT NULL AND channel='SUPPLIER_ORDER'),'[]'::JSONB))
  FROM mutation_routines

  UNION ALL
  SELECT 'supplier_order_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE writable)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE writable),
      '[]'::JSONB))
  FROM (
    SELECT expected.relation_name,has_table_privilege(
      'authenticated',format('public.%I',expected.relation_name),
      'INSERT,UPDATE,DELETE') writable
    FROM expected_relations expected
  ) write_state

  UNION ALL
  SELECT 'supplier_order_mutation_routine_state',
    CASE WHEN count(DISTINCT proname) FILTER(WHERE oid IS NOT NULL)=
      (SELECT count(*) FROM mutation_names)
      AND count(DISTINCT proname) FILTER(WHERE oid IS NOT NULL AND
        has_function_privilege('authenticated',oid,'EXECUTE'))=
      (SELECT count(*) FROM mutation_names)
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',(SELECT count(*) FROM mutation_names),
      'routine_names',COALESCE(jsonb_agg(DISTINCT proname ORDER BY proname)
        FILTER(WHERE oid IS NOT NULL),'[]'::JSONB),
      'authenticated_executable_rows',count(*) FILTER(WHERE oid IS NOT NULL
        AND has_function_privilege('authenticated',oid,'EXECUTE')),
      'anon_executable_rows',count(*) FILTER(WHERE oid IS NOT NULL
        AND has_function_privilege('anon',oid,'EXECUTE')))
  FROM mutation_routines

  UNION ALL
  SELECT 'supplier_order_override_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  LEFT JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id
  WHERE override_row.permission_key='purchase.supplier_orders'
    AND membership.user_id IS NULL

  UNION ALL
  SELECT 'supplier_order_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
  FROM (
    SELECT document.company_id
    FROM public.stock_request_documents document
    LEFT JOIN public.companies company ON company.id=document.company_id
    LEFT JOIN public.stores store ON store.company_id=document.company_id
      AND store.id=document.store_id
    LEFT JOIN public.pos_terminals terminal
      ON terminal.company_id=document.company_id
     AND terminal.id=document.requesting_pos_id
    LEFT JOIN public.cashier_sessions session
      ON session.company_id=document.company_id
     AND session.id=document.requesting_session_id
    WHERE company.id IS NULL OR store.id IS NULL OR terminal.id IS NULL
       OR session.id IS NULL
    UNION ALL
    SELECT document.company_id
    FROM public.supplier_order_documents document
    LEFT JOIN public.companies company ON company.id=document.company_id
    LEFT JOIN public.stores store ON store.company_id=document.company_id
      AND store.id=document.store_id
    LEFT JOIN public.warehouses warehouse
      ON warehouse.company_id=document.company_id
     AND warehouse.id=document.destination_warehouse_id
    LEFT JOIN public.suppliers supplier
      ON supplier.company_id=document.company_id
     AND supplier.id=document.supplier_id
    WHERE company.id IS NULL OR store.id IS NULL OR warehouse.id IS NULL
       OR supplier.id IS NULL
    UNION ALL
    SELECT allocation.company_id
    FROM public.supplier_order_request_allocations allocation
    LEFT JOIN public.supplier_order_lines order_line
      ON order_line.company_id=allocation.company_id
     AND order_line.id=allocation.supplier_order_line_id
    LEFT JOIN public.stock_request_lines request_line
      ON request_line.company_id=allocation.company_id
     AND request_line.id=allocation.stock_request_line_id
    WHERE order_line.id IS NULL OR request_line.id IS NULL
       OR order_line.product_id<>request_line.product_id
  ) invalid_reference

  UNION ALL
  SELECT 'invalid_stock_request_lifecycle',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.stock_request_documents document
  WHERE document.line_count<0 OR document.requested_total_base_qty<0
     OR (document.status='DRAFT' AND
       (document.submitted_by IS NOT NULL OR document.submitted_at IS NOT NULL))
     OR (document.status NOT IN('DRAFT','CANCELED') AND
       (document.submitted_by IS NULL OR document.submitted_at IS NULL))
     OR (document.status='CLOSED' AND
       (document.closed_by IS NULL OR document.closed_at IS NULL))
     OR (document.status='CANCELED' AND
       (document.canceled_by IS NULL OR document.canceled_at IS NULL))

  UNION ALL
  SELECT 'invalid_supplier_order_lifecycle',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.supplier_order_documents document
  WHERE document.line_count<0 OR document.total_ordered_base_qty<0
     OR document.estimated_total<0
     OR (document.expected_date IS NOT NULL
       AND document.expected_date<document.order_date)
     OR (document.status='DRAFT' AND
       (document.confirmed_by IS NOT NULL OR document.confirmed_at IS NOT NULL
        OR document.confirmation_idempotency_key IS NOT NULL))
     OR (document.status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED') AND
       (document.confirmed_by IS NULL OR document.confirmed_at IS NULL
        OR document.confirmation_idempotency_key IS NULL))
     OR (document.status='CANCELED' AND
       (document.canceled_by IS NULL OR document.canceled_at IS NULL))

  UNION ALL
  SELECT 'supplier_order_line_allocation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('line_count',count(*))
  FROM (
    SELECT line.company_id,line.id,line.ordered_base_qty,
      COALESCE(sum(allocation.allocated_base_qty),0) allocated_base_qty
    FROM public.supplier_order_lines line
    JOIN public.supplier_order_documents document
      ON document.company_id=line.company_id AND document.id=line.document_id
    LEFT JOIN public.supplier_order_request_allocations allocation
      ON allocation.company_id=line.company_id
     AND allocation.supplier_order_line_id=line.id
    WHERE document.status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
    GROUP BY line.company_id,line.id,line.ordered_base_qty
    HAVING COALESCE(sum(allocation.allocated_base_qty),0)<>line.ordered_base_qty
  ) invalid_line

  UNION ALL
  SELECT 'stock_request_active_allocation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('request_line_count',count(*))
  FROM (
    SELECT request_line.company_id,request_line.id,
      request_line.requested_base_qty,
      COALESCE(sum(allocation.allocated_base_qty),0) allocated_base_qty
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
      FILTER(WHERE order_document.id IS NOT NULL),0)>request_line.requested_base_qty
  ) invalid_request_line

  UNION ALL
  SELECT 'supplier_order_header_line_totals',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*))
  FROM (
    SELECT document.id,document.line_count,document.total_ordered_base_qty,
      document.estimated_total,count(line.id) actual_line_count,
      COALESCE(sum(line.ordered_base_qty),0) actual_base_qty,
      COALESCE(sum(line.estimated_subtotal),0) actual_estimated_total
    FROM public.supplier_order_documents document
    LEFT JOIN public.supplier_order_lines line
      ON line.company_id=document.company_id AND line.document_id=document.id
    GROUP BY document.id,document.line_count,document.total_ordered_base_qty,
      document.estimated_total
    HAVING document.line_count<>count(line.id)
      OR document.total_ordered_base_qty<>COALESCE(sum(line.ordered_base_qty),0)
      OR document.estimated_total<>COALESCE(sum(line.estimated_subtotal),0)
  ) invalid_document

  UNION ALL
  SELECT 'supplier_order_zero_final_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('effect_rows',count(*))
  FROM (
    SELECT movement.id
    FROM public.stock_movements movement
    WHERE lower(movement.reference_table) IN(
      'supplier_order_documents','supplier_order_document','supplier_order')
    UNION ALL
    SELECT event.id
    FROM public.financial_events event
    WHERE lower(event.source_table) IN(
      'supplier_order_documents','supplier_order_document','supplier_order')
  ) unexpected_effect

  UNION ALL
  SELECT 'supplier_order_runtime_inventory','INFO',jsonb_build_object(
    'companies',count(DISTINCT document.company_id),
    'stock_requests',(SELECT count(*) FROM public.stock_request_documents),
    'supplier_orders',count(*),
    'draft_orders',count(*) FILTER(WHERE document.status='DRAFT'),
    'confirmed_orders',count(*) FILTER(WHERE document.status='CONFIRMED'),
    'partially_received_orders',count(*) FILTER(
      WHERE document.status='PARTIALLY_RECEIVED'),
    'received_orders',count(*) FILTER(WHERE document.status='RECEIVED'),
    'canceled_orders',count(*) FILTER(WHERE document.status='CANCELED'),
    'allocation_rows',(SELECT count(*)
      FROM public.supplier_order_request_allocations),
    'override_rows',(SELECT count(*)
      FROM public.user_company_permission_overrides
      WHERE permission_key='purchase.supplier_orders'))
  FROM public.supplier_order_documents document
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
