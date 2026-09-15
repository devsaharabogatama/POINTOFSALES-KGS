-- Read-only preflight for Backoffice Regular/DP Invoice Finance mapping.
-- Target: isolated Development Supabase only. No mutation.
WITH required_function(function_key) AS (
  VALUES ('CUSTOMER_RECEIVABLE'::text),('SALES_REVENUE'::text),
    ('OUTPUT_TAX'::text),('CUSTOMER_ADVANCE_LIABILITY'::text)
), active_company AS (
  SELECT company.id company_id,company.company_code
  FROM public.companies company WHERE company.status='ACTIVE'
), requirement AS (
  SELECT company.company_id,company.company_code,function.function_key
  FROM active_company company CROSS JOIN required_function function
), candidate AS (
  SELECT requirement.*,
    (SELECT count(DISTINCT rule.account_id)
     FROM public.transaction_account_rules rule
     JOIN public.transaction_categories category ON category.company_id=rule.company_id
       AND category.id=rule.transaction_category_id AND category.is_active
     JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
       AND account.id=rule.account_id
     JOIN public.account_functions function_state
       ON function_state.function_key=requirement.function_key AND function_state.is_active
     WHERE rule.company_id=requirement.company_id AND rule.system_key='SALE_POSTED'
       AND category.system_key='SALE_POSTED'
       AND rule.account_function_key=requirement.function_key AND rule.status='ACTIVE'
       AND rule.effective_from<=clock_timestamp()
       AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
       AND account.is_active AND account.is_postable
       AND account.account_type=ANY(function_state.compatible_account_types)) sale_count,
    (SELECT count(DISTINCT rule.account_id)
     FROM public.transaction_account_rules rule
     JOIN public.transaction_categories category ON category.company_id=rule.company_id
       AND category.id=rule.transaction_category_id AND category.is_active
     JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
       AND account.id=rule.account_id
     JOIN public.account_functions function_state
       ON function_state.function_key=requirement.function_key AND function_state.is_active
     WHERE rule.company_id=requirement.company_id AND rule.system_key='SALE_DISPATCHED'
       AND category.system_key='SALE_DISPATCHED'
       AND rule.account_function_key=requirement.function_key AND rule.status='ACTIVE'
       AND rule.effective_from<=clock_timestamp()
       AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
       AND account.is_active AND account.is_postable
       AND account.account_type=ANY(function_state.compatible_account_types)) dispatch_count,
    (SELECT count(DISTINCT fallback.account_id)
     FROM public.company_account_function_fallbacks fallback
     JOIN public.chart_of_accounts account ON account.company_id=fallback.company_id
       AND account.id=fallback.account_id
     JOIN public.account_functions function_state
       ON function_state.function_key=requirement.function_key AND function_state.is_active
     WHERE fallback.company_id=requirement.company_id
       AND fallback.account_function_key=requirement.function_key
       AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
       AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp())
       AND account.is_active AND account.is_postable
       AND account.account_type=ANY(function_state.compatible_account_types)) fallback_count,
    (SELECT count(*) FROM public.chart_of_accounts account
     JOIN public.account_functions function_state
       ON function_state.function_key=requirement.function_key AND function_state.is_active
     WHERE account.company_id=requirement.company_id
       AND account.system_function_key=requirement.function_key
       AND account.is_system_account AND account.is_active AND account.is_postable
       AND account.account_type=ANY(function_state.compatible_account_types)) system_count
  FROM requirement
), resolution AS (
  SELECT candidate.*,CASE
    WHEN sale_count=1 THEN 'SALE_POSTED_RULE'
    WHEN sale_count>1 THEN 'AMBIGUOUS_SALE_POSTED_RULE'
    WHEN dispatch_count=1 THEN 'SALE_DISPATCHED_RULE'
    WHEN dispatch_count>1 THEN 'AMBIGUOUS_SALE_DISPATCHED_RULE'
    WHEN fallback_count=1 THEN 'COMPANY_FALLBACK'
    WHEN fallback_count>1 THEN 'AMBIGUOUS_COMPANY_FALLBACK'
    WHEN system_count=1 THEN 'SYSTEM_ACCOUNT'
    WHEN system_count>1 THEN 'AMBIGUOUS_SYSTEM_ACCOUNT'
    ELSE 'MISSING' END resolution_source
  FROM candidate
), checks AS (
  SELECT 'invoice_tax_breakdown_dependency'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909159000'
  UNION ALL
  SELECT 'linked_super_admin',CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint,jsonb_build_object('profileRows',count(*))
  FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role::text='super_admin'
  UNION ALL
  SELECT 'required_invoice_account_functions',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(4-count(*))::bigint,jsonb_build_object('functionRows',count(*),'expected',4)
  FROM public.account_functions WHERE function_key IN(SELECT function_key FROM required_function)
    AND is_active
  UNION ALL
  SELECT 'invoice_account_source_coverage',CASE WHEN count(*) FILTER(WHERE
      resolution_source='MISSING' OR resolution_source LIKE 'AMBIGUOUS%')=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE resolution_source='MISSING'
      OR resolution_source LIKE 'AMBIGUOUS%')::bigint,
    jsonb_build_object('requirements',count(*),'invalid',COALESCE(jsonb_agg(
      jsonb_build_object('companyCode',company_code,'functionKey',function_key,
        'resolution',resolution_source,'saleRuleCount',sale_count,
        'dispatchRuleCount',dispatch_count,'fallbackCount',fallback_count,
        'systemCount',system_count) ORDER BY company_code,function_key)
      FILTER(WHERE resolution_source='MISSING'
        OR resolution_source LIKE 'AMBIGUOUS%'),'[]'::jsonb))
  FROM resolution
  UNION ALL
  SELECT 'invoice_finance_identity_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('collisionRows',count(*))
  FROM (SELECT event.system_key::text identity FROM public.system_events event
      WHERE event.system_key IN('BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')
    UNION ALL SELECT category.id::text FROM public.transaction_categories category
      WHERE upper(regexp_replace(btrim(category.category_code),'\s+',' ','g'))
        IN('BO-SALE-INVOICE','BO-SALE-DOWN-PAYMENT')
      OR lower(regexp_replace(btrim(category.category_name),'\s+',' ','g'))
        IN('backoffice invoice penjualan','backoffice uang muka penjualan')) collision
  UNION ALL
  SELECT 'active_finance_posting_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'invoice_pre_posting_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('unexpectedRows',count(*))
  FROM public.backoffice_sales_invoices WHERE status IN('POSTED','REVERSED')
    OR invoice_no IS NOT NULL OR financial_event_id IS NOT NULL OR posted_at IS NOT NULL
    OR posted_by IS NOT NULL
  UNION ALL
  SELECT 'invoice_tax_account_snapshot_compatibility',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
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
  SELECT 'invoice_finance_mapping_inventory','INFO',0::bigint,jsonb_build_object(
    'activeCompanies',(SELECT count(*) FROM active_company),
    'draftRegular',(SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE status='DRAFT' AND invoice_type='REGULAR'),
    'draftDownPayment',(SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE status='DRAFT' AND invoice_type='DOWN_PAYMENT'),
    'taxBreakdowns',(SELECT count(*) FROM public.backoffice_sales_invoice_tax_breakdowns))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
