-- Read-only preflight for the applied 157000 pgcrypto schema forward-fix.
WITH routines(signature) AS (VALUES
  ('private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)'),
  ('public.cancel_backoffice_sales_invoice_draft(uuid,bigint,uuid,text)')
), checks AS (
  SELECT 'digest_fix_dependency_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909157000'
  UNION ALL
  SELECT 'extensions_digest_dependency',
    CASE WHEN to_regprocedure('extensions.digest(bytea,text)') IS NOT NULL THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure('extensions.digest(bytea,text)') IS NOT NULL THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('signature','extensions.digest(bytea,text)',
      'exists',to_regprocedure('extensions.digest(bytea,text)') IS NOT NULL)
  UNION ALL
  SELECT 'digest_definition_patchable',CASE WHEN patchable_rows=2 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(patchable_rows-2)::bigint,jsonb_build_object('expected',2,
      'patchableRows',patchable_rows,'alreadyQualifiedRows',qualified_rows,
      'unqualifiedRows',unqualified_rows)
  FROM (SELECT count(*) FILTER(WHERE qualified OR occurrence_count=1) patchable_rows,
      count(*) FILTER(WHERE qualified) qualified_rows,
      count(*) FILTER(WHERE NOT qualified AND occurrence_count=1) unqualified_rows
    FROM (SELECT pg_get_functiondef(to_regprocedure(signature))
        LIKE '%extensions.digest(convert_to(%' qualified,
      (length(pg_get_functiondef(to_regprocedure(signature)))
        -length(replace(pg_get_functiondef(to_regprocedure(signature)),
          'digest(convert_to(','')))/length('digest(convert_to(') occurrence_count
      FROM routines) definitions) tally
  UNION ALL
  SELECT 'failed_behavior_left_no_runtime_rows',CASE WHEN row_count=0 THEN 'PASS' ELSE 'BLOCKER' END,
    row_count::bigint,jsonb_build_object('rowCount',row_count)
  FROM (SELECT (SELECT count(*) FROM public.backoffice_sales_invoices)
    +(SELECT count(*) FROM public.backoffice_sales_invoice_operations)
    +(SELECT count(*) FROM public.backoffice_sales_invoice_audit) row_count) tally
)
SELECT * FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 ELSE 2 END,check_name;
