-- Read-only verification for 20260917110000.
WITH required_relations(name) AS (VALUES
  ('backoffice_sales_returns'),('backoffice_sales_return_lines'),
  ('backoffice_sales_return_operations'),('backoffice_sales_return_audit')
), required_routines(signature) AS (VALUES
  ('private.trg_guard_backoffice_sales_return_history()'),
  ('private.backoffice_sales_return_snapshot(uuid,uuid)'),
  ('private.backoffice_sales_return_operation_retry(uuid,uuid,text,text)'),
  ('private.assert_backoffice_sales_return_quantities(uuid,uuid,uuid)'),
  ('private.transition_backoffice_sales_return(uuid,bigint,uuid,text,text)'),
  ('public.get_backoffice_sales_returns(text,text,integer)'),
  ('public.get_backoffice_sales_return(uuid)'),
  ('public.get_backoffice_sales_return_source(uuid)'),
  ('public.save_backoffice_sales_return_draft(uuid,bigint,uuid,uuid,jsonb)'),
  ('public.submit_backoffice_sales_return(uuid,bigint,uuid)'),
  ('public.approve_backoffice_sales_return(uuid,bigint,uuid)'),
  ('public.cancel_backoffice_sales_return(uuid,bigint,uuid,text)')
), checks AS (
  SELECT 'return_commercial_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,abs(1-count(*)) violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260917110000'
  UNION ALL
  SELECT 'return_commercial_relation_contract',
    CASE WHEN count(*) FILTER(WHERE to_regclass('public.'||name) IS NOT NULL)=4 THEN 'PASS' ELSE 'BLOCKER' END,
    4-count(*) FILTER(WHERE to_regclass('public.'||name) IS NOT NULL),
    jsonb_build_object('present',count(*) FILTER(WHERE to_regclass('public.'||name) IS NOT NULL),'expected',4,
      'missing',COALESCE(jsonb_agg(name) FILTER(WHERE to_regclass('public.'||name) IS NULL),'[]'::jsonb))
  FROM required_relations
  UNION ALL
  SELECT 'return_commercial_routine_contract',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NOT NULL)=12 THEN 'PASS' ELSE 'BLOCKER' END,
    12-count(*) FILTER(WHERE to_regprocedure(signature) IS NOT NULL),
    jsonb_build_object('present',count(*) FILTER(WHERE to_regprocedure(signature) IS NOT NULL),'expected',12,
      'missing',COALESCE(jsonb_agg(signature) FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::jsonb))
  FROM required_routines
  UNION ALL
  SELECT 'return_commercial_permission_contract',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED'
      AND operator_roles @> ARRAY['SALES','SALES_ADMIN']::text[]
      AND NOT(operator_roles @> ARRAY['FINANCE']::text[])
      AND approver_roles @> ARRAY['SALES_ADMIN','FINANCE']::text[]
      AND NOT(approver_roles @> ARRAY['SALES']::text[])) THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED'
      AND operator_roles @> ARRAY['SALES','SALES_ADMIN']::text[]
      AND NOT(operator_roles @> ARRAY['FINANCE']::text[])
      AND approver_roles @> ARRAY['SALES_ADMIN','FINANCE']::text[]
      AND NOT(approver_roles @> ARRAY['SALES']::text[])) THEN 0 ELSE 1 END,
    jsonb_build_object('permissionRows',count(*),'financeApprover',
      COALESCE(bool_or(approver_roles @> ARRAY['FINANCE']::text[]),false),
      'financeOperator',COALESCE(bool_or(operator_roles @> ARRAY['FINANCE']::text[]),false))
  FROM public.access_permission_catalog WHERE permission_key='sales.backoffice_returns'
  UNION ALL
  SELECT 'return_commercial_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges
  WHERE specific_schema='private' AND grantee='authenticated'
    AND routine_name IN('trg_guard_backoffice_sales_return_history',
      'backoffice_sales_return_snapshot','backoffice_sales_return_operation_retry',
      'assert_backoffice_sales_return_quantities','transition_backoffice_sales_return')
  UNION ALL
  SELECT 'return_commercial_public_boundary',
    CASE WHEN count(*) FILTER(WHERE grantee='anon')=0
      AND count(*) FILTER(WHERE grantee='authenticated')=7 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE grantee='anon')+abs(7-count(*) FILTER(WHERE grantee='authenticated')),
    jsonb_build_object('anonExecute',count(*) FILTER(WHERE grantee='anon'),
      'authenticatedExecute',count(*) FILTER(WHERE grantee='authenticated'))
  FROM information_schema.routine_privileges
  WHERE specific_schema='public' AND privilege_type='EXECUTE'
    AND routine_name IN('get_backoffice_sales_returns','get_backoffice_sales_return',
      'get_backoffice_sales_return_source','save_backoffice_sales_return_draft',
      'submit_backoffice_sales_return','approve_backoffice_sales_return',
      'cancel_backoffice_sales_return')
  UNION ALL
  SELECT 'return_commercial_quantity_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_returns document
  WHERE document.total_requested_base_qty<>(SELECT COALESCE(sum(line.requested_base_qty),0)
    FROM public.backoffice_sales_return_lines line
    WHERE line.company_id=document.company_id AND line.return_id=document.id)
  UNION ALL
  SELECT 'return_commercial_runtime_inventory','INFO',0,
    jsonb_build_object('returns',count(*),'statuses',COALESCE(jsonb_agg(
      jsonb_build_object('status',status,'rows',rows) ORDER BY status),'[]'::jsonb))
  FROM (SELECT status,count(*) rows FROM public.backoffice_sales_returns GROUP BY status) inventory
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
