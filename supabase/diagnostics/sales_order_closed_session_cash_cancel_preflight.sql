-- Sales Order Cash cancellation after the source Cashier session was closed.
-- SAFETY: SELECT-only.
WITH checks AS (
  SELECT 'active_finance_posting_queue' check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('runCount',count(*)) details
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'closed_source_session_cash_cancel_scope',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
    jsonb_build_object('requestCount',count(*),'amount',COALESCE(sum(request.amount),0),
      'companyCount',count(DISTINCT request.company_id))
  FROM public.sales_payment_verification_requests request
  JOIN public.cashier_sessions session ON session.company_id=request.company_id
    AND session.id=request.cashier_session_id
  JOIN public.sales_headers sale ON sale.company_id=request.company_id
    AND sale.id=request.sales_id
  WHERE request.status='PENDING'
    AND request.settlement_route_snapshot='CASH_DRAWER'
    AND session.status='CLOSED'::public.session_status
    AND sale.order_runtime_status IN('CONFIRMED','RESERVED')
  UNION ALL
  SELECT 'cash_cancel_forward_fix_dependency',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requiredVersion','20260830110000','ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260830110000'
  UNION ALL
  SELECT 'cash_cancel_forward_fix_state',
    CASE WHEN count(*)=0 THEN 'SETUP' ELSE 'PASS' END,
    jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260830120000'
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
