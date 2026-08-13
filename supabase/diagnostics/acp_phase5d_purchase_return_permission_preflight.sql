-- ACP-5D preflight: Purchase Return permission boundary.
-- SAFETY: one SELECT statement; aggregate metadata only; no business identity.

WITH required_versions(version) AS (
  VALUES ('20260806070000'),('20260806080000'),('20260813000000')
), expected_relations(relation_name) AS (
  VALUES ('purchase_return_documents'),('purchase_return_lines'),
    ('purchase_return_fifo_allocations'),
    ('purchase_return_ap_adjustments'),('purchase_return_audit')
), mutation_names(routine_name,channel) AS (
  VALUES
    ('save_purchase_return_draft','CASHIER_DRAFT'),
    ('cancel_purchase_return_draft','MIXED_CANCEL'),
    ('review_purchase_return','MANAGEMENT_REVIEW'),
    ('post_purchase_return','MANAGEMENT_POST')
), mutation_routines AS (
  SELECT procedure.oid,procedure.proname,names.channel,
    pg_get_functiondef(procedure.oid) definition
  FROM mutation_names names
  LEFT JOIN pg_proc procedure ON procedure.proname=names.routine_name
    AND procedure.pronamespace='public'::regnamespace
), stock_reconciliation AS (
  SELECT stock.company_id,stock.product_id,stock.warehouse_id,stock.stock_qty,
    COALESCE((SELECT sum(movement.qty_change)
      FROM public.stock_movements movement
      WHERE movement.company_id=stock.company_id
        AND movement.product_id=stock.product_id
        AND movement.warehouse_id=stock.warehouse_id),0) movement_qty,
    COALESCE((SELECT sum(batch.qty_remaining)
      FROM public.product_batches batch
      WHERE batch.company_id=stock.company_id
        AND batch.product_id=stock.product_id
        AND batch.warehouse_id=stock.warehouse_id),0) fifo_qty
  FROM public.product_stocks stock
), checks AS (
  SELECT 'acp_phase5d_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE ledger.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(required.version ORDER BY required.version)
        FILTER(WHERE ledger.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required
  LEFT JOIN private.kgs_schema_migrations ledger
    ON ledger.version=required.version

  UNION ALL
  SELECT 'purchase_return_permission_catalog_state',
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
        'VIEW','CREATE_DRAFT','EDIT_DRAFT','REVIEW','POST','CANCEL_FINAL'
      ]::TEXT[]
    )=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
        (SELECT to_jsonb(supported_capabilities)
         FROM public.access_permission_catalog
         WHERE permission_key='purchase.purchase_returns'),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='purchase.purchase_returns'

  UNION ALL
  SELECT 'canonical_purchase_return_schema_state',
    CASE WHEN count(*) FILTER(WHERE relation.oid IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
        FILTER(WHERE relation.oid IS NULL),'[]'::JSONB))
  FROM expected_relations expected
  LEFT JOIN pg_class relation ON relation.relname=expected.relation_name
    AND relation.relnamespace='public'::regnamespace

  UNION ALL
  SELECT 'canonical_purchase_return_composed_read_state','SETUP',
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_purchase_returns()') IS NOT NULL,
      'required_design',jsonb_build_array(
        'guard the Backoffice workspace with purchase.purchase_returns VIEW',
        'return Return documents, lines, actors, and document-scoped posting proof only',
        'include narrow Receipt, Supplier, Store, and Warehouse labels',
        'do not expose unrelated Goods Receipt, FIFO, AP, stock, or Finance ledgers'))

  UNION ALL
  SELECT 'purchase_return_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticated_read_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE readable),
      '[]'::JSONB),'required_design',jsonb_build_array(
        'replace Backoffice table reads with one VIEW-guarded composed RPC',
        'replace PWA Return workspace reads with a separate open-session RPC',
        'revoke direct SELECT only after every active browser consumer is migrated'))
  FROM (
    SELECT expected.relation_name,has_table_privilege(
      'authenticated',format('public.%I',expected.relation_name),'SELECT') readable
    FROM expected_relations expected
  ) privilege_state

  UNION ALL
  SELECT 'purchase_return_channel_authority_split','REVIEW',
    jsonb_build_object(
      'cashier_routines',jsonb_build_array('save_purchase_return_draft'),
      'management_routines',jsonb_build_array(
        'review_purchase_return','post_purchase_return'),
      'mixed_routine','cancel_purchase_return_draft',
      'required_design',jsonb_build_array(
        'Cashier Draft/Edit remains limited to own open session and Store',
        'Cashier cancellation remains limited to its own Draft',
        'Backoffice Review and Post require their distinct effective capabilities',
        'custom permission may restrict but never widen Store or Company scope'))

  UNION ALL
  SELECT 'purchase_return_source_consumer_scope','REVIEW',
    jsonb_build_object('current_pwa_sources',jsonb_build_array(
      'posted Goods Receipt and condition allocation',
      'source FIFO remaining quantity',
      'Product-UOM conversion',
      'Supplier Order, Supplier, and Warehouse labels'),
      'required_design',jsonb_build_array(
        'PWA workspace requires an active open Cashier session',
        'returnable quantity and UOM references are server-derived',
        'Purchase Return never inherits Goods Receipt or Supplier Order management authority',
        'client-supplied purpose never bypasses permission or Store scope'))

  UNION ALL
  SELECT 'purchase_return_reference_consumer_scope','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'Backoffice VIEW receives only Return-linked Receipt and master labels',
      'Purchase Return users do not require Contacts Supplier or Inventory Master management access',
      'Finance evidence is Return-document scoped and remains read-only',
      'a client-supplied purpose never bypasses effective permission'))

  UNION ALL
  SELECT 'purchase_return_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routine_rows',count(*) FILTER(WHERE oid IS NOT NULL),
      'hooked_rows',count(*) FILTER(WHERE oid IS NOT NULL
        AND definition ILIKE '%acp_require_permission_capability%'
        AND definition ILIKE '%purchase.purchase_returns%'),
      'routine_names',COALESCE(jsonb_agg(DISTINCT proname ORDER BY proname)
        FILTER(WHERE oid IS NOT NULL),'[]'::JSONB))
  FROM mutation_routines

  UNION ALL
  SELECT 'purchase_return_direct_write_boundary',
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
  SELECT 'purchase_return_mutation_routine_state',
    CASE WHEN count(DISTINCT proname) FILTER(WHERE oid IS NOT NULL)=
      (SELECT count(*) FROM mutation_names)
      AND count(DISTINCT proname) FILTER(WHERE oid IS NOT NULL AND
        has_function_privilege('authenticated',oid,'EXECUTE'))=
      (SELECT count(*) FROM mutation_names)
      AND count(*) FILTER(WHERE oid IS NOT NULL AND
        has_function_privilege('anon',oid,'EXECUTE'))=0
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
  SELECT 'purchase_return_override_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  LEFT JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id
  WHERE override_row.permission_key='purchase.purchase_returns'
    AND membership.user_id IS NULL

  UNION ALL
  SELECT 'purchase_return_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
  FROM public.purchase_return_documents document
  LEFT JOIN public.companies company ON company.id=document.company_id
  LEFT JOIN public.goods_receipt_documents receipt
    ON receipt.company_id=document.company_id
   AND receipt.id=document.source_receipt_id
  LEFT JOIN public.supplier_order_documents supplier_order
    ON supplier_order.company_id=document.company_id
   AND supplier_order.id=document.supplier_order_id
  LEFT JOIN public.suppliers supplier ON supplier.company_id=document.company_id
    AND supplier.id=document.supplier_id
  LEFT JOIN public.stores store ON store.company_id=document.company_id
    AND store.id=document.store_id
  LEFT JOIN public.warehouses warehouse
    ON warehouse.company_id=document.company_id
   AND warehouse.id=document.source_warehouse_id
  LEFT JOIN public.cashier_sessions session
    ON session.company_id=document.company_id
   AND session.id=document.created_session_id
  WHERE company.id IS NULL OR receipt.id IS NULL OR supplier_order.id IS NULL
     OR supplier.id IS NULL OR store.id IS NULL OR warehouse.id IS NULL
     OR session.id IS NULL

  UNION ALL
  SELECT 'purchase_return_line_source_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.purchase_return_lines line
  LEFT JOIN public.purchase_return_documents document
    ON document.company_id=line.company_id AND document.id=line.document_id
  LEFT JOIN public.goods_receipt_lines receipt_line
    ON receipt_line.company_id=line.company_id
   AND receipt_line.id=line.source_receipt_line_id
  LEFT JOIN public.goods_receipt_condition_allocations allocation
    ON allocation.company_id=line.company_id
   AND allocation.id=line.source_condition_allocation_id
  LEFT JOIN public.product_batches batch ON batch.company_id=line.company_id
    AND batch.id=line.source_product_batch_id
  LEFT JOIN public.products product ON product.company_id=line.company_id
    AND product.id=line.product_id
  LEFT JOIN public.uoms uom ON uom.company_id=line.company_id
    AND uom.id=line.return_uom_id
  WHERE document.id IS NULL OR receipt_line.id IS NULL OR allocation.id IS NULL
     OR batch.id IS NULL OR product.id IS NULL OR uom.id IS NULL
     OR receipt_line.document_id<>document.source_receipt_id
     OR allocation.receipt_line_id<>receipt_line.id
     OR allocation.product_batch_id<>batch.id
     OR receipt_line.product_id<>line.product_id

  UNION ALL
  SELECT 'invalid_purchase_return_lifecycle',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.purchase_return_documents document
  WHERE document.line_count<=0 OR document.total_return_base_qty<=0
     OR document.provisional_ap_adjustment_total<0
     OR (document.status='POSTED' AND (
       document.review_status<>'APPROVED' OR document.reviewed_by IS NULL
       OR document.reviewed_at IS NULL OR document.posted_by IS NULL
       OR document.posted_at IS NULL OR document.handed_over_at IS NULL
       OR document.posting_idempotency_key IS NULL
       OR document.financial_event_id IS NULL))
     OR (document.status='CANCELED' AND (
       document.canceled_by IS NULL OR document.canceled_at IS NULL))

  UNION ALL
  SELECT 'purchase_return_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*))
  FROM (
    SELECT document.id,document.line_count,
      document.total_return_base_qty,
      document.provisional_ap_adjustment_total,count(line.id) line_count_actual,
      COALESCE(sum(line.return_base_qty),0) return_base_actual,
      COALESCE(sum(line.provisional_return_value),0) return_value_actual
    FROM public.purchase_return_documents document
    LEFT JOIN public.purchase_return_lines line
      ON line.company_id=document.company_id AND line.document_id=document.id
    GROUP BY document.id,document.line_count,document.total_return_base_qty,
      document.provisional_ap_adjustment_total
    HAVING document.line_count<>count(line.id)
      OR document.total_return_base_qty<>COALESCE(sum(line.return_base_qty),0)
      OR document.provisional_ap_adjustment_total<>
        COALESCE(sum(line.provisional_return_value),0)
  ) invalid

  UNION ALL
  SELECT 'duplicate_purchase_return_posting_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*))
  FROM (
    SELECT company_id,posting_idempotency_key
    FROM public.purchase_return_documents
    WHERE posting_idempotency_key IS NOT NULL
    GROUP BY company_id,posting_idempotency_key HAVING count(*)>1
  ) duplicate_group

  UNION ALL
  SELECT 'nonfinal_purchase_return_with_final_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*))
  FROM public.purchase_return_documents document
  WHERE document.status<>'POSTED' AND (
    document.financial_event_id IS NOT NULL
    OR EXISTS(SELECT 1 FROM public.purchase_return_fifo_allocations allocation
      WHERE allocation.company_id=document.company_id
        AND allocation.document_id=document.id)
    OR EXISTS(SELECT 1 FROM public.purchase_return_ap_adjustments adjustment
      WHERE adjustment.company_id=document.company_id
        AND adjustment.document_id=document.id)
    OR EXISTS(SELECT 1 FROM public.stock_movements movement
      WHERE movement.company_id=document.company_id
        AND movement.reference_table='purchase_return_documents'
        AND movement.reference_id=document.id))

  UNION ALL
  SELECT 'posted_purchase_return_final_effect_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('line_count',count(*))
  FROM public.purchase_return_lines line
  JOIN public.purchase_return_documents document
    ON document.company_id=line.company_id AND document.id=line.document_id
   AND document.status='POSTED'
  WHERE NOT EXISTS(SELECT 1 FROM public.purchase_return_fifo_allocations allocation
      WHERE allocation.company_id=line.company_id
        AND allocation.return_line_id=line.id)
     OR NOT EXISTS(SELECT 1 FROM public.purchase_return_ap_adjustments adjustment
      WHERE adjustment.company_id=line.company_id
        AND adjustment.return_line_id=line.id)

  UNION ALL
  SELECT 'cumulative_purchase_return_quantity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('allocation_count',count(*))
  FROM (
    SELECT source.id
    FROM public.goods_receipt_condition_allocations source
    JOIN public.purchase_return_lines line
      ON line.company_id=source.company_id
     AND line.source_condition_allocation_id=source.id
    JOIN public.purchase_return_documents document
      ON document.company_id=line.company_id AND document.id=line.document_id
     AND document.status='POSTED'
    GROUP BY source.id,source.quantity_base
    HAVING sum(line.return_base_qty)>source.quantity_base
  ) invalid

  UNION ALL
  SELECT 'cumulative_purchase_return_ap_adjustment',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('source_count',count(*))
  FROM (
    SELECT source.id
    FROM public.goods_receipt_ap_provisionals source
    JOIN public.purchase_return_ap_adjustments adjustment
      ON adjustment.company_id=source.company_id
     AND adjustment.source_ap_provisional_id=source.id
    JOIN public.purchase_return_documents document
      ON document.company_id=adjustment.company_id
     AND document.id=adjustment.document_id AND document.status='POSTED'
    GROUP BY source.id,source.amount
    HAVING sum(adjustment.amount)>source.amount
  ) invalid

  UNION ALL
  SELECT 'stock_balance_movement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pair_count',count(*))
  FROM stock_reconciliation WHERE stock_qty<>movement_qty

  UNION ALL
  SELECT 'stock_balance_fifo_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pair_count',count(*))
  FROM stock_reconciliation
  WHERE fifo_qty<0 OR (stock_qty>=0 AND fifo_qty<>stock_qty)

  UNION ALL
  SELECT 'purchase_return_runtime_inventory','INFO',
    jsonb_build_object('companies',count(DISTINCT company_id),
      'documents',count(*),'drafts',count(*) FILTER(WHERE status='DRAFT'),
      'posted',count(*) FILTER(WHERE status='POSTED'),
      'canceled',count(*) FILTER(WHERE status='CANCELED'),
      'override_rows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='purchase.purchase_returns'),
      'posted_return_base_qty',COALESCE(sum(total_return_base_qty)
        FILTER(WHERE status='POSTED'),0),
      'posted_ap_adjustment_total',COALESCE(
        sum(provisional_ap_adjustment_total) FILTER(WHERE status='POSTED'),0))
  FROM public.purchase_return_documents
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status
  WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2 WHEN 'SETUP' THEN 3
  WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
