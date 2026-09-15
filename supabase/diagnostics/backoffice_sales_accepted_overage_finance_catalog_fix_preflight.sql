-- SELECT-only preflight for C3 accepted-overage Finance catalog forward-fix.
WITH function_fact AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)')) definition
), active_companies AS (
  SELECT company.id FROM public.companies company WHERE company.status='ACTIVE'
), checks AS (
  SELECT 'c3g_dependency_ledger' check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(2-count(*)) violation_rows,jsonb_build_object('expected',2,'present',count(*)) details
  FROM private.kgs_schema_migrations WHERE version IN('20260912130000','20260912131000')
  UNION ALL
  SELECT 'c3g_migration_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('existingRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260912132000'
  UNION ALL
  SELECT 'c3g_system_event_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('existingRows',count(*))
  FROM public.system_events WHERE system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
  UNION ALL
  SELECT 'c3g_category_identity_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('existingRows',count(*))
  FROM public.transaction_categories category
  WHERE upper(regexp_replace(btrim(category.category_code),'\s+',' ','g'))='BO-OVERAGE-COGS'
    OR lower(regexp_replace(btrim(category.category_name),'\s+',' ','g'))=
      'backoffice hpp kelebihan diterima'
  UNION ALL
  SELECT 'c3g_routine_trigger_collision',CASE WHEN routine_count+trigger_count=0 THEN 'PASS' ELSE 'BLOCKER' END,
    routine_count+trigger_count,jsonb_build_object('routineRows',routine_count,'triggerRows',trigger_count)
  FROM (SELECT
    (SELECT count(*) FROM pg_proc WHERE oid IN(
      to_regprocedure('private.provision_backoffice_accepted_overage_finance(uuid,uuid)'),
      to_regprocedure('private.trg_provision_backoffice_accepted_overage_finance()'))) routine_count,
    (SELECT count(*) FROM pg_trigger WHERE tgrelid='public.companies'::regclass
      AND tgname='zz_provision_backoffice_accepted_overage_finance' AND NOT tgisinternal) trigger_count) tally
  UNION ALL
  SELECT 'c3g_source_mapping_readiness',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('invalidCompanies',count(*),'companyIds',
      coalesce(jsonb_agg(company.id),'[]'::jsonb))
  FROM active_companies company
  WHERE EXISTS(SELECT 1 FROM (VALUES('COGS'),('INVENTORY_ASSET')) required(function_key)
    WHERE (SELECT count(DISTINCT rule.account_id)
      FROM public.transaction_account_rules rule
      JOIN public.transaction_categories category
        ON category.company_id=rule.company_id AND category.id=rule.transaction_category_id
      WHERE rule.company_id=company.id AND rule.system_key='BACKOFFICE_CUSTOMER_RECEIPT'
        AND category.system_key='BACKOFFICE_CUSTOMER_RECEIPT' AND category.is_active
        AND rule.account_function_key=required.function_key AND rule.status='ACTIVE'
        AND rule.effective_from<=clock_timestamp()
        AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp()))<>1)
  UNION ALL
  SELECT 'c3g_resolver_finance_anchor_contract',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE definition IS NOT NULL)=1
      AND bool_and(position('category.system_key=''SALE_POSTED''' in definition)>0)
      AND bool_and(position('transaction_rule_version)' in definition)=0)
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE definition IS NOT NULL)=1
      AND bool_and(position('category.system_key=''SALE_POSTED''' in definition)>0)
      AND bool_and(position('transaction_rule_version)' in definition)=0)
      THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*),'legacyCategoryAnchorRows',count(*) FILTER(
      WHERE position('category.system_key=''SALE_POSTED''' in definition)>0),
      'versionedEventColumnRows',count(*) FILTER(
      WHERE position('transaction_rule_version)' in definition)>0))
  FROM function_fact
  UNION ALL
  SELECT 'c3g_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'c3g_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'c3g_runtime_inventory','INFO',0,jsonb_build_object('activeCompanies',count(*),
    'acceptedOverageEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'))
  FROM active_companies
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
