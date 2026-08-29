-- ODR-5B Finance mapping and runtime preflight.
-- SAFETY: SELECT-only. No master, event, queue or journal mutation.
WITH dependency_versions(version) AS (
  VALUES('20260828210000'::TEXT),('20260827140000'::TEXT),
    ('20260827141000'::TEXT)
), target_events(system_key,category_code,category_name) AS (
  VALUES
    ('SALE_DISPATCHED'::TEXT,'ODR-SALE-DISPATCHED'::TEXT,
      'ODR Dispatch Penjualan'::TEXT),
    ('SALE_PAYMENT_VERIFIED','ODR-SALE-PAYMENT-VERIFIED',
      'ODR Verifikasi Pembayaran Penjualan')
), target_functions(function_key,function_scope) AS (
  VALUES
    ('SALES_REVENUE'::TEXT,'CORE'::TEXT),
    ('INVENTORY_ASSET','CORE'),('COGS','CORE'),
    ('CUSTOMER_RECEIVABLE','CORE'),('PAYMENT_CLEARING','CORE'),
    ('CASH_DRAWER','CORE'),('BANK','CORE'),
    ('CUSTOMER_ADVANCE_LIABILITY','ADVANCE'),
    ('OUTPUT_TAX','CONDITIONAL'),('DELIVERY_FEE_REVENUE','CONDITIONAL'),
    ('PAYMENT_SURCHARGE_INCOME','CONDITIONAL'),
    ('ROUNDING_GAIN','CONDITIONAL'),('ROUNDING_LOSS','CONDITIONAL')
), active_companies AS (
  SELECT company.id company_id,company.company_code,company.company_name
  FROM public.companies company WHERE company.status='ACTIVE'
), account_candidates AS (
  SELECT company.company_id,company.company_code,company.company_name,
    target_function.function_key,target_function.function_scope,
    count(DISTINCT account.id) FILTER(WHERE account.id IS NOT NULL
      AND account.is_active AND account.is_postable) direct_accounts,
    count(DISTINCT fallback.id) FILTER(WHERE fallback.id IS NOT NULL
      AND fallback.status='ACTIVE'
      AND fallback.effective_from<=clock_timestamp()
      AND (fallback.effective_to IS NULL
        OR fallback.effective_to>clock_timestamp())
      AND fallback_account.is_active AND fallback_account.is_postable)
      fallback_rows
  FROM active_companies company CROSS JOIN target_functions target_function
  LEFT JOIN public.chart_of_accounts account
    ON account.company_id=company.company_id
   AND account.system_function_key=target_function.function_key
  LEFT JOIN public.company_account_function_fallbacks fallback
    ON fallback.company_id=company.company_id
   AND fallback.account_function_key=target_function.function_key
  LEFT JOIN public.chart_of_accounts fallback_account
    ON fallback_account.company_id=fallback.company_id
   AND fallback_account.id=fallback.account_id
  GROUP BY company.company_id,company.company_code,company.company_name,
    target_function.function_key,target_function.function_scope
), account_readiness AS (
  SELECT candidate.*,
    CASE WHEN candidate.direct_accounts=1 THEN 'READY'
      WHEN candidate.direct_accounts=0 AND candidate.fallback_rows=1
        THEN 'READY'
      WHEN candidate.direct_accounts=0 AND candidate.fallback_rows=0
        THEN 'MISSING'
      ELSE 'AMBIGUOUS' END resolution_state
  FROM account_candidates candidate
), category_scope AS (
  SELECT company.company_id,company.company_code,target.system_key,
    target.category_code,target.category_name,
    count(DISTINCT category.id) FILTER(WHERE category.system_key=target.system_key
      AND upper(regexp_replace(btrim(category.category_code),'\s+',' ','g'))=
        upper(target.category_code) AND category.is_active) exact_categories,
    count(DISTINCT category.id) FILTER(WHERE
      (upper(regexp_replace(btrim(category.category_code),'\s+',' ','g'))=
        upper(target.category_code)
       OR lower(regexp_replace(btrim(category.category_name),'\s+',' ','g'))=
        lower(target.category_name))
      AND category.system_key<>target.system_key) identity_collisions
  FROM active_companies company CROSS JOIN target_events target
  LEFT JOIN public.transaction_categories category
    ON category.company_id=company.company_id
   AND (category.system_key=target.system_key
    OR upper(regexp_replace(btrim(category.category_code),'\s+',' ','g'))=
      upper(target.category_code)
    OR lower(regexp_replace(btrim(category.category_name),'\s+',' ','g'))=
      lower(target.category_name))
  GROUP BY company.company_id,company.company_code,target.system_key,
    target.category_code,target.category_name
), approved_rule_scope AS (
  SELECT scope.company_id,scope.company_code,scope.system_key,
    count(DISTINCT rule_set.id) FILTER(WHERE rule_set.status='APPROVED'
      AND rule_set.effective_from<=clock_timestamp()
      AND (rule_set.effective_to IS NULL
        OR rule_set.effective_to>clock_timestamp())) approved_rule_sets
  FROM category_scope scope
  LEFT JOIN public.transaction_categories category
    ON category.company_id=scope.company_id
   AND category.system_key=scope.system_key AND category.is_active
  LEFT JOIN public.posting_rule_sets rule_set
    ON rule_set.company_id=category.company_id
   AND rule_set.transaction_category_id=category.id
   AND rule_set.system_key=scope.system_key
  GROUP BY scope.company_id,scope.company_code,scope.system_key
), advance_code_collisions AS (
  SELECT account.company_id,company.company_code,account.id,account.account_code,
    account.account_name,account.system_function_key
  FROM public.chart_of_accounts account
  JOIN active_companies company ON company.company_id=account.company_id
  WHERE (upper(regexp_replace(btrim(account.account_code),'\s+',' ','g'))='2190'
      OR lower(regexp_replace(btrim(account.account_name),'\s+',' ','g'))=
        'uang muka customer')
    AND account.system_function_key IS DISTINCT FROM
      'CUSTOMER_ADVANCE_LIABILITY'
), runtime_definition AS (
  SELECT
    COALESCE((SELECT procedure.prosrc FROM pg_proc procedure
      JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
      WHERE namespace.nspname='private'
        AND procedure.proname='post_financial_event_core'
        AND pg_get_function_identity_arguments(procedure.oid)=
          'p_company_id uuid, p_event_id uuid, p_expected_event_version bigint, p_actor_id uuid'
      LIMIT 1),'') dispatcher_source,
    COALESCE((SELECT procedure.prosrc FROM pg_proc procedure
      JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
      WHERE namespace.nspname='private'
        AND procedure.proname='f4b_financial_event_supported'
      LIMIT 1),'') queue_support_source
), checks AS (
  SELECT 'odr_phase5b_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(
      dependency.version ORDER BY dependency.version)
      FILTER(WHERE migration.version IS NULL),'[]'::JSONB)) details
  FROM dependency_versions dependency
  LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=dependency.version

  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')

  UNION ALL
  SELECT 'odr_phase5a_foundation_state',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',4,'relationRows',count(*))
  FROM (VALUES('public.sales_dispatch_financial_effects'::TEXT),
      ('public.sales_payment_verification_requests'),
      ('public.sales_dispatch_financial_effect_audit'),
      ('public.sales_payment_verification_audit')) required(relation_name)
  WHERE to_regclass(required.relation_name) IS NOT NULL

  UNION ALL
  SELECT 'odr_event_type_runtime_state',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',2,'enumRows',count(*),'required',
      jsonb_build_array('SALE_POSTED','PAYMENT_RECEIVED'))
  FROM pg_enum enum_value JOIN pg_type enum_type
    ON enum_type.oid=enum_value.enumtypid
  JOIN pg_namespace namespace ON namespace.oid=enum_type.typnamespace
  WHERE namespace.nspname='public' AND enum_type.typname='event_type'
    AND enum_value.enumlabel IN('SALE_POSTED','PAYMENT_RECEIVED')

  UNION ALL
  SELECT 'odr_target_category_identity_collision',
    CASE WHEN COALESCE(sum(identity_collisions),0)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('collisionRows',COALESCE(sum(identity_collisions),0),
      'companyCodes',COALESCE(jsonb_agg(DISTINCT company_code)
        FILTER(WHERE identity_collisions>0),'[]'::JSONB))
  FROM category_scope

  UNION ALL
  SELECT 'odr_target_category_state',
    CASE WHEN count(*) FILTER(WHERE exact_categories<>1)=0
      THEN 'PASS' ELSE 'SETUP' END,
    jsonb_build_object('expectedPerCompany',2,'companies',
      count(DISTINCT company_id),'missingOrAmbiguous',count(*) FILTER(
        WHERE exact_categories<>1))
  FROM category_scope

  UNION ALL
  SELECT 'odr_approved_posting_rule_state',
    CASE WHEN count(*) FILTER(WHERE approved_rule_sets<>1)=0
      THEN 'PASS' ELSE 'SETUP' END,
    jsonb_build_object('expectedPerCompany',2,'missingOrAmbiguous',
      count(*) FILTER(WHERE approved_rule_sets<>1))
  FROM approved_rule_scope

  UNION ALL
  SELECT 'core_account_mapping_candidate_state',
    CASE WHEN count(*) FILTER(WHERE resolution_state<>'READY')=0
      THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('invalidRows',count(*) FILTER(
        WHERE resolution_state<>'READY'),
      'functions',COALESCE(jsonb_agg(DISTINCT function_key ORDER BY function_key)
        FILTER(WHERE resolution_state<>'READY'),'[]'::JSONB),
      'companyCodes',COALESCE(jsonb_agg(DISTINCT company_code ORDER BY company_code)
        FILTER(WHERE resolution_state<>'READY'),'[]'::JSONB))
  FROM account_readiness WHERE function_scope='CORE'

  UNION ALL
  SELECT 'conditional_account_mapping_candidate_state',
    CASE WHEN count(*) FILTER(WHERE resolution_state<>'READY')=0
      THEN 'PASS' ELSE 'REVIEW' END,
    jsonb_build_object('invalidRows',count(*) FILTER(
        WHERE resolution_state<>'READY'),
      'functions',COALESCE(jsonb_agg(DISTINCT function_key ORDER BY function_key)
        FILTER(WHERE resolution_state<>'READY'),'[]'::JSONB),
      'companyCodes',COALESCE(jsonb_agg(DISTINCT company_code ORDER BY company_code)
        FILTER(WHERE resolution_state<>'READY'),'[]'::JSONB))
  FROM account_readiness WHERE function_scope='CONDITIONAL'

  UNION ALL
  SELECT 'customer_advance_mapping_candidate_state',
    CASE WHEN count(*) FILTER(WHERE resolution_state<>'READY')=0
      THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('invalidRows',count(*) FILTER(
        WHERE resolution_state<>'READY'),
      'companyCodes',COALESCE(jsonb_agg(company_code ORDER BY company_code)
        FILTER(WHERE resolution_state<>'READY'),'[]'::JSONB),
      'resolutionStates',COALESCE(jsonb_object_agg(company_code,resolution_state),
        '{}'::JSONB))
  FROM account_readiness WHERE function_scope='ADVANCE'

  UNION ALL
  SELECT 'customer_advance_coa_identity_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
    jsonb_build_object('collisionRows',count(*),'targetCode','2190',
      'companyCodes',COALESCE(jsonb_agg(DISTINCT company_code ORDER BY company_code),
        '[]'::JSONB))
  FROM advance_code_collisions

  UNION ALL
  SELECT 'odr_dispatcher_runtime_state',
    CASE WHEN dispatcher_source LIKE '%SALE_DISPATCHED%'
      AND dispatcher_source LIKE '%SALE_PAYMENT_VERIFIED%'
      THEN 'PASS' ELSE 'SETUP' END,
    jsonb_build_object('dispatchSupported',
      dispatcher_source LIKE '%SALE_DISPATCHED%',
      'paymentSupported',dispatcher_source LIKE '%SALE_PAYMENT_VERIFIED%')
  FROM runtime_definition

  UNION ALL
  SELECT 'odr_controlled_queue_support_state',
    CASE WHEN queue_support_source LIKE '%SALE_DISPATCHED%'
      AND queue_support_source LIKE '%SALE_PAYMENT_VERIFIED%'
      THEN 'PASS' ELSE 'SETUP' END,
    jsonb_build_object('dispatchSupported',
      queue_support_source LIKE '%SALE_DISPATCHED%',
      'paymentSupported',queue_support_source LIKE '%SALE_PAYMENT_VERIFIED%')
  FROM runtime_definition

  UNION ALL
  SELECT 'odr_finance_source_zero_runtime',
    CASE WHEN dispatch_rows+payment_rows=0 THEN 'PASS' ELSE 'REVIEW' END,
    jsonb_build_object('dispatchEffects',dispatch_rows,
      'paymentRequests',payment_rows)
  FROM (SELECT
    (SELECT count(*) FROM public.sales_dispatch_financial_effects) dispatch_rows,
    (SELECT count(*) FROM public.sales_payment_verification_requests) payment_rows
  ) inventory

  UNION ALL
  SELECT 'odr_finance_mapping_runtime_inventory','INFO',jsonb_build_object(
    'activeCompanies',(SELECT count(*) FROM active_companies),
    'categoryRows',(SELECT count(*) FROM public.transaction_categories
      WHERE system_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')),
    'approvedRuleSets',(SELECT count(*) FROM public.posting_rule_sets
      WHERE system_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
        AND status='APPROVED'),
    'controlledCompanies',(SELECT count(*) FROM public.finance_company_policies
      WHERE posting_mode='CONTROLLED'),
    'automaticCompanies',(SELECT count(*) FROM public.finance_company_policies
      WHERE posting_mode='AUTOMATIC'),
    'historicalPostedJournals',(SELECT count(*) FROM public.finance_journals
      WHERE status='POSTED'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'BACKFILL' THEN 1
  WHEN 'PASS' THEN 2 WHEN 'REVIEW' THEN 3 WHEN 'SETUP' THEN 4 ELSE 5 END,
  check_name;
