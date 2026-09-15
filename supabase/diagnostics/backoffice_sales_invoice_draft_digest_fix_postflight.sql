-- Read-only verification after gate 20260909158000.
WITH routines(signature) AS (VALUES
  ('private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)'),
  ('public.cancel_backoffice_sales_invoice_draft(uuid,bigint,uuid,text)')
), checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909158000'
  UNION ALL
  SELECT 'qualified_digest_definition',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-2)::bigint,jsonb_build_object('expected',2,'routineRows',count(*))
  FROM routines WHERE pg_get_functiondef(to_regprocedure(signature))
    LIKE '%extensions.digest(convert_to(%'
    AND (length(pg_get_functiondef(to_regprocedure(signature)))
      -length(replace(pg_get_functiondef(to_regprocedure(signature)),
        'digest(convert_to(','')))/length('digest(convert_to(')=1
  UNION ALL
  SELECT 'security_definer_search_path_preserved',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-2)::bigint,jsonb_build_object('expected',2,'routineRows',count(*))
  FROM routines required JOIN pg_proc routine
    ON routine.oid=to_regprocedure(required.signature)
  WHERE routine.prosecdef
    AND routine.proconfig @> ARRAY['search_path=public, pg_temp']::text[]
  UNION ALL
  SELECT 'forward_fix_zero_runtime_rows',CASE WHEN row_count=0 THEN 'PASS' ELSE 'FAIL' END,
    row_count::bigint,jsonb_build_object('rowCount',row_count)
  FROM (SELECT (SELECT count(*) FROM public.backoffice_sales_invoices)
    +(SELECT count(*) FROM public.backoffice_sales_invoice_operations)
    +(SELECT count(*) FROM public.backoffice_sales_invoice_audit) row_count) tally
)
SELECT * FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
