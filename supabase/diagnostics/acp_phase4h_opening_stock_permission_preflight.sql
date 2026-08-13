-- ACP-4H preflight: Opening Stock custom-permission cutover readiness.
-- SAFETY: one SELECT statement; aggregate metadata only; no mutation.

WITH required_versions(version) AS (
  VALUES ('20260728120000'),('20260812190000')
), opening_relations(relation_name) AS (
  VALUES ('opening_stock_documents'),('opening_stock_lines'),
    ('opening_stock_audit')
), runtime_routines(routine_name) AS (
  VALUES ('save_opening_stock_document'),('post_opening_stock')
), routine_state AS (
  SELECT procedure.oid,procedure.proname,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname IN(SELECT routine_name FROM runtime_routines)
), movement_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_change),0) qty
  FROM public.stock_movements GROUP BY company_id,product_id,warehouse_id
), fifo_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_remaining),0) qty
  FROM public.product_batches GROUP BY company_id,product_id,warehouse_id
), checks AS (
  SELECT 'acp_phase4h_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(required.version ORDER BY required.version)
        FILTER(WHERE migration.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=required.version

  UNION ALL
  SELECT 'opening_stock_permission_catalog_state',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE enforcement_status='SHADOW'
      AND is_customizable AND supported_capabilities @> ARRAY[
        'VIEW','CREATE_DRAFT','EDIT_DRAFT','POST']::TEXT[])=1
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
      (SELECT to_jsonb(supported_capabilities)
       FROM public.access_permission_catalog
       WHERE permission_key='inventory.opening_stock'),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='inventory.opening_stock'

  UNION ALL
  SELECT 'opening_stock_authority_alignment','REVIEW',
    jsonb_build_object(
      'approvedPrepareRoles',ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE'],
      'approvedPostRoles',ARRAY['COMPANY_OWNER','COMPANY_ADMIN'],
      'catalogOperatorRoles',COALESCE(operator_roles,'{}'::TEXT[]),
      'catalogApproverRoles',COALESCE(approver_roles,'{}'::TEXT[]),
      'requiredDesign',ARRAY[
        'Finance and Store Manager may prepare Draft',
        'Accounting is report-only unless a newer approved decision exists',
        'only Company Owner/Admin may Post',
        'Store-scoped authority must never widen Warehouse scope'])
  FROM public.access_permission_catalog
  WHERE permission_key='inventory.opening_stock'

  UNION ALL
  SELECT 'opening_stock_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticatedReadRelations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE
        has_table_privilege('authenticated',format('public.%I',relation_name),'SELECT')),
      '[]'::JSONB),'requiredDesign',ARRAY[
        'replace browser table reads with one Opening Stock VIEW-guarded RPC',
        'return only document-linked balance, Movement, FIFO and Finance proof',
        'revoke direct SELECT after every active browser consumer is migrated'])
  FROM opening_relations

  UNION ALL
  SELECT 'opening_stock_composite_read_scope','REVIEW',
    jsonb_build_object('currentBrowserReads',ARRAY[
      'all Company product_stocks','all Company stock_movements',
      'all Opening-linked product_batches'],
      'requiredDesign',ARRAY[
        'derive posted proof only for returned Opening Stock documents',
        'do not expose the full Company Movement ledger through Stok Awal',
        'include narrow active Product/UOM and Warehouse references'])

  UNION ALL
  SELECT 'canonical_opening_stock_read_rpc_state',
    CASE WHEN to_regprocedure('public.get_inventory_opening_stock()') IS NULL
      THEN 'SETUP' ELSE 'PASS' END,
    jsonb_build_object('rpcExists',
      to_regprocedure('public.get_inventory_opening_stock()') IS NOT NULL)

  UNION ALL
  SELECT 'opening_stock_runtime_permission_hook_state',
    CASE WHEN count(*)=2 AND count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%'
      AND definition ILIKE '%inventory.opening_stock%')=2
      THEN 'PASS' ELSE 'SETUP' END,
    jsonb_build_object('routineRows',count(*),'hookedRows',count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%'
      AND definition ILIKE '%inventory.opening_stock%'))
  FROM routine_state

  UNION ALL
  SELECT 'opening_stock_reference_consumer_scope','REVIEW',
    jsonb_build_object('requiredDesign',ARRAY[
      'Product reference is authorized by inventory.opening_stock VIEW',
      'Warehouse reference must not require inventory.master_data VIEW',
      'a client-supplied purpose must never bypass effective permission',
      'eligibility is decided again during atomic server Post'])

  UNION ALL
  SELECT 'opening_stock_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE has_table_privilege('authenticated',
      format('public.%I',relation_name),'INSERT,UPDATE,DELETE'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('directWriteRelations',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE has_table_privilege('authenticated',
        format('public.%I',relation_name),'INSERT,UPDATE,DELETE')),'[]'::JSONB))
  FROM opening_relations

  UNION ALL
  SELECT 'opening_stock_mutation_routine_state',
    CASE WHEN count(DISTINCT proname)=2
      AND count(*) FILTER(WHERE has_function_privilege(
        'authenticated',oid,'EXECUTE'))=count(*)
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineNames',COALESCE(jsonb_agg(DISTINCT proname
      ORDER BY proname),'[]'::JSONB),'authenticatedRows',count(*) FILTER(WHERE
      has_function_privilege('authenticated',oid,'EXECUTE')))
  FROM routine_state

  UNION ALL
  SELECT 'legacy_opening_stock_helper_execution',
    CASE WHEN count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE'))=0 THEN 'PASS' ELSE 'REVIEW' END,
    jsonb_build_object('authenticatedExecutableRows',count(*) FILTER(WHERE
      has_function_privilege('authenticated',procedure.oid,'EXECUTE')))
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname='private_opening_stock_prepare_allowed'

  UNION ALL
  SELECT 'invalid_opening_stock_lifecycle',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.opening_stock_documents document
  WHERE (status='DRAFT' AND (posted_at IS NOT NULL
      OR posting_idempotency_key IS NOT NULL OR financial_event_id IS NOT NULL))
    OR (status='POSTED' AND (posted_at IS NULL OR posted_by IS NULL
      OR posting_idempotency_key IS NULL OR financial_event_id IS NULL))

  UNION ALL
  SELECT 'invalid_opening_stock_line_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.opening_stock_lines line
  WHERE quantity_base<=0 OR unit_cost_base<0
    OR total_cost IS DISTINCT FROM round(quantity_base*unit_cost_base,4)
    OR (unit_cost_base=0 AND NULLIF(btrim(zero_cost_reason),'') IS NULL)

  UNION ALL
  SELECT 'duplicate_opening_stock_product_line',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT company_id,document_id,product_id
    FROM public.opening_stock_lines GROUP BY company_id,document_id,product_id
    HAVING count(*)>1) duplicate_group

  UNION ALL
  SELECT 'opening_stock_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphanOrCrossTenantRows',count(*))
  FROM public.opening_stock_documents document
  LEFT JOIN public.warehouses warehouse
    ON warehouse.company_id=document.company_id
   AND warehouse.id=document.warehouse_id
  WHERE warehouse.id IS NULL OR EXISTS(SELECT 1
    FROM public.opening_stock_lines line
    LEFT JOIN public.products product ON product.company_id=line.company_id
      AND product.id=line.product_id
    LEFT JOIN public.uoms uom ON uom.company_id=line.company_id
      AND uom.id=line.base_uom_id
    WHERE line.company_id=document.company_id
      AND line.document_id=document.id
      AND (product.id IS NULL OR uom.id IS NULL))

  UNION ALL
  SELECT 'posted_opening_stock_final_evidence',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('lineCount',count(*))
  FROM public.opening_stock_documents document
  JOIN public.opening_stock_lines line
    ON line.company_id=document.company_id AND line.document_id=document.id
  WHERE document.status='POSTED' AND (
    NOT EXISTS(SELECT 1 FROM public.stock_movements movement
      WHERE movement.company_id=line.company_id
        AND movement.product_id=line.product_id
        AND movement.warehouse_id=document.warehouse_id
        AND movement.movement_type='OPENING_BALANCE'
        AND movement.reference_table='opening_stock_documents'
        AND movement.reference_id=document.id)
    OR NOT EXISTS(SELECT 1 FROM public.product_batches batch
      WHERE batch.company_id=line.company_id
        AND batch.product_id=line.product_id
        AND batch.warehouse_id=document.warehouse_id
        AND batch.opening_stock_line_id=line.id)
    OR NOT EXISTS(SELECT 1 FROM public.financial_events event
      WHERE event.company_id=document.company_id
        AND event.id=document.financial_event_id
        AND event.source_table='opening_stock_documents'
        AND event.source_id=document.id))

  UNION ALL
  SELECT 'opening_stock_pair_with_prior_nonopening_movement',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pairCount',count(*))
  FROM (SELECT DISTINCT document.company_id,line.product_id,
      document.warehouse_id,document.id
    FROM public.opening_stock_documents document
    JOIN public.opening_stock_lines line
      ON line.company_id=document.company_id AND line.document_id=document.id
    WHERE EXISTS(SELECT 1 FROM public.stock_movements movement
      WHERE movement.company_id=document.company_id
        AND movement.product_id=line.product_id
        AND movement.warehouse_id=document.warehouse_id
        AND NOT (movement.movement_type='OPENING_BALANCE'
          AND movement.reference_table='opening_stock_documents'
          AND movement.reference_id=document.id)
        -- created_at may be transaction-start time and can precede a lock wait.
        -- posted_at is the canonical final-effect ordering timestamp.
        AND COALESCE(movement.posted_at,movement.created_at)
          < document.posted_at)) invalid_pair

  UNION ALL
  SELECT 'stock_balance_movement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pairCount',count(*))
  FROM (SELECT COALESCE(stock.company_id,movement.company_id)
    FROM public.product_stocks stock FULL JOIN movement_totals movement
      ON movement.company_id=stock.company_id
     AND movement.product_id=stock.product_id
     AND movement.warehouse_id=stock.warehouse_id
    WHERE COALESCE(stock.stock_qty,0)<>COALESCE(movement.qty,0)) invalid_pair

  UNION ALL
  SELECT 'stock_balance_fifo_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pairCount',count(*))
  FROM public.product_stocks stock LEFT JOIN fifo_totals fifo
    ON fifo.company_id=stock.company_id AND fifo.product_id=stock.product_id
   AND fifo.warehouse_id=stock.warehouse_id
  WHERE stock.stock_qty>0 AND stock.stock_qty<>COALESCE(fifo.qty,0)

  UNION ALL
  SELECT 'opening_stock_runtime_inventory','INFO',jsonb_build_object(
    'documents',count(*),'drafts',count(*) FILTER(WHERE status='DRAFT'),
    'posted',count(*) FILTER(WHERE status='POSTED'),
    'lines',(SELECT count(*) FROM public.opening_stock_lines),
    'zeroCostLines',(SELECT count(*) FROM public.opening_stock_lines
      WHERE unit_cost_base=0),'companies',count(DISTINCT company_id))
  FROM public.opening_stock_documents
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
