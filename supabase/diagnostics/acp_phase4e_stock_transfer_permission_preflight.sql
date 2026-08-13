-- ACP-4E preflight: Stock Transfer complete permission-cutover readiness.
-- SAFETY: one SELECT statement; aggregate metadata only; no business identity.

WITH required_versions(version) AS (
  VALUES ('20260728180000'),('20260812160000')
), required_relations(relation_name) AS (
  VALUES ('stock_transfer_documents'),('stock_transfer_lines'),
    ('stock_transfer_fifo_allocations'),('stock_transfer_audit')
), required_routines(routine_name) AS (
  VALUES ('save_stock_transfer_document'),('post_stock_transfer'),
    ('cancel_stock_transfer')
), routine_state AS (
  SELECT procedure.oid,procedure.proname,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname IN(SELECT routine_name FROM required_routines)
), transfer_groups AS (
  SELECT company_id,reference_id,source_line_id,product_id,
    count(*) FILTER(WHERE movement_type='TRANSFER_OUT'::public.stock_movement_type) out_rows,
    count(*) FILTER(WHERE movement_type='TRANSFER_IN'::public.stock_movement_type) in_rows,
    count(DISTINCT warehouse_id) warehouse_count,sum(qty_change) net_qty
  FROM public.stock_movements
  WHERE reference_table='stock_transfer_documents'
    AND movement_type IN('TRANSFER_OUT'::public.stock_movement_type,
      'TRANSFER_IN'::public.stock_movement_type)
  GROUP BY company_id,reference_id,source_line_id,product_id
), movement_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_change),0) qty
  FROM public.stock_movements GROUP BY company_id,product_id,warehouse_id
), stock_reconciliation AS (
  SELECT COALESCE(stock.company_id,movement.company_id) company_id,
    COALESCE(stock.product_id,movement.product_id) product_id,
    COALESCE(stock.warehouse_id,movement.warehouse_id) warehouse_id,
    COALESCE(stock.stock_qty,0) stock_qty,COALESCE(movement.qty,0) movement_qty
  FROM public.product_stocks stock FULL JOIN movement_totals movement
    ON movement.company_id=stock.company_id
   AND movement.product_id=stock.product_id
   AND movement.warehouse_id=stock.warehouse_id
), fifo_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_remaining),0) qty
  FROM public.product_batches GROUP BY company_id,product_id,warehouse_id
), checks AS (
  SELECT 'acp_phase4e_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(
      required.version ORDER BY required.version) FILTER(WHERE migration.version IS NULL),
      '[]'::JSONB)) details
  FROM required_versions required LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=required.version

  UNION ALL
  SELECT 'stock_transfer_permission_catalog_state',
    CASE WHEN count(*)=1
      AND count(*) FILTER(WHERE enforcement_status='SHADOW'
        AND is_customizable
        AND supported_capabilities @> ARRAY[
          'VIEW','CREATE_DRAFT','EDIT_DRAFT','POST','CANCEL_FINAL'
        ]::TEXT[])=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
      (SELECT to_jsonb(supported_capabilities) FROM public.access_permission_catalog
       WHERE permission_key='inventory.stock_transfers'),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='inventory.stock_transfers'

  UNION ALL
  SELECT 'stock_transfer_override_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  LEFT JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id AND membership.status='ACTIVE'
  WHERE override_row.permission_key='inventory.stock_transfers'
    AND membership.id IS NULL

  UNION ALL
  SELECT 'canonical_stock_transfer_schema_state',
    CASE WHEN count(*) FILTER(WHERE to_regclass('public.'||relation_name) IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(
      relation_name ORDER BY relation_name) FILTER(
        WHERE to_regclass('public.'||relation_name) IS NULL),'[]'::JSONB))
  FROM required_relations

  UNION ALL
  SELECT 'stock_transfer_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE has_table_privilege('authenticated',
      format('public.%I',relation_name),'INSERT,UPDATE,DELETE'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE has_table_privilege('authenticated',
        format('public.%I',relation_name),'INSERT,UPDATE,DELETE')),'[]'::JSONB))
  FROM required_relations

  UNION ALL
  SELECT 'stock_transfer_direct_read_cutover_scope','REVIEW',
    jsonb_build_object(
      'authenticated_read_relations',COALESCE(jsonb_agg(relation_name ORDER BY relation_name)
        FILTER(WHERE has_table_privilege('authenticated',
          format('public.%I',relation_name),'SELECT')),'[]'::JSONB),
      'required_design',ARRAY[
        'replace browser table reads with a Stock Transfer VIEW-guarded composed RPC',
        'remove direct table SELECT only after all active consumers use the guarded RPC',
        'retain service-role and server-authoritative posting compatibility'
      ])
  FROM required_relations

  UNION ALL
  SELECT 'canonical_stock_transfer_read_rpc_state','SETUP',
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_inventory_stock_transfers()') IS NOT NULL)

  UNION ALL
  SELECT 'stock_transfer_mutation_routine_state',
    CASE WHEN count(*)=3
      AND count(*) FILTER(WHERE has_function_privilege(
        'authenticated',oid,'EXECUTE'))=3
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routine_rows',count(*),'authenticated_rows',count(*) FILTER(
      WHERE has_function_privilege('authenticated',oid,'EXECUTE')),
      'anon_rows',count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE')))
  FROM routine_state

  UNION ALL
  SELECT 'stock_transfer_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        AND definition ILIKE '%inventory.stock_transfers%'))
  FROM routine_state

  UNION ALL
  SELECT 'legacy_stock_transfer_execution',
    CASE WHEN has_function_privilege('authenticated',
      'public.transfer_product_stock(uuid,uuid,uuid,numeric)','EXECUTE')
      THEN 'BLOCKER' ELSE 'PASS' END,
    jsonb_build_object('authenticated_execute',has_function_privilege(
      'authenticated','public.transfer_product_stock(uuid,uuid,uuid,numeric)','EXECUTE'))

  UNION ALL
  SELECT 'stock_transfer_reference_consumer_scope','REVIEW',jsonb_build_object(
    'current_reference_paths',ARRAY[
      'Product references already accept inventory.stock_transfers VIEW',
      'Warehouse references currently depend on inventory.master_data VIEW'
    ],
    'required_design',ARRAY[
      'provide narrow Product and Warehouse references under Stock Transfer VIEW',
      'Finance or Accounting Transfer viewers must not require Master Inventory access',
      'a client-supplied purpose must never authorize reference reads'
    ])

  UNION ALL
  SELECT 'invalid_stock_transfer_lifecycle',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.stock_transfer_documents document
  WHERE source_warehouse_id=destination_warehouse_id OR line_count<0
    OR total_quantity_base<0 OR total_cost<0
    OR (status='DRAFT' AND (posted_at IS NOT NULL OR canceled_at IS NOT NULL))
    OR (status='POSTED' AND (posted_at IS NULL OR posting_idempotency_key IS NULL))
    OR (status='CANCELED' AND canceled_at IS NULL)

  UNION ALL
  SELECT 'duplicate_stock_transfer_posting_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*))
  FROM (SELECT company_id,posting_idempotency_key
    FROM public.stock_transfer_documents WHERE posting_idempotency_key IS NOT NULL
    GROUP BY company_id,posting_idempotency_key HAVING count(*)>1) duplicate_group

  UNION ALL
  SELECT 'invalid_stock_transfer_movement_pair',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('group_count',count(*))
  FROM transfer_groups WHERE out_rows<>1 OR in_rows<>1
    OR warehouse_count<>2 OR net_qty<>0

  UNION ALL
  SELECT 'posted_stock_transfer_line_evidence',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('line_count',count(*))
  FROM public.stock_transfer_lines line
  JOIN public.stock_transfer_documents document
    ON document.company_id=line.company_id AND document.id=line.document_id
  WHERE document.status='POSTED' AND (
    (SELECT COALESCE(sum(allocation.quantity_base),0)
      FROM public.stock_transfer_fifo_allocations allocation
      WHERE allocation.company_id=line.company_id AND allocation.line_id=line.id)
      IS DISTINCT FROM line.quantity_base
    OR (SELECT count(*) FROM public.stock_movements movement
      WHERE movement.company_id=line.company_id
        AND movement.reference_table='stock_transfer_documents'
        AND movement.reference_id=line.document_id
        AND movement.source_line_id=line.id
        AND movement.movement_type IN(
          'TRANSFER_IN'::public.stock_movement_type,
          'TRANSFER_OUT'::public.stock_movement_type))<>2)

  UNION ALL
  SELECT 'stock_balance_movement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pair_count',count(*))
  FROM stock_reconciliation WHERE stock_qty<>movement_qty

  UNION ALL
  SELECT 'stock_balance_fifo_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pair_count',count(*))
  FROM public.product_stocks stock LEFT JOIN fifo_totals fifo
    ON fifo.company_id=stock.company_id AND fifo.product_id=stock.product_id
   AND fifo.warehouse_id=stock.warehouse_id
  WHERE stock.stock_qty>0 AND stock.stock_qty<>COALESCE(fifo.qty,0)

  UNION ALL
  SELECT 'stock_transfer_runtime_inventory','INFO',jsonb_build_object(
    'documents',count(*),'drafts',count(*) FILTER(WHERE status='DRAFT'),
    'posted',count(*) FILTER(WHERE status='POSTED'),
    'canceled',count(*) FILTER(WHERE status='CANCELED'),
    'companies',count(DISTINCT company_id),
    'override_rows',(SELECT count(*) FROM public.user_company_permission_overrides
      WHERE permission_key='inventory.stock_transfers'))
  FROM public.stock_transfer_documents
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
