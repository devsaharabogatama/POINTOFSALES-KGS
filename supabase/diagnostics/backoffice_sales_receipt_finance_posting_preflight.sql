-- Read-only preflight for 20260909155000. Isolated Development only.
WITH checks AS (
  SELECT 'migration_dependency' check_name,
    CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260909154000') THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('required','20260909154000') details
  UNION ALL
  SELECT 'active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*)) FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'finance_runtime_dependencies',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineRows',count(*),'expected',3)
  FROM pg_proc proc JOIN pg_namespace ns ON ns.oid=proc.pronamespace
  WHERE ns.nspname||'.'||proc.proname IN(
    'private.post_financial_event_core','private.f4b_financial_event_supported',
    'private.resolve_financial_event_account')
  UNION ALL
  SELECT 'finance_wrapper_collisions',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc proc JOIN pg_namespace ns ON ns.oid=proc.pronamespace
  WHERE ns.nspname='private' AND proc.proname IN(
    'post_backoffice_receipt_financial_event_core',
    'post_financial_event_core_pre_backoffice_receipt',
    'f4b_financial_event_supported_pre_backoffice_receipt')
  UNION ALL
  SELECT 'receipt_event_source_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_delivery_receipts receipt
  LEFT JOIN public.financial_events event ON event.company_id=receipt.company_id
    AND event.id=receipt.financial_event_id
  WHERE event.id IS NULL OR event.source_table<>'backoffice_sales_delivery_receipts'
    OR event.source_id<>receipt.id
    OR event.system_event_key<>'BACKOFFICE_CUSTOMER_RECEIPT'
    OR event.event_type::text<>'SALE_POSTED'
    OR event.amounts->>'acceptedDate' IS DISTINCT FROM receipt.accepted_date::text
    OR event.amounts->>'deliveryOrderId' IS DISTINCT FROM receipt.delivery_order_id::text
    OR event.amounts->>'salesOrderId' IS DISTINCT FROM receipt.sales_order_id::text
    OR jsonb_typeof(event.amounts->'fifoCostTotal') IS DISTINCT FROM 'number'
    OR round((event.amounts->>'fifoCostTotal')::numeric,4)<>round(receipt.total_fifo_cost,4)
  UNION ALL
  SELECT 'receipt_cost_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM (SELECT receipt.id,receipt.total_fifo_cost,
      COALESCE(sum(DISTINCT_LINE.fifo_cost_total),0) line_cost,
      COALESCE((SELECT sum(allocation.total_cost)
        FROM public.backoffice_sales_receipt_fifo_allocations allocation
        WHERE allocation.company_id=receipt.company_id
          AND allocation.receipt_id=receipt.id),0) allocation_cost
    FROM public.backoffice_sales_delivery_receipts receipt
    LEFT JOIN public.backoffice_sales_delivery_receipt_lines DISTINCT_LINE
      ON DISTINCT_LINE.company_id=receipt.company_id AND DISTINCT_LINE.receipt_id=receipt.id
    GROUP BY receipt.company_id,receipt.id,receipt.total_fifo_cost) reconciled
  WHERE round(reconciled.total_fifo_cost,4)<>round(reconciled.line_cost,4)
    OR round(reconciled.total_fifo_cost,4)<>round(reconciled.allocation_cost,4)
  UNION ALL
  SELECT 'receipt_finance_inventory','INFO',jsonb_build_object(
    'receipts',(SELECT count(*) FROM public.backoffice_sales_delivery_receipts),
    'holdEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='BACKOFFICE_CUSTOMER_RECEIPT' AND status='HOLD'),
    'postedEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='BACKOFFICE_CUSTOMER_RECEIPT' AND status='POSTED'),
    'openPeriods',(SELECT count(*) FROM public.accounting_periods
      WHERE status IN('OPEN','REOPENED')))
)
SELECT check_name,status,CASE WHEN status='BLOCKER' THEN 1 ELSE 0 END violation_rows,details
FROM checks ORDER BY check_name;
