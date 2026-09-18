-- SELECT-only. Run before 20260918150000.
WITH required_ledger(version) AS (VALUES
  ('20260917131000'),('20260917150000'),('20260917151000'),
  ('20260918120000'),('20260918130000')
),missing_ledger AS (
  SELECT version FROM required_ledger required
  WHERE NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations migration
    WHERE migration.version=required.version)
),received_retained AS (
  SELECT document.company_id,document.id return_id,document.retail_sales_id,
    document.status,document.total_received_base_qty
  FROM public.backoffice_sales_returns document
  WHERE document.source_kind='RETAINED_RETAIL'
    AND document.status IN('RECEIVED','CREDIT_PENDING','REFUND_PENDING','COMPLETED')
),invalid_source AS (
  SELECT document.return_id
  FROM received_retained document
  LEFT JOIN public.sales_headers sale ON sale.company_id=document.company_id
    AND sale.id=document.retail_sales_id
  LEFT JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=sale.company_id
    AND invoice.sales_id=sale.id
  WHERE sale.id IS NULL OR invoice.id IS NULL OR sale.document_status='CANCELED'
),invalid_lines AS (
  SELECT return_line.id
  FROM public.backoffice_sales_return_lines return_line
  JOIN received_retained document ON document.company_id=return_line.company_id
    AND document.return_id=return_line.return_id
  LEFT JOIN public.sales_details detail ON detail.company_id=return_line.company_id
    AND detail.id=return_line.retail_sales_detail_id
    AND detail.sales_id=document.retail_sales_id
  WHERE return_line.source_kind<>'RETAINED_RETAIL' OR detail.id IS NULL
    OR detail.qty<=0 OR detail.quantity_base<=0 OR detail.sale_uom_id IS NULL
),invalid_tax AS (
  SELECT DISTINCT detail.id
  FROM public.backoffice_sales_return_lines return_line
  JOIN received_retained document ON document.company_id=return_line.company_id
    AND document.return_id=return_line.return_id
  JOIN public.sales_details detail ON detail.company_id=return_line.company_id
    AND detail.id=return_line.retail_sales_detail_id
  LEFT JOIN public.chart_of_accounts account ON account.company_id=detail.company_id
    AND account.id=detail.tax_account_id
  WHERE detail.tax_amount>0
    AND (detail.tax_account_id IS NULL OR account.id IS NULL
      OR NOT account.is_active OR NOT account.is_postable)
),active_queue AS (
  SELECT id FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
),offline AS (
  SELECT id FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
),runtime_definitions AS (
  SELECT
    pg_get_functiondef(to_regprocedure(
      'public.get_finance_ar_aging(date,uuid,uuid)')) ar_definition,
    pg_get_functiondef(to_regprocedure(
      'public.get_finance_customer_statement(uuid,date,date,uuid)')) statement_definition
),runtime_anchor_violations AS (
  SELECT anchor_name
  FROM runtime_definitions definition
  CROSS JOIN LATERAL (VALUES
    ('retail_ar_credit_column',definition.ar_definition,
      'WHERE allocation.company_id=v_company AND allocation.sales_id=sale.id),0) allocated_amount'::text),
    ('backoffice_ar_credit_column',definition.ar_definition,
      'ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0),schedule.amount_due),0)'::text),
    ('ar_outstanding',definition.ar_definition,
      'GREATEST(original_receivable-allocated_amount,0) outstanding'::text),
    ('ar_open_item',definition.ar_definition,
      'WHERE original_receivable-allocated_amount>0'::text),
    ('ar_output',definition.ar_definition,
      '''allocatedAmount'',item.allocated_amount,'::text),
    ('statement_source',definition.statement_definition,
      'SELECT note.id,''CREDIT_NOTE'',''BACKOFFICE'',note.credit_note_no'::text),
    ('statement_invoice',definition.statement_definition,
      '(''Credit Note Retur Customer untuk ''||source.invoice_no)::text'::text)
  ) anchor(anchor_name,function_definition,required_fragment)
  WHERE function_definition IS NULL
    OR (length(function_definition)-length(replace(
      function_definition,required_fragment,'')))/length(required_fragment)<>1
),required_constraints(constraint_name) AS (VALUES
  ('backoffice_sales_credit_notes_invoice_fk'),
  ('backoffice_sales_credit_note_lines_order_line_fk'),
  ('backoffice_sales_credit_note_lines_invoice_line_fk'),
  ('backoffice_sales_return_invoice_alloc_order_line_fk'),
  ('backoffice_sales_return_invoice_alloc_shape_check'),
  ('backoffice_sales_customer_refunds_invoice_fk')
),missing_constraints AS (
  SELECT required.constraint_name
  FROM required_constraints required
  WHERE NOT EXISTS(SELECT 1 FROM pg_constraint constraint_row
    WHERE constraint_row.conname=required.constraint_name
      AND constraint_row.connamespace='public'::regnamespace)
)
SELECT * FROM (
  SELECT 'retained_credit_dependency_ledger' check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,count(*)::bigint violation_rows,
    jsonb_build_object('missing',COALESCE(jsonb_agg(version) FILTER(WHERE version IS NOT NULL),'[]'::jsonb)) details
  FROM missing_ledger
  UNION ALL
  SELECT 'retained_credit_schema_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('existing',COALESCE(jsonb_agg(column_name),'[]'::jsonb))
  FROM information_schema.columns WHERE table_schema='public'
    AND ((table_name='backoffice_sales_credit_notes' AND column_name='source_kind')
      OR (table_name='backoffice_sales_credit_note_lines' AND column_name='source_kind')
      OR (table_name='backoffice_sales_return_invoice_allocations' AND column_name='source_kind')
      OR (table_name='backoffice_sales_customer_refunds' AND column_name='source_kind'))
  UNION ALL
  SELECT 'retained_credit_routine_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('existing',COALESCE(jsonb_agg(signature),'[]'::jsonb))
  FROM (VALUES
    ('private.allocate_retained_retail_return_credit_core(uuid,bigint,uuid,jsonb)'),
    ('private.post_retained_retail_credit_note_core(uuid,bigint,uuid)'),
    ('private.trg_assign_backoffice_customer_refund_source()'),
    ('public.get_retained_retail_return_invoice_workspace(uuid)'),
    ('public.get_backoffice_sales_credit_note_payment_context(uuid)')) item(signature)
  WHERE to_regprocedure(signature) IS NOT NULL
  UNION ALL
  SELECT 'retained_credit_trigger_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('existing',COALESCE(jsonb_agg(trigger.tgname),'[]'::jsonb))
  FROM pg_trigger trigger
  WHERE trigger.tgname IN('retained_retail_credit_note_fee_guard',
      'assign_backoffice_customer_refund_source')
    AND NOT trigger.tgisinternal
  UNION ALL
  SELECT 'retained_credit_required_constraint_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('missing',COALESCE(
      jsonb_agg(constraint_name ORDER BY constraint_name),'[]'::jsonb))
  FROM missing_constraints
  UNION ALL
  SELECT 'retained_credit_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('runRows',count(*)) FROM active_queue
  UNION ALL
  SELECT 'retained_credit_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissionRows',count(*)) FROM offline
  UNION ALL
  SELECT 'retained_credit_source_invoice_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidReturns',count(*)) FROM invalid_source
  UNION ALL
  SELECT 'retained_credit_source_line_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidLines',count(*)) FROM invalid_lines
  UNION ALL
  SELECT 'retained_credit_source_tax_account_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidTaxLines',count(*)) FROM invalid_tax
  UNION ALL
  SELECT 'retained_credit_required_runtime',
    CASE WHEN count(*)=8 THEN 'PASS' ELSE 'BLOCKER' END,abs(count(*)-8)::bigint,
    jsonb_build_object('present',count(*),'expected',8)
  FROM (VALUES
    ('public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb)'),
    ('public.post_backoffice_sales_credit_note(uuid,bigint,uuid)'),
    ('public.post_backoffice_sales_customer_refund(uuid,bigint,uuid,date,numeric,uuid,text,text,text)'),
    ('public.reverse_backoffice_sales_customer_refund(uuid,bigint,uuid,date,text)'),
    ('public.get_finance_ar_aging(date,uuid,uuid)'),
    ('public.get_finance_customer_statement(uuid,date,date,uuid)'),
    ('private.backoffice_sales_credit_note_snapshot(uuid,uuid)'),
    ('private.backoffice_sales_customer_refund_snapshot(uuid,uuid)')) item(signature)
  WHERE to_regprocedure(signature) IS NOT NULL
  UNION ALL
  SELECT 'retained_credit_runtime_anchor_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidAnchors',COALESCE(
      jsonb_agg(anchor_name ORDER BY anchor_name),'[]'::jsonb))
  FROM runtime_anchor_violations
  UNION ALL
  SELECT 'retained_credit_runtime_inventory','INFO',0,
    jsonb_build_object('receivedRetainedReturns',(SELECT count(*) FROM received_retained),
      'receivedQuantity',(SELECT COALESCE(sum(total_received_base_qty),0) FROM received_retained),
      'rule','Invoice Retail asli wajib tunggal; Sale/Invoice/Payment historis tidak dimutasi')
) result ORDER BY status,check_name;
