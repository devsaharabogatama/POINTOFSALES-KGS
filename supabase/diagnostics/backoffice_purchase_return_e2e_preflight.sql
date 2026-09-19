-- Read-only preflight for the Backoffice Purchase Return end-to-end rollout.
-- Run on Production immediately before migration 20260919140000.
WITH required_migrations(version) AS (
  VALUES
    ('20260813010000'::text), -- Purchase Return ACP
    ('20260814140000'::text), -- Purchase/AP Finance posting
    ('20260825130000'::text), -- Backoffice Goods Receipt channel
    ('20260914140000'::text)  -- PO cancellation runtime
), missing_migrations AS (
  SELECT version FROM required_migrations required
  WHERE NOT EXISTS (
    SELECT 1 FROM private.kgs_schema_migrations installed
    WHERE installed.version=required.version
  )
), active_finance AS (
  SELECT count(*)::bigint rows
  FROM public.finance_posting_queue_runs run
  WHERE run.status IN('PREVIEWED','APPROVED','PROCESSING')
), active_offline AS (
  SELECT count(*)::bigint rows
  FROM public.pos_offline_sale_submissions submission
  WHERE submission.status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
), collisions AS (
  SELECT array_remove(ARRAY[
    CASE WHEN to_regclass('public.purchase_return_draft_operations') IS NOT NULL
      THEN 'table:purchase_return_draft_operations' END,
    CASE WHEN to_regprocedure('public.get_backoffice_purchase_return_workspace(uuid)') IS NOT NULL
      THEN 'function:get_backoffice_purchase_return_workspace(uuid)' END,
    CASE WHEN to_regprocedure('public.save_backoffice_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)') IS NOT NULL
      THEN 'function:save_backoffice_purchase_return_draft(...)' END,
    CASE WHEN to_regclass('public.purchase_return_finance_allocations') IS NOT NULL
      THEN 'table:purchase_return_finance_allocations' END,
    CASE WHEN to_regclass('public.supplier_return_credit_notes') IS NOT NULL
      THEN 'table:supplier_return_credit_notes' END,
    CASE WHEN to_regprocedure('public.post_backoffice_purchase_return(uuid,bigint,uuid)') IS NOT NULL
      THEN 'function:post_backoffice_purchase_return(...)' END,
    CASE WHEN to_regprocedure('public.get_purchase_supplier_order_return_readiness(uuid)') IS NOT NULL
      THEN 'function:get_purchase_supplier_order_return_readiness(uuid)' END
  ],NULL) objects
), runtime_anchor AS (
  SELECT to_regprocedure('public.get_finance_supplier_payments()') IS NOT NULL
      AS supplier_payment_read,
    to_regprocedure('public.save_supplier_payment_draft(uuid,bigint,uuid,date,text,uuid,text,text,text,text,text,text,jsonb)') IS NOT NULL
      AS supplier_payment_write,
    to_regprocedure('public.validate_supplier_payment(uuid,bigint,uuid)') IS NOT NULL
      AS supplier_payment_validate,
    to_regprocedure('public.cancel_purchase_supplier_order(uuid,bigint,uuid,text)') IS NOT NULL
      AS po_cancel,
    to_regprocedure('public.post_purchase_return(uuid,bigint,uuid)') IS NOT NULL
      AS retail_return_post
), source_shape AS (
  SELECT
    count(*)::bigint posted_receipts,
    count(*) FILTER(WHERE order_document.supplier_id IS NULL)::bigint supplier_pending,
    count(*) FILTER(WHERE receipt.store_id IS NULL)::bigint missing_store,
    count(*) FILTER(WHERE receipt.warehouse_id IS NULL)::bigint missing_warehouse
  FROM public.goods_receipt_documents receipt
  JOIN public.supplier_order_documents order_document
    ON order_document.company_id=receipt.company_id
   AND order_document.id=receipt.supplier_order_id
  WHERE receipt.status='POSTED'
), fifo_shape AS (
  SELECT
    count(*)::bigint allocation_rows,
    count(*) FILTER(WHERE allocation.product_batch_id IS NULL)::bigint missing_batch,
    count(*) FILTER(WHERE batch.id IS NULL)::bigint orphan_batch,
    count(*) FILTER(WHERE batch.qty_remaining<0)::bigint negative_batch
  FROM public.goods_receipt_condition_allocations allocation
  JOIN public.goods_receipt_lines receipt_line
    ON receipt_line.company_id=allocation.company_id
   AND receipt_line.id=allocation.receipt_line_id
  JOIN public.goods_receipt_documents receipt
    ON receipt.company_id=receipt_line.company_id
   AND receipt.id=receipt_line.document_id
   AND receipt.status='POSTED'
  LEFT JOIN public.product_batches batch
    ON batch.company_id=allocation.company_id
   AND batch.id=allocation.product_batch_id
  WHERE allocation.condition_type IN('GOOD','DAMAGED')
), partial_invoice AS (
  SELECT
    count(DISTINCT provisional.id)::bigint partially_invoiced_sources,
    round(COALESCE(sum(invoice_allocation.allocated_base_qty),0),6) invoiced_base_qty,
    round(COALESCE(sum(invoice_allocation.actual_value),0),4) invoiced_value
  FROM public.goods_receipt_ap_provisionals provisional
  JOIN public.supplier_invoice_allocations invoice_allocation
    ON invoice_allocation.company_id=provisional.company_id
   AND invoice_allocation.source_ap_provisional_id=provisional.id
  JOIN public.supplier_invoice_documents invoice
    ON invoice.company_id=invoice_allocation.company_id
   AND invoice.id=invoice_allocation.document_id
   AND invoice.status='VALIDATED'
), payment_shape AS (
  SELECT
    count(*)::bigint validated_allocations,
    round(COALESCE(sum(allocation.allocated_amount),0),4) paid_amount
  FROM public.supplier_payment_allocations allocation
  JOIN public.supplier_payment_documents payment
    ON payment.company_id=allocation.company_id
   AND payment.id=allocation.document_id
   AND payment.status='VALIDATED'
), active_draft_duplicates AS (
  SELECT count(*)::bigint rows FROM (
    SELECT document.company_id,document.source_receipt_id,
      document.source_warehouse_id
    FROM public.purchase_return_documents document
    WHERE document.status='DRAFT'
    GROUP BY document.company_id,document.source_receipt_id,
      document.source_warehouse_id
    HAVING count(*)>1
  ) duplicate_group
)
SELECT 'dependency_ledger' check_name,
  CASE WHEN EXISTS(SELECT 1 FROM missing_migrations) THEN 'BLOCKER' ELSE 'PASS' END status,
  (SELECT count(*) FROM missing_migrations) violation_rows,
  jsonb_build_object('missing',COALESCE((SELECT jsonb_agg(version ORDER BY version)
    FROM missing_migrations),'[]'::jsonb)) details
