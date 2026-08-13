-- ACP-6B postflight: Cash Deposit capability and channel closure.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH expected_relations(relation_name) AS (VALUES
  ('cash_deposit_policies'),('cash_deposit_documents'),
  ('cash_deposit_session_lines'),('cash_deposit_audit')
), expected_routines(signature) AS (VALUES
  ('public.get_finance_cash_deposits(text)'),
  ('public.get_deposit_variance_cash_deposit_references()'),
  ('public.list_cash_deposit_eligible_sessions(uuid)'),
  ('public.save_cash_deposit_draft(uuid,bigint,uuid,text,text,numeric,timestamp with time zone,text,text,uuid,jsonb)'),
  ('public.submit_cash_deposit(uuid,bigint,uuid)'),
  ('public.review_cash_deposit(uuid,bigint,text,text,uuid)'),
  ('public.cancel_cash_deposit(uuid,bigint,text)')
), mutation_routines AS (
  SELECT procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure WHERE procedure.oid IN(
    to_regprocedure('public.list_cash_deposit_eligible_sessions(uuid)'),
    to_regprocedure('public.save_cash_deposit_draft(uuid,bigint,uuid,text,text,numeric,timestamp with time zone,text,text,uuid,jsonb)'),
    to_regprocedure('public.submit_cash_deposit(uuid,bigint,uuid)'),
    to_regprocedure('public.review_cash_deposit(uuid,bigint,text,text,uuid)'),
    to_regprocedure('public.cancel_cash_deposit(uuid,bigint,text)'))
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*) FILTER(WHERE version<>'20260813070000') violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813070000'

  UNION ALL SELECT 'cash_deposit_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE enforcement_status<>'ENFORCED'),
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='finance.cash_deposits'

  UNION ALL SELECT 'required_cash_deposit_routines',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE to_regprocedure(signature) IS NULL),
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(signature)
      FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB))
  FROM expected_routines

  UNION ALL SELECT 'cash_deposit_runtime_permission_hooks',
    CASE WHEN count(*)=5 AND count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%'
      OR definition ILIKE '%acp_require_cash_deposit_channel_mutation%')=5
      THEN 'PASS' ELSE 'FAIL' END,
    5-count(*) FILTER(WHERE definition ILIKE '%acp_require_permission_capability%'
      OR definition ILIKE '%acp_require_cash_deposit_channel_mutation%'),
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        OR definition ILIKE '%acp_require_cash_deposit_channel_mutation%'))
  FROM mutation_routines

  UNION ALL SELECT 'browser_cash_deposit_table_boundary',
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

  UNION ALL SELECT 'private_cash_deposit_core_boundary',
    CASE WHEN count(*)=5 AND count(*) FILTER(WHERE
      has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE')),
    jsonb_build_object('core_rows',count(*))
  FROM pg_proc procedure WHERE procedure.pronamespace='private'::regnamespace
    AND procedure.proname LIKE 'acp6b_%_core'

  UNION ALL SELECT 'deposit_variance_direct_read_preserved',
    CASE WHEN NOT has_table_privilege('authenticated',
      'public.cash_deposit_documents','SELECT')
      AND to_regprocedure(
        'public.get_deposit_variance_cash_deposit_references()') IS NOT NULL
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN NOT has_table_privilege('authenticated',
      'public.cash_deposit_documents','SELECT')
      AND to_regprocedure(
        'public.get_deposit_variance_cash_deposit_references()') IS NOT NULL
      THEN 0 ELSE 1 END,
    jsonb_build_object('reference_rpc_exists',to_regprocedure(
      'public.get_deposit_variance_cash_deposit_references()') IS NOT NULL)

  UNION ALL SELECT 'cash_deposit_finance_hold_preserved',
    CASE WHEN count(*) FILTER(WHERE status<>'HOLD')=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE status<>'HOLD'),
    jsonb_build_object('hold_events',count(*) FILTER(WHERE status='HOLD'))
  FROM public.financial_events WHERE event_type='BANK_DEPOSIT'

  UNION ALL SELECT 'cash_deposit_runtime_inventory','INFO',0,
    jsonb_build_object(
      'documents',(SELECT count(*) FROM public.cash_deposit_documents),
      'approved',(SELECT count(*) FROM public.cash_deposit_documents
        WHERE status='APPROVED'),
      'session_lines',(SELECT count(*) FROM public.cash_deposit_session_lines),
      'variance_documents',(SELECT count(*)
        FROM public.deposit_variance_exceptions),
      'override_rows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='finance.cash_deposits'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
