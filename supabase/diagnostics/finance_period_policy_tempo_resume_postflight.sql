-- Finance period policy + TEMPO resume postflight. SELECT-only.
WITH function_state AS (
  SELECT namespace.nspname schema_name,procedure.proname,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname) IN(
    ('public','get_finance_company_policy'),
    ('public','save_finance_company_policy'),
    ('public','save_pos_sale_draft_with_pricelist'),
    ('public','list_pos_sale_drafts'),
    ('private','ensure_company_accounting_periods'),
    ('private','validate_pos_tempo_effective_dates'))
), checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260827090000'
  UNION ALL
  SELECT 'required_policy_schema',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,abs(2-count(*)),
    jsonb_build_object('expected',2,'relationRows',count(*))
  FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname IN(
    'finance_company_policies','finance_company_policy_audit')
  UNION ALL
  SELECT 'required_policy_tempo_routines',
    CASE WHEN count(*)=6 THEN 'PASS' ELSE 'FAIL' END,abs(6-count(*)),
    jsonb_build_object('expected',6,'routineRows',count(*)) FROM function_state
  UNION ALL
  SELECT 'company_policy_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('companyCount',count(*))
  FROM public.companies company LEFT JOIN public.finance_company_policies policy
    ON policy.company_id=company.id WHERE policy.company_id IS NULL
  UNION ALL
  SELECT 'tempo_resume_intent_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*)) FROM function_state
  WHERE schema_name='public' AND proname='save_pos_sale_draft_with_pricelist'
    AND definition LIKE '%transactionDateIntent%'
    AND definition LIKE '%PRESERVE%'
  UNION ALL
  SELECT 'tempo_business_date_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*)) FROM function_state
  WHERE schema_name='private' AND proname='validate_pos_tempo_effective_dates'
    AND definition LIKE '%v_due_date%'
    AND definition LIKE '%ensure_company_accounting_periods%'
  UNION ALL
  SELECT 'browser_policy_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('directWriteRelations',COALESCE(jsonb_agg(table_name),'[]'::JSONB))
  FROM information_schema.role_table_grants
  WHERE grantee='authenticated' AND table_schema='public'
    AND table_name IN('finance_company_policies','finance_company_policy_audit')
    AND privilege_type IN('INSERT','UPDATE','DELETE')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 ELSE 1 END,check_name;
