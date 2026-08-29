-- ODR Cash session close asynchronous Finance preflight.
-- SAFETY: SELECT-only.
WITH runtime AS (
  SELECT CASE WHEN to_regprocedure(
    'public.close_cashier_session(uuid,bigint,numeric)') IS NULL
    THEN NULL ELSE pg_get_functiondef(
      'public.close_cashier_session(uuid,bigint,numeric)'::regprocedure) END definition
),checks AS (
  SELECT 'payment_verification_dependency'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('requiredVersion','20260828240000','ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828240000'
  UNION ALL
  SELECT 'cash_session_close_runtime',
    CASE WHEN definition IS NULL THEN 'BLOCKER'
      WHEN definition~'odr5d_close_cashier_session_legacy' THEN 'PASS'
      ELSE 'BLOCKER' END,
    jsonb_build_object('routineExists',definition IS NOT NULL,
      'currentlyBlocksPendingCash',COALESCE(
        definition~'PENDING_CASH_PAYMENT_VERIFICATION',FALSE))
  FROM runtime
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
),inventory AS (
  SELECT 'pending_payment_inventory'::TEXT check_name,'INFO'::TEXT status,
    jsonb_build_object(
      'pendingCash',(SELECT count(*) FROM public.sales_payment_verification_requests
        WHERE status='PENDING' AND settlement_route_snapshot='CASH_DRAWER'),
      'pendingNonCash',(SELECT count(*) FROM public.sales_payment_verification_requests
        WHERE status='PENDING' AND settlement_route_snapshot<>'CASH_DRAWER'),
      'openSessions',(SELECT count(*) FROM public.cashier_sessions
        WHERE status='OPEN'::public.session_status)) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
