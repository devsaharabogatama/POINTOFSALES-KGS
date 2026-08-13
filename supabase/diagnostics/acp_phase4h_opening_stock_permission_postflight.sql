-- ACP-4H postflight: Opening Stock capability and composed-read boundary.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH required_relations(relation_name) AS (
  VALUES ('opening_stock_documents'),('opening_stock_lines'),
    ('opening_stock_audit')
), public_routines AS (
  SELECT procedure.oid,procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname IN(
    'get_inventory_opening_stock','save_opening_stock_document',
    'post_opening_stock')
), movement_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_change),0) qty
  FROM public.stock_movements GROUP BY company_id,product_id,warehouse_id
), fifo_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_remaining),0) qty
  FROM public.product_batches GROUP BY company_id,product_id,warehouse_id
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260812200000'

  UNION ALL
  SELECT 'opening_stock_permission_enforced',CASE WHEN count(*)=1
    AND count(*) FILTER(WHERE enforcement_status='ENFORCED'
      AND operator_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE']::TEXT[]
      AND approver_roles=ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
      AND supported_capabilities @> ARRAY[
        'VIEW','CREATE_DRAFT','EDIT_DRAFT','POST']::TEXT[])=1
    THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='inventory.opening_stock'

  UNION ALL
  SELECT 'required_opening_stock_public_routines',CASE WHEN count(*)=3
    AND count(*) FILTER(WHERE has_function_privilege(
      'authenticated',oid,'EXECUTE'))=3
    AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
    THEN 0 ELSE 1 END,
    jsonb_build_object('routine_names',COALESCE(jsonb_agg(proname ORDER BY proname),
      '[]'::JSONB),'routine_rows',count(*))
  FROM public_routines

  UNION ALL
  SELECT 'opening_stock_public_runtime_guard',CASE WHEN count(*)=3
    AND count(*) FILTER(WHERE definition ILIKE
      '%acp_require_permission_capability%')=3
    AND count(*) FILTER(WHERE proname='get_inventory_opening_stock'
      AND definition ILIKE '%inventory.opening_stock%'
      AND definition ILIKE '%''VIEW''%')=1
    AND count(*) FILTER(WHERE proname='post_opening_stock'
      AND definition ILIKE '%''POST''%')=1 THEN 0 ELSE 1 END,
    jsonb_build_object('routine_rows',count(*),'guarded_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'))
  FROM public_routines

  UNION ALL
  SELECT 'opening_stock_private_core_boundary',CASE WHEN count(*)=2
    AND count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE'))=0
    AND count(*) FILTER(WHERE has_function_privilege(
      'anon',procedure.oid,'EXECUTE'))=0 THEN 0 ELSE 1 END,
    jsonb_build_object('core_rows',count(*),'authenticated_executable',
      count(*) FILTER(WHERE has_function_privilege(
        'authenticated',procedure.oid,'EXECUTE')))
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private' AND procedure.proname IN(
    'save_opening_stock_document','post_opening_stock')

  UNION ALL
  SELECT 'opening_stock_direct_read_write_boundary',count(*) FILTER(WHERE
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'SELECT,INSERT,UPDATE,DELETE')),
    jsonb_build_object('direct_relations',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE has_table_privilege('authenticated',
        format('public.%I',relation_name),'SELECT,INSERT,UPDATE,DELETE')),
      '[]'::JSONB))
  FROM required_relations

  UNION ALL
  SELECT 'legacy_opening_stock_helper_execution',count(*) FILTER(WHERE
    has_function_privilege('authenticated',procedure.oid,'EXECUTE')),
    jsonb_build_object('executable_rows',count(*) FILTER(WHERE
      has_function_privilege('authenticated',procedure.oid,'EXECUTE')))
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname='private_opening_stock_prepare_allowed'

  UNION ALL
  SELECT 'invalid_opening_stock_lifecycle',count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.opening_stock_documents document
  WHERE (status='DRAFT' AND (posted_at IS NOT NULL
      OR posting_idempotency_key IS NOT NULL OR financial_event_id IS NOT NULL))
    OR (status='POSTED' AND (posted_at IS NULL
      OR posting_idempotency_key IS NULL OR financial_event_id IS NULL))

  UNION ALL
  SELECT 'invalid_opening_stock_line_shape',count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.opening_stock_lines line
  WHERE quantity_base<=0 OR unit_cost_base<0
    OR total_cost IS DISTINCT FROM round(quantity_base*unit_cost_base,4)
    OR (unit_cost_base=0 AND NULLIF(btrim(zero_cost_reason),'') IS NULL)

  UNION ALL
  SELECT 'posted_opening_stock_final_evidence',count(*),
    jsonb_build_object('line_count',count(*))
  FROM public.opening_stock_lines line
  JOIN public.opening_stock_documents document
    ON document.company_id=line.company_id AND document.id=line.document_id
  WHERE document.status='POSTED' AND (
    NOT EXISTS(SELECT 1 FROM public.stock_movements movement
      WHERE movement.company_id=line.company_id
        AND movement.reference_table='opening_stock_documents'
        AND movement.reference_id=document.id
        AND movement.product_id=line.product_id
        AND movement.warehouse_id=document.warehouse_id
        AND movement.movement_type='OPENING_BALANCE')
    OR NOT EXISTS(SELECT 1 FROM public.product_batches batch
      WHERE batch.company_id=line.company_id
        AND batch.opening_stock_line_id=line.id))

  UNION ALL
  SELECT 'stock_balance_movement_reconciliation',count(*),
    jsonb_build_object('pair_count',count(*))
  FROM (SELECT COALESCE(stock.company_id,movement.company_id)
    FROM public.product_stocks stock FULL JOIN movement_totals movement
      ON movement.company_id=stock.company_id
     AND movement.product_id=stock.product_id
     AND movement.warehouse_id=stock.warehouse_id
    WHERE COALESCE(stock.stock_qty,0)<>COALESCE(movement.qty,0)) invalid_pair

  UNION ALL
  SELECT 'stock_balance_fifo_reconciliation',count(*),
    jsonb_build_object('pair_count',count(*))
  FROM public.product_stocks stock LEFT JOIN fifo_totals fifo
    ON fifo.company_id=stock.company_id AND fifo.product_id=stock.product_id
   AND fifo.warehouse_id=stock.warehouse_id
  WHERE stock.stock_qty>0 AND stock.stock_qty<>COALESCE(fifo.qty,0)

  UNION ALL
  SELECT 'opening_stock_runtime_inventory',0,jsonb_build_object(
    'documents',count(*),'drafts',count(*) FILTER(WHERE status='DRAFT'),
    'posted',count(*) FILTER(WHERE status='POSTED'),
    'lines',(SELECT count(*) FROM public.opening_stock_lines),
    'companies',count(DISTINCT company_id))
  FROM public.opening_stock_documents
)
SELECT check_name,CASE WHEN violation_rows=0 THEN 'PASS' ELSE 'FAIL' END status,
  violation_rows,details
FROM checks ORDER BY CASE WHEN violation_rows>0 THEN 1 ELSE 2 END,check_name;
