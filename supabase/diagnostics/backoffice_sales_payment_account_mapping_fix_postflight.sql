-- SELECT-only verification for 20260911161000.
WITH required_functions(function_key) AS (
  VALUES ('CASH_DRAWER'::text),('BANK'::text),('CUSTOMER_RECEIVABLE'::text)
), mapping_state AS (
  SELECT company.id company_id,required.function_key,
    count(fallback.id) current_fallbacks,
    count(fallback.id) FILTER(WHERE account.id IS NULL) invalid_accounts
  FROM public.companies company CROSS JOIN required_functions required
  LEFT JOIN public.account_functions function_state
    ON function_state.function_key=required.function_key AND function_state.is_active
  LEFT JOIN public.company_account_function_fallbacks fallback
    ON fallback.company_id=company.id
   AND fallback.account_function_key=required.function_key
   AND fallback.status='ACTIVE'
   AND fallback.effective_from<=clock_timestamp()
   AND (fallback.effective_to IS NULL
     OR fallback.effective_to>clock_timestamp())
  LEFT JOIN public.chart_of_accounts account
    ON account.company_id=fallback.company_id AND account.id=fallback.account_id
   AND account.is_active AND account.is_postable
   AND account.account_type=ANY(function_state.compatible_account_types)
  WHERE company.status='ACTIVE'
  GROUP BY company.id,required.function_key
), checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260911161000'

  UNION ALL
  SELECT 'customer_receipt_mapping_routine_contract',
    CASE WHEN to_regprocedure(
      'private.provision_customer_receipt_account_fallbacks(uuid,uuid)') IS NOT NULL
      AND to_regprocedure(
        'private.trg_provision_customer_receipt_account_fallbacks()') IS NOT NULL
      THEN 'PASS' ELSE 'FAIL' END,
    (CASE WHEN to_regprocedure(
      'private.provision_customer_receipt_account_fallbacks(uuid,uuid)') IS NULL THEN 1 ELSE 0 END
      +CASE WHEN to_regprocedure(
        'private.trg_provision_customer_receipt_account_fallbacks()') IS NULL THEN 1 ELSE 0 END)::bigint,
    jsonb_build_object('provisioner',to_regprocedure(
      'private.provision_customer_receipt_account_fallbacks(uuid,uuid)') IS NOT NULL,
      'triggerFunction',to_regprocedure(
        'private.trg_provision_customer_receipt_account_fallbacks()') IS NOT NULL)

  UNION ALL
  SELECT 'customer_receipt_mapping_security_contract',
    CASE WHEN count(*)=2 AND bool_and(proc.prosecdef)
      AND bool_and(COALESCE(proc.proconfig,'{}'::text[])
        @> ARRAY['search_path=public, pg_temp']::text[])
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=2 AND bool_and(proc.prosecdef)
      AND bool_and(COALESCE(proc.proconfig,'{}'::text[])
        @> ARRAY['search_path=public, pg_temp']::text[]) THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*),'securityDefiner',bool_and(proc.prosecdef),
      'safeSearchPath',bool_and(COALESCE(proc.proconfig,'{}'::text[])
        @> ARRAY['search_path=public, pg_temp']::text[]))
  FROM pg_proc proc WHERE proc.oid IN(
    to_regprocedure('private.provision_customer_receipt_account_fallbacks(uuid,uuid)'),
    to_regprocedure('private.trg_provision_customer_receipt_account_fallbacks()'))

  UNION ALL
  SELECT 'customer_receipt_mapping_trigger_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-1)::bigint,
    jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger trigger_row
  WHERE trigger_row.tgrelid='public.companies'::regclass
    AND trigger_row.tgname='payment_provision_customer_receipt_fallbacks'
    AND NOT trigger_row.tgisinternal AND trigger_row.tgenabled<>'D'

  UNION ALL
  SELECT 'customer_receipt_mapping_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM (VALUES
    ('private.provision_customer_receipt_account_fallbacks(uuid,uuid)'::text),
    ('private.trg_provision_customer_receipt_account_fallbacks()'::text)
  ) routine(signature)
  WHERE has_function_privilege('authenticated',routine.signature,'EXECUTE')

  UNION ALL
  SELECT 'customer_receipt_mapping_company_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalid',COALESCE(jsonb_agg(jsonb_build_object(
      'companyId',company_id,'functionKey',function_key,
      'currentFallbacks',current_fallbacks,'invalidAccounts',invalid_accounts)),'[]'::jsonb))
  FROM mapping_state WHERE current_fallbacks<>1 OR invalid_accounts<>0

  UNION ALL
  SELECT 'customer_receipt_mapping_runtime_inventory','INFO',0,
    jsonb_build_object('activeCompanies',(SELECT count(*) FROM public.companies WHERE status='ACTIVE'),
      'mappingRows',(SELECT count(*) FROM mapping_state),
      'cashDrawerMappings',(SELECT count(*) FROM mapping_state WHERE function_key='CASH_DRAWER'),
      'bankMappings',(SELECT count(*) FROM mapping_state WHERE function_key='BANK'),
      'receivableMappings',(SELECT count(*) FROM mapping_state WHERE function_key='CUSTOMER_RECEIVABLE'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'BLOCKER' THEN 2 WHEN 'PASS' THEN 3 ELSE 4 END,
  check_name;
