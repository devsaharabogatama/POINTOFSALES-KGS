-- ACP-6G postflight. SAFETY: SELECT-only; aggregate metadata only.

WITH expected_relations(relation_name) AS (VALUES
  ('payment_methods'),('payment_method_store_assignments'),
  ('payment_method_master_audit')
), expected_routines(signature) AS (VALUES
  ('public.get_finance_payment_methods()'),
  ('public.get_pos_payment_method_references(uuid)'),
  ('public.get_finance_expense_payment_method_references()'),
  ('public.export_finance_payment_methods()'),
  ('public.save_payment_method(uuid,bigint,text,text,text,text,boolean,boolean,uuid[],text,boolean,text,text,numeric,numeric,text,text,timestamp with time zone,timestamp with time zone,boolean)'),
  ('public.save_payment_method(uuid,bigint,text,text,text,boolean,boolean,uuid[],text,boolean,text,text,numeric,numeric,text,text,timestamp with time zone,timestamp with time zone,boolean)')
), save_routines AS (
  SELECT procedure.oid,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname='save_payment_method'
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813130000'

  UNION ALL SELECT 'payment_method_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE enforcement_status<>'ENFORCED'),
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='finance.payment_methods'

  UNION ALL SELECT 'required_payment_method_routines',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE to_regprocedure(signature) IS NULL),
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(signature)
      FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB))
  FROM expected_routines

  UNION ALL SELECT 'payment_method_runtime_permission_hooks',
    CASE WHEN count(*)=2 AND count(*) FILTER(WHERE definition ILIKE
      '%acp_require_permission_capability%')=2 THEN 'PASS' ELSE 'FAIL' END,
    2-count(*) FILTER(WHERE definition ILIKE
      '%acp_require_permission_capability%'),
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'))
  FROM save_routines

  UNION ALL SELECT 'browser_payment_method_table_boundary',
    CASE WHEN count(*) FILTER(WHERE readable OR writable)=0
      THEN 'PASS' ELSE 'FAIL' END,count(*) FILTER(WHERE readable OR writable),
    jsonb_build_object('readable',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE readable),'[]'::JSONB),'writable',COALESCE(
      jsonb_agg(relation_name) FILTER(WHERE writable),'[]'::JSONB))
  FROM (SELECT relation_name,has_table_privilege('authenticated',
      format('public.%I',relation_name),'SELECT') readable,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'INSERT,UPDATE,DELETE') writable FROM expected_relations) privilege_state

  UNION ALL SELECT 'private_payment_method_core_boundary',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE
      has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE')),
    jsonb_build_object('core_rows',count(*))
  FROM pg_proc procedure WHERE procedure.pronamespace='private'::regnamespace
    AND procedure.proname='acp6g_save_payment_method_core'

  UNION ALL SELECT 'payment_method_audit_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('method_count',count(*))
  FROM public.payment_methods method WHERE NOT EXISTS(SELECT 1
    FROM public.payment_method_master_audit audit
    WHERE audit.company_id=method.company_id
      AND audit.payment_method_id=method.id)

  UNION ALL SELECT 'payment_method_audit_immutable_trigger',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
    jsonb_build_object('trigger_rows',count(*))
  FROM pg_trigger trigger_row
  WHERE trigger_row.tgrelid='public.payment_method_master_audit'::regclass
    AND trigger_row.tgname='acp6g_payment_method_audit_immutable'
    AND trigger_row.tgenabled<>'D'

  UNION ALL SELECT 'active_company_default_payment_method_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('company_count',count(*))
  FROM public.companies company WHERE company.status='ACTIVE'
    AND (SELECT count(*) FROM public.payment_methods method
      WHERE method.company_id=company.id AND method.is_active
        AND method.is_default)<>1

  UNION ALL SELECT 'payment_method_sales_snapshot_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('payment_count',count(*))
  FROM public.sales_payments payment WHERE payment.payment_method_id IS NOT NULL
    AND (btrim(COALESCE(payment.payment_method_code_snapshot,''))=''
      OR btrim(COALESCE(payment.payment_method_name_snapshot,''))=''
      OR btrim(COALESCE(payment.payment_method_type_snapshot,''))=''
      OR btrim(COALESCE(payment.settlement_route_snapshot,''))='')

  UNION ALL SELECT 'payment_method_runtime_inventory','INFO',0,
    jsonb_build_object('methods',(SELECT count(*) FROM public.payment_methods),
      'active',(SELECT count(*) FROM public.payment_methods WHERE is_active),
      'system',(SELECT count(*) FROM public.payment_methods
        WHERE is_system_method),'assignments',(SELECT count(*)
        FROM public.payment_method_store_assignments),'auditRows',
        (SELECT count(*) FROM public.payment_method_master_audit),
      'overrideRows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='finance.payment_methods'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
