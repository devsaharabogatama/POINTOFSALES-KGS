-- Read-only verification after gate 20260909153000.
WITH active_companies AS (
  SELECT count(*) company_count FROM public.companies WHERE status='ACTIVE'
), results AS (
  SELECT 'migration_ledger'::text check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909153000'
  UNION ALL
  SELECT 'receipt_system_event_contract',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-1)::bigint,jsonb_build_object('eventRows',count(*))
  FROM public.system_events WHERE system_key='BACKOFFICE_CUSTOMER_RECEIPT'
    AND event_group='SALES' AND is_active
    AND required_account_functions=ARRAY['COGS','INVENTORY_ASSET']::text[]
    AND conditional_account_functions=ARRAY[]::text[]
  UNION ALL
  SELECT 'receipt_category_company_coverage',
    CASE WHEN count(*)=(SELECT company_count FROM active_companies)
      AND count(*)=count(DISTINCT category.company_id) THEN 'PASS' ELSE 'FAIL' END,
    GREATEST(abs(count(*)-(SELECT company_count FROM active_companies)),
      (SELECT company_count FROM active_companies)-count(DISTINCT category.company_id))::bigint,
    jsonb_build_object('categoryRows',count(*),'activeCompanies',
      (SELECT company_count FROM active_companies))
  FROM public.transaction_categories category JOIN public.companies company
    ON company.id=category.company_id AND company.status='ACTIVE'
  WHERE category.system_key='BACKOFFICE_CUSTOMER_RECEIPT' AND category.is_active
  UNION ALL
  SELECT 'receipt_account_rule_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidCompanies',count(*))
  FROM (SELECT category.company_id,count(rule.id) rule_count,
      count(DISTINCT rule.account_function_key) function_count
    FROM public.transaction_categories category
    JOIN public.companies company ON company.id=category.company_id AND company.status='ACTIVE'
    LEFT JOIN public.transaction_account_rules rule ON rule.company_id=category.company_id
      AND rule.transaction_category_id=category.id
      AND rule.system_key='BACKOFFICE_CUSTOMER_RECEIPT' AND rule.status='ACTIVE'
    WHERE category.system_key='BACKOFFICE_CUSTOMER_RECEIPT' AND category.is_active
    GROUP BY category.company_id) invalid
  WHERE rule_count<>2 OR function_count<>2
  UNION ALL
  SELECT 'receipt_posting_rule_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidCompanies',count(*))
  FROM (SELECT category.company_id,count(DISTINCT rule_set.id) set_count,
      count(line.id) line_count,count(DISTINCT line.account_function_key) function_count
    FROM public.transaction_categories category
    JOIN public.companies company ON company.id=category.company_id AND company.status='ACTIVE'
    LEFT JOIN public.posting_rule_sets rule_set ON rule_set.company_id=category.company_id
      AND rule_set.transaction_category_id=category.id
      AND rule_set.system_key='BACKOFFICE_CUSTOMER_RECEIPT' AND rule_set.status='APPROVED'
    LEFT JOIN public.posting_rule_lines line ON line.company_id=rule_set.company_id
      AND line.rule_set_id=rule_set.id
    WHERE category.system_key='BACKOFFICE_CUSTOMER_RECEIPT' AND category.is_active
    GROUP BY category.company_id) invalid
  WHERE set_count<>1 OR line_count<>2 OR function_count<>2
  UNION ALL
  SELECT 'mapping_zero_runtime_effect',CASE WHEN event_count+journal_count=0 THEN 'PASS' ELSE 'FAIL' END,
    (event_count+journal_count)::bigint,
    jsonb_build_object('financialEvents',event_count,'financeJournals',journal_count)
  FROM (SELECT (SELECT count(*) FROM public.financial_events
        WHERE system_event_key='BACKOFFICE_CUSTOMER_RECEIPT') event_count,
      (SELECT count(*) FROM public.finance_journals
        WHERE system_event_key='BACKOFFICE_CUSTOMER_RECEIPT') journal_count) tally
)
SELECT * FROM results ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
