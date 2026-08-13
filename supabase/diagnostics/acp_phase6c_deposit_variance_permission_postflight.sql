-- ACP-6C postflight: Deposit Variance capability closure.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH expected_relations(relation_name) AS (VALUES
  ('deposit_variance_exceptions'),('deposit_variance_allocations'),
  ('deposit_variance_resolution_requests'),
  ('deposit_variance_resolution_audit')
), expected_routines(signature) AS (VALUES
  ('public.get_finance_deposit_variances()'),
  ('public.assign_deposit_variance_responsible_party(uuid,bigint,uuid,text)'),
  ('public.resolve_deposit_variance(uuid,bigint,numeric,text,text,text,text,text,uuid)'),
  ('public.review_deposit_variance_resolution(uuid,bigint,text,text,uuid)')
), mutation_routines AS (
  SELECT procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure WHERE procedure.oid IN(
    to_regprocedure('public.assign_deposit_variance_responsible_party(uuid,bigint,uuid,text)'),
    to_regprocedure('public.resolve_deposit_variance(uuid,bigint,numeric,text,text,text,text,text,uuid)'),
    to_regprocedure('public.review_deposit_variance_resolution(uuid,bigint,text,text,uuid)'))
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*) FILTER(WHERE version<>'20260813080000') violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813080000'

  UNION ALL SELECT 'deposit_variance_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE enforcement_status<>'ENFORCED'),
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='finance.deposit_variances'

  UNION ALL SELECT 'required_deposit_variance_routines',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE to_regprocedure(signature) IS NULL),
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(signature)
      FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB))
  FROM expected_routines

  UNION ALL SELECT 'deposit_variance_runtime_permission_hooks',
    CASE WHEN count(*)=3 AND count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%')=3
      THEN 'PASS' ELSE 'FAIL' END,
    3-count(*) FILTER(WHERE definition ILIKE
      '%acp_require_permission_capability%'),
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'))
  FROM mutation_routines

  UNION ALL SELECT 'browser_deposit_variance_table_boundary',
    CASE WHEN count(*) FILTER(WHERE readable OR writable)=0
      THEN 'PASS' ELSE 'FAIL' END,count(*) FILTER(WHERE readable OR writable),
    jsonb_build_object('readable',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE readable),'[]'::JSONB),'writable',COALESCE(
      jsonb_agg(relation_name) FILTER(WHERE writable),'[]'::JSONB))
  FROM (SELECT relation_name,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'SELECT') readable,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'INSERT,UPDATE,DELETE') writable FROM expected_relations) privilege_state

  UNION ALL SELECT 'private_deposit_variance_core_boundary',
    CASE WHEN count(*)=3 AND count(*) FILTER(WHERE
      has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE')),
    jsonb_build_object('core_rows',count(*))
  FROM pg_proc procedure WHERE procedure.pronamespace='private'::regnamespace
    AND procedure.proname LIKE 'acp6c_%_core'

  UNION ALL SELECT 'deposit_variance_request_allocation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('request_count',count(*))
  FROM public.deposit_variance_resolution_requests request
  LEFT JOIN public.deposit_variance_allocations allocation
    ON allocation.company_id=request.company_id
   AND allocation.id=request.allocation_id
  WHERE request.status='APPROVED' AND (
    allocation.id IS NULL
    OR allocation.resolution_request_id<>request.id
    OR allocation.allocation_amount<>request.allocation_amount
    OR allocation.financial_event_id<>request.financial_event_id)

  UNION ALL SELECT 'deposit_variance_maker_checker_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('request_count',count(*))
  FROM public.deposit_variance_resolution_requests request
  WHERE request.requires_review AND request.status IN('APPROVED','REJECTED')
    AND request.created_by=request.reviewed_by

  UNION ALL SELECT 'deposit_variance_finance_hold_preserved',
    CASE WHEN count(*) FILTER(WHERE status<>'HOLD')=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE status<>'HOLD'),
    jsonb_build_object('hold_events',count(*) FILTER(WHERE status='HOLD'))
  FROM public.financial_events
  WHERE event_type='DEPOSIT_VARIANCE_RESOLUTION'

  UNION ALL SELECT 'deposit_variance_runtime_inventory','INFO',0,
    jsonb_build_object(
      'exceptions',(SELECT count(*) FROM public.deposit_variance_exceptions),
      'open_exceptions',(SELECT count(*)
        FROM public.deposit_variance_exceptions
        WHERE status IN('OPEN','UNDER_INVESTIGATION','PARTIALLY_RESOLVED')),
      'requests',(SELECT count(*)
        FROM public.deposit_variance_resolution_requests),
      'submitted_requests',(SELECT count(*)
        FROM public.deposit_variance_resolution_requests
        WHERE status='SUBMITTED'),
      'allocations',(SELECT count(*) FROM public.deposit_variance_allocations),
      'override_rows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='finance.deposit_variances'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
