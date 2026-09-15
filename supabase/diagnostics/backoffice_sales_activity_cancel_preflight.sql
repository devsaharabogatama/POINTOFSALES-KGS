-- SELECT-only preflight for SO activity history and guarded cancellation.
WITH transition_definition AS (
  SELECT pg_get_functiondef(
    'private.transition_backoffice_sales_order(uuid,bigint,uuid,text,text)'::regprocedure
  ) AS body
), marker AS (
  SELECT (length(body) - length(replace(body,
    'IF v_document.status NOT IN(''DRAFT'',''SENT'') THEN RAISE EXCEPTION ''BACKOFFICE_SALES_CANCEL_STATE_INVALID''; END IF;',
    ''))) / length(
    'IF v_document.status NOT IN(''DRAFT'',''SENT'') THEN RAISE EXCEPTION ''BACKOFFICE_SALES_CANCEL_STATE_INVALID''; END IF;'
    ) AS marker_count
  FROM transition_definition
), checks AS (
  SELECT 'activity_cancel_dependency_ledger'::text AS check_name,
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END::text AS status,
    abs(count(*) - 1)::bigint AS violation_rows,
    jsonb_build_object('requiredVersion', '20260909142000', 'rows', count(*)) AS details
  FROM private.kgs_schema_migrations WHERE version = '20260909142000'
  UNION ALL
  SELECT 'activity_cancel_migration_collision',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint, jsonb_build_object('ledgerRows', count(*))
  FROM private.kgs_schema_migrations WHERE version = '20260909143000'
  UNION ALL
  SELECT 'activity_snapshot_function_collision',
    CASE WHEN to_regprocedure(
      'private.backoffice_sales_order_snapshot_before_activity(uuid,uuid)') IS NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure(
      'private.backoffice_sales_order_snapshot_before_activity(uuid,uuid)') IS NULL
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('existing', to_regprocedure(
      'private.backoffice_sales_order_snapshot_before_activity(uuid,uuid)') IS NOT NULL)
  UNION ALL
  SELECT 'cancel_state_exact_patch_marker',
    CASE WHEN marker_count = 1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(marker_count - 1)::bigint,
    jsonb_build_object('expected', 1, 'markerRows', marker_count)
  FROM marker
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint, jsonb_build_object('runRows', count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN ('PREVIEWED', 'APPROVED', 'PROCESSING')
)
SELECT check_name, status, violation_rows, details
FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
