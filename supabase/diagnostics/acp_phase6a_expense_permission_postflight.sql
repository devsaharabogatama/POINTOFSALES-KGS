-- ACP-6A postflight: Expense capability and Cashier-channel closure.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH expected_relations(relation_name) AS (VALUES
  ('expense_categories'),('expense_approval_policies'),('expense_documents'),
  ('expense_disbursements'),('expense_returns'),('expense_settlement_requests'),
  ('expense_settlements'),('expense_additional_disbursement_requests'),
  ('expense_audit')
), expected_routines(signature) AS (VALUES
  ('public.get_finance_expenses(text)'),
  ('public.get_pos_expense_categories(uuid)'),
  ('public.get_pos_expense_workspace(uuid)'),
  ('public.save_expense_category(uuid,bigint,text,text,uuid,uuid,text,text,uuid,boolean)'),
  ('public.save_expense_approval_policy(uuid,bigint,boolean,boolean)'),
  ('public.save_expense_draft(uuid,bigint,uuid,uuid,uuid,text,uuid,text,numeric,uuid,text,text,text,date,uuid)'),
  ('public.submit_expense_request(uuid,bigint)'),
  ('public.review_expense_request(uuid,bigint,boolean,text)'),
  ('public.cancel_expense_request(uuid,bigint,text)'),
  ('public.disburse_expense(uuid,bigint,uuid,text,uuid)'),
  ('public.save_expense_settlement(uuid,bigint,numeric,text,uuid)'),
  ('public.review_expense_settlement(uuid,bigint,text,text)'),
  ('public.return_expense_funds(uuid,bigint,numeric,uuid,uuid,text,uuid)'),
  ('public.request_additional_expense_disbursement(uuid,bigint,numeric,uuid,text,uuid)'),
  ('public.review_additional_expense_disbursement(uuid,bigint,text,text)'),
  ('public.disburse_additional_expense(uuid,bigint,bigint,uuid,text,uuid)')
), mutation_routines AS (
  SELECT procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure WHERE procedure.oid IN(
    to_regprocedure('public.save_expense_category(uuid,bigint,text,text,uuid,uuid,text,text,uuid,boolean)'),
    to_regprocedure('public.save_expense_approval_policy(uuid,bigint,boolean,boolean)'),
    to_regprocedure('public.save_expense_draft(uuid,bigint,uuid,uuid,uuid,text,uuid,text,numeric,uuid,text,text,text,date,uuid)'),
    to_regprocedure('public.submit_expense_request(uuid,bigint)'),
    to_regprocedure('public.review_expense_request(uuid,bigint,boolean,text)'),
    to_regprocedure('public.cancel_expense_request(uuid,bigint,text)'),
    to_regprocedure('public.disburse_expense(uuid,bigint,uuid,text,uuid)'),
    to_regprocedure('public.save_expense_settlement(uuid,bigint,numeric,text,uuid)'),
    to_regprocedure('public.review_expense_settlement(uuid,bigint,text,text)'),
    to_regprocedure('public.return_expense_funds(uuid,bigint,numeric,uuid,uuid,text,uuid)'),
    to_regprocedure('public.request_additional_expense_disbursement(uuid,bigint,numeric,uuid,text,uuid)'),
    to_regprocedure('public.review_additional_expense_disbursement(uuid,bigint,text,text)'),
    to_regprocedure('public.disburse_additional_expense(uuid,bigint,bigint,uuid,text,uuid)'))
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*) FILTER(WHERE version<>'20260813060000') violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813060000'

  UNION ALL SELECT 'expense_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      AND bool_and('MANAGE'=ANY(supported_capabilities)) THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE enforcement_status<>'ENFORCED'
      OR NOT ('MANAGE'=ANY(supported_capabilities))),
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog WHERE permission_key='finance.expenses'

  UNION ALL SELECT 'required_expense_routines',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE to_regprocedure(signature) IS NULL),
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(signature)
      FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB))
  FROM expected_routines

  UNION ALL SELECT 'expense_runtime_permission_hooks',
    CASE WHEN count(*)=13 AND count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%'
      OR definition ILIKE '%acp_require_expense_channel_mutation%')=13
      THEN 'PASS' ELSE 'FAIL' END,
    13-count(*) FILTER(WHERE definition ILIKE '%acp_require_permission_capability%'
      OR definition ILIKE '%acp_require_expense_channel_mutation%'),
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        OR definition ILIKE '%acp_require_expense_channel_mutation%'))
  FROM mutation_routines

  UNION ALL SELECT 'cashier_expense_workspace_contract',
    CASE WHEN count(*)=1 AND bool_and(definition ILIKE '%cashier_sessions%'
      AND definition ILIKE '%OPEN%' AND definition ILIKE '%cashier_id%')
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE definition NOT ILIKE '%cashier_sessions%'
      OR definition NOT ILIKE '%OPEN%' OR definition NOT ILIKE '%cashier_id%'),
    jsonb_build_object('routine_rows',count(*))
  FROM (SELECT pg_get_functiondef(procedure.oid) definition FROM pg_proc procedure
    WHERE procedure.oid=to_regprocedure(
      'public.get_pos_expense_workspace(uuid)')) workspace

  UNION ALL SELECT 'browser_expense_table_boundary',
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

  UNION ALL SELECT 'private_expense_core_boundary',
    CASE WHEN count(*)=13 AND count(*) FILTER(WHERE
      has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE')),
    jsonb_build_object('core_rows',count(*))
  FROM pg_proc procedure WHERE procedure.pronamespace='private'::regnamespace
    AND procedure.proname LIKE 'acp6a_%_core'

  UNION ALL SELECT 'expense_finance_hold_preserved',
    CASE WHEN count(*) FILTER(WHERE status<>'HOLD')=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE status<>'HOLD'),
    jsonb_build_object('hold_events',count(*) FILTER(WHERE status='HOLD'))
  FROM public.financial_events WHERE event_type IN(
    'EXPENSE_DISBURSEMENT','EXPENSE_SETTLEMENT','EXPENSE_RETURN',
    'EXPENSE_ADDITIONAL_DISBURSEMENT')

  UNION ALL SELECT 'expense_runtime_inventory','INFO',0,
    jsonb_build_object('documents',(SELECT count(*) FROM public.expense_documents),
      'approved',(SELECT count(*) FROM public.expense_documents WHERE status='APPROVED'),
      'open_outstanding',(SELECT count(*) FROM public.expense_documents
        WHERE status IN('DISBURSED','PARTIALLY_SETTLED') AND outstanding_amount>0),
      'override_rows',(SELECT count(*) FROM public.user_company_permission_overrides
        WHERE permission_key='finance.expenses'),
      'cash_drawer_shared_select_preserved',has_table_privilege(
        'authenticated','public.cash_drawer_movements','SELECT'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

