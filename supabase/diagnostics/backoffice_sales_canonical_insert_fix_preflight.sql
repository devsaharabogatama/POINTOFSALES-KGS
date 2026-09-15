-- SELECT-only preflight for canonical_unit_price atomic INSERT forward-fix.
WITH definition AS (
  SELECT pg_get_functiondef(
    'public.save_backoffice_sales_order_draft_before_pricelist_header(uuid,bigint,uuid,jsonb)'::regprocedure
  ) AS body
), marker AS (
  SELECT
    (length(body) - length(replace(body,
      'product_id,uom_id,ordered_qty,base_qty_per_uom,unit_price,', '')))
      / length('product_id,uom_id,ordered_qty,base_qty_per_uom,unit_price,') AS column_marker,
    (length(body) - length(replace(body,
      'v_unit_price,v_sku,v_product_name,v_uom_code,v_uom_name,v_price,v_actor,v_actor);', '')))
      / length('v_unit_price,v_sku,v_product_name,v_uom_code,v_uom_name,v_price,v_actor,v_actor);') AS value_marker
  FROM definition
), checks AS (
  SELECT 'canonical_insert_dependency_ledger'::text AS check_name,
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END::text AS status,
    abs(count(*) - 1)::bigint AS violation_rows,
    jsonb_build_object('requiredVersion', '20260909140000', 'rows', count(*)) AS details
  FROM private.kgs_schema_migrations WHERE version = '20260909140000'
  UNION ALL
  SELECT 'canonical_insert_migration_collision',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint, jsonb_build_object('ledgerRows', count(*))
  FROM private.kgs_schema_migrations WHERE version = '20260909141000'
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint, jsonb_build_object('runRows', count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN ('PREVIEWED', 'APPROVED', 'PROCESSING')
  UNION ALL
  SELECT 'canonical_price_column_pre_fix_contract',
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(count(*) - 1)::bigint,
    jsonb_build_object('expected', 1, 'rows', count(*))
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'backoffice_sales_order_lines'
    AND column_name = 'canonical_unit_price' AND is_nullable = 'NO'
    AND column_default IS NULL
  UNION ALL
  SELECT 'canonical_price_existing_row_integrity',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint, jsonb_build_object('nullRows', count(*))
  FROM public.backoffice_sales_order_lines WHERE canonical_unit_price IS NULL
  UNION ALL
  SELECT 'canonical_insert_exact_patch_markers',
    CASE WHEN column_marker = 1 AND value_marker = 1 THEN 'PASS' ELSE 'BLOCKER' END,
    (abs(column_marker - 1) + abs(value_marker - 1))::bigint,
    jsonb_build_object('columnMarker', column_marker, 'valueMarker', value_marker)
  FROM marker
)
SELECT check_name, status, violation_rows, details
FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
