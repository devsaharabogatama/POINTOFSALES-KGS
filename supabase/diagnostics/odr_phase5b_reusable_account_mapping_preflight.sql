-- ODR-5B exact reusable account mapping source preflight.
-- SAFETY: SELECT-only. Resolution follows existing event rule, fallback, then
-- one canonical system account. No COA, mapping, event or journal mutation.
WITH mapping_requirements(
  target_system_key,source_system_key,function_key,function_scope
) AS (
  VALUES
    ('SALE_DISPATCHED'::TEXT,'SALE_POSTED'::TEXT,
      'SALES_REVENUE'::TEXT,'CORE'::TEXT),
    ('SALE_DISPATCHED','SALE_POSTED','INVENTORY_ASSET','CORE'),
    ('SALE_DISPATCHED','SALE_POSTED','COGS','CORE'),
    ('SALE_DISPATCHED','SALE_POSTED','CUSTOMER_RECEIVABLE','CORE'),
    ('SALE_DISPATCHED','SALE_POSTED','PAYMENT_CLEARING','CORE'),
    ('SALE_DISPATCHED','SALE_POSTED','OUTPUT_TAX','CONDITIONAL'),
    ('SALE_DISPATCHED','SALE_POSTED','DELIVERY_FEE_REVENUE','CONDITIONAL'),
    ('SALE_DISPATCHED','SALE_POSTED','PAYMENT_SURCHARGE_INCOME','CONDITIONAL'),
    ('SALE_DISPATCHED','SALE_POSTED','ROUNDING_GAIN','CONDITIONAL'),
    ('SALE_DISPATCHED','SALE_POSTED','ROUNDING_LOSS','CONDITIONAL'),
    ('SALE_PAYMENT_VERIFIED','SALE_PAYMENT','CASH_DRAWER','CORE'),
    ('SALE_PAYMENT_VERIFIED','SALE_PAYMENT','BANK','CORE'),
    ('SALE_PAYMENT_VERIFIED','SALE_PAYMENT','PAYMENT_CLEARING','CORE'),
    ('SALE_PAYMENT_VERIFIED','SALE_PAYMENT','CUSTOMER_RECEIVABLE','CORE'),
    ('SALE_PAYMENT_VERIFIED',NULL,'CUSTOMER_ADVANCE_LIABILITY','ADVANCE')
), active_companies AS (
  SELECT company.id company_id,company.company_code,company.company_name
  FROM public.companies company WHERE company.status='ACTIVE'
), candidate_counts AS (
  SELECT company.company_id,company.company_code,company.company_name,
    requirement.target_system_key,requirement.source_system_key,
    requirement.function_key,requirement.function_scope,
    CASE WHEN requirement.source_system_key IS NULL THEN 0 ELSE
      (SELECT count(DISTINCT rule.account_id)
      FROM public.transaction_account_rules rule
      JOIN public.transaction_categories category
        ON category.company_id=rule.company_id
       AND category.id=rule.transaction_category_id AND category.is_active
      JOIN public.chart_of_accounts account
        ON account.company_id=rule.company_id AND account.id=rule.account_id
      JOIN public.account_functions account_function
        ON account_function.function_key=requirement.function_key
       AND account_function.is_active
      WHERE rule.company_id=company.company_id
        AND rule.system_key=requirement.source_system_key
        AND category.system_key=requirement.source_system_key
        AND rule.account_function_key=requirement.function_key
        AND rule.status='ACTIVE'
        AND rule.effective_from<=clock_timestamp()
        AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
        AND account.is_active AND account.is_postable
        AND account.account_type=ANY(account_function.compatible_account_types))
      END source_rule_account_count,
    (SELECT count(DISTINCT fallback.account_id)
      FROM public.company_account_function_fallbacks fallback
      JOIN public.chart_of_accounts account
        ON account.company_id=fallback.company_id
       AND account.id=fallback.account_id
      JOIN public.account_functions account_function
        ON account_function.function_key=requirement.function_key
       AND account_function.is_active
      WHERE fallback.company_id=company.company_id
        AND fallback.account_function_key=requirement.function_key
        AND fallback.status='ACTIVE'
        AND fallback.effective_from<=clock_timestamp()
        AND (fallback.effective_to IS NULL
          OR fallback.effective_to>clock_timestamp())
        AND account.is_active AND account.is_postable
        AND account.account_type=ANY(account_function.compatible_account_types))
      fallback_account_count,
    (SELECT count(DISTINCT account.id)
      FROM public.chart_of_accounts account
      JOIN public.account_functions account_function
        ON account_function.function_key=requirement.function_key
       AND account_function.is_active
      WHERE account.company_id=company.company_id
        AND account.system_function_key=requirement.function_key
        AND account.is_active AND account.is_postable
        AND account.account_type=ANY(account_function.compatible_account_types))
      system_account_count
  FROM active_companies company CROSS JOIN mapping_requirements requirement
), candidate_resolution AS (
  SELECT candidate.*,
    CASE
      WHEN source_rule_account_count=1 THEN 'SOURCE_EVENT_RULE'
      WHEN source_rule_account_count>1 THEN 'AMBIGUOUS_SOURCE_EVENT_RULE'
      WHEN fallback_account_count=1 THEN 'COMPANY_FALLBACK'
      WHEN fallback_account_count>1 THEN 'AMBIGUOUS_COMPANY_FALLBACK'
      WHEN system_account_count=1 THEN 'SYSTEM_ACCOUNT'
      WHEN system_account_count>1 THEN 'AMBIGUOUS_SYSTEM_ACCOUNT'
      ELSE 'MISSING' END resolution_source
  FROM candidate_counts candidate
), advance_code_collisions AS (
  SELECT account.company_id,company.company_code,account.id,
    account.account_code,account.account_name,account.system_function_key
  FROM public.chart_of_accounts account
  JOIN active_companies company ON company.company_id=account.company_id
  WHERE (upper(regexp_replace(btrim(account.account_code),'\s+',' ','g'))='2190'
      OR lower(regexp_replace(btrim(account.account_name),'\s+',' ','g'))=
        'uang muka customer')
    AND account.system_function_key IS DISTINCT FROM
      'CUSTOMER_ADVANCE_LIABILITY'
), target_category_collisions AS (
  SELECT category.company_id,company.company_code,category.id,
    category.category_code,category.category_name,category.system_key
  FROM public.transaction_categories category
  JOIN active_companies company ON company.company_id=category.company_id
  WHERE (upper(regexp_replace(btrim(category.category_code),'\s+',' ','g'))
      IN('ODR-SALE-DISPATCHED','ODR-SALE-PAYMENT-VERIFIED')
    OR lower(regexp_replace(btrim(category.category_name),'\s+',' ','g'))
      IN('odr dispatch penjualan','odr verifikasi pembayaran penjualan'))
    AND category.system_key NOT IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
), checks AS (
  SELECT 'odr_phase5a_dependency'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828210000'

  UNION ALL
  SELECT 'mapping_audit_actor_readiness',
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('candidateRows',count(*))
  FROM public.profiles profile WHERE profile.role::TEXT='super_admin'

  UNION ALL
  SELECT 'core_reusable_account_source',
    CASE WHEN count(*) FILTER(WHERE resolution_source='MISSING'
      OR resolution_source LIKE 'AMBIGUOUS%')=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*) FILTER(
        WHERE resolution_source='MISSING'
          OR resolution_source LIKE 'AMBIGUOUS%'),
      'functions',COALESCE(jsonb_agg(DISTINCT function_key ORDER BY function_key)
        FILTER(WHERE resolution_source='MISSING'
          OR resolution_source LIKE 'AMBIGUOUS%'),'[]'::JSONB),
      'companyCodes',COALESCE(jsonb_agg(DISTINCT company_code ORDER BY company_code)
        FILTER(WHERE resolution_source='MISSING'
          OR resolution_source LIKE 'AMBIGUOUS%'),'[]'::JSONB))
  FROM candidate_resolution WHERE function_scope='CORE'

  UNION ALL
  SELECT 'conditional_reusable_account_source',
    CASE WHEN count(*) FILTER(WHERE resolution_source='MISSING'
      OR resolution_source LIKE 'AMBIGUOUS%')=0
      THEN 'PASS' ELSE 'REVIEW' END,
    jsonb_build_object('invalidRows',count(*) FILTER(
        WHERE resolution_source='MISSING'
          OR resolution_source LIKE 'AMBIGUOUS%'),
      'functions',COALESCE(jsonb_agg(DISTINCT function_key ORDER BY function_key)
        FILTER(WHERE resolution_source='MISSING'
          OR resolution_source LIKE 'AMBIGUOUS%'),'[]'::JSONB),
      'companyCodes',COALESCE(jsonb_agg(DISTINCT company_code ORDER BY company_code)
        FILTER(WHERE resolution_source='MISSING'
          OR resolution_source LIKE 'AMBIGUOUS%'),'[]'::JSONB))
  FROM candidate_resolution WHERE function_scope='CONDITIONAL'

  UNION ALL
  SELECT 'customer_advance_provision_scope',
    CASE WHEN count(*) FILTER(WHERE resolution_source LIKE 'AMBIGUOUS%')=0
      THEN 'BACKFILL' ELSE 'BLOCKER' END,
    jsonb_build_object('missingRows',count(*) FILTER(
        WHERE resolution_source='MISSING'),
      'ambiguousRows',count(*) FILTER(
        WHERE resolution_source LIKE 'AMBIGUOUS%'),
      'companyCodes',COALESCE(jsonb_agg(company_code ORDER BY company_code)
        FILTER(WHERE resolution_source='MISSING'),'[]'::JSONB),
      'targetCode','2190')
  FROM candidate_resolution WHERE function_scope='ADVANCE'

  UNION ALL
  SELECT 'customer_advance_coa_identity_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('collisionRows',count(*),
      'companyCodes',COALESCE(jsonb_agg(DISTINCT company_code ORDER BY company_code),
        '[]'::JSONB))
  FROM advance_code_collisions

  UNION ALL
  SELECT 'odr_target_category_identity_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('collisionRows',count(*),
      'companyCodes',COALESCE(jsonb_agg(DISTINCT company_code ORDER BY company_code),
        '[]'::JSONB))
  FROM target_category_collisions

  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'protected_finance_history',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidJournalRows',count(*),
      'historicalPostedJournals',(SELECT count(*) FROM public.finance_journals
        WHERE status='POSTED'))
  FROM public.finance_journals journal
  WHERE journal.status='POSTED'
    AND (journal.total_debit<>journal.total_credit OR journal.total_debit<0)

  UNION ALL
  SELECT 'exact_mapping_source_inventory','INFO',jsonb_build_object(
    'activeCompanies',(SELECT count(*) FROM active_companies),
    'byResolution',COALESCE((SELECT jsonb_object_agg(source_state,row_count)
      FROM (SELECT resolution_source source_state,count(*) row_count
        FROM candidate_resolution GROUP BY resolution_source) grouped),
      '{}'::JSONB),
    'invalidDetail',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'companyCode',company_code,'targetEvent',target_system_key,
      'sourceEvent',source_system_key,'functionKey',function_key,
      'scope',function_scope,'resolution',resolution_source,
      'sourceRuleAccounts',source_rule_account_count,
      'fallbackAccounts',fallback_account_count,
      'systemAccounts',system_account_count)
      ORDER BY company_code,target_system_key,function_key)
      FROM candidate_resolution WHERE resolution_source='MISSING'
        OR resolution_source LIKE 'AMBIGUOUS%'),'[]'::JSONB))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'BACKFILL' THEN 1
  WHEN 'PASS' THEN 2 WHEN 'REVIEW' THEN 3 ELSE 4 END,check_name;
