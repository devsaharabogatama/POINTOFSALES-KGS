-- SELECT-only gate for 20260919143000.
WITH dependency AS (
  SELECT version FROM private.kgs_schema_migrations
  WHERE version IN('20260919140000','20260919141000','20260919142000')
), target AS (
  SELECT order_document.company_id,order_document.id order_id,
    order_document.order_no,receipt.id receipt_id,receipt.receipt_no,
    allocation.id condition_allocation_id,allocation.product_batch_id,
    receipt_line.product_id,allocation.warehouse_id,allocation.quantity_base,
    batch.qty_remaining,warehouse.allow_negative_stock,
    warehouse.master_version warehouse_version,
    stock.stock_qty,
    COALESCE((SELECT sum(line.return_base_qty)
      FROM public.purchase_return_lines line
      JOIN public.purchase_return_documents document
        ON document.company_id=line.company_id AND document.id=line.document_id
       AND document.status='POSTED'
      WHERE line.company_id=allocation.company_id
        AND line.source_condition_allocation_id=allocation.id),0) posted_return_base_qty
  FROM public.supplier_order_documents order_document
  JOIN public.goods_receipt_documents receipt
    ON receipt.company_id=order_document.company_id
   AND receipt.supplier_order_id=order_document.id AND receipt.status='POSTED'
  JOIN public.goods_receipt_lines receipt_line
    ON receipt_line.company_id=receipt.company_id AND receipt_line.document_id=receipt.id
  JOIN public.goods_receipt_condition_allocations allocation
    ON allocation.company_id=receipt_line.company_id
   AND allocation.receipt_line_id=receipt_line.id
   AND allocation.condition_type IN('GOOD','DAMAGED')
  JOIN public.product_batches batch
    ON batch.company_id=allocation.company_id AND batch.id=allocation.product_batch_id
  JOIN public.warehouses warehouse
    ON warehouse.company_id=allocation.company_id AND warehouse.id=allocation.warehouse_id
  LEFT JOIN public.product_stocks stock
    ON stock.company_id=allocation.company_id AND stock.product_id=receipt_line.product_id
   AND stock.warehouse_id=allocation.warehouse_id
  WHERE order_document.company_id='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'
    AND order_document.order_no='PO-20260825-0000000015'
), target_company AS (
  SELECT DISTINCT company_id FROM target
), eligible_company AS (
  SELECT DISTINCT receipt.company_id
  FROM public.goods_receipt_documents receipt
  JOIN public.goods_receipt_lines line ON line.company_id=receipt.company_id
    AND line.document_id=receipt.id
  JOIN public.goods_receipt_condition_allocations allocation
    ON allocation.company_id=line.company_id AND allocation.receipt_line_id=line.id
    AND allocation.condition_type IN('GOOD','DAMAGED')
  JOIN public.warehouses warehouse ON warehouse.company_id=allocation.company_id
    AND warehouse.id=allocation.warehouse_id AND warehouse.allow_negative_stock
  WHERE receipt.status='POSTED'
), finance_gap AS (
  SELECT company.company_id,
    array_agg(required.function_key ORDER BY required.function_key)
      FILTER(WHERE account.id IS NULL) missing_functions
  FROM eligible_company company
  CROSS JOIN (VALUES('INVENTORY_ASSET'),('PURCHASE_PRICE_VARIANCE')) required(function_key)
  LEFT JOIN public.chart_of_accounts account ON account.company_id=company.company_id
    AND account.system_function_key=required.function_key
    AND account.is_active AND account.is_postable
  GROUP BY company.company_id
  HAVING count(DISTINCT account.system_function_key)<2
), workspace_patch AS (
  SELECT definition,
    (SELECT count(*) FROM regexp_matches(definition,
      'GREATEST\(LEAST\([[:space:]]*allocation\.quantity_base[[:space:]]*-[[:space:]]*COALESCE\(posted_return\.base_qty,[[:space:]]*0(::numeric)?\),[[:space:]]*batch\.qty_remaining\),[[:space:]]*0(::numeric)?\)','g')) cap_hits,
    (SELECT count(*) FROM regexp_matches(definition,
      'batch\.qty_remaining[[:space:]]*<=[[:space:]]*0(::numeric)?','g')) condition_hits,
    regexp_replace(regexp_replace(
        replace(definition,'EXACT_SOURCE_BATCH',
          'SOURCE_RECEIPT_WITH_NEGATIVE_SHORTAGE'),
        'GREATEST\(LEAST\([[:space:]]*allocation\.quantity_base[[:space:]]*-[[:space:]]*COALESCE\(posted_return\.base_qty,[[:space:]]*0(::numeric)?\),[[:space:]]*batch\.qty_remaining\),[[:space:]]*0(::numeric)?\)',
        'GREATEST(allocation.quantity_base-COALESCE(posted_return.base_qty, 0), 0)','g'),
      'batch\.qty_remaining[[:space:]]*<=[[:space:]]*0(::numeric)?','FALSE','g') patched
  FROM (SELECT pg_get_functiondef(
    'public.get_backoffice_purchase_return_workspace(uuid)'::regprocedure) definition) source
), workspace_patch_result AS (
  SELECT definition,cap_hits,condition_hits,
    replace(patched,'PURCHASE_RETURN_FIFO_NOT_AVAILABLE',
      'PURCHASE_RETURN_SOURCE_FULLY_RETURNED') patched
  FROM workspace_patch
), checks AS (
  SELECT 'dependency_ledger' check_name,
    CASE WHEN (SELECT count(*) FROM dependency)=3 THEN 'PASS' ELSE 'BLOCKER' END status,
    (3-(SELECT count(*) FROM dependency))::bigint violation_rows,
    jsonb_build_object('installed',(SELECT COALESCE(jsonb_agg(version ORDER BY version),'[]') FROM dependency)) details
  UNION ALL SELECT 'active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('rows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('rows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL SELECT 'forward_fix_object_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('existing',COALESCE(jsonb_agg(name),'[]'))
  FROM (SELECT name FROM unnest(ARRAY['purchase_return_stock_shortages',
      'purchase_return_shortage_replenishments','purchase_return_shortage_cost_adjustments']) name
    WHERE to_regclass('public.'||name) IS NOT NULL) collision
  UNION ALL SELECT 'target_purchase_order_source',
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),
      'companyId','4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8',
      'orderNo','PO-20260825-0000000015',
      'receivedBaseQty',COALESCE(sum(quantity_base),0),
      'commercialRemainingBaseQty',COALESCE(sum(quantity_base-posted_return_base_qty),0),
      'sourceFifoRemainingBaseQty',COALESCE(sum(qty_remaining),0),
      'stockQty',min(stock_qty),'negativeStockWarehouses',
      count(*) FILTER(WHERE allow_negative_stock))
  FROM target
  UNION ALL SELECT 'target_negative_stock_authority',
    CASE WHEN count(*)>0 AND bool_and(allow_negative_stock) THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE NOT allow_negative_stock)::bigint,
    jsonb_build_object('rows',count(*),'warehouseVersions',
      COALESCE(jsonb_agg(DISTINCT warehouse_version),'[]'))
  FROM target
  UNION ALL SELECT 'target_finance_account_contract',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    (2-count(*))::bigint,
    jsonb_build_object('presentFunctions',COALESCE(jsonb_agg(account_function_key
      ORDER BY account_function_key),'[]'::jsonb),
      'requiredFunctions',jsonb_build_array('INVENTORY_ASSET','PURCHASE_PRICE_VARIANCE'))
  FROM (SELECT DISTINCT account.system_function_key account_function_key
    FROM target_company target
    JOIN public.chart_of_accounts account ON account.company_id=target.company_id
      AND account.is_active AND account.is_postable
      AND account.system_function_key IN('INVENTORY_ASSET','PURCHASE_PRICE_VARIANCE')) account
  UNION ALL SELECT 'eligible_company_finance_account_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('companies',COALESCE(jsonb_agg(jsonb_build_object(
      'companyId',company_id,'missingFunctions',missing_functions)
      ORDER BY company_id),'[]'::jsonb))
  FROM finance_gap
  UNION ALL SELECT 'runtime_anchor_contract',
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END,(5-count(*))::bigint,
    jsonb_build_object('present',count(*),'expected',5)
  FROM (SELECT signature FROM unnest(ARRAY[
      'public.get_backoffice_purchase_return_workspace(uuid)',
      'public.save_backoffice_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)',
      'public.post_backoffice_purchase_return(uuid,bigint,uuid)',
      'private.reconcile_negative_stock_replenishment()',
      'private.nsc_insert_signed_journal_line(uuid,uuid,integer,uuid,numeric,uuid,uuid,uuid,text)']) signature
    WHERE to_regprocedure(signature) IS NOT NULL) runtime
  UNION ALL SELECT 'goods_receipt_finance_catalog',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,(1-count(*))::bigint,
    jsonb_build_object('activeRows',count(*))
  FROM public.system_events event
  WHERE event.system_key='GOODS_RECEIPT' AND event.is_active
  UNION ALL SELECT 'workspace_patch_dry_run',
    CASE WHEN cap_hits=4 AND condition_hits=1 AND patched<>definition
        AND patched!~'PURCHASE_RETURN_FIFO_NOT_AVAILABLE'
        AND patched~'SOURCE_RECEIPT_WITH_NEGATIVE_SHORTAGE'
        AND patched~'WHEN[[:space:]]+\(?FALSE\)?[[:space:]]+THEN'
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN cap_hits=4 AND condition_hits=1 AND patched<>definition
        AND patched!~'PURCHASE_RETURN_FIFO_NOT_AVAILABLE'
        AND patched~'SOURCE_RECEIPT_WITH_NEGATIVE_SHORTAGE'
        AND patched~'WHEN[[:space:]]+\(?FALSE\)?[[:space:]]+THEN'
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('workspaceCapAnchors',cap_hits,
      'fifoConditionAnchors',condition_hits,
      'definitionChanged',patched<>definition,
      'fifoCodeRemoved',patched!~'PURCHASE_RETURN_FIFO_NOT_AVAILABLE',
      'policyChanged',patched~'SOURCE_RECEIPT_WITH_NEGATIVE_SHORTAGE',
      'fifoConditionDisabled',
        patched~'WHEN[[:space:]]+\(?FALSE\)?[[:space:]]+THEN')
  FROM workspace_patch_result
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
