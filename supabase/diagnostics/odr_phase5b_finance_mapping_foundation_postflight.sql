-- ODR-5B Finance mapping foundation postflight. SELECT-only.
WITH active_companies AS (
  SELECT id,company_code FROM public.companies WHERE status='ACTIVE'
),expected_categories(system_key,category_code,line_count,rule_count) AS (
  VALUES('SALE_DISPATCHED'::TEXT,'ODR-SALE-DISPATCHED'::TEXT,11,11),
    ('SALE_PAYMENT_VERIFIED','ODR-SALE-PAYMENT-VERIFIED',7,6)
),category_scope AS (
  SELECT company.id company_id,company.company_code,expected.*,
    category.id category_id
  FROM active_companies company CROSS JOIN expected_categories expected
  LEFT JOIN public.transaction_categories category
    ON category.company_id=company.id AND category.system_key=expected.system_key
   AND category.category_code=expected.category_code AND category.is_active
),checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828220000'
  UNION ALL
  SELECT 'customer_advance_account_contract',
    CASE WHEN count(*)=(SELECT count(*) FROM active_companies) THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',(SELECT count(*) FROM active_companies),'accountRows',count(*))
  FROM public.chart_of_accounts account JOIN active_companies company
    ON company.id=account.company_id
  WHERE account.account_code='2190' AND account.account_name='Uang Muka Customer'
    AND account.system_function_key='CUSTOMER_ADVANCE_LIABILITY'
    AND account.account_type='LIABILITY' AND account.normal_balance='CREDIT'
    AND account.is_system_account AND account.is_active AND account.is_postable
    AND account.allow_reconciliation AND NOT account.allow_manual_posting
  UNION ALL
  SELECT 'odr_dispatch_event_account_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('eventRows',count(*))
  FROM public.system_events system_event
  WHERE system_event.system_key='SALE_DISPATCHED' AND system_event.is_active
    AND system_event.conditional_account_functions=ARRAY[
      'CUSTOMER_RECEIVABLE','PAYMENT_CLEARING','CUSTOMER_ADVANCE_LIABILITY',
      'OUTPUT_TAX','DELIVERY_FEE_REVENUE','PAYMENT_SURCHARGE_INCOME',
      'ROUNDING_GAIN','ROUNDING_LOSS']::TEXT[]
  UNION ALL
  SELECT 'odr_transaction_category_contract',
    CASE WHEN count(*)=(SELECT count(*) FROM category_scope) THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',(SELECT count(*) FROM category_scope),'categoryRows',count(*))
  FROM category_scope WHERE category_id IS NOT NULL
  UNION ALL
  SELECT 'odr_exact_account_mapping_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('invalidRows',count(*))
  FROM category_scope scope
  WHERE scope.category_id IS NULL OR (SELECT count(*)
    FROM public.transaction_account_rules rule
    JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
      AND account.id=rule.account_id AND account.is_active AND account.is_postable
    WHERE rule.company_id=scope.company_id
      AND rule.transaction_category_id=scope.category_id
      AND rule.system_key=scope.system_key AND rule.status='ACTIVE'
      AND rule.effective_from<=clock_timestamp()
      AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp()))<>scope.rule_count
  UNION ALL
  SELECT 'approved_posting_rule_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('invalidRows',count(*))
  FROM category_scope scope
  WHERE scope.category_id IS NULL OR (SELECT count(*)
    FROM public.posting_rule_sets rule_set
    WHERE rule_set.company_id=scope.company_id
      AND rule_set.transaction_category_id=scope.category_id
      AND rule_set.system_key=scope.system_key AND rule_set.status='APPROVED'
      AND rule_set.effective_from<=clock_timestamp()
      AND (rule_set.effective_to IS NULL OR rule_set.effective_to>clock_timestamp()))<>1
    OR (SELECT count(*) FROM public.posting_rule_lines line
      JOIN public.posting_rule_sets rule_set ON rule_set.company_id=line.company_id
        AND rule_set.id=line.rule_set_id
      WHERE rule_set.company_id=scope.company_id
        AND rule_set.transaction_category_id=scope.category_id
        AND rule_set.status='APPROVED')<>scope.line_count
  UNION ALL
  SELECT 'odr_mapping_audit_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('missingAuditRows',count(*))
  FROM category_scope scope
  WHERE scope.category_id IS NULL OR NOT EXISTS(SELECT 1
    FROM public.finance_master_audit audit
    WHERE audit.company_id=scope.company_id AND audit.entity_type='CATEGORY'
      AND audit.entity_id=scope.category_id AND audit.action='CREATE')
    OR NOT EXISTS(SELECT 1 FROM public.posting_rule_sets rule_set
      JOIN public.posting_rule_set_audit audit
        ON audit.company_id=rule_set.company_id AND audit.rule_set_id=rule_set.id
      WHERE rule_set.company_id=scope.company_id
        AND rule_set.transaction_category_id=scope.category_id
        AND audit.action='APPROVE')
  UNION ALL
  SELECT 'odr_finance_zero_runtime_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('eventOrJournalRows',count(*))
  FROM public.financial_events event
  LEFT JOIN public.finance_journals journal
    ON journal.company_id=event.company_id AND journal.financial_event_id=event.id
  WHERE event.system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
     OR journal.id IS NOT NULL AND event.system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
),inventory AS (
  SELECT 'odr_mapping_runtime_inventory' check_name,'INFO' status,
    jsonb_build_object('activeCompanies',(SELECT count(*) FROM active_companies),
      'advanceAccounts',(SELECT count(*) FROM public.chart_of_accounts account
        JOIN active_companies company ON company.id=account.company_id
        WHERE account.system_function_key='CUSTOMER_ADVANCE_LIABILITY'
          AND account.is_system_account),
      'categories',(SELECT count(*) FROM category_scope WHERE category_id IS NOT NULL),
      'activeRules',(SELECT count(*) FROM public.transaction_account_rules rule
        JOIN category_scope scope ON scope.company_id=rule.company_id
          AND scope.category_id=rule.transaction_category_id WHERE rule.status='ACTIVE'),
      'approvedRuleSets',(SELECT count(*) FROM public.posting_rule_sets rule_set
        JOIN category_scope scope ON scope.company_id=rule_set.company_id
          AND scope.category_id=rule_set.transaction_category_id
        WHERE rule_set.status='APPROVED'),
      'historicalPostedJournals',(SELECT count(*) FROM public.finance_journals
        WHERE status='POSTED')) details
)
SELECT result.check_name,result.status,result.details
FROM (
  SELECT * FROM checks
  UNION ALL
  SELECT * FROM inventory
) result
ORDER BY CASE result.status
  WHEN 'FAIL' THEN 1
  WHEN 'PASS' THEN 2
  ELSE 3
END,result.check_name;
