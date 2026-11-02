-- SELECT-only classifier for KGS Ketul readiness forward fix.
WITH target AS (
  SELECT company.id
  FROM public.companies company
  WHERE company.id='d290f1ee-6c54-4b01-90e6-d701748f0851'::uuid
    AND company.company_code='KGS' AND company.company_name='KGS Company'
    AND company.status='ACTIVE'
), category AS (
  SELECT category.id
  FROM public.transaction_categories category,target
  WHERE category.company_id=target.id AND category.is_active
    AND category.system_key='KETUL_CUSTOMER_INTAKE'
), state AS (
  SELECT
    (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261031110000') AS dependency_rows,
    (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261101120000') AS fix_rows,
    (SELECT count(*) FROM target) AS company_rows,
    (SELECT count(*) FROM public.company_features feature,target
      WHERE feature.company_id=target.id AND feature.feature_code='ketul_enabled'
        AND feature.is_enabled) AS entitlement_rows,
    (SELECT count(*) FROM public.product_categories product_category,target
      WHERE product_category.company_id=target.id AND product_category.is_active
        AND upper(btrim(product_category.category_name))='KETUL') AS product_category_rows,
    (SELECT count(*) FROM public.products product
      JOIN public.product_categories product_category
        ON product_category.company_id=product.company_id
       AND product_category.id=product.category_id,target
      WHERE product.company_id=target.id AND product.is_active
        AND NOT product.is_bundle AND product_category.is_active
        AND upper(btrim(product_category.category_name))='KETUL') AS product_rows,
    (SELECT count(*) FROM category) AS event_category_rows,
    (SELECT count(*) FROM public.transaction_account_rules rule
      JOIN public.chart_of_accounts account
        ON account.company_id=rule.company_id AND account.id=rule.account_id
      JOIN category ON category.id=rule.transaction_category_id,target
      WHERE rule.company_id=target.id AND rule.account_function_key='INVENTORY_ASSET'
        AND rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
        AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
        AND account.account_code='1030100-4'
        AND account.account_name='PERSEDIAAN KETUL'
        AND account.is_active AND account.is_postable
        AND NOT account.is_system_account) AS inventory_rows,
    (SELECT count(*) FROM public.chart_of_accounts account,target
      WHERE account.company_id=target.id AND account.account_code='2010105'
        AND account.account_name='HUTANG LAIN-LAINNYA'
        AND account.account_type='LIABILITY' AND account.normal_balance='CREDIT'
        AND account.is_active AND account.is_postable
        AND NOT account.is_system_account) AS authority_rows,
    (SELECT count(*) FROM public.chart_of_accounts account,target
      WHERE account.company_id=target.id AND (account.account_code='2010105-1'
        OR lower(btrim(account.account_name))=lower('HUTANG KETUL CUSTOMER'))) AS target_account_rows,
    (SELECT count(*) FROM public.transaction_account_rules rule
      JOIN category ON category.id=rule.transaction_category_id,target
      WHERE rule.company_id=target.id
        AND rule.account_function_key='CUSTOMER_KETUL_PAYABLE'
        AND rule.status='ACTIVE' AND rule.effective_to IS NULL) AS payable_rule_rows,
    (SELECT count(*) FROM public.company_account_function_fallbacks fallback,target
      WHERE fallback.company_id=target.id
        AND fallback.account_function_key='CUSTOMER_KETUL_PAYABLE'
        AND fallback.status='ACTIVE' AND fallback.effective_to IS NULL) AS fallback_rows,
    (SELECT count(*) FROM public.payment_methods method,target
      WHERE method.company_id=target.id AND method.method_type='KETUL_OFFSET'
        AND method.is_active) AS method_rows
), checks AS (
  SELECT 10 AS seq,'pos_ketul_kgs_readiness_preflight_identity'::text check_name,
    CASE WHEN company_rows=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    CASE WHEN company_rows=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('companyRows',company_rows,'companyCode','KGS') details
  FROM state
  UNION ALL
  SELECT 20,'pos_ketul_kgs_readiness_preflight_dependency',
    CASE WHEN dependency_rows=1 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN dependency_rows=1 THEN 0 ELSE 1 END,
    jsonb_build_object('required','20261031110000','rows',dependency_rows) FROM state
  UNION ALL
  SELECT 30,'pos_ketul_kgs_readiness_preflight_installation_state',
    CASE WHEN fix_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN fix_rows=0 THEN 0 ELSE 1 END,
    jsonb_build_object('state',CASE WHEN fix_rows=0 THEN 'NOT_INSTALLED' ELSE 'INSTALLED' END,
      'ledgerRows',fix_rows) FROM state
  UNION ALL
  SELECT 40,'pos_ketul_kgs_readiness_preflight_catalog_contract',
    CASE WHEN entitlement_rows=1 AND product_category_rows=1 AND product_rows=4
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN entitlement_rows=1 AND product_category_rows=1 AND product_rows=4
      THEN 0 ELSE 1 END,
    jsonb_build_object('entitlementRows',entitlement_rows,
      'categoryRows',product_category_rows,'productRows',product_rows) FROM state
  UNION ALL
  SELECT 50,'pos_ketul_kgs_readiness_preflight_finance_authority',
    CASE WHEN event_category_rows=1 AND inventory_rows=1 AND authority_rows=1
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN event_category_rows=1 AND inventory_rows=1 AND authority_rows=1
      THEN 0 ELSE 1 END,
    jsonb_build_object('eventCategoryRows',event_category_rows,
      'currentInventoryRows',inventory_rows,'liabilityAuthorityRows',authority_rows) FROM state
  UNION ALL
  SELECT 60,'pos_ketul_kgs_readiness_preflight_exact_gap',
    CASE WHEN target_account_rows=0 AND payable_rule_rows=0
      AND fallback_rows=0 AND method_rows=0 THEN 'ROOT_CAUSE' ELSE 'BLOCKER' END,
    CASE WHEN target_account_rows=0 AND payable_rule_rows=0
      AND fallback_rows=0 AND method_rows=0 THEN 0 ELSE 1 END,
    jsonb_build_object('targetAccountRows',target_account_rows,
      'payableRuleRows',payable_rule_rows,'fallbackRows',fallback_rows,
      'internalMethodRows',method_rows) FROM state
  UNION ALL
  SELECT 70,'pos_ketul_kgs_readiness_preflight_runtime_boundary',
    CASE WHEN finance_rows=0 AND offline_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    finance_rows+offline_rows,
    jsonb_build_object('activeFinanceQueue',finance_rows,
      'nonterminalOffline',offline_rows)
  FROM (SELECT
    (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('DRAFT','PROCESSING')) finance_rows,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) offline_rows) boundary
  UNION ALL
  SELECT 80,'pos_ketul_kgs_readiness_preflight_business_boundary','INFO',0,
    jsonb_build_object('company','KGS only','mutation','NONE',
      'preserved',ARRAY['KGFF','other Companies','Sales','Payment','Stock','FIFO',
        'Events','Journals','Cashier Sessions','historical rows'])
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY seq;
