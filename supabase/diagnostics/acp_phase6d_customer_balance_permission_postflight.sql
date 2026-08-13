-- ACP-6D postflight: Customer Balance capability closure.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH expected_relations(relation_name) AS (VALUES
  ('customer_balance_company_policies'),
  ('customer_balance_correction_requests'),
  ('customer_balance_ledger_entries'),('customer_balance_audit')
), expected_routines(signature) AS (VALUES
  ('public.get_finance_customer_balances()'),
  ('public.export_finance_customer_balances(timestamp with time zone,timestamp with time zone)'),
  ('public.request_customer_balance_correction(uuid,uuid,text,numeric,text,text,text,uuid)'),
  ('public.review_customer_balance_correction(uuid,bigint,text,text,uuid)'),
  ('public.get_customer_balance_statement(uuid,timestamp with time zone,timestamp with time zone)')
), guarded_routines AS (
  SELECT procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure WHERE procedure.oid IN(
    to_regprocedure('public.get_finance_customer_balances()'),
    to_regprocedure('public.export_finance_customer_balances(timestamp with time zone,timestamp with time zone)'),
    to_regprocedure('public.request_customer_balance_correction(uuid,uuid,text,numeric,text,text,text,uuid)'),
    to_regprocedure('public.review_customer_balance_correction(uuid,bigint,text,text,uuid)'),
    to_regprocedure('public.get_customer_balance_statement(uuid,timestamp with time zone,timestamp with time zone)'))
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*) FILTER(WHERE version<>'20260813090000') violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813090000'

  UNION ALL SELECT 'wind_down_compatibility_ledger',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE version<>'20260813100000'),
    jsonb_build_object('ledger_rows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260813100000'

  UNION ALL SELECT 'customer_balance_wind_down_permission_contract',
    CASE WHEN count(*)=1 AND bool_and(definition ILIKE
      '%finance.customer_balances%WIND_DOWN%'
      AND definition ILIKE '%historyOnly%'
      AND definition ILIKE '%VIEW%EXPORT%')
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE definition NOT ILIKE
      '%finance.customer_balances%WIND_DOWN%'
      OR definition NOT ILIKE '%historyOnly%'
      OR definition NOT ILIKE '%VIEW%EXPORT%'),
    jsonb_build_object('routine_rows',count(*),'wind_down_aware_rows',
      count(*) FILTER(WHERE definition ILIKE
        '%finance.customer_balances%WIND_DOWN%'))
  FROM (SELECT pg_get_functiondef(procedure.oid) definition
    FROM pg_proc procedure
    WHERE procedure.oid=to_regprocedure(
      'private.acp_resolve_permission(uuid,uuid,text)')) resolver

  UNION ALL SELECT 'customer_balance_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE enforcement_status<>'ENFORCED'),
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='finance.customer_balances'

  UNION ALL SELECT 'required_customer_balance_routines',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE to_regprocedure(signature) IS NULL),
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(signature)
      FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB))
  FROM expected_routines

  UNION ALL SELECT 'customer_balance_runtime_permission_hooks',
    CASE WHEN count(*)=5 AND count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%')=5
      THEN 'PASS' ELSE 'FAIL' END,
    5-count(*) FILTER(WHERE definition ILIKE
      '%acp_require_permission_capability%'),
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'))
  FROM guarded_routines

  UNION ALL SELECT 'browser_customer_balance_table_boundary',
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

  UNION ALL SELECT 'private_customer_balance_core_boundary',
    CASE WHEN count(*)=3 AND count(*) FILTER(WHERE
      has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE')),
    jsonb_build_object('core_rows',count(*))
  FROM pg_proc procedure WHERE procedure.pronamespace='private'::regnamespace
    AND procedure.proname LIKE 'acp6d_%_core'

  UNION ALL SELECT 'customer_balance_cache_ledger_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('customer_count',count(*))
  FROM public.customers customer
  WHERE customer.current_balance<>COALESCE((SELECT sum(CASE
    WHEN entry.direction='CREDIT' THEN entry.amount ELSE -entry.amount END)
    FROM public.customer_balance_ledger_entries entry
    WHERE entry.company_id=customer.company_id
      AND entry.customer_id=customer.id),0)

  UNION ALL SELECT 'customer_balance_maker_checker_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('request_count',count(*))
  FROM public.customer_balance_correction_requests request
  WHERE request.status IN('APPROVED','REJECTED')
    AND request.created_by=request.reviewed_by

  UNION ALL SELECT 'customer_balance_source_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('entry_count',count(*))
  FROM public.customer_balance_ledger_entries entry
  WHERE (entry.source_type='MANUAL_CORRECTION' AND NOT EXISTS(SELECT 1
      FROM public.customer_balance_correction_requests request
      WHERE request.company_id=entry.company_id AND request.id=entry.source_id
        AND request.status='APPROVED' AND request.ledger_entry_id=entry.id))
    OR (entry.source_type IN('SALE_OVERPAYMENT','SALE_PAYMENT')
      AND NOT EXISTS(SELECT 1 FROM public.sales_payments payment
      WHERE payment.company_id=entry.company_id AND payment.id=entry.source_id
        AND NOT payment.is_reversal))

  UNION ALL SELECT 'customer_balance_runtime_inventory','INFO',0,
    jsonb_build_object(
      'active_policies',(SELECT count(*)
        FROM public.customer_balance_company_policies
        WHERE lifecycle_state='ACTIVE'),
      'customers_with_balance',(SELECT count(*) FROM public.customers
        WHERE current_balance>0),
      'balance_total',(SELECT COALESCE(sum(current_balance),0)
        FROM public.customers),
      'requests',(SELECT count(*)
        FROM public.customer_balance_correction_requests),
      'submitted_requests',(SELECT count(*)
        FROM public.customer_balance_correction_requests
        WHERE status='SUBMITTED'),
      'ledger_entries',(SELECT count(*)
        FROM public.customer_balance_ledger_entries),
      'override_rows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='finance.customer_balances'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
