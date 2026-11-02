-- SELECT-only closing proof for KGS Ketul readiness forward fix.
WITH target AS (
  SELECT company.id FROM public.companies company
  WHERE company.id='d290f1ee-6c54-4b01-90e6-d701748f0851'::uuid
    AND company.company_code='KGS' AND company.status='ACTIVE'
), category AS (
  SELECT category.id FROM public.transaction_categories category,target
  WHERE category.company_id=target.id AND category.is_active
    AND category.system_key='KETUL_CUSTOMER_INTAKE'
), account AS (
  SELECT account.id FROM public.chart_of_accounts account,target
  WHERE account.company_id=target.id AND account.account_code='2010105-1'
    AND account.account_name='HUTANG KETUL CUSTOMER'
    AND account.account_type='LIABILITY' AND account.normal_balance='CREDIT'
    AND account.parent_account_id IS NULL AND account.is_active
    AND account.is_postable AND NOT account.is_system_account
), checks AS (
  SELECT 10 AS seq,'pos_ketul_kgs_readiness_postflight_migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20261101120000'
  UNION ALL
  SELECT 20,'pos_ketul_kgs_readiness_postflight_account_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),'accountCode','2010105-1') FROM account
  UNION ALL
  SELECT 30,'pos_ketul_kgs_readiness_postflight_mapping_contract',
    CASE WHEN rule_rows=1 AND fallback_rows=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN rule_rows=1 AND fallback_rows=1 THEN 0 ELSE 1 END,
    jsonb_build_object('directRules',rule_rows,'fallbacks',fallback_rows)
  FROM (SELECT
    (SELECT count(*) FROM public.transaction_account_rules rule,category,account,target
      WHERE rule.company_id=target.id AND rule.transaction_category_id=category.id
        AND rule.account_function_key='CUSTOMER_KETUL_PAYABLE'
        AND rule.account_id=account.id AND rule.status='ACTIVE'
        AND rule.effective_to IS NULL) rule_rows,
    (SELECT count(*) FROM public.company_account_function_fallbacks fallback,account,target
      WHERE fallback.company_id=target.id
        AND fallback.account_function_key='CUSTOMER_KETUL_PAYABLE'
        AND fallback.account_id=account.id AND fallback.status='ACTIVE'
        AND fallback.effective_to IS NULL) fallback_rows) mapping
  UNION ALL
  SELECT 40,'pos_ketul_kgs_readiness_postflight_internal_method_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),'methodType','KETUL_OFFSET',
      'normalPickerBoundary','SYSTEM_ONLY')
  FROM public.payment_methods method,target
  WHERE method.company_id=target.id AND method.method_type='KETUL_OFFSET'
    AND method.settlement_route='INTERNAL_LIABILITY' AND method.is_active
    AND method.is_system_method
  UNION ALL
  SELECT 50,'pos_ketul_kgs_readiness_postflight_rpc_contract',
    CASE WHEN to_regprocedure('public.get_pos_ketul_readiness()') IS NOT NULL
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regprocedure('public.get_pos_ketul_readiness()') IS NOT NULL
      THEN 0 ELSE 1 END,
    jsonb_build_object('function','get_pos_ketul_readiness()',
      'companyScoped',pg_get_functiondef(
        'public.get_pos_ketul_readiness()'::regprocedure)
        LIKE '%public.private_active_company_id()%')
  UNION ALL
  SELECT 60,'pos_ketul_kgs_readiness_postflight_zero_business_effect',
    CASE WHEN event_rows=0 AND intake_rows=0 AND journal_rows=0
      AND movement_rows=0 THEN 'PASS' ELSE 'FAIL' END,
    event_rows+intake_rows+journal_rows+movement_rows,
    jsonb_build_object('eventRows',event_rows,'intakeRows',intake_rows,
      'journalRows',journal_rows,'movementRows',movement_rows)
  FROM (SELECT
    (SELECT count(*) FROM public.financial_events event,target
      WHERE event.company_id=target.id AND event.source_table='pos_ketul_customer_intakes'
        AND event.created_at>=(SELECT applied_at FROM private.kgs_schema_migrations
          WHERE version='20261101120000')) event_rows,
    (SELECT count(*) FROM public.pos_ketul_customer_intakes intake,target
      WHERE intake.company_id=target.id AND intake.created_at>=(SELECT applied_at
        FROM private.kgs_schema_migrations WHERE version='20261101120000')) intake_rows,
    (SELECT count(*) FROM public.finance_journals journal,target
      WHERE journal.company_id=target.id AND journal.created_at>=(SELECT applied_at
        FROM private.kgs_schema_migrations WHERE version='20261101120000')) journal_rows,
    (SELECT count(*) FROM public.stock_movements movement,target
      WHERE movement.company_id=target.id AND movement.reference_table='pos_ketul_customer_intakes'
        AND movement.created_at>=(SELECT applied_at FROM private.kgs_schema_migrations
          WHERE version='20261101120000')) movement_rows) effects
  UNION ALL
  SELECT 70,'pos_ketul_kgs_readiness_postflight_business_boundary','INFO',0,
    jsonb_build_object('changed',ARRAY['KGS Ketul payable configuration',
      'generic Company-scoped readiness authority'],
      'preserved',ARRAY['KGFF','other Companies','2010105','Backoffice/ODR',
        'Tempo','Offline','Return','historical Posted rows'])
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY seq;
