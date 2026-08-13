-- G6 phase 8B mapping fix postflight. SAFETY: SELECT-only.
WITH event_functions AS MATERIALIZED (
  SELECT event.company_id,event.id event_id,event.transaction_category_id,
    event.system_event_key,event.event_date,function_key
  FROM public.financial_events event CROSS JOIN LATERAL unnest(
    CASE event.system_event_key
      WHEN 'SALE_POSTED' THEN ARRAY['SALES_REVENUE','COGS','INVENTORY_ASSET']::TEXT[]
      WHEN 'SALES_RETURN' THEN ARRAY['SALES_RETURN_DISCOUNT','COGS','INVENTORY_ASSET']::TEXT[]
    END) function_key
  WHERE event.status='HOLD'::public.event_status
    AND event.system_event_key IN('SALE_POSTED','SALES_RETURN')
), resolution AS MATERIALIZED (
  SELECT scope.*,
    (SELECT count(*) FROM public.transaction_account_rules rule
      WHERE rule.company_id=scope.company_id
       AND rule.transaction_category_id=scope.transaction_category_id
       AND rule.system_key=scope.system_event_key
       AND rule.account_function_key=scope.function_key AND rule.status='ACTIVE'
       AND rule.effective_from<=scope.event_date
       AND (rule.effective_to IS NULL OR rule.effective_to>scope.event_date)) exact_count,
    (SELECT count(*) FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=scope.company_id
       AND fallback.account_function_key=scope.function_key AND fallback.status='ACTIVE'
       AND fallback.effective_from<=scope.event_date
       AND (fallback.effective_to IS NULL OR fallback.effective_to>scope.event_date)) fallback_count
  FROM event_functions scope
), checks(check_name,status,violation_rows,details) AS (
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260814120000'
  UNION ALL
  SELECT 'runtime_required_account_resolution',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('unresolvedRows',count(*),'functions',
      COALESCE(jsonb_agg(DISTINCT function_key),'[]'))
  FROM resolution WHERE NOT(exact_count=1 OR (exact_count=0 AND fallback_count=1))
  UNION ALL
  SELECT 'runtime_account_resolution_ambiguity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('ambiguousRows',count(*)) FROM resolution
  WHERE exact_count>1 OR (exact_count=0 AND fallback_count>1)
  UNION ALL
  SELECT 'sale_return_history_still_closed',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('journalRows',count(*))
  FROM public.finance_journals journal JOIN public.financial_events event
   ON event.company_id=journal.company_id AND event.id=journal.financial_event_id
  WHERE event.system_event_key IN('SALE_POSTED','SALES_RETURN')
  UNION ALL
  SELECT 'runtime_account_mapping_inventory','INFO',0,jsonb_build_object(
    'eventFunctionRows',(SELECT count(*) FROM resolution),
    'resolvedRows',(SELECT count(*) FROM resolution
      WHERE exact_count=1 OR (exact_count=0 AND fallback_count=1)),
    'functions',(SELECT jsonb_agg(DISTINCT function_key) FROM resolution))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
