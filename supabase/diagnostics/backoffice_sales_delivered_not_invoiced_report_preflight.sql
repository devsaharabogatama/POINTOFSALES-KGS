-- SELECT-only preflight for Step 5/6.3 Delivered Not Invoiced report.
WITH required_relations(name) AS (VALUES
  ('backoffice_sales_orders'),('backoffice_sales_order_lines'),
  ('backoffice_sales_delivery_receipts'),('backoffice_sales_delivery_receipt_lines'),
  ('backoffice_sales_delivery_discrepancy_lines'),('backoffice_sales_discrepancy_stock_effects'),
  ('backoffice_sales_invoices'),('backoffice_sales_invoice_quantity_allocations')
), checks AS (
  SELECT 'dni_dependency_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('requiredVersion','20260912137000','ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912137000'
  UNION ALL
  SELECT 'dni_relation_contract',CASE WHEN count(*)=8 THEN 'PASS' ELSE 'BLOCKER' END,
    8-count(*),jsonb_build_object('present',count(*),'expected',8,
      'missing',(SELECT COALESCE(jsonb_agg(required.name),'[]'::jsonb) FROM required_relations required
        WHERE to_regclass('public.'||required.name) IS NULL))
  FROM required_relations WHERE to_regclass('public.'||name) IS NOT NULL
  UNION ALL
  SELECT 'dni_delivery_fee_column_contract',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,
    3-count(*),jsonb_build_object('present',count(*),'expected',3)
  FROM information_schema.columns
  WHERE table_schema='public'
    AND ((table_name='backoffice_sales_orders' AND column_name='delivery_fee_amount')
      OR (table_name='backoffice_sales_invoices'
        AND column_name IN('delivery_fee_amount','invoice_type')))
  UNION ALL
  SELECT 'dni_routine_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('existing',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE (namespace.nspname='private' AND routine.proname='classify_backoffice_sales_dni')
     OR (namespace.nspname='public' AND routine.proname='get_finance_delivered_not_invoiced')
  UNION ALL
  SELECT 'dni_active_finance_queue','INFO',0,
    jsonb_build_object('runRows',count(*),'rule','Read-only report does not mutate queue')
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'dni_nonterminal_offline','INFO',0,
    jsonb_build_object('submissionRows',count(*),'rule','Read-only report does not mutate Offline state')
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'dni_regular_quantity_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_order_lines line
  WHERE line.invoiced_base_qty+line.draft_invoice_allocated_base_qty
    >line.accepted_base_qty-line.returned_before_invoice_base_qty
  UNION ALL
  SELECT 'dni_overage_quantity_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.invoiced_overage_base_qty+line.draft_overage_invoice_allocated_base_qty
    >line.accepted_overage_base_qty
  UNION ALL
  SELECT 'dni_runtime_inventory','INFO',0,jsonb_build_object(
    'acceptedRegularLines',(SELECT count(*) FROM public.backoffice_sales_order_lines WHERE accepted_base_qty>0),
    'acceptedOverageLines',(SELECT count(*) FROM public.backoffice_sales_delivery_discrepancy_lines WHERE accepted_overage_base_qty>0),
    'draftRegularAllocations',(SELECT count(*) FROM public.backoffice_sales_invoice_quantity_allocations allocation
      WHERE allocation.source_kind='SALES_ORDER' AND allocation.status='HELD'),
    'postedRegularAllocations',(SELECT count(*) FROM public.backoffice_sales_invoice_quantity_allocations allocation
      WHERE allocation.source_kind='SALES_ORDER' AND allocation.status='POSTED'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
