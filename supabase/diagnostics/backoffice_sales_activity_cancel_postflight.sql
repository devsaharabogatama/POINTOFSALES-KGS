WITH checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909143000'
  UNION ALL
  SELECT 'activity_snapshot_contract',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*))::bigint,jsonb_build_object('expected',2,'routineRows',count(*))
  FROM (VALUES
    (to_regprocedure('private.backoffice_sales_order_snapshot(uuid,uuid)')),
    (to_regprocedure('private.backoffice_sales_order_snapshot_before_activity(uuid,uuid)'))
  ) routines(oid) WHERE oid IS NOT NULL
  UNION ALL
  SELECT 'confirmed_cancel_guard_definition',
    CASE WHEN body LIKE '%fulfillment_status=''CONFIRMED''%'
      AND body LIKE '%BACKOFFICE_SALES_CANCEL_STATE_INVALID%' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN body LIKE '%fulfillment_status=''CONFIRMED''%'
      AND body LIKE '%BACKOFFICE_SALES_CANCEL_STATE_INVALID%' THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',1)
  FROM (SELECT pg_get_functiondef(
    'private.transition_backoffice_sales_order(uuid,bigint,uuid,text,text)'::regprocedure) body) definition
  UNION ALL
  SELECT 'private_activity_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges
  WHERE routine_schema='private' AND grantee='authenticated'
    AND routine_name IN('backoffice_sales_order_snapshot',
      'backoffice_sales_order_snapshot_before_activity')
  UNION ALL
  SELECT 'activity_cancel_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'revisionAudits',count(*) FILTER(WHERE action='REVISE'),
    'canceledSalesOrders',count(*) FILTER(WHERE action='CANCEL'
      AND before_state->>'status'='CONFIRMED'))
  FROM public.backoffice_sales_order_audit
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