UNION ALL
SELECT 'active_finance_queue',CASE WHEN rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
  rows,jsonb_build_object('rows',rows) FROM active_finance
UNION ALL
SELECT 'nonterminal_offline_submission',CASE WHEN rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
  rows,jsonb_build_object('rows',rows) FROM active_offline
UNION ALL
SELECT 'object_collision',CASE WHEN cardinality(objects)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  cardinality(objects),jsonb_build_object('objects',objects) FROM collisions
UNION ALL
SELECT 'runtime_anchor_contract',
  CASE WHEN supplier_payment_read AND supplier_payment_write
    AND supplier_payment_validate AND po_cancel
    AND retail_return_post THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN supplier_payment_read AND supplier_payment_write
    AND supplier_payment_validate AND po_cancel
    AND retail_return_post THEN 0 ELSE 1 END::bigint,to_jsonb(runtime_anchor)
FROM runtime_anchor
UNION ALL
SELECT 'posted_receipt_source_shape',
  CASE WHEN missing_store=0 AND missing_warehouse=0 THEN 'PASS' ELSE 'BLOCKER' END,
  missing_store+missing_warehouse,to_jsonb(source_shape) FROM source_shape
UNION ALL
SELECT 'exact_fifo_source_shape',
  CASE WHEN missing_batch=0 AND orphan_batch=0 AND negative_batch=0 THEN 'PASS' ELSE 'BLOCKER' END,
  missing_batch+orphan_batch+negative_batch,to_jsonb(fifo_shape) FROM fifo_shape
UNION ALL
SELECT 'partial_invoice_inventory','INFO',0,to_jsonb(partial_invoice) FROM partial_invoice
UNION ALL
SELECT 'supplier_payment_inventory','INFO',0,to_jsonb(payment_shape) FROM payment_shape
UNION ALL
SELECT 'active_return_draft_uniqueness',
  CASE WHEN rows=0 THEN 'PASS' ELSE 'BLOCKER' END,rows,
  jsonb_build_object('duplicateReceiptWarehousePairs',rows)
FROM active_draft_duplicates
ORDER BY check_name;
