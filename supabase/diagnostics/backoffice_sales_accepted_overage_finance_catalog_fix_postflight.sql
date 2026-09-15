-- SELECT-only verification for C3 accepted-overage Finance catalog forward-fix.
WITH active_companies AS (
  SELECT company.id FROM public.companies company WHERE company.status='ACTIVE'
), function_fact AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)')) definition
), checks AS (
  SELECT 'c3g_migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912132000'
  UNION ALL
  SELECT 'c3g_system_event_contract',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('eventRows',count(*))
  FROM public.system_events event
  WHERE event.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS' AND event.event_group='SALES'
    AND event.required_account_functions=ARRAY['COGS','INVENTORY_ASSET']::text[]
    AND event.conditional_account_functions=ARRAY[]::text[]
    AND event.optional_account_functions=ARRAY[]::text[] AND event.is_active
  UNION ALL
  SELECT 'c3g_category_company_coverage',
    CASE WHEN count(*)=(SELECT count(*) FROM active_companies)
      AND count(*)=count(DISTINCT category.company_id) THEN 'PASS' ELSE 'FAIL' END,
    greatest(abs(count(*)-(SELECT count(*) FROM active_companies)),
      (SELECT count(*) FROM active_companies)-count(DISTINCT category.company_id)),
    jsonb_build_object('categoryRows',count(*),'activeCompanies',(SELECT count(*) FROM active_companies))
  FROM public.transaction_categories category JOIN active_companies company
    ON company.id=category.company_id
  WHERE category.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS' AND category.is_active
  UNION ALL
  SELECT 'c3g_account_rule_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidCompanies',count(*))
  FROM (SELECT category.company_id,count(rule.id) rule_count,
      count(DISTINCT rule.account_function_key) function_count
    FROM public.transaction_categories category JOIN active_companies company
      ON company.id=category.company_id
    LEFT JOIN public.transaction_account_rules rule ON rule.company_id=category.company_id
      AND rule.transaction_category_id=category.id
      AND rule.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS' AND rule.status='ACTIVE'
      AND rule.effective_from<=clock_timestamp()
      AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
    WHERE category.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS' AND category.is_active
    GROUP BY category.company_id) invalid
  WHERE rule_count<>2 OR function_count<>2
  UNION ALL
  SELECT 'c3g_posting_rule_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidCompanies',count(*))
  FROM (SELECT category.company_id,count(DISTINCT rule_set.id) set_count,
      count(line.id) line_count,count(DISTINCT line.account_function_key) function_count,
      count(DISTINCT line.amount_expression_key) expression_count
    FROM public.transaction_categories category JOIN active_companies company
      ON company.id=category.company_id
    LEFT JOIN public.posting_rule_sets rule_set ON rule_set.company_id=category.company_id
      AND rule_set.transaction_category_id=category.id
      AND rule_set.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
      AND rule_set.status='APPROVED' AND rule_set.effective_from<=clock_timestamp()
      AND (rule_set.effective_to IS NULL OR rule_set.effective_to>clock_timestamp())
    LEFT JOIN public.posting_rule_lines line ON line.company_id=rule_set.company_id
      AND line.rule_set_id=rule_set.id
    WHERE category.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS' AND category.is_active
    GROUP BY category.company_id) invalid
  WHERE set_count<>1 OR line_count<>2 OR function_count<>2 OR expression_count<>1
  UNION ALL
  SELECT 'c3g_resolver_definition_contract',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE definition IS NOT NULL)=1
      AND bool_and(position('category.system_key=''SALE_POSTED''' in definition)=0)
      AND bool_and(position('category.system_key=''BACKOFFICE_ACCEPTED_OVERAGE_COGS''' in definition)>0)
      AND bool_and(position('transaction_rule_version)' in definition)>0)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE definition IS NOT NULL)=1
      AND bool_and(position('category.system_key=''SALE_POSTED''' in definition)=0)
      AND bool_and(position('category.system_key=''BACKOFFICE_ACCEPTED_OVERAGE_COGS''' in definition)>0)
      AND bool_and(position('transaction_rule_version)' in definition)>0)
      THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*),'newCategoryAnchorRows',count(*) FILTER(
      WHERE position('category.system_key=''BACKOFFICE_ACCEPTED_OVERAGE_COGS''' in definition)>0),
      'versionedEventColumnRows',count(*) FILTER(
      WHERE position('transaction_rule_version)' in definition)>0))
  FROM function_fact
  UNION ALL
  SELECT 'c3g_event_mapping_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidEvents',count(*))
  FROM public.financial_events event
  LEFT JOIN public.transaction_categories category ON category.company_id=event.company_id
    AND category.id=event.transaction_category_id
  LEFT JOIN public.posting_rule_sets rule_set ON rule_set.company_id=event.company_id
    AND rule_set.transaction_category_id=event.transaction_category_id
    AND rule_set.system_key=event.system_event_key
    AND rule_set.rule_set_version=event.transaction_rule_version
  WHERE event.system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
    AND (category.id IS NULL OR category.system_key<>event.system_event_key
      OR rule_set.id IS NULL OR event.source_table<>'backoffice_sales_discrepancy_stock_effects'
      OR event.status<>'HOLD'::public.event_status)
  UNION ALL
  SELECT 'c3g_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges
  WHERE specific_schema='private' AND grantee IN('anon','authenticated')
    AND routine_name IN('provision_backoffice_accepted_overage_finance',
      'trg_provision_backoffice_accepted_overage_finance') AND privilege_type='EXECUTE'
  UNION ALL
  SELECT 'c3g_runtime_inventory','INFO',0,jsonb_build_object(
    'acceptedOverageEvents',count(*),'holdEvents',count(*) FILTER(WHERE status='HOLD'::public.event_status),
    'postedEvents',count(*) FILTER(WHERE status='POSTED'::public.event_status))
  FROM public.financial_events WHERE system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
