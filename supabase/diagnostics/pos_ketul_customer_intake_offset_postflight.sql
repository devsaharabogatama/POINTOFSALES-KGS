-- SELECT-only postflight for KGFF direct Retail POS Ketul customer intake.
-- This proves installation/configuration state only. Behavioral proof is a
-- separate rollback-only test and authenticated POS smoke.
WITH
scope AS (
  SELECT id company_id
  FROM public.companies
  WHERE company_code='KGFF' AND status='ACTIVE'
),
accounts AS (
  SELECT account.account_code,account.account_name,account.account_type,
    account.normal_balance,account.parent_account_id,account.is_postable,
    account.is_system_account,account.is_active
  FROM public.chart_of_accounts account
  JOIN scope ON scope.company_id=account.company_id
  WHERE account.account_code IN('2010105','2010105-1')
),
rules AS (
  SELECT category.category_code,rule.account_function_key,
    account.account_code,rule.status
  FROM public.transaction_account_rules rule
  JOIN scope ON scope.company_id=rule.company_id
  JOIN public.transaction_categories category
    ON category.company_id=rule.company_id
   AND category.id=rule.transaction_category_id
  JOIN public.chart_of_accounts account
    ON account.company_id=rule.company_id AND account.id=rule.account_id
  WHERE category.system_key='KETUL_CUSTOMER_INTAKE'
),
fallbacks AS (
  SELECT fallback.account_function_key,account.account_code,fallback.status
  FROM public.company_account_function_fallbacks fallback
  JOIN scope ON scope.company_id=fallback.company_id
  JOIN public.chart_of_accounts account
    ON account.company_id=fallback.company_id AND account.id=fallback.account_id
  WHERE fallback.account_function_key='CUSTOMER_KETUL_PAYABLE'
),
methods AS (
  SELECT method.payment_method_code,method.payment_method_name,
    method.method_type,method.settlement_route,method.is_active,
    method.is_system_method
  FROM public.payment_methods method
  JOIN scope ON scope.company_id=method.company_id
  WHERE method.method_type='KETUL_OFFSET'
),
runtime AS (
  SELECT
    pg_get_functiondef(
      'private.post_pos_sale_online_core(uuid,bigint,uuid)'::regprocedure
    ) post_core_definition,
    pg_get_functiondef(
      'private.trg_g6_set_settlement_function_snapshot()'::regprocedure
    ) settlement_snapshot_definition
),
business_effect AS (
  SELECT
    (SELECT count(*) FROM public.pos_ketul_customer_intakes intake
      JOIN scope ON scope.company_id=intake.company_id) intake_rows,
    (SELECT count(*) FROM public.stock_movements movement
      JOIN scope ON scope.company_id=movement.company_id
      WHERE movement.reference_table='pos_ketul_customer_intakes') movement_rows,
    (SELECT count(*) FROM public.financial_events event
      JOIN scope ON scope.company_id=event.company_id
      WHERE event.source_table='pos_ketul_customer_intakes') event_rows,
    (SELECT count(*) FROM public.finance_journals journal
      JOIN scope ON scope.company_id=journal.company_id
      WHERE journal.source_type='pos_ketul_customer_intakes') journal_rows
),
checks AS (
  SELECT 10 seq,'pos_ketul_postflight_company_identity'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1) violation_rows,
    jsonb_build_object('rows',count(*),'companyCode','KGFF') details
  FROM scope
  UNION ALL
  SELECT 20,'pos_ketul_postflight_migration_ledger',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-1),
    jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20261031110000'
  UNION ALL
  SELECT 30,'pos_ketul_postflight_account_contract',
    CASE WHEN count(*) FILTER (WHERE account_code='2010105-1'
        AND account_name='HUTANG KETUL CUSTOMER'
        AND account_type='LIABILITY' AND normal_balance='CREDIT'
        AND parent_account_id IS NULL AND is_postable AND NOT is_system_account
        AND is_active)=1
      AND count(*) FILTER (WHERE account_code='2010105')=1
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*) FILTER (WHERE account_code='2010105-1'
        AND account_name='HUTANG KETUL CUSTOMER'
        AND account_type='LIABILITY' AND normal_balance='CREDIT'
        AND parent_account_id IS NULL AND is_postable AND NOT is_system_account
        AND is_active)=1
      AND count(*) FILTER (WHERE account_code='2010105')=1
      THEN 0 ELSE 1 END,
    jsonb_build_object('accounts',COALESCE(jsonb_agg(to_jsonb(accounts)
      ORDER BY account_code),'[]'::jsonb),
      'structure','2010105-1 is an independent postable liability; 2010105 is preserved')
  FROM accounts
  UNION ALL
  SELECT 40,'pos_ketul_postflight_mapping_contract',
    CASE WHEN count(*) FILTER (WHERE account_function_key='INVENTORY_ASSET'
        AND account_code='1030100-4' AND status='ACTIVE')=1
      AND count(*) FILTER (WHERE account_function_key='CUSTOMER_KETUL_PAYABLE'
        AND account_code='2010105-1' AND status='ACTIVE')=1
      AND (SELECT count(*) FROM fallbacks WHERE account_function_key='CUSTOMER_KETUL_PAYABLE'
        AND account_code='2010105-1' AND status='ACTIVE')=1
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*) FILTER (WHERE account_function_key='INVENTORY_ASSET'
        AND account_code='1030100-4' AND status='ACTIVE')=1
      AND count(*) FILTER (WHERE account_function_key='CUSTOMER_KETUL_PAYABLE'
        AND account_code='2010105-1' AND status='ACTIVE')=1
      AND (SELECT count(*) FROM fallbacks WHERE account_function_key='CUSTOMER_KETUL_PAYABLE'
        AND account_code='2010105-1' AND status='ACTIVE')=1
      THEN 0 ELSE 1 END,
    jsonb_build_object('rules',COALESCE(jsonb_agg(to_jsonb(rules)
      ORDER BY account_function_key),'[]'::jsonb),
      'fallbacks',(SELECT COALESCE(jsonb_agg(to_jsonb(fallbacks)),'[]'::jsonb)
        FROM fallbacks))
  FROM rules
  UNION ALL
  SELECT 50,'pos_ketul_postflight_internal_method_contract',
    CASE WHEN count(*)=1 AND bool_and(method_type='KETUL_OFFSET'
        AND settlement_route='INTERNAL_LIABILITY' AND is_active
        AND is_system_method) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(method_type='KETUL_OFFSET'
        AND settlement_route='INTERNAL_LIABILITY' AND is_active
        AND is_system_method) THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),'methods',
      COALESCE(jsonb_agg(to_jsonb(methods)),'[]'::jsonb),
      'boundary','system-only settlement leg; normal payment picker remains closed')
  FROM methods
  UNION ALL
  SELECT 60,'pos_ketul_postflight_runtime_contract',
    CASE WHEN to_regprocedure('public.save_pos_sale_draft_with_ketul(jsonb)') IS NOT NULL
      AND to_regprocedure('public.post_pos_sale_with_ketul(uuid,bigint,uuid)') IS NOT NULL
      AND to_regprocedure('private.post_pos_ketul_intake(uuid,uuid,uuid,uuid)') IS NOT NULL
      AND post_core_definition~'kgs.ketul_post_context'
      AND settlement_snapshot_definition~'CUSTOMER_KETUL_PAYABLE'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regprocedure('public.save_pos_sale_draft_with_ketul(jsonb)') IS NOT NULL
      AND to_regprocedure('public.post_pos_sale_with_ketul(uuid,bigint,uuid)') IS NOT NULL
      AND to_regprocedure('private.post_pos_ketul_intake(uuid,uuid,uuid,uuid)') IS NOT NULL
      AND post_core_definition~'kgs.ketul_post_context'
      AND settlement_snapshot_definition~'CUSTOMER_KETUL_PAYABLE'
      THEN 0 ELSE 1 END,
    jsonb_build_object('saveRpc',
        to_regprocedure('public.save_pos_sale_draft_with_ketul(jsonb)') IS NOT NULL,
      'postRpc',to_regprocedure(
        'public.post_pos_sale_with_ketul(uuid,bigint,uuid)') IS NOT NULL,
      'postingCore',to_regprocedure(
        'private.post_pos_ketul_intake(uuid,uuid,uuid,uuid)') IS NOT NULL,
      'guardPatched',post_core_definition~'kgs.ketul_post_context',
      'settlementFunctionPatched',
        settlement_snapshot_definition~'CUSTOMER_KETUL_PAYABLE')
  FROM runtime
  UNION ALL
  SELECT 70,'pos_ketul_postflight_table_security_contract',
    CASE WHEN to_regclass('public.pos_ketul_customer_intakes') IS NOT NULL
      AND to_regclass('public.pos_ketul_customer_intake_lines') IS NOT NULL
      AND to_regclass('public.pos_ketul_customer_intake_audit') IS NOT NULL
      AND (SELECT relrowsecurity FROM pg_class
        WHERE oid='public.pos_ketul_customer_intakes'::regclass)
      AND (SELECT relrowsecurity FROM pg_class
        WHERE oid='public.pos_ketul_customer_intake_lines'::regclass)
      AND (SELECT relrowsecurity FROM pg_class
        WHERE oid='public.pos_ketul_customer_intake_audit'::regclass)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regclass('public.pos_ketul_customer_intakes') IS NOT NULL
      AND to_regclass('public.pos_ketul_customer_intake_lines') IS NOT NULL
      AND to_regclass('public.pos_ketul_customer_intake_audit') IS NOT NULL
      AND (SELECT relrowsecurity FROM pg_class
        WHERE oid='public.pos_ketul_customer_intakes'::regclass)
      AND (SELECT relrowsecurity FROM pg_class
        WHERE oid='public.pos_ketul_customer_intake_lines'::regclass)
      AND (SELECT relrowsecurity FROM pg_class
        WHERE oid='public.pos_ketul_customer_intake_audit'::regclass)
      THEN 0 ELSE 1 END,
    jsonb_build_object('headers',to_regclass(
        'public.pos_ketul_customer_intakes') IS NOT NULL,
      'lines',to_regclass('public.pos_ketul_customer_intake_lines') IS NOT NULL,
      'audit',to_regclass('public.pos_ketul_customer_intake_audit') IS NOT NULL,
      'rls',true)
  UNION ALL
  SELECT 80,'pos_ketul_postflight_zero_business_effect',
    CASE WHEN intake_rows=0 AND movement_rows=0 AND event_rows=0
      AND journal_rows=0 THEN 'PASS' ELSE 'FAIL' END,
    intake_rows+movement_rows+event_rows+journal_rows,
    jsonb_build_object('intakeRows',intake_rows,'movementRows',movement_rows,
      'eventRows',event_rows,'journalRows',journal_rows,
      'meaning','installation creates configuration only')
  FROM business_effect
  UNION ALL
  SELECT 90,'pos_ketul_postflight_business_boundary','INFO',0,
    jsonb_build_object('company','KGFF only',
      'included',jsonb_build_array('direct Retail POS Ketul intake',
        'hidden settlement offset','Stock/FIFO inbound','Ketul Finance Event/Journal',
        'receipt snapshot'),
      'preserved',jsonb_build_array('2010105 and its existing mappings',
        'Backoffice/ODR','Tempo','Offline','normal payment picker',
        'existing Sales Return','historical Posted rows','other Companies'),
      'remainingGate',jsonb_build_array('rollback-only behavior test',
        'authenticated POS smoke','posted correction is not implemented'))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY seq;
