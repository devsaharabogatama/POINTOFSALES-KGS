-- G6 phase 6A postflight: POSTED-only Trial Balance and General Ledger.
-- SAFETY: one aggregate SELECT; no routine execution or mutation.

WITH expected_tables(name) AS (VALUES
 ('finance_report_definitions'),('finance_report_versions'),('finance_report_lines'),
 ('finance_report_exports'),('finance_report_audit')
), expected_routines(name) AS (VALUES('get_finance_trial_balance'),('get_finance_general_ledger')),
checks AS (
 SELECT 'migration_ledger'::TEXT check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
 abs(count(*)-1) violation_rows,jsonb_build_object('ledger_rows',count(*)) details
 FROM private.kgs_schema_migrations WHERE version='20260810220000'
 UNION ALL
 SELECT 'required_report_tables',CASE WHEN count(relation.oid)=count(*) THEN 'PASS' ELSE 'FAIL' END,
 count(*)-count(relation.oid),jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(expected.name ORDER BY expected.name) FILTER(WHERE relation.oid IS NULL),'[]'::JSONB))
 FROM expected_tables expected LEFT JOIN pg_namespace namespace ON namespace.nspname='public'
 LEFT JOIN pg_class relation ON relation.relnamespace=namespace.oid AND relation.relname=expected.name AND relation.relkind IN('r','p')
 UNION ALL
 SELECT 'required_report_routines',CASE WHEN count(routine.oid)=count(*) THEN 'PASS' ELSE 'FAIL' END,
 count(*)-count(routine.oid),jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(expected.name ORDER BY expected.name) FILTER(WHERE routine.oid IS NULL),'[]'::JSONB))
 FROM expected_routines expected LEFT JOIN pg_namespace namespace ON namespace.nspname='public'
 LEFT JOIN pg_proc routine ON routine.pronamespace=namespace.oid AND routine.proname=expected.name
 UNION ALL
 SELECT 'report_rls',CASE WHEN count(*) FILTER(WHERE NOT relation.relrowsecurity)=0 THEN 'PASS' ELSE 'FAIL' END,
 count(*) FILTER(WHERE NOT relation.relrowsecurity),jsonb_build_object('table_rows',count(*))
 FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
 WHERE namespace.nspname='public' AND relation.relname IN(SELECT name FROM expected_tables)
 UNION ALL
 SELECT 'browser_report_write_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
 jsonb_build_object('writable_relations',COALESCE(jsonb_agg(relation.relname ORDER BY relation.relname),'[]'::JSONB))
 FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
 WHERE namespace.nspname='public' AND relation.relname IN(SELECT name FROM expected_tables)
 AND has_table_privilege('authenticated',relation.oid,'INSERT,UPDATE,DELETE')
 UNION ALL
 SELECT 'report_rpc_boundary',CASE WHEN count(*) FILTER(WHERE has_function_privilege('anon',routine.oid,'EXECUTE')
 OR NOT has_function_privilege('authenticated',routine.oid,'EXECUTE'))=0 THEN 'PASS' ELSE 'FAIL' END,
 count(*) FILTER(WHERE has_function_privilege('anon',routine.oid,'EXECUTE')
 OR NOT has_function_privilege('authenticated',routine.oid,'EXECUTE')),jsonb_build_object('routine_rows',count(*))
 FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
 WHERE namespace.nspname='public' AND routine.proname IN(SELECT name FROM expected_routines)
 UNION ALL
 SELECT 'active_company_report_provisioning',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
 jsonb_build_object('company_count',count(*)) FROM(
  SELECT company.id FROM public.companies company LEFT JOIN public.finance_report_definitions definition
  ON definition.company_id=company.id AND definition.report_code IN('TRIAL_BALANCE','GENERAL_LEDGER') AND definition.is_active
  WHERE company.status='ACTIVE' GROUP BY company.id HAVING count(definition.id)<>2
 ) invalid
 UNION ALL
 SELECT 'active_report_version_provisioning',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
 jsonb_build_object('definition_count',count(*)) FROM(
  SELECT definition.id FROM public.finance_report_definitions definition LEFT JOIN public.finance_report_versions version
  ON version.company_id=definition.company_id AND version.report_definition_id=definition.id AND version.status='ACTIVE' AND version.effective_to IS NULL
  WHERE definition.report_code IN('TRIAL_BALANCE','GENERAL_LEDGER') AND definition.is_active
  GROUP BY definition.id HAVING count(version.id)<>1
 ) invalid
 UNION ALL
 SELECT 'posted_only_report_contract',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-2),
 jsonb_build_object('routine_rows',count(*)) FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
 WHERE namespace.nspname='public' AND routine.proname IN(SELECT name FROM expected_routines)
 AND pg_get_functiondef(routine.oid) ILIKE '%status=''POSTED''%'
 AND pg_get_functiondef(routine.oid) ILIKE '%private_active_company_id%'
 AND pg_get_functiondef(routine.oid) ILIKE '%FINANCE_REPORT_ROLE_REQUIRED%'
 UNION ALL
 SELECT 'report_history_triggers',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-3),
 jsonb_build_object('trigger_rows',count(*)) FROM pg_trigger trigger_state
 WHERE trigger_state.tgname IN('g6_guard_report_version_history','g6_guard_report_line_history','g6_guard_report_audit_history')
 AND NOT trigger_state.tgisinternal AND trigger_state.tgenabled<>'D'
 UNION ALL
 SELECT 'report_export_baseline','PASS',0,jsonb_build_object('export_rows',count(*)) FROM public.finance_report_exports
 UNION ALL
 SELECT 'financial_history_unchanged',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
 jsonb_build_object('report_linked_journals',count(*)) FROM public.finance_journals WHERE source_type LIKE 'finance_report_%'
 UNION ALL
 SELECT 'phase6a_runtime_inventory','INFO',0,jsonb_build_object(
  'definitions',(SELECT count(*) FROM public.finance_report_definitions),
  'active_versions',(SELECT count(*) FROM public.finance_report_versions WHERE status='ACTIVE'),
  'posted_journals',(SELECT count(*) FROM public.finance_journals WHERE status='POSTED'),
  'hold_events',(SELECT count(*) FROM public.financial_events WHERE status::TEXT='HOLD'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
