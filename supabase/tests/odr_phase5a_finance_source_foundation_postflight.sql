-- ODR-5A Finance source foundation postflight. SELECT-only.
WITH required_relations(name) AS (
  VALUES('sales_dispatch_financial_effects'::TEXT),
    ('sales_payment_verification_requests'),
    ('sales_dispatch_financial_effect_audit'),
    ('sales_payment_verification_audit')
), required_triggers(name) AS (
  VALUES('trg_odr5_guard_dispatch_financial_effect'::TEXT),
    ('trg_odr5_guard_payment_verification'),
    ('trg_odr5_guard_dispatch_effect_audit'),
    ('trg_odr5_guard_payment_verification_audit')
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828210000'

  UNION ALL
  SELECT 'required_finance_source_relations',
    CASE WHEN count(*) FILTER(WHERE relation.oid IS NULL)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE relation.oid IS NULL),jsonb_build_object(
      'expected',count(*),'relationRows',count(relation.oid))
  FROM required_relations required
  LEFT JOIN pg_class relation ON relation.oid=to_regclass('public.'||required.name)

  UNION ALL
  SELECT 'finance_source_rls_state',
    CASE WHEN count(*) FILTER(WHERE NOT relation.relrowsecurity)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE NOT relation.relrowsecurity),
    jsonb_build_object('enabledRelations',count(*) FILTER(WHERE relation.relrowsecurity))
  FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname IN(
    'sales_dispatch_financial_effects','sales_payment_verification_requests',
    'sales_dispatch_financial_effect_audit','sales_payment_verification_audit')

  UNION ALL
  SELECT 'browser_finance_source_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants privilege
  WHERE privilege.table_schema='public' AND privilege.table_name IN(
    'sales_dispatch_financial_effects','sales_payment_verification_requests',
    'sales_dispatch_financial_effect_audit','sales_payment_verification_audit')
    AND privilege.grantee IN('anon','authenticated')

  UNION ALL
  SELECT 'required_finance_source_triggers',
    CASE WHEN count(DISTINCT trigger.trigger_name)=4 THEN 'PASS' ELSE 'FAIL' END,
    4-count(DISTINCT trigger.trigger_name),jsonb_build_object(
      'expected',4,'triggerRows',count(DISTINCT trigger.trigger_name))
  FROM required_triggers required LEFT JOIN information_schema.triggers trigger
    ON trigger.trigger_schema='public' AND trigger.trigger_name=required.name

  UNION ALL
  SELECT 'odr_finance_event_catalog',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,abs(2-count(*)),
    jsonb_build_object('expected',2,'eventRows',count(*))
  FROM public.system_events system_event
  WHERE (system_event.system_key='SALE_DISPATCHED'
      AND system_event.event_group='SALES'
      AND system_event.required_account_functions=
        ARRAY['SALES_REVENUE','INVENTORY_ASSET','COGS']::TEXT[]
      AND system_event.conditional_account_functions=
        ARRAY['CUSTOMER_RECEIVABLE','PAYMENT_CLEARING','OUTPUT_TAX',
          'DELIVERY_FEE_REVENUE','PAYMENT_SURCHARGE_INCOME',
          'ROUNDING_GAIN','ROUNDING_LOSS']::TEXT[]
      AND system_event.is_active)
    OR (system_event.system_key='SALE_PAYMENT_VERIFIED'
      AND system_event.event_group='SALES'
      AND system_event.required_account_functions=ARRAY[]::TEXT[]
      AND system_event.conditional_account_functions=
        ARRAY['CASH_DRAWER','BANK','BANK_RECEIPT','PAYMENT_CLEARING',
          'CUSTOMER_RECEIVABLE','CUSTOMER_ADVANCE_LIABILITY']::TEXT[]
      AND system_event.is_active)

  UNION ALL
  SELECT 'customer_advance_account_function',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('functionRows',count(*))
  FROM public.account_functions account_function
  WHERE account_function.function_key='CUSTOMER_ADVANCE_LIABILITY'
    AND account_function.compatible_account_types=ARRAY['LIABILITY']::TEXT[]
    AND account_function.default_normal_balance='CREDIT'
    AND account_function.allow_reconciliation AND account_function.is_active

  UNION ALL
  SELECT 'payment_verification_permission_shadow',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
    jsonb_build_object('rows',count(*),'statuses',COALESCE(jsonb_agg(
      catalog.enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog catalog
  WHERE catalog.permission_key='finance.sales_payment_verification'
    AND catalog.enforcement_status='SHADOW'

  UNION ALL
  SELECT 'foundation_zero_backfill',
    CASE WHEN sum(row_count)=0 THEN 'PASS' ELSE 'FAIL' END,sum(row_count),
    jsonb_build_object('dispatchEffects',max(row_count) FILTER(WHERE source='dispatch'),
      'paymentRequests',max(row_count) FILTER(WHERE source='payment'))
  FROM (SELECT 'dispatch' source,count(*) row_count
      FROM public.sales_dispatch_financial_effects
    UNION ALL SELECT 'payment',count(*)
      FROM public.sales_payment_verification_requests) inventory

  UNION ALL
  SELECT 'foundation_runtime_inventory','INFO',0,jsonb_build_object(
    'dispatchEffects',(SELECT count(*) FROM public.sales_dispatch_financial_effects),
    'paymentRequests',(SELECT count(*) FROM public.sales_payment_verification_requests),
    'dispatchAudit',(SELECT count(*) FROM public.sales_dispatch_financial_effect_audit),
    'paymentAudit',(SELECT count(*) FROM public.sales_payment_verification_audit),
    'historicalPostedJournals',(SELECT count(*) FROM public.finance_journals
      WHERE status='POSTED'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
