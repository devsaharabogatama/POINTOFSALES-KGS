-- Sales Order cancellation and Invoice projection preflight.
-- SAFETY: SELECT-only.

WITH checks AS (
  SELECT 'migration_dependencies'::TEXT check_name,
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',3,'ledgerRows',count(*),'requiredVersions',
      ARRAY['20260828240000','20260828270000','20260828280000']) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260828240000','20260828270000','20260828280000')
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
  SELECT 'canceled_order_payment_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('unresolvedRows',count(*))
  FROM public.sales_payment_verification_requests request
  JOIN public.sales_headers sale ON sale.company_id=request.company_id
    AND sale.id=request.sales_id
  WHERE sale.order_runtime_status='CANCELED'
    AND request.status IN('PENDING','VERIFIED')
  UNION ALL
  SELECT 'canceled_order_dispatch_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_headers sale
  JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=sale.company_id AND reservation.sales_id=sale.id
  WHERE sale.order_runtime_status='CANCELED'
    AND reservation.total_dispatched_base_qty>0
  UNION ALL
  SELECT 'cancelable_payment_scope','INFO',jsonb_build_object(
    'pendingCashOpenSession',count(*) FILTER(WHERE request.status='PENDING'
      AND request.settlement_route_snapshot='CASH_DRAWER' AND session.status='OPEN'),
    'pendingCashClosedSession',count(*) FILTER(WHERE request.status='PENDING'
      AND request.settlement_route_snapshot='CASH_DRAWER'
      AND session.status IS DISTINCT FROM 'OPEN'),
    'pendingNonCash',count(*) FILTER(WHERE request.status='PENDING'
      AND request.settlement_route_snapshot<>'CASH_DRAWER'),
    'verified',count(*) FILTER(WHERE request.status='VERIFIED'))
  FROM public.sales_payment_verification_requests request
  JOIN public.sales_headers sale ON sale.company_id=request.company_id
    AND sale.id=request.sales_id
  LEFT JOIN public.cashier_sessions session ON session.company_id=request.company_id
    AND session.id=request.cashier_session_id
  WHERE sale.order_runtime_status IN('CONFIRMED','RESERVED')
  UNION ALL
  SELECT 'invoice_cancellation_projection','SETUP',jsonb_build_object(
    'canceledInvoices',count(*),'requiredDesign',ARRAY[
      'Invoice snapshot remains immutable historical evidence',
      'Backoffice list/detail/export exposes canceled lifecycle',
      'canceled print and PDF carry DIBATALKAN watermark'])
  FROM public.sales_headers sale
  JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=sale.company_id
    AND invoice.sales_id=sale.id
  WHERE sale.order_runtime_status='CANCELED'
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2
  WHEN 'SETUP' THEN 3 ELSE 4 END,check_name;
