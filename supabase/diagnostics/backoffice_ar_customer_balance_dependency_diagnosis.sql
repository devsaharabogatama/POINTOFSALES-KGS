-- SELECT-only diagnosis for the Backoffice AR Task 5 Customer Balance dependency.
-- Purpose: distinguish intentional disabled entitlement from an unresolved
-- Finance mapping. No DDL, DML, context mutation, temp object, or deployment.
WITH target_companies AS (
  SELECT company.id AS company_id,company.company_code,company.company_name
  FROM public.companies company
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=company.id
   AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  WHERE company.status='ACTIVE' AND company.company_code IN('KMS','LSM','SMS')
), required_paths AS (
  SELECT 'CUSTOMER_BALANCE_RECEIPT'::text AS system_key,
    'CUSTOMER_BALANCE_LIABILITY'::text AS function_key
  UNION ALL SELECT 'CUSTOMER_BALANCE_USAGE','CUSTOMER_BALANCE_LIABILITY'
  UNION ALL SELECT 'CUSTOMER_BALANCE_USAGE','CUSTOMER_RECEIVABLE'
), scope AS (
  SELECT company.company_id,company.company_code,company.company_name,
    feature.is_enabled AS feature_enabled,feature.updated_by AS feature_updated_by,
    policy.id AS policy_id,policy.lifecycle_state,policy.master_version AS policy_version,
    count(method.id) FILTER(WHERE method.method_type='CUSTOMER_BALANCE')
      AS method_rows,
    count(method.id) FILTER(WHERE method.method_type='CUSTOMER_BALANCE'
      AND method.is_system_method
      AND method.settlement_route='INTERNAL_LIABILITY') AS valid_system_methods,
    count(method.id) FILTER(WHERE method.method_type='CUSTOMER_BALANCE'
      AND method.is_active) AS active_methods
  FROM target_companies company
  LEFT JOIN public.company_features feature
    ON feature.company_id=company.company_id
   AND feature.feature_code='customer_balance_enabled'
  LEFT JOIN public.customer_balance_company_policies policy
    ON policy.company_id=company.company_id
  LEFT JOIN public.payment_methods method
    ON method.company_id=company.company_id
   AND method.method_type='CUSTOMER_BALANCE'
  GROUP BY company.company_id,company.company_code,company.company_name,
    feature.is_enabled,feature.updated_by,policy.id,policy.lifecycle_state,
    policy.master_version
), required_mapping AS (
  SELECT company.company_id,company.company_code,path.system_key,
    path.function_key,category.id AS category_id,
    (SELECT count(*) FROM public.transaction_account_rules rule
      JOIN public.chart_of_accounts account
        ON account.company_id=rule.company_id AND account.id=rule.account_id
       AND account.is_active AND account.is_postable
      WHERE rule.company_id=company.company_id
        AND rule.transaction_category_id=category.id
        AND rule.account_function_key=path.function_key
        AND rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
        AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp()))
      AS direct_rows,
    (SELECT count(*) FROM public.company_account_function_fallbacks fallback
      JOIN public.chart_of_accounts account
        ON account.company_id=fallback.company_id AND account.id=fallback.account_id
       AND account.is_active AND account.is_postable
      WHERE fallback.company_id=company.company_id
        AND fallback.account_function_key=path.function_key
        AND fallback.status='ACTIVE'
        AND fallback.effective_from<=clock_timestamp()
        AND (fallback.effective_to IS NULL
          OR fallback.effective_to>clock_timestamp())) AS fallback_rows,
    (SELECT count(*) FROM public.chart_of_accounts account
      WHERE account.company_id=company.company_id
        AND account.system_function_key=path.function_key
        AND account.is_active AND account.is_postable) AS system_account_rows,
    (SELECT jsonb_agg(jsonb_build_object('accountCode',account.account_code,
        'accountName',account.account_name,'ruleVersion',rule.rule_version)
        ORDER BY rule.effective_from DESC,rule.rule_version DESC)
      FROM public.transaction_account_rules rule
      JOIN public.chart_of_accounts account
        ON account.company_id=rule.company_id AND account.id=rule.account_id
       AND account.is_active AND account.is_postable
      WHERE rule.company_id=company.company_id
        AND rule.transaction_category_id=category.id
        AND rule.account_function_key=path.function_key
        AND rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
        AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp()))
      AS direct_accounts,
    (SELECT jsonb_agg(jsonb_build_object('accountCode',account.account_code,
        'accountName',account.account_name,'fallbackVersion',fallback.fallback_version)
        ORDER BY fallback.effective_from DESC,fallback.fallback_version DESC)
      FROM public.company_account_function_fallbacks fallback
      JOIN public.chart_of_accounts account
        ON account.company_id=fallback.company_id AND account.id=fallback.account_id
       AND account.is_active AND account.is_postable
      WHERE fallback.company_id=company.company_id
        AND fallback.account_function_key=path.function_key
        AND fallback.status='ACTIVE'
        AND fallback.effective_from<=clock_timestamp()
        AND (fallback.effective_to IS NULL
          OR fallback.effective_to>clock_timestamp())) AS fallback_accounts,
    (SELECT jsonb_agg(jsonb_build_object('accountCode',account.account_code,
        'accountName',account.account_name) ORDER BY account.account_code)
      FROM public.chart_of_accounts account
      WHERE account.company_id=company.company_id
        AND account.system_function_key=path.function_key
        AND account.is_active AND account.is_postable) AS system_accounts
  FROM target_companies company
  CROSS JOIN required_paths path
  LEFT JOIN public.transaction_categories category
    ON category.company_id=company.company_id
   AND category.system_key=path.system_key AND category.is_active
), mapping_resolution AS (
  SELECT mapping.*,
    CASE
      WHEN category_id IS NULL THEN 'MISSING_CATEGORY'
      WHEN direct_rows=1 THEN 'DIRECT_RULE'
      WHEN direct_rows>1 THEN 'AMBIGUOUS_DIRECT_RULE'
      WHEN fallback_rows=1 THEN 'COMPANY_FALLBACK'
      WHEN fallback_rows>1 THEN 'AMBIGUOUS_FALLBACK'
      WHEN system_account_rows=1 THEN 'SYSTEM_FUNCTION_ACCOUNT'
      WHEN system_account_rows>1 THEN 'AMBIGUOUS_SYSTEM_ACCOUNT'
      ELSE 'UNRESOLVED'
    END AS resolution_tier
  FROM required_mapping mapping
), path_identity AS (
  SELECT company.company_id,company.company_code,path.system_key,
    path.function_key,
    count(resolution.category_id) AS category_rows,
    count(*) FILTER(WHERE resolution.category_id IS NOT NULL
      AND resolution.resolution_tier NOT IN(
        'DIRECT_RULE','COMPANY_FALLBACK','SYSTEM_FUNCTION_ACCOUNT'))
      AS invalid_category_rows
  FROM target_companies company
  CROSS JOIN required_paths path
  LEFT JOIN mapping_resolution resolution
    ON resolution.company_id=company.company_id
   AND resolution.system_key=path.system_key
   AND resolution.function_key=path.function_key
  GROUP BY company.company_id,company.company_code,path.system_key,
    path.function_key
), mapping_contract AS (
  SELECT count(*) AS expected_path_rows,
    count(*) FILTER(WHERE category_rows=0) AS missing_path_rows,
    COALESCE(sum(invalid_category_rows),0) AS invalid_category_rows
  FROM path_identity
), liability_candidates AS (
  SELECT company.company_code,account.account_code,account.account_name,
    account.account_type,account.normal_balance,account.system_function_key,
    account.is_active,account.is_postable
  FROM target_companies company
  JOIN public.chart_of_accounts account ON account.company_id=company.company_id
  WHERE account.is_active AND account.is_postable
    AND account.account_type='LIABILITY' AND account.normal_balance='CREDIT'
), trigger_state AS (
  SELECT count(*) AS trigger_rows,
    count(*) FILTER(WHERE trigger_row.tgenabled='O') AS enabled_rows,
    bool_and(pg_get_triggerdef(trigger_row.oid) ILIKE
      '%AFTER INSERT OR UPDATE OF is_enabled ON public.company_features%')
      AS expected_timing,
    bool_and(pg_get_triggerdef(trigger_row.oid) ILIKE
      '%private.trg_g4_sync_customer_balance_feature%') AS expected_function
  FROM pg_trigger trigger_row
  WHERE trigger_row.tgrelid='public.company_features'::regclass
    AND trigger_row.tgname='g4_sync_customer_balance_feature'
    AND NOT trigger_row.tgisinternal
), balance_integrity AS (
  SELECT count(*) FILTER(WHERE customer.current_balance<0
      OR (customer.is_system_customer AND customer.current_balance<>0))
      AS invalid_customer_rows,
    count(*) FILTER(WHERE customer.current_balance<>
      COALESCE((SELECT sum(CASE entry.direction WHEN 'CREDIT' THEN entry.amount
        ELSE -entry.amount END)
        FROM public.customer_balance_ledger_entries entry
        WHERE entry.company_id=customer.company_id
          AND entry.customer_id=customer.id),0)) AS cache_mismatch_rows,
    count(*) FILTER(WHERE customer.current_balance>0) AS positive_balance_rows,
    round(COALESCE(sum(customer.current_balance),0),4) AS total_balance
  FROM public.customers customer
  JOIN target_companies company ON company.company_id=customer.company_id
), runtime_boundary AS (
  SELECT (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
      AS active_finance_queue,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))
      AS nonterminal_offline
)
SELECT 'backoffice_ar_customer_balance_dependency_company_state' AS check_name,
  CASE WHEN count(*)=3 AND count(*) FILTER(WHERE policy_id IS NULL
      OR method_rows<>1 OR valid_system_methods<>1)=0
    THEN 'PASS' ELSE 'BLOCKER' END AS status,
  count(*) FILTER(WHERE policy_id IS NULL OR method_rows<>1
    OR valid_system_methods<>1) AS violation_rows,
  jsonb_build_object('companies',jsonb_agg(jsonb_build_object(
    'company',company_code,'featureEnabled',COALESCE(feature_enabled,false),
    'lifecycleState',lifecycle_state,'policyVersion',policy_version,
    'methodRows',method_rows,'validSystemMethods',valid_system_methods,
    'activeMethods',active_methods) ORDER BY company_code)) AS details
