-- Read-only preflight for clean Customer receipt and Qty To Invoice foundation.
WITH results AS (
  SELECT 'customer_receipt_foundation_dependencies'::text check_name,
    CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260909151000')
      AND to_regclass('public.backoffice_sales_delivery_dispatches') IS NOT NULL
      AND to_regclass('public.backoffice_sales_delivery_dispatch_lines') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END status,
    0::bigint violation_rows,
    jsonb_build_object('dispatchGate',EXISTS(SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260909151000'),
      'dispatchHeaders',to_regclass('public.backoffice_sales_delivery_dispatches') IS NOT NULL,
      'dispatchLines',to_regclass('public.backoffice_sales_delivery_dispatch_lines') IS NOT NULL) details
  UNION ALL
  SELECT 'active_finance_posting_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'receipt_relation_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('relationRows',count(*))
  FROM information_schema.tables WHERE table_schema='public'
    AND table_name IN('backoffice_sales_delivery_receipts',
      'backoffice_sales_delivery_receipt_lines','backoffice_sales_receipt_fifo_allocations')
  UNION ALL
  SELECT 'invoiceable_column_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='backoffice_sales_order_lines'
    AND column_name IN('accepted_base_qty','returned_before_invoice_base_qty',
      'draft_invoice_allocated_base_qty','invoiced_base_qty',
      'net_delivered_base_qty','to_invoice_base_qty')
), inventory AS (
  SELECT 'customer_receipt_foundation_runtime_inventory'::text check_name,'INFO'::text status,
    0::bigint violation_rows,jsonb_build_object(
      'inTransitDeliveries',(SELECT count(*) FROM public.backoffice_sales_delivery_orders
        WHERE status='IN_TRANSIT'),
      'completedDeliveries',(SELECT count(*) FROM public.backoffice_sales_delivery_orders
        WHERE status='COMPLETED'),
      'rule','Foundation does not complete Delivery or create Stock/Finance/Invoice effects') details
)
SELECT * FROM (SELECT * FROM results UNION ALL SELECT * FROM inventory) output
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
