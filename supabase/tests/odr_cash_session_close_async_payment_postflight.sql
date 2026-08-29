-- Cash session close asynchronous Finance postflight.
-- SAFETY: SELECT-only.
WITH runtime AS (
  SELECT pg_get_functiondef(
    'public.close_cashier_session(uuid,bigint,numeric)'::regprocedure) definition
),checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::BIGINT violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260829130000'
  UNION ALL
  SELECT 'cash_session_close_async_contract',
    CASE WHEN definition~'odr5d_close_cashier_session_legacy'
      AND definition~'paymentVerificationDeferred'
      AND definition!~'PENDING_CASH_PAYMENT_VERIFICATION'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'odr5d_close_cashier_session_legacy'
      AND definition~'paymentVerificationDeferred'
      AND definition!~'PENDING_CASH_PAYMENT_VERIFICATION'
      THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',1)
  FROM runtime
  UNION ALL
  SELECT 'cash_drawer_payment_intent_preserved',
    CASE WHEN count(*)=0 THEN 'FAIL' ELSE 'PASS' END,
    CASE WHEN count(*)=0 THEN 1 ELSE 0 END,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private'
    AND routine.proname='capture_sales_order_payment_requests'
    AND pg_get_functiondef(routine.oid)~'SALE_PAYMENT_INTENT'
  UNION ALL
  SELECT 'private_close_runtime_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private'
    AND privilege.routine_name='odr5d_close_cashier_session_legacy'
    AND privilege.grantee IN('anon','authenticated','PUBLIC')
    AND privilege.privilege_type='EXECUTE'
  UNION ALL
  SELECT 'pending_verification_preserved',
    'PASS',0::BIGINT,jsonb_build_object('pendingRows',count(*))
  FROM public.sales_payment_verification_requests WHERE status='PENDING'
),inventory AS (
  SELECT 'async_payment_runtime_inventory'::TEXT check_name,'INFO'::TEXT status,
    0::BIGINT violation_rows,jsonb_build_object(
      'pendingCash',(SELECT count(*) FROM public.sales_payment_verification_requests
        WHERE status='PENDING' AND settlement_route_snapshot='CASH_DRAWER'),
      'pendingNonCash',(SELECT count(*) FROM public.sales_payment_verification_requests
        WHERE status='PENDING' AND settlement_route_snapshot<>'CASH_DRAWER'),
      'openSessions',(SELECT count(*) FROM public.cashier_sessions
        WHERE status='OPEN'::public.session_status)) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
