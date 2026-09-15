-- Read-only preflight for Odoo-style Backoffice invoice/accounting foundation.
WITH results AS (
  SELECT 'invoice_foundation_dependencies'::text check_name,
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END status,
    (4-count(*))::bigint violation_rows,
    jsonb_build_object('expected',4,'ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260909140000','20260909152000','20260909154000','20260909155000')
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
  SELECT 'invoice_foundation_relation_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('relationRows',count(*))
  FROM information_schema.tables WHERE table_schema='public' AND table_name IN(
    'backoffice_sales_payment_terms','backoffice_sales_payment_term_lines',
    'backoffice_sales_proformas','backoffice_sales_invoices',
    'backoffice_sales_invoice_lines','backoffice_sales_invoice_quantity_allocations',
    'backoffice_sales_down_payment_applications',
    'backoffice_sales_invoice_receivable_schedules','backoffice_sales_invoice_audit')
  UNION ALL
  SELECT 'invoice_foundation_order_column_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='backoffice_sales_orders'
    AND column_name IN('payment_term_id','payment_term_snapshot')
  UNION ALL
  SELECT 'required_account_function_catalog',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END,
    (5-count(*))::bigint,jsonb_build_object('expected',5,'functionRows',count(*),
      'required',ARRAY['SALES_REVENUE','OUTPUT_TAX','CUSTOMER_RECEIVABLE',
        'CUSTOMER_ADVANCE_LIABILITY','PAYMENT_CLEARING'])
  FROM public.account_functions
  WHERE function_key IN('SALES_REVENUE','OUTPUT_TAX','CUSTOMER_RECEIVABLE',
    'CUSTOMER_ADVANCE_LIABILITY','PAYMENT_CLEARING')
), inventory AS (
  SELECT 'invoice_foundation_runtime_inventory'::text check_name,'INFO'::text status,
    0::bigint violation_rows,jsonb_build_object(
      'featureCompanies',(SELECT count(*) FROM public.company_features
        WHERE feature_code='backoffice_delivered_qty_sales_enabled' AND is_enabled),
      'orders',(SELECT count(*) FROM public.backoffice_sales_orders),
      'invoiceableLines',(SELECT count(*) FROM public.backoffice_sales_order_lines
        WHERE to_invoice_base_qty>0),
      'invoiceableBaseQty',(SELECT COALESCE(sum(to_invoice_base_qty),0)
        FROM public.backoffice_sales_order_lines),
      'rule','Preflight is SELECT-only and creates no Invoice, Payment, Event, Journal, or Stock effect') details
)
SELECT * FROM (SELECT * FROM results UNION ALL SELECT * FROM inventory) output
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
