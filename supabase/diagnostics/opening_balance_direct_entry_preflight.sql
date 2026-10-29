-- SELECT-only preflight. Run before migration 20261029100000.
WITH migration_state AS (
  SELECT count(*)::bigint ledger_rows
  FROM private.kgs_schema_migrations WHERE version='20261029100000'
), dependencies AS (
  SELECT count(*)::bigint installed
  FROM private.kgs_schema_migrations
  WHERE version IN('20260810180000','20260919120000')
), runtime AS (
  SELECT jsonb_build_object(
    'financeJournals',to_regclass('public.finance_journals') IS NOT NULL,
    'journalLines',to_regclass('public.finance_journal_lines') IS NOT NULL,
    'periods',to_regclass('public.accounting_periods') IS NOT NULL,
    'customers',to_regclass('public.customers') IS NOT NULL,
    'suppliers',to_regclass('public.suppliers') IS NOT NULL,
    'permissionGuard',to_regprocedure('private.acp_require_permission_capability(uuid,text,text)') IS NOT NULL
  ) details
), kgff AS (
  SELECT id,company_code,company_name,status FROM public.companies WHERE company_code='KGFF'
), control_accounts AS (
  SELECT function_key,count(DISTINCT account_id)::bigint account_rows
  FROM (
    SELECT fallback.account_function_key function_key,fallback.account_id
    FROM public.company_account_function_fallbacks fallback JOIN kgff ON kgff.id=fallback.company_id
    WHERE fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
      AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp())
    UNION
    SELECT rule.account_function_key,rule.account_id
    FROM public.transaction_account_rules rule JOIN kgff ON kgff.id=rule.company_id
    WHERE rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
      AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
  ) mapping
  WHERE function_key IN('CUSTOMER_RECEIVABLE','SUPPLIER_AP_FINAL','INVENTORY_ASSET')
  GROUP BY function_key
), opening_effect AS (
  SELECT count(*)::bigint rows
  FROM public.finance_journals journal JOIN kgff ON kgff.id=journal.company_id
  WHERE journal.journal_type='OPENING_BALANCE'
)
SELECT 'opening_balance_direct_entry_migration_absence' check_name,
  CASE WHEN ledger_rows=0 THEN 'PASS' ELSE 'BLOCKER' END status,
  ledger_rows violation_rows,jsonb_build_object('version','20261029100000','ledgerRows',ledger_rows) details
FROM migration_state
UNION ALL
SELECT 'opening_balance_direct_entry_dependencies',CASE WHEN installed=2 THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN installed=2 THEN 0 ELSE 2-installed END,jsonb_build_object('installed',installed,'expected',2)
FROM dependencies
UNION ALL
SELECT 'opening_balance_direct_entry_runtime',CASE WHEN details @> '{"financeJournals":true,"journalLines":true,"periods":true,"customers":true,"suppliers":true,"permissionGuard":true}'::jsonb THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN details @> '{"financeJournals":true,"journalLines":true,"periods":true,"customers":true,"suppliers":true,"permissionGuard":true}'::jsonb THEN 0 ELSE 1 END,details
FROM runtime
UNION ALL
SELECT 'opening_balance_direct_entry_kgff_identity',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
  abs(count(*)-1),jsonb_build_object('rows',count(*),'companies',coalesce(jsonb_agg(to_jsonb(kgff)),'[]'::jsonb))
FROM kgff
UNION ALL
SELECT 'opening_balance_direct_entry_kgff_control_accounts',
  CASE WHEN count(*)=3 AND bool_and(account_rows>=1) THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN count(*)=3 AND bool_and(account_rows>=1) THEN 0 ELSE 1 END,
  jsonb_build_object('mappings',coalesce(jsonb_agg(jsonb_build_object('function',function_key,'accounts',account_rows) ORDER BY function_key),'[]'::jsonb))
FROM control_accounts
UNION ALL
SELECT 'opening_balance_direct_entry_existing_opening_inventory','INFO',0,
  jsonb_build_object('openingBalanceJournals',rows,'rule','Existing Opening Stock journals remain immutable and must not be recreated as GL lines')
FROM opening_effect
ORDER BY check_name;
