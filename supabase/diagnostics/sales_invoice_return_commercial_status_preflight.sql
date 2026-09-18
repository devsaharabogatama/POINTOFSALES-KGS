-- Read-only preflight for 20260918160000.
WITH checks AS (
  SELECT 'invoice_return_status_dependency_ledger' check_name,
    CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260918150000') THEN 'PASS' ELSE 'BLOCKER' END status,
    CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260918150000') THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('requiredVersion','20260918150000') details
  UNION ALL
  SELECT 'invoice_return_status_routine_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('existing',COALESCE(jsonb_agg(signature),'[]'::jsonb))
  FROM (SELECT signature FROM (VALUES
    (to_regprocedure('private.derive_sales_invoice_commercial_status(boolean,numeric,numeric,boolean)')::text),
    (to_regprocedure('public.get_sales_invoice_commercial_statuses()')::text)
  ) value(signature) WHERE signature IS NOT NULL) collision
  UNION ALL
  SELECT 'invoice_return_status_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'invoice_return_status_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'invoice_return_status_runtime_inventory','INFO',0::bigint,
    jsonb_build_object(
      'retailInvoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
      'backofficeInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices),
      'postedNativeReturns',(SELECT count(*) FROM public.sales_return_documents WHERE status='POSTED'),
      'postedCreditNotes',(SELECT count(*) FROM public.backoffice_sales_credit_notes WHERE status='POSTED'),
      'activeReturnDocuments',(SELECT count(*) FROM public.backoffice_sales_returns WHERE status<>'CANCELED'))
)
SELECT * FROM checks ORDER BY status,check_name;
