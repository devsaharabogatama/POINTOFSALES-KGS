-- Read-only verification after gate 20260909152000.
WITH results AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909152000'
  UNION ALL
  SELECT 'required_customer_receipt_relations',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-3)::bigint,jsonb_build_object('expected',3,'relationRows',count(*))
  FROM information_schema.tables WHERE table_schema='public'
    AND table_name IN('backoffice_sales_delivery_receipts',
      'backoffice_sales_delivery_receipt_lines','backoffice_sales_receipt_fifo_allocations')
  UNION ALL
  SELECT 'required_invoiceable_columns',CASE WHEN count(*)=6 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-6)::bigint,jsonb_build_object('expected',6,'columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='backoffice_sales_order_lines'
    AND column_name IN('accepted_base_qty','returned_before_invoice_base_qty',
      'draft_invoice_allocated_base_qty','invoiced_base_qty',
      'net_delivered_base_qty','to_invoice_base_qty')
  UNION ALL
  SELECT 'customer_receipt_rls_state',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-3)::bigint,jsonb_build_object('enabledRelations',count(*))
  FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relrowsecurity
    AND relation.relname IN('backoffice_sales_delivery_receipts',
      'backoffice_sales_delivery_receipt_lines','backoffice_sales_receipt_fifo_allocations')
  UNION ALL
  SELECT 'browser_customer_receipt_table_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants WHERE grantee IN('anon','authenticated')
    AND table_schema='public' AND table_name IN('backoffice_sales_delivery_receipts',
      'backoffice_sales_delivery_receipt_lines','backoffice_sales_receipt_fifo_allocations')
  UNION ALL
  SELECT 'foundation_zero_receipt_backfill',CASE WHEN receipt_count+line_count+allocation_count=0
      THEN 'PASS' ELSE 'FAIL' END,
    (receipt_count+line_count+allocation_count)::bigint,
    jsonb_build_object('receipts',receipt_count,'receiptLines',line_count,
      'fifoAllocations',allocation_count)
  FROM (SELECT (SELECT count(*) FROM public.backoffice_sales_delivery_receipts) receipt_count,
      (SELECT count(*) FROM public.backoffice_sales_delivery_receipt_lines) line_count,
      (SELECT count(*) FROM public.backoffice_sales_receipt_fifo_allocations) allocation_count) tally
  UNION ALL
  SELECT 'foundation_zero_quantity_backfill',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('nonzeroRows',count(*))
  FROM public.backoffice_sales_order_lines
  WHERE accepted_base_qty<>0 OR returned_before_invoice_base_qty<>0
    OR draft_invoice_allocated_base_qty<>0 OR invoiced_base_qty<>0
    OR net_delivered_base_qty<>0 OR to_invoice_base_qty<>0
  UNION ALL
  SELECT 'receipt_lineage_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('rowCount',count(*))
  FROM public.backoffice_sales_delivery_receipt_lines line
  JOIN public.backoffice_sales_delivery_receipts receipt
    ON receipt.company_id=line.company_id AND receipt.id=line.receipt_id
  JOIN public.backoffice_sales_delivery_order_lines delivery_line
    ON delivery_line.company_id=line.company_id AND delivery_line.id=line.delivery_order_line_id
  JOIN public.backoffice_sales_reservation_lines reservation_line
    ON reservation_line.company_id=line.company_id AND reservation_line.id=line.reservation_line_id
  WHERE (line.delivery_order_id,line.sales_order_id,line.reservation_id,
      line.sales_order_line_id,line.product_id,line.uom_id) IS DISTINCT FROM
    (receipt.delivery_order_id,receipt.sales_order_id,receipt.reservation_id,
      delivery_line.sales_order_line_id,delivery_line.product_id,delivery_line.uom_id)
    OR (reservation_line.reservation_id,reservation_line.sales_order_id,
      reservation_line.sales_order_line_id,reservation_line.product_id) IS DISTINCT FROM
      (line.reservation_id,line.sales_order_id,line.sales_order_line_id,line.product_id)
), inventory AS (
  SELECT 'customer_receipt_foundation_runtime_inventory'::text check_name,'INFO'::text status,
    0::bigint violation_rows,jsonb_build_object(
      'inTransitDeliveries',(SELECT count(*) FROM public.backoffice_sales_delivery_orders
        WHERE status='IN_TRANSIT'),
      'receiptRows',(SELECT count(*) FROM public.backoffice_sales_delivery_receipts),
      'invoiceableBaseQty',(SELECT COALESCE(sum(to_invoice_base_qty),0)
        FROM public.backoffice_sales_order_lines)) details
)
SELECT * FROM (SELECT * FROM results UNION ALL SELECT * FROM inventory) output
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