FROM scope
UNION ALL
SELECT 'backoffice_ar_customer_balance_dependency_mapping_resolution',
  CASE WHEN expected_path_rows=9 AND missing_path_rows=0
      AND invalid_category_rows=0
    THEN 'PASS' ELSE 'BLOCKER' END,
  missing_path_rows+invalid_category_rows,
  jsonb_build_object('expectedPathRows',expected_path_rows,
    'missingPathRows',missing_path_rows,
    'invalidCategoryRows',invalid_category_rows,
    'paths',(SELECT jsonb_agg(jsonb_build_object(
      'company',resolution.company_code,'systemKey',resolution.system_key,
      'function',resolution.function_key,'categoryId',resolution.category_id,
      'resolutionTier',resolution.resolution_tier,
      'directRows',resolution.direct_rows,
      'fallbackRows',resolution.fallback_rows,
      'systemAccountRows',resolution.system_account_rows,
      'directAccounts',COALESCE(resolution.direct_accounts,'[]'::jsonb),
      'fallbackAccounts',COALESCE(resolution.fallback_accounts,'[]'::jsonb),
      'systemAccounts',COALESCE(resolution.system_accounts,'[]'::jsonb))
      ORDER BY resolution.company_code,resolution.system_key,
        resolution.function_key,resolution.category_id)
      FROM mapping_resolution resolution))
