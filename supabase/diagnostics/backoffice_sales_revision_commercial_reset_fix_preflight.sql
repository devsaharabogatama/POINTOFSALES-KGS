-- SELECT-only preflight for revision commercial transient-state reset fix.
WITH save_definition AS (
  SELECT pg_get_functiondef(
    'public.save_backoffice_sales_order_draft_before_pricelist_header(uuid,bigint,uuid,jsonb)'::regprocedure
  ) AS body
), marker AS (
  SELECT (length(body) - length(replace(body,
    'subtotal=0,discount_total=0,tax_total=0,grand_total=0,', '')))
    / length('subtotal=0,discount_total=0,tax_total=0,grand_total=0,') AS marker_count
  FROM save_definition
), checks AS (
  SELECT 'revision_reset_dependency_ledger'::text AS check_name,
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END::text AS status,
    abs(count(*) - 1)::bigint AS violation_rows,
    jsonb_build_object('requiredVersion', '20260909143000', 'rows', count(*)) AS details
  FROM private.kgs_schema_migrations WHERE version = '20260909143000'
  UNION ALL
  SELECT 'revision_reset_migration_collision',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint, jsonb_build_object('ledgerRows', count(*))
  FROM private.kgs_schema_migrations WHERE version = '20260909144000'
  UNION ALL
  SELECT 'revision_reset_exact_patch_marker',
    CASE WHEN marker_count = 1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(marker_count - 1)::bigint,
    jsonb_build_object('expected', 1, 'markerRows', marker_count)
  FROM marker
  UNION ALL
  SELECT 'commercial_amount_constraint_active',
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(count(*) - 1)::bigint,
    jsonb_build_object('expected', 1, 'validatedRows', count(*))
  FROM pg_constraint constraint_row
  JOIN pg_class relation ON relation.oid = constraint_row.conrelid
  JOIN pg_namespace schema_row ON schema_row.oid = relation.relnamespace
  WHERE schema_row.nspname = 'public'
    AND relation.relname = 'backoffice_sales_orders'
    AND constraint_row.conname = 'backoffice_sales_orders_amount_check'
    AND constraint_row.convalidated
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
