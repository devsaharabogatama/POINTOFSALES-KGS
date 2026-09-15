-- Read-only preflight for Backoffice Customer receipt COGS mapping.
WITH company_function AS (
  SELECT company.id company_id,function_key
  FROM public.companies company
  CROSS JOIN unnest(ARRAY['COGS','INVENTORY_ASSET']::text[]) function_key
  WHERE company.status='ACTIVE'
), counts AS (
  SELECT requirement.*,
    (SELECT count(DISTINCT rule.account_id)
      FROM public.transaction_account_rules rule
      JOIN public.transaction_categories category ON category.company_id=rule.company_id
        AND category.id=rule.transaction_category_id
      JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
        AND account.id=rule.account_id
      JOIN public.account_functions function_state
        ON function_state.function_key=requirement.function_key AND function_state.is_active
      WHERE rule.company_id=requirement.company_id AND rule.system_key='SALE_POSTED'
        AND category.system_key='SALE_POSTED' AND category.is_active
        AND rule.account_function_key=requirement.function_key AND rule.status='ACTIVE'
        AND rule.effective_from<=clock_timestamp()
        AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
        AND account.is_active AND account.is_postable
        AND account.account_type=ANY(function_state.compatible_account_types)) sale_count,
    (SELECT count(DISTINCT rule.account_id)
      FROM public.transaction_account_rules rule
      JOIN public.transaction_categories category ON category.company_id=rule.company_id
        AND category.id=rule.transaction_category_id
      JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
        AND account.id=rule.account_id
      JOIN public.account_functions function_state
        ON function_state.function_key=requirement.function_key AND function_state.is_active
      WHERE rule.company_id=requirement.company_id AND rule.system_key='SALE_DISPATCHED'
        AND category.system_key='SALE_DISPATCHED' AND category.is_active
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
  FROM company_function requirement
), classified AS (
  SELECT *,CASE
    WHEN sale_count=1 THEN true
    WHEN sale_count=0 AND dispatch_count=1 THEN true
    WHEN sale_count=0 AND dispatch_count=0 AND fallback_count=1 THEN true
    WHEN sale_count=0 AND dispatch_count=0 AND fallback_count=0 AND system_count=1 THEN true
    ELSE false END resolvable
  FROM counts
), results AS (
  SELECT 'receipt_finance_mapping_dependencies'::text check_name,
    CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260909152000')
      AND to_regprocedure('private.resolve_financial_event_account(public.financial_events,text)') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END status,0::bigint violation_rows,
    jsonb_build_object('receiptFoundation',EXISTS(SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260909152000'),
      'accountResolver',to_regprocedure(
        'private.resolve_financial_event_account(public.financial_events,text)') IS NOT NULL) details
  UNION ALL
  SELECT 'receipt_account_source_coverage',CASE WHEN count(*) FILTER(WHERE NOT resolvable)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE NOT resolvable)::bigint,
    jsonb_build_object('requirements',count(*),'invalid',COALESCE(jsonb_agg(
      jsonb_build_object('companyId',company_id,'functionKey',function_key,
        'saleCount',sale_count,'dispatchCount',dispatch_count,
        'fallbackCount',fallback_count,'systemCount',system_count))
      FILTER(WHERE NOT resolvable),'[]'::jsonb))
  FROM classified
  UNION ALL
  SELECT 'receipt_finance_identity_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('rows',count(*))
  FROM (SELECT system_key::text identity FROM public.system_events
      WHERE system_key='BACKOFFICE_CUSTOMER_RECEIPT'
    UNION ALL SELECT category.id::text FROM public.transaction_categories category
      WHERE upper(regexp_replace(btrim(category.category_code),'\s+',' ','g'))='BO-SALE-RECEIPT'
        OR lower(regexp_replace(btrim(category.category_name),'\s+',' ','g'))=
          'backoffice penerimaan customer') collision
  UNION ALL
  SELECT 'active_finance_posting_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
)
SELECT * FROM results ORDER BY CASE status WHEN 'BLOCKER' THEN 1 ELSE 2 END,check_name;