FROM mapping_contract
UNION ALL
SELECT 'backoffice_ar_customer_balance_dependency_liability_candidates','INFO',0,
  jsonb_build_object('accounts',COALESCE(jsonb_agg(jsonb_build_object(
    'company',company_code,'accountCode',account_code,'accountName',account_name,
    'function',system_function_key,'active',is_active,'postable',is_postable)
    ORDER BY company_code,account_code),'[]'::jsonb))
FROM liability_candidates
UNION ALL
SELECT 'backoffice_ar_customer_balance_dependency_feature_sync_trigger',
  CASE WHEN trigger_rows=1 AND enabled_rows=1 AND expected_timing
      AND expected_function THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN trigger_rows=1 AND enabled_rows=1 AND expected_timing
      AND expected_function THEN 0 ELSE 1 END,
  jsonb_build_object('triggerRows',trigger_rows,'enabledRows',enabled_rows,
    'expectedTiming',expected_timing,'expectedFunction',expected_function)
FROM trigger_state
UNION ALL
SELECT 'backoffice_ar_customer_balance_dependency_balance_integrity',
  CASE WHEN invalid_customer_rows=0 AND cache_mismatch_rows=0
    THEN 'PASS' ELSE 'BLOCKER' END,
  invalid_customer_rows+cache_mismatch_rows,
  jsonb_build_object('invalidCustomerRows',invalid_customer_rows,
    'cacheMismatchRows',cache_mismatch_rows,
    'positiveBalanceRows',positive_balance_rows,'totalBalance',total_balance)
FROM balance_integrity
UNION ALL
SELECT 'backoffice_ar_customer_balance_dependency_runtime_boundary',
  CASE WHEN active_finance_queue=0 AND nonterminal_offline=0
    THEN 'PASS' ELSE 'BLOCKER' END,
  active_finance_queue+nonterminal_offline,
  jsonb_build_object('activeFinanceQueue',active_finance_queue,
    'nonterminalOffline',nonterminal_offline)
FROM runtime_boundary
UNION ALL
SELECT 'backoffice_ar_customer_balance_dependency_interpretation','INFO',0,
  jsonb_build_object('mutation','NONE','rule',
    'Disabled feature is intentional state, not proof of mapping failure',
    'resolverOrder',jsonb_build_array('DIRECT_RULE','COMPANY_FALLBACK',
      'SYSTEM_FUNCTION_ACCOUNT'),
    'next','Return every row; any BLOCKER freezes configuration and Task 5');
