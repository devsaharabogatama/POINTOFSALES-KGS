-- SELECT-only readiness gate for Customer Receipt account-mapping forward fix.
-- Target: isolated Development only. This file performs no writes.
WITH required_migrations(version) AS (
  VALUES ('20260814100000'::text),('20260827110000'::text),('20260911160000'::text)
), required_functions(function_key,account_function_key) AS (
  VALUES
    ('CASH_DRAWER'::text,'CASH_DRAWER'::text),
    ('BANK'::text,'BANK'::text),
    ('CUSTOMER_RECEIVABLE'::text,'CUSTOMER_RECEIVABLE'::text)
), company_functions AS (
  SELECT company.id company_id,required.function_key,required.account_function_key
  FROM public.companies company CROSS JOIN required_functions required
  WHERE company.status='ACTIVE'
), mapping_state AS (
  SELECT scope.*,
    (SELECT count(*) FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=scope.company_id
        AND fallback.account_function_key=scope.function_key
        AND fallback.status='ACTIVE') active_fallbacks,
    (SELECT count(*) FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=scope.company_id
        AND fallback.account_function_key=scope.function_key
        AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
        AND (fallback.effective_to IS NULL
          OR fallback.effective_to>clock_timestamp())) current_fallbacks,
    (SELECT count(*) FROM public.chart_of_accounts account
      JOIN public.account_functions function_state
        ON function_state.function_key=scope.account_function_key
       AND function_state.is_active
      WHERE account.company_id=scope.company_id
        AND account.system_function_key=scope.account_function_key
        AND account.is_system_account AND account.is_active AND account.is_postable
        AND account.account_type=ANY(function_state.compatible_account_types)) canonical_accounts
  FROM company_functions scope
), checks AS (
  SELECT 'payment_mapping_fix_dependency_ledger'::text check_name,
    CASE WHEN count(ledger.version)=count(*) THEN 'PASS' ELSE 'BLOCKER' END status,
    count(*)-count(ledger.version) violation_rows,
    jsonb_build_object('expected',count(*),'present',count(ledger.version),
      'missing',COALESCE(jsonb_agg(required.version)
        FILTER(WHERE ledger.version IS NULL),'[]'::jsonb)) details
  FROM required_migrations required
  LEFT JOIN private.kgs_schema_migrations ledger ON ledger.version=required.version

  UNION ALL
  SELECT 'payment_mapping_fix_object_collision',
    CASE WHEN to_regprocedure(
      'private.provision_customer_receipt_account_fallbacks(uuid,uuid)') IS NULL
      AND to_regprocedure(
        'private.trg_provision_customer_receipt_account_fallbacks()') IS NULL
      AND NOT EXISTS(SELECT 1 FROM pg_trigger trigger_row
        WHERE trigger_row.tgrelid='public.companies'::regclass
          AND trigger_row.tgname='payment_provision_customer_receipt_fallbacks'
          AND NOT trigger_row.tgisinternal)
      THEN 'PASS' ELSE 'BLOCKER' END,
    (CASE WHEN to_regprocedure(
      'private.provision_customer_receipt_account_fallbacks(uuid,uuid)') IS NULL THEN 0 ELSE 1 END
      +CASE WHEN to_regprocedure(
        'private.trg_provision_customer_receipt_account_fallbacks()') IS NULL THEN 0 ELSE 1 END
      +CASE WHEN EXISTS(SELECT 1 FROM pg_trigger trigger_row
        WHERE trigger_row.tgrelid='public.companies'::regclass
          AND trigger_row.tgname='payment_provision_customer_receipt_fallbacks'
          AND NOT trigger_row.tgisinternal) THEN 1 ELSE 0 END)::bigint,
    jsonb_build_object('routineExists',to_regprocedure(
      'private.provision_customer_receipt_account_fallbacks(uuid,uuid)') IS NOT NULL,
      'triggerFunctionExists',to_regprocedure(
        'private.trg_provision_customer_receipt_account_fallbacks()') IS NOT NULL,
      'triggerExists',EXISTS(SELECT 1 FROM pg_trigger trigger_row
        WHERE trigger_row.tgrelid='public.companies'::regclass
          AND trigger_row.tgname='payment_provision_customer_receipt_fallbacks'
          AND NOT trigger_row.tgisinternal))

  UNION ALL
  SELECT 'payment_mapping_fix_canonical_account_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('invalid',COALESCE(jsonb_agg(jsonb_build_object(
      'companyId',company_id,'functionKey',function_key,
      'canonicalAccounts',canonical_accounts)),'[]'::jsonb))
  FROM mapping_state WHERE canonical_accounts<>1

  UNION ALL
  SELECT 'payment_mapping_fix_existing_fallback_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('invalid',COALESCE(jsonb_agg(jsonb_build_object(
      'companyId',company_id,'functionKey',function_key,
      'activeFallbacks',active_fallbacks,'currentFallbacks',current_fallbacks)),'[]'::jsonb))
  FROM mapping_state
  WHERE current_fallbacks>1 OR (active_fallbacks>0 AND current_fallbacks=0)

  UNION ALL
  SELECT 'payment_mapping_fix_sale_payment_category_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('invalidCompanies',COALESCE(jsonb_agg(company_id),'[]'::jsonb))
  FROM (
    SELECT company.id company_id
    FROM public.companies company
    LEFT JOIN public.transaction_categories category
      ON category.company_id=company.id AND category.system_key='SALE_PAYMENT'
     AND category.is_active
    WHERE company.status='ACTIVE'
    GROUP BY company.id HAVING count(category.id)<>1
  ) invalid

  UNION ALL
  SELECT 'payment_mapping_fix_sale_payment_rule_ambiguity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('invalid',COALESCE(jsonb_agg(jsonb_build_object(
      'companyId',company_id,'functionKey',account_function_key,
      'activeRules',rule_count)),'[]'::jsonb))
  FROM (
    SELECT scope.company_id,scope.function_key account_function_key,count(rule.id) rule_count
    FROM company_functions scope
    JOIN public.transaction_categories category
      ON category.company_id=scope.company_id AND category.system_key='SALE_PAYMENT'
     AND category.is_active
    LEFT JOIN public.transaction_account_rules rule
      ON rule.company_id=scope.company_id
     AND rule.transaction_category_id=category.id
     AND rule.system_key='SALE_PAYMENT'
     AND rule.account_function_key=scope.function_key
     AND rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
     AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
    GROUP BY scope.company_id,scope.function_key
    HAVING count(rule.id)>1
  ) ambiguous

  UNION ALL
  SELECT 'payment_mapping_fix_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'payment_mapping_fix_runtime_inventory','INFO',0,
    jsonb_build_object('activeCompanies',(SELECT count(*) FROM public.companies WHERE status='ACTIVE'),
      'requiredMappings',(SELECT count(*) FROM mapping_state),
      'currentFallbacks',(SELECT count(*) FROM mapping_state WHERE current_fallbacks=1),
      'missingFallbacks',(SELECT count(*) FROM mapping_state WHERE active_fallbacks=0),
      'revision','PAYMENT_ACCOUNT_MAPPING_FIX_V1')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'FAIL' THEN 2 WHEN 'PASS' THEN 3 ELSE 4 END,
  check_name;
