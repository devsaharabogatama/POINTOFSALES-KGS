-- SELECT-only live-state preflight for POS Ketul Customer Intake Offset.
-- This file performs no mutation and is safe to run in Production SQL Editor.
WITH company_identity AS (
  SELECT count(*) AS company_rows
  FROM public.companies
  WHERE company_code='KGFF'
), company_scope AS (
  SELECT id AS company_id
  FROM public.companies
  WHERE company_code='KGFF'
  ORDER BY id::text
  LIMIT 1
), migration_state AS (
  SELECT
    count(DISTINCT version) FILTER (WHERE version IN (
      '20260720090000','20260722120000','20260722150000','20260722180000',
      '20261008110000','20261008120000','20261008130000',
      '20261030120000','20261030130000','20261031100000'
    )) AS installed_rows,
    coalesce(jsonb_agg(version ORDER BY version) FILTER (WHERE version IN (
      '20260720090000','20260722120000','20260722150000','20260722180000',
      '20261008110000','20261008120000','20261008130000',
      '20261030120000','20261030130000','20261031100000'
    )),'[]'::jsonb) AS installed
  FROM private.kgs_schema_migrations
), checks AS (
  SELECT 10 AS seq,'pos_ketul_preflight_company_identity'::text AS check_name,
    CASE WHEN company_rows=1 THEN 'PASS' ELSE 'BLOCKER' END AS status,
    abs(company_rows-1)::bigint AS violation_rows,
    jsonb_build_object('companyCode','KGFF','rows',company_rows,
      'companyId',(SELECT company_id FROM company_scope)) AS details
  FROM company_identity

  UNION ALL
  SELECT 20,'pos_ketul_preflight_dependency_ledger',
    CASE WHEN installed_rows=10 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(installed_rows-10),
    jsonb_build_object('expected',10,'installedRows',installed_rows,
      'installed',installed)
  FROM migration_state

  UNION ALL
  SELECT 30,'pos_ketul_preflight_feature_entitlement',
    CASE WHEN count(*)=1 AND count(*) FILTER (WHERE feature.is_enabled)=1
      THEN 'PASS' ELSE 'BLOCKER' END,
    abs(count(*)-1)+count(*) FILTER (WHERE NOT feature.is_enabled),
    jsonb_build_object('rows',count(*),'enabledRows',
      count(*) FILTER (WHERE feature.is_enabled),'config',
      coalesce(jsonb_agg(feature.config),'[]'::jsonb))
  FROM company_scope scope
  LEFT JOIN public.company_features feature
    ON feature.company_id=scope.company_id AND feature.feature_code='ketul_enabled'
  WHERE scope.company_id IS NOT NULL AND feature.company_id IS NOT NULL

  UNION ALL
  SELECT 40,'pos_ketul_preflight_product_catalog',
    CASE WHEN category_rows=1 AND active_product_rows>0
      AND invalid_product_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(category_rows-1)+CASE WHEN active_product_rows>0 THEN 0 ELSE 1 END
      +invalid_product_rows,
    jsonb_build_object('categoryRows',category_rows,
      'activeProductRows',active_product_rows,
      'invalidProductRows',invalid_product_rows,'products',products)
  FROM company_scope scope
  CROSS JOIN LATERAL (
    SELECT
      count(DISTINCT category.id) AS category_rows,
      count(DISTINCT product.id) FILTER (WHERE product.is_active) AS active_product_rows,
      count(DISTINCT product.id) FILTER (WHERE product.is_active AND (
        product.uom_id IS NULL OR NOT EXISTS (
          SELECT 1 FROM public.uoms uom
          WHERE uom.company_id=product.company_id AND uom.id=product.uom_id
            AND uom.is_active))) AS invalid_product_rows,
      coalesce(jsonb_agg(DISTINCT jsonb_build_object(
        'id',product.id,'sku',product.sku,'name',product.name,
        'active',product.is_active,'uomId',product.uom_id))
        FILTER (WHERE product.id IS NOT NULL),'[]'::jsonb) AS products
    FROM public.product_categories category
    LEFT JOIN public.products product
      ON product.company_id=category.company_id AND product.category_id=category.id
    WHERE category.company_id=scope.company_id
      AND category.category_code='CAT-000011'
      AND upper(btrim(category.category_name))='KETUL'
      AND category.is_active
  ) catalog
  WHERE scope.company_id IS NOT NULL

  UNION ALL
  SELECT 50,'pos_ketul_preflight_payment_method_foundation',
    CASE WHEN count(*)<=1 THEN 'INFO' ELSE 'BLOCKER' END,
    greatest(count(*)-1,0),
    jsonb_build_object('rows',count(*),'methods',coalesce(jsonb_agg(
      jsonb_build_object('id',method.id,'code',method.payment_method_code,
        'name',method.payment_method_name,'active',method.is_active,
        'route',method.settlement_route,'system',method.is_system_method)
      ORDER BY method.payment_method_code),'[]'::jsonb),
      'meaning','Presence is foundation only; normal payment picker must remain closed')
  FROM company_scope scope
  JOIN public.payment_methods method ON method.company_id=scope.company_id
  WHERE method.method_type='KETUL_OFFSET'

  UNION ALL
  SELECT 60,'pos_ketul_preflight_finance_event_contract',
    CASE WHEN event_rows=1 AND category_rows=1 THEN 'REVIEW' ELSE 'BLOCKER' END,
    abs(event_rows-1)+abs(category_rows-1),
    jsonb_build_object('eventRows',event_rows,'categoryRows',category_rows,
      'requiredFunctionSets',required_function_sets,
      'conditionalFunctionSets',conditional_function_sets,
      'meaning','Current catalog proves Inventory only and has no dedicated Ketul payable function')
  FROM company_scope scope
  CROSS JOIN LATERAL (
    SELECT count(*) AS event_rows,
      coalesce(jsonb_agg(to_jsonb(event.required_account_functions)),
        '[]'::jsonb) AS required_function_sets,
      coalesce(jsonb_agg(to_jsonb(event.conditional_account_functions)),
        '[]'::jsonb) AS conditional_function_sets
    FROM public.system_events event
    WHERE event.system_key='KETUL_CUSTOMER_INTAKE' AND event.is_active
  ) event_contract
  CROSS JOIN LATERAL (
    SELECT count(*) AS category_rows
    FROM public.transaction_categories category
    WHERE category.company_id=scope.company_id
      AND category.system_key='KETUL_CUSTOMER_INTAKE' AND category.is_active
  ) category_contract
  WHERE scope.company_id IS NOT NULL

  UNION ALL
  SELECT 70,'pos_ketul_preflight_finance_mapping_inventory','INFO',0,
    jsonb_build_object('rows',count(*),'rules',coalesce(jsonb_agg(
      jsonb_build_object('categoryCode',category.category_code,
        'function',rule.account_function_key,'accountCode',account.account_code,
        'accountName',account.account_name,'accountType',account.account_type,
        'normalBalance',account.normal_balance,'status',rule.status)
      ORDER BY rule.account_function_key),'[]'::jsonb))
  FROM company_scope scope
  JOIN public.transaction_categories category
    ON category.company_id=scope.company_id
   AND category.system_key='KETUL_CUSTOMER_INTAKE'
  JOIN public.transaction_account_rules rule
    ON rule.company_id=category.company_id
   AND rule.transaction_category_id=category.id
  JOIN public.chart_of_accounts account
    ON account.company_id=rule.company_id AND account.id=rule.account_id
  WHERE rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
    AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())

  UNION ALL
  SELECT 80,'pos_ketul_preflight_inventory_account_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,abs(count(*)-1),
    jsonb_build_object('expectedAccountCode','1030100-4','rows',count(*),
      'accounts',coalesce(jsonb_agg(jsonb_build_object('id',account.id,
        'code',account.account_code,'name',account.account_name,
        'active',account.is_active,'postable',account.is_postable,
        'system',account.is_system_account)),'[]'::jsonb))
  FROM company_scope scope
  JOIN public.chart_of_accounts account ON account.company_id=scope.company_id
  WHERE account.account_code='1030100-4' AND account.account_type='ASSET'
    AND account.normal_balance='DEBIT' AND account.is_active
    AND account.is_postable AND NOT account.is_system_account

  UNION ALL
  SELECT 90,'pos_ketul_preflight_liability_account_inventory','REVIEW',0,
    jsonb_build_object('meaning','Finance must select/create the dedicated Ketul Customer Payable child account',
      'accounts',coalesce(jsonb_agg(jsonb_build_object('id',account.id,
        'code',account.account_code,'name',account.account_name,
        'parentCode',parent.account_code,'active',account.is_active,
        'postable',account.is_postable,'function',account.system_function_key)
        ORDER BY account.account_code),'[]'::jsonb))
  FROM company_scope scope
  JOIN public.chart_of_accounts account ON account.company_id=scope.company_id
  LEFT JOIN public.chart_of_accounts parent
    ON parent.company_id=account.company_id AND parent.id=account.parent_account_id
  WHERE account.account_type='LIABILITY' AND account.normal_balance='CREDIT'
    AND account.is_active

  UNION ALL
  SELECT 100,'pos_ketul_preflight_runtime_absence',
    CASE WHEN ketul_routines=0 AND checkout_blocks_ketul THEN 'PASS' ELSE 'BLOCKER' END,
    ketul_routines+CASE WHEN checkout_blocks_ketul THEN 0 ELSE 1 END,
    jsonb_build_object('ketulNamedRoutines',ketul_routines,
      'checkoutBlocksKetul',checkout_blocks_ketul,
      'classification','NOT_INSTALLED_OPERATIONAL_RUNTIME')
  FROM (
    SELECT
      (SELECT count(*) FROM pg_proc proc
       JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
       WHERE namespace.nspname IN('public','private')
         AND proc.proname ILIKE '%ketul%') AS ketul_routines,
      coalesce(pg_get_functiondef(to_regprocedure(
        'private.post_pos_sale_online_core(uuid,bigint,uuid)')) LIKE
          '%DEFERRED_PAYMENT_METHOD_NOT_ENABLED%',false) AS checkout_blocks_ketul
  ) runtime

  UNION ALL
  SELECT 110,'pos_ketul_preflight_runtime_boundary',
    CASE WHEN active_finance_queue=0 AND nonterminal_offline=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    active_finance_queue+nonterminal_offline,
    jsonb_build_object('activeFinanceQueue',active_finance_queue,
      'nonterminalOffline',nonterminal_offline)
  FROM (
    SELECT
      (SELECT count(*) FROM public.finance_posting_queue_runs
       WHERE status IN ('PREVIEWED','APPROVED','PROCESSING')) AS active_finance_queue,
      (SELECT count(*) FROM public.pos_offline_sale_submissions
       WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION')) AS nonterminal_offline
  ) boundary

  UNION ALL
  SELECT 120,'pos_ketul_preflight_business_boundary','INFO',0,
    jsonb_build_object('company','KGFF only','mutation','NONE',
      'included',jsonb_build_array('linked Retail POS Ketul intake','Stock/FIFO inbound',
        'dedicated Ketul payable','linked after-tax Sale offset','Ketul correction'),
      'excluded',jsonb_build_array('Ketul Vendor','standalone Ketul intake',
        'Customer Balance payout','Backoffice/ODR changes','historical Posted rewrites'))
)
SELECT check_name,status,violation_rows,details
FROM checks ORDER BY seq;
