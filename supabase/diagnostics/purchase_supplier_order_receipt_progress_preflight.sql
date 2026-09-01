-- Supplier Order receipt-progress read model preflight.
-- SAFETY: SELECT-only. It does not change PO, Goods Receipt, Stock, or Finance.
WITH checks AS (
  SELECT 'migration_dependencies'::TEXT check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',2,'ledgerRows',count(*),
      'requiredVersions',ARRAY['20260828190000','20260831100000']) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260828190000','20260831100000')

  UNION ALL
  SELECT 'canonical_supplier_order_read_runtime',
    CASE WHEN to_regprocedure('public.get_purchase_supplier_orders()') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineExists',
      to_regprocedure('public.get_purchase_supplier_orders()') IS NOT NULL)

  UNION ALL
  SELECT 'posted_receipt_order_line_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.goods_receipt_lines receipt_line
  JOIN public.goods_receipt_documents receipt
    ON receipt.company_id=receipt_line.company_id
   AND receipt.id=receipt_line.document_id
   AND receipt.status='POSTED'
  LEFT JOIN public.supplier_order_lines order_line
    ON order_line.company_id=receipt_line.company_id
   AND order_line.id=receipt_line.supplier_order_line_id
  LEFT JOIN public.supplier_order_documents purchase_order
    ON purchase_order.company_id=order_line.company_id
   AND purchase_order.id=order_line.document_id
  WHERE order_line.id IS NULL OR purchase_order.id IS NULL
    OR receipt.supplier_order_id<>purchase_order.id
    OR receipt_line.product_id<>order_line.product_id

  UNION ALL
  SELECT 'negative_posted_receipt_quantity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.goods_receipt_lines receipt_line
  JOIN public.goods_receipt_documents receipt
    ON receipt.company_id=receipt_line.company_id
   AND receipt.id=receipt_line.document_id
   AND receipt.status='POSTED'
  WHERE receipt_line.received_base_qty<=0

  UNION ALL
  SELECT 'supplier_order_receipt_progress_runtime_state','SETUP',
    jsonb_build_object('requiredFields',ARRAY[
      'factor_to_base_snapshot','product_sku_snapshot','received_base_qty',
      'remaining_base_qty','received_ordered_qty','remaining_ordered_qty',
      'receipt_progress','posted_receipt_count','last_received_at'])

  UNION ALL
  SELECT 'supplier_order_receipt_inventory','INFO',jsonb_build_object(
    'orders',(SELECT count(*) FROM public.supplier_order_documents),
    'orderLines',(SELECT count(*) FROM public.supplier_order_lines),
    'postedReceipts',(SELECT count(*) FROM public.goods_receipt_documents
      WHERE status='POSTED'),
    'postedReceiptLines',(SELECT count(*) FROM public.goods_receipt_lines line
      JOIN public.goods_receipt_documents receipt
        ON receipt.company_id=line.company_id AND receipt.id=line.document_id
      WHERE receipt.status='POSTED'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2
  WHEN 'SETUP' THEN 3 ELSE 4 END,check_name;
