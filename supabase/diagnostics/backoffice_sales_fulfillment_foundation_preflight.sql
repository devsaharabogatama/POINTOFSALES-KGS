WITH checks AS (
  SELECT 'foundation_dependency'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('ledgerRows',count(*),'expected',1) details
  FROM private.kgs_schema_migrations WHERE version='20260909144000'
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'foundation_relation_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('existingRelations',count(*))
  FROM information_schema.tables WHERE table_schema='public' AND table_name IN(
    'backoffice_sales_reservations','backoffice_sales_reservation_lines',
    'backoffice_sales_delivery_orders','backoffice_sales_delivery_order_lines',
    'backoffice_sales_fulfillment_audit')
  UNION ALL
  SELECT 'retail_delivery_invoice_boundary','PASS',jsonb_build_object(
    'invoiceSnapshotStillRequired',EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='sales_delivery_documents'
        AND column_name='invoice_snapshot_id' AND is_nullable='NO'),
    'rule','Retail Delivery remains unchanged; Backoffice lineage must be separate')
  UNION ALL
  SELECT 'foundation_runtime_inventory','INFO',jsonb_build_object(
    'confirmedSalesOrders',count(*) FILTER(WHERE status='CONFIRMED'),
    'completedSalesOrders',count(*) FILTER(WHERE fulfillment_status='COMPLETED'))
  FROM public.backoffice_sales_orders
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
