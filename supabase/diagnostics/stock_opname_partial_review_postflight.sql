-- Stock Opname partial completion and owner review postflight.
-- SAFETY: SELECT-only.

WITH routines AS (
  SELECT namespace.nspname schema_name,procedure.proname,
    pg_get_function_identity_arguments(procedure.oid) arguments,
    procedure.prosecdef,procedure.provolatile,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname) IN(
    ('public','complete_stock_opname_partial'),
    ('public','get_pos_stock_opname_count_review'),
    ('private','complete_stock_opname_partial'),
    ('private','post_stock_opname'))
),checks(check_name,status,violation_rows,details) AS (
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260902120000'
  UNION ALL
  SELECT 'required_partial_review_routines',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=4 THEN 0 ELSE 4-count(*) END,
    jsonb_build_object('expected',4,'routineRows',count(*)) FROM routines
  UNION ALL
  SELECT 'partial_review_rpc_boundary',
    CASE WHEN anon_rows=0 AND authenticated_rows=2 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN anon_rows=0 AND authenticated_rows=2 THEN 0 ELSE 1 END,
    jsonb_build_object('anonRows',anon_rows,
      'authenticatedRows',authenticated_rows)
  FROM (SELECT count(*) FILTER(WHERE grantee='anon') anon_rows,
      count(*) FILTER(WHERE grantee='authenticated') authenticated_rows
    FROM information_schema.routine_privileges
    WHERE routine_schema='public' AND routine_name IN(
      'complete_stock_opname_partial','get_pos_stock_opname_count_review')
      AND privilege_type='EXECUTE') privilege_state
  UNION ALL
  SELECT 'private_partial_runtime_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges
  WHERE routine_schema='private'
    AND routine_name='complete_stock_opname_partial'
    AND grantee='authenticated' AND privilege_type='EXECUTE'
  UNION ALL
  SELECT 'skipped_line_shape',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('rowCount',count(*))
  FROM public.stock_opname_details WHERE line_status='SKIPPED' AND(
    counted_at IS NOT NULL OR counter_id IS NOT NULL
    OR expected_qty_at_count IS NOT NULL OR variance_at_count IS NOT NULL
    OR physical_qty<>0 OR difference<>0)
  UNION ALL
  SELECT 'posted_skipped_zero_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.stock_opname_details detail
  WHERE detail.line_status='SKIPPED' AND detail.adjustment_line_id IS NOT NULL
  UNION ALL
  SELECT 'counted_only_posting_definition',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*))
  FROM routines WHERE schema_name='private' AND proname='post_stock_opname'
    AND definition ILIKE '%line_status NOT IN%'
    AND regexp_replace(definition,'\s+','','g') ILIKE
      '%NOTIN(''COUNTED'',''SKIPPED'',''SUPERSEDED'')%'
    AND regexp_replace(definition,'\s+','','g') ILIKE
      '%line_status=''COUNTED''%'
  UNION ALL
  SELECT 'stock_opname_partial_runtime_inventory','INFO',0,
    jsonb_build_object('skippedLines',count(*) FILTER(WHERE line_status='SKIPPED'),
      'countedLines',count(*) FILTER(WHERE line_status='COUNTED'),
      'pendingLines',count(*) FILTER(WHERE line_status='PENDING'),
      'recountRequiredLines',count(*) FILTER(WHERE line_status='RECOUNT_REQUIRED'))
  FROM public.stock_opname_details
)
SELECT * FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
