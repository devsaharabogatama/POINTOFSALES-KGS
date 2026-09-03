-- Stock Opname partial completion and owner review preflight.
-- SAFETY: SELECT-only.

WITH checks(check_name,status,details) AS (
  SELECT 'migration_dependency',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requiredVersion','20260902110000','ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260902110000'
  UNION ALL
  SELECT 'partial_review_runtime_state',
    CASE WHEN count(*)=0 THEN 'SETUP' ELSE 'BLOCKER' END,
    jsonb_build_object('existingRoutineRows',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname IN(
      'complete_stock_opname_partial','get_pos_stock_opname_count_review')
  UNION ALL
  SELECT 'existing_line_status_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('unexpectedRows',count(*))
  FROM public.stock_opname_details WHERE line_status NOT IN(
    'PENDING','COUNTED','RECOUNT_REQUIRED','SUPERSEDED','POSTED')
  UNION ALL
  SELECT 'pending_line_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM public.stock_opname_details WHERE line_status='PENDING' AND(
    counted_at IS NOT NULL OR counter_id IS NOT NULL
    OR expected_qty_at_count IS NOT NULL OR variance_at_count IS NOT NULL)
  UNION ALL
  SELECT 'existing_unresolved_session_inventory','INFO',
    jsonb_build_object('sessions',(SELECT count(DISTINCT opname_id)
        FROM public.stock_opname_details
        WHERE line_status IN('PENDING','RECOUNT_REQUIRED')),
      'lines',(SELECT count(*) FROM public.stock_opname_details
        WHERE line_status IN('PENDING','RECOUNT_REQUIRED')),
      'byStatus',COALESCE((SELECT jsonb_object_agg(line_status,line_count)
        FROM (SELECT line_status,count(*) line_count
          FROM public.stock_opname_details
          WHERE line_status IN('PENDING','RECOUNT_REQUIRED')
          GROUP BY line_status) status_inventory),'{}'::JSONB))
)
SELECT * FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2
  WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
