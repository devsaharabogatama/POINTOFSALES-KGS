-- Read-only structure/security verification, not behavioral proof.
WITH core AS (SELECT routine.oid,routine.prosecdef,routine.proconfig,pg_get_functiondef(routine.oid) body
FROM pg_proc routine WHERE routine.oid=to_regprocedure(
  'private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)')), checks AS (
SELECT 'dp_fix_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
  jsonb_build_object('ledgerRows',count(*)) details FROM private.kgs_schema_migrations WHERE version='20260915100000'
UNION ALL SELECT 'dp_fix_marker_and_rejection',CASE WHEN count(*)=1 AND bool_and(
  position($m$CASE WHEN v_type='DOWN_PAYMENT' THEN '' ELSE v_overage::text END$m$ in body)>0
  AND position($m$(v_type='DOWN_PAYMENT' AND jsonb_array_length(v_overage)>0)$m$ in body)>0
  AND position($m$BACKOFFICE_INVOICE_DELIVERY_FEE_NOT_ALLOWED_ON_DP$m$ in body)>0)
  THEN 'PASS' ELSE 'FAIL' END,jsonb_build_object('coreRows',count(*)) FROM core
UNION ALL SELECT 'dp_fix_private_security',CASE WHEN count(*)=1 AND bool_and(prosecdef
  AND proconfig @> ARRAY['search_path=public, pg_temp']
  AND NOT has_function_privilege('anon',oid,'EXECUTE')
  AND NOT has_function_privilege('authenticated',oid,'EXECUTE')) THEN 'PASS' ELSE 'FAIL' END,
  jsonb_build_object('coreRows',count(*)) FROM core
) SELECT check_name,status,CASE WHEN status='PASS' THEN 0 ELSE 1 END violation_rows,details FROM checks;
