-- Read-only postflight for 20260909160000.
WITH active_company AS (
  SELECT id FROM public.companies WHERE status='ACTIVE'
), expected_mapping(system_key,account_function_key) AS (
  VALUES
    ('BACKOFFICE_SALES_INVOICE'::text,'CUSTOMER_RECEIVABLE'::text),
    ('BACKOFFICE_SALES_INVOICE','SALES_REVENUE'),
    ('BACKOFFICE_SALES_INVOICE','OUTPUT_TAX'),
    ('BACKOFFICE_SALES_INVOICE','CUSTOMER_ADVANCE_LIABILITY'),
    ('BACKOFFICE_SALES_DOWN_PAYMENT','CUSTOMER_RECEIVABLE'),
    ('BACKOFFICE_SALES_DOWN_PAYMENT','CUSTOMER_ADVANCE_LIABILITY'),
    ('BACKOFFICE_SALES_DOWN_PAYMENT','OUTPUT_TAX')
), expected_company_mapping AS (
  SELECT company.id company_id,mapping.* FROM active_company company
  CROSS JOIN expected_mapping mapping
), actual_mapping AS (
  SELECT rule.company_id,rule.system_key,rule.account_function_key
  FROM public.transaction_account_rules rule
  JOIN public.transaction_categories category ON category.company_id=rule.company_id
    AND category.id=rule.transaction_category_id
    AND category.system_key=rule.system_key AND category.is_active
  JOIN active_company company ON company.id=rule.company_id
  WHERE rule.system_key IN('BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')
    AND rule.status='ACTIVE' AND rule.rule_version=1
    AND rule.effective_from='-infinity'::timestamptz AND rule.effective_to IS NULL
), missing_mapping AS (
  SELECT * FROM expected_company_mapping EXCEPT SELECT * FROM actual_mapping
), unexpected_mapping AS (
  SELECT * FROM actual_mapping EXCEPT SELECT * FROM expected_company_mapping
), mapping_delta AS (
  SELECT * FROM missing_mapping UNION ALL SELECT * FROM unexpected_mapping
), expected_definition(system_key,line_no,account_function_key,entry_side,
    amount_expression_key,condition_key,is_required) AS (
  VALUES
    ('BACKOFFICE_SALES_INVOICE'::text,10,'CUSTOMER_RECEIVABLE','DEBIT',
      'BACKOFFICE_INVOICE_RECEIVABLE',NULL::text,true),
    ('BACKOFFICE_SALES_INVOICE',20,'CUSTOMER_ADVANCE_LIABILITY','DEBIT',
      'BACKOFFICE_INVOICE_DP_BASIS_APPLIED','BACKOFFICE_INVOICE_HAS_DP',false),
    ('BACKOFFICE_SALES_INVOICE',30,'SALES_REVENUE','CREDIT',
      'BACKOFFICE_INVOICE_REVENUE_DPP',NULL,true),
    ('BACKOFFICE_SALES_INVOICE',40,'OUTPUT_TAX','CREDIT',
      'BACKOFFICE_INVOICE_REMAINING_OUTPUT_TAX','BACKOFFICE_INVOICE_HAS_TAX',false),
    ('BACKOFFICE_SALES_DOWN_PAYMENT',10,'CUSTOMER_RECEIVABLE','DEBIT',
      'BACKOFFICE_DP_RECEIVABLE',NULL,true),
    ('BACKOFFICE_SALES_DOWN_PAYMENT',20,'CUSTOMER_ADVANCE_LIABILITY','CREDIT',
      'BACKOFFICE_DP_BASIS',NULL,true),
    ('BACKOFFICE_SALES_DOWN_PAYMENT',30,'OUTPUT_TAX','CREDIT',
      'BACKOFFICE_DP_OUTPUT_TAX','BACKOFFICE_DP_HAS_TAX',false)
), expected_company_definition AS (
  SELECT company.id company_id,definition.* FROM active_company company
  CROSS JOIN expected_definition definition
), actual_definition AS (
  SELECT rule_set.company_id,rule_set.system_key,line.line_no,
    line.account_function_key,line.entry_side,line.amount_expression_key,
    line.condition_key,line.is_required
  FROM public.posting_rule_sets rule_set
  JOIN public.posting_rule_lines line ON line.company_id=rule_set.company_id
    AND line.rule_set_id=rule_set.id
  JOIN active_company company ON company.id=rule_set.company_id
  WHERE rule_set.system_key IN('BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')
    AND rule_set.status='APPROVED' AND rule_set.rule_set_version=1
    AND rule_set.effective_from='-infinity'::timestamptz
    AND rule_set.effective_to IS NULL
), missing_definition AS (
  SELECT * FROM expected_company_definition
  EXCEPT SELECT * FROM actual_definition
), unexpected_definition AS (
  SELECT * FROM actual_definition
  EXCEPT SELECT * FROM expected_company_definition
), definition_delta AS (
  SELECT * FROM missing_definition UNION ALL SELECT * FROM unexpected_definition
), checks AS (
  SELECT 'migration_ledger'::text check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909160000'
  UNION ALL
  SELECT 'invoice_system_event_catalog',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*))::bigint,jsonb_build_object('eventRows',count(*),'expected',2)
  FROM public.system_events WHERE system_key IN(
    'BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')
  UNION ALL
  SELECT 'invoice_system_event_definition',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.system_events event WHERE
    (event.system_key='BACKOFFICE_SALES_INVOICE' AND (
      event.event_group<>'SALES'
      OR event.required_account_functions<>ARRAY['CUSTOMER_RECEIVABLE','SALES_REVENUE']::text[]
      OR event.conditional_account_functions<>
        ARRAY['OUTPUT_TAX','CUSTOMER_ADVANCE_LIABILITY']::text[]
      OR event.optional_account_functions<>ARRAY[]::text[] OR NOT event.is_active))
    OR (event.system_key='BACKOFFICE_SALES_DOWN_PAYMENT' AND (
      event.event_group<>'SALES'
      OR event.required_account_functions<>
        ARRAY['CUSTOMER_RECEIVABLE','CUSTOMER_ADVANCE_LIABILITY']::text[]
      OR event.conditional_account_functions<>ARRAY['OUTPUT_TAX']::text[]
      OR event.optional_account_functions<>ARRAY[]::text[] OR NOT event.is_active))
  UNION ALL
  SELECT 'invoice_finance_category_scope',
    CASE WHEN count(*)=(SELECT count(*)*2 FROM active_company) THEN 'PASS' ELSE 'FAIL' END,
    abs((SELECT count(*)*2 FROM active_company)-count(*))::bigint,
    jsonb_build_object('categoryRows',count(*),'expected',(SELECT count(*)*2 FROM active_company))
  FROM public.transaction_categories category JOIN active_company company
    ON company.id=category.company_id
  WHERE category.system_key IN('BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')
    AND category.is_active
  UNION ALL
  SELECT 'invoice_finance_category_definition',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.transaction_categories category JOIN active_company company
    ON company.id=category.company_id
  WHERE (category.system_key='BACKOFFICE_SALES_INVOICE' AND (
      category.category_code<>'BO-SALE-INVOICE'
      OR category.category_name<>'Backoffice Invoice Penjualan' OR NOT category.is_active))
    OR (category.system_key='BACKOFFICE_SALES_DOWN_PAYMENT' AND (
      category.category_code<>'BO-SALE-DOWN-PAYMENT'
      OR category.category_name<>'Backoffice Uang Muka Penjualan' OR NOT category.is_active))
  UNION ALL
  SELECT 'invoice_account_rule_scope',
    CASE WHEN count(*)=(SELECT count(*)*7 FROM active_company) THEN 'PASS' ELSE 'FAIL' END,
    abs((SELECT count(*)*7 FROM active_company)-count(*))::bigint,
    jsonb_build_object('ruleRows',count(*),'expected',(SELECT count(*)*7 FROM active_company))
  FROM public.transaction_account_rules rule JOIN active_company company
    ON company.id=rule.company_id
  WHERE rule.system_key IN('BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')
    AND rule.status='ACTIVE'
  UNION ALL
  SELECT 'invoice_account_rule_definition_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('mappingDeltaRows',count(*))
  FROM mapping_delta
  UNION ALL
  SELECT 'invoice_approved_posting_rule_sets',
    CASE WHEN count(*)=(SELECT count(*)*2 FROM active_company) THEN 'PASS' ELSE 'FAIL' END,
    abs((SELECT count(*)*2 FROM active_company)-count(*))::bigint,
    jsonb_build_object('ruleSetRows',count(*),'expected',(SELECT count(*)*2 FROM active_company))
  FROM public.posting_rule_sets rule_set JOIN active_company company
    ON company.id=rule_set.company_id
  WHERE rule_set.system_key IN('BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')
    AND rule_set.status='APPROVED'
  UNION ALL
  SELECT 'invoice_posting_definition_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('definitionDeltaRows',count(*))
  FROM definition_delta
  UNION ALL
  SELECT 'invoice_mapping_account_compatibility',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.transaction_account_rules rule
  JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
    AND account.id=rule.account_id
  JOIN public.account_functions function_state
    ON function_state.function_key=rule.account_function_key
  WHERE rule.system_key IN('BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')
    AND (rule.status<>'ACTIVE' OR NOT account.is_active OR NOT account.is_postable
      OR NOT function_state.is_active
      OR NOT account.account_type=ANY(function_state.compatible_account_types))
  UNION ALL
  SELECT 'invoice_mapping_master_audit_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('missingAuditRows',count(*))
  FROM (SELECT category.company_id,category.id entity_id,'CATEGORY'::text entity_type
      FROM public.transaction_categories category JOIN active_company company
        ON company.id=category.company_id
      WHERE category.system_key IN('BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')
    UNION ALL
    SELECT rule.company_id,rule.id,'RULE'::text
      FROM public.transaction_account_rules rule JOIN active_company company
        ON company.id=rule.company_id
      WHERE rule.system_key IN('BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')
        AND rule.status='ACTIVE') entity
  WHERE NOT EXISTS(SELECT 1 FROM public.finance_master_audit audit
    WHERE audit.company_id=entity.company_id AND audit.entity_id=entity.entity_id
      AND audit.entity_type=entity.entity_type AND audit.action='CREATE')
  UNION ALL
  SELECT 'invoice_posting_rule_audit_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRuleSetRows',count(*))
  FROM public.posting_rule_sets rule_set JOIN active_company company
    ON company.id=rule_set.company_id
  WHERE rule_set.system_key IN('BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')
    AND ((SELECT count(*) FROM public.posting_rule_set_audit audit
        WHERE audit.company_id=rule_set.company_id AND audit.rule_set_id=rule_set.id
          AND audit.action='CREATE')<>1
      OR (SELECT count(*) FROM public.posting_rule_set_audit audit
        WHERE audit.company_id=rule_set.company_id AND audit.rule_set_id=rule_set.id
          AND audit.action='APPROVE')<>1)
  UNION ALL
  SELECT 'invoice_tax_account_snapshot_compatibility',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_invoice_tax_breakdowns breakdown
  JOIN public.tax_rule_versions version ON version.company_id=breakdown.company_id
    AND version.tax_rule_id=breakdown.tax_rule_id
    AND version.rule_version=breakdown.tax_rule_version
  JOIN public.chart_of_accounts account ON account.company_id=breakdown.company_id
    AND account.id=breakdown.tax_account_id
  LEFT JOIN public.account_functions function_state
    ON function_state.function_key=version.account_function_key
  WHERE version.account_id<>breakdown.tax_account_id
    OR version.account_function_key<>'OUTPUT_TAX'
    OR function_state.function_key IS NULL OR NOT function_state.is_active
    OR NOT account.is_active OR NOT account.is_postable
    OR NOT account.account_type=ANY(function_state.compatible_account_types)
  UNION ALL
  SELECT 'invoice_mapping_helper_cleanup',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('routineRows',count(*))
  FROM pg_proc function JOIN pg_namespace namespace ON namespace.oid=function.pronamespace
  WHERE namespace.nspname='private'
    AND function.proname='resolve_backoffice_invoice_reusable_account'
  UNION ALL
  SELECT 'invoice_mapping_zero_runtime_effect',CASE WHEN event_count=0 AND journal_count=0
      THEN 'PASS' ELSE 'FAIL' END,(event_count+journal_count)::bigint,
    jsonb_build_object('eventRows',event_count,'journalRows',journal_count)
  FROM (SELECT
    (SELECT count(*) FROM public.financial_events WHERE system_event_key IN(
      'BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')) event_count,
    (SELECT count(*) FROM public.finance_journals WHERE system_event_key IN(
      'BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')) journal_count) inventory
  UNION ALL
  SELECT 'invoice_mapping_inventory','INFO',0::bigint,jsonb_build_object(
    'activeCompanies',(SELECT count(*) FROM active_company),
    'categories',(SELECT count(*) FROM public.transaction_categories WHERE system_key IN(
      'BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')),
    'accountRules',(SELECT count(*) FROM public.transaction_account_rules WHERE system_key IN(
      'BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')),
    'approvedRuleSets',(SELECT count(*) FROM public.posting_rule_sets WHERE system_key IN(
      'BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT') AND status='APPROVED'))
)
SELECT * FROM checks ORDER BY check_name;
