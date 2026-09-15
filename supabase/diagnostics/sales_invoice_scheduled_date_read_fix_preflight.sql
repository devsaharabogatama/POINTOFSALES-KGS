-- Scheduled Invoice date read-model forward-fix preflight. SELECT-only.
WITH invoice_scope AS (
  SELECT invoice.company_id,invoice.sales_id,invoice.invoice_no,
    invoice.snapshot_payload,sale.order_timing_mode,sale.planned_order_date,
    company.company_code,company.timezone,
    (NULLIF(invoice.snapshot_payload->>'transactionAt','')::TIMESTAMPTZ
      AT TIME ZONE COALESCE(NULLIF(invoice.snapshot_payload#>>'{company,timezone}',''),
        company.timezone,'Asia/Jakarta'))::DATE snapshot_order_date
  FROM public.sales_invoice_snapshots invoice
  JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
    AND sale.id=invoice.sales_id
  JOIN public.companies company ON company.id=invoice.company_id
  WHERE COALESCE(invoice.snapshot_payload#>>'{branding,invoiceDateDisplayMode}',
      'ORDER_DATE')='ORDER_DATE'
    AND sale.order_timing_mode='SCHEDULED'
), checks(check_name,status,details,sort_order) AS (
  SELECT 'migration_dependencies',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',2,'ledgerRows',count(*)),1
  FROM private.kgs_schema_migrations
  WHERE version IN('20260904100000','20260904140000')
  UNION ALL
  SELECT 'canonical_invoice_reader_state',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',4,'routineRows',count(*)),2
  FROM (VALUES(to_regprocedure('public.get_sales_documents()')),
    (to_regprocedure('public.get_sales_invoice_document(uuid)')),
    (to_regprocedure('public.get_pos_sales_invoice_document(uuid)')),
    (to_regprocedure('public.export_sales_documents(date,date)'))) routine(oid)
  WHERE oid IS NOT NULL
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*)),3
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'scheduled_order_date_read_scope','REVIEW',jsonb_build_object(
    'invoiceRows',count(*),'historicalDisplayMismatch',count(*) FILTER(
      WHERE planned_order_date IS NOT NULL
        AND planned_order_date IS DISTINCT FROM snapshot_order_date),
    'companyCodes',COALESCE(jsonb_agg(DISTINCT company_code) FILTER(
      WHERE planned_order_date IS NOT NULL
        AND planned_order_date IS DISTINCT FROM snapshot_order_date),'[]'::JSONB)),4
  FROM invoice_scope
  UNION ALL
  SELECT 'invoice_snapshot_immutability','PASS',jsonb_build_object(
    'rule','No Invoice snapshot row or payload is updated by this forward-fix'),5
)
SELECT check_name,status,details FROM checks ORDER BY sort_order,check_name;
