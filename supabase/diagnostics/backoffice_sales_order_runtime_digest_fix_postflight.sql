-- Backoffice Sales runtime digest forward-fix postflight. READ ONLY.
WITH routines(signature) AS (VALUES
  ('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)'),
  ('private.transition_backoffice_sales_order(uuid,bigint,uuid,text,text)')
), results AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END::text status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260908121000'
  UNION ALL
  SELECT 'qualified_digest_definition',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(2-count(*))::bigint,jsonb_build_object('expected',2,'routineRows',count(*))
  FROM routines WHERE pg_get_functiondef(to_regprocedure(signature))
    LIKE '%extensions.digest(convert_to(%'
  UNION ALL
  SELECT 'security_definer_search_path_preserved',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(2-count(*))::bigint,jsonb_build_object('expected',2,'routineRows',count(*))
  FROM routines required JOIN pg_proc routine
    ON routine.oid=to_regprocedure(required.signature)
  WHERE routine.prosecdef
    AND routine.proconfig @> ARRAY['search_path=public, pg_temp']::text[]
  UNION ALL
  SELECT 'forward_fix_zero_runtime_rows',
    CASE WHEN row_count=0 THEN 'PASS' ELSE 'BLOCKER' END,row_count::bigint,
    jsonb_build_object('rowCount',row_count)
  FROM (SELECT (SELECT count(*) FROM public.backoffice_sales_orders)
    +(SELECT count(*) FROM public.backoffice_sales_order_operations) row_count) inventory
)
SELECT check_name,status,violation_rows,details FROM results
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
