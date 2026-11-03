-- SELECT-only postflight for migration 20261102140000.
WITH routine_state AS (
  SELECT pg_get_userbyid(routine.proowner) owner_name,
    routine.prosecdef,pg_get_functiondef(routine.oid) definition
  FROM pg_proc routine
  WHERE routine.oid=to_regprocedure(
    'private.trg_enforce_no_pending_pos_cash()')
), trigger_state AS (
  SELECT trigger_row.tgdeferrable,trigger_row.tginitdeferred,
    trigger_row.tgenabled,
    trigger_row.tgfoid=to_regprocedure(
      'private.trg_enforce_no_pending_pos_cash()')
      correct_function
  FROM pg_trigger trigger_row
  JOIN pg_class relation ON relation.oid=trigger_row.tgrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public'
    AND relation.relname='sales_payment_verification_requests'
    AND trigger_row.tgname='enforce_no_pending_pos_cash'
    AND NOT trigger_row.tgisinternal
)
SELECT 'pos_retail_non_cash_deferred_guard_postflight_migration_ledger' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
  abs(count(*)-1) violation_rows,
  jsonb_build_object('ledgerRows',count(*)) details
FROM private.kgs_schema_migrations WHERE version='20261102140000'
UNION ALL
SELECT 'pos_retail_non_cash_deferred_guard_postflight_runtime_contract',
  CASE WHEN count(*)=1 AND bool_and(owner_name='postgres' AND prosecdef
      AND definition LIKE '%sales_payment_verification_requests%'
      AND definition LIKE '%POS_CASH_AUTO_VERIFICATION_REQUIRED%')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN count(*)=1 AND bool_and(owner_name='postgres' AND prosecdef
      AND definition LIKE '%sales_payment_verification_requests%'
      AND definition LIKE '%POS_CASH_AUTO_VERIFICATION_REQUIRED%')
    THEN 0 ELSE 1 END,
  jsonb_build_object('rows',count(*),'owner',max(owner_name),
    'securityDefiner',bool_or(prosecdef),'definitionMd5',md5(max(definition)))
FROM routine_state
UNION ALL
SELECT 'pos_retail_non_cash_deferred_guard_postflight_trigger_contract',
  CASE WHEN count(*)=1 AND bool_and(tgdeferrable AND tginitdeferred
      AND tgenabled='O' AND correct_function)
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN count(*)=1 AND bool_and(tgdeferrable AND tginitdeferred
      AND tgenabled='O' AND correct_function)
    THEN 0 ELSE 1 END,
  jsonb_build_object('rows',count(*),'deferrable',bool_or(tgdeferrable),
    'initiallyDeferred',bool_or(tginitdeferred),
    'enabled',max(tgenabled::text),'correctFunction',bool_and(correct_function))
FROM trigger_state
UNION ALL
SELECT 'pos_retail_non_cash_deferred_guard_postflight_table_boundary',
  CASE WHEN NOT has_table_privilege('authenticated',
        'public.sales_payment_verification_requests','SELECT')
      AND NOT has_table_privilege('authenticated',
        'public.sales_payment_verification_requests','INSERT')
      AND NOT has_table_privilege('authenticated',
        'public.sales_payment_verification_requests','UPDATE')
    THEN 'PASS' ELSE 'FAIL' END,
  has_table_privilege('authenticated',
      'public.sales_payment_verification_requests','SELECT')::int
    +has_table_privilege('authenticated',
      'public.sales_payment_verification_requests','INSERT')::int
    +has_table_privilege('authenticated',
      'public.sales_payment_verification_requests','UPDATE')::int,
  jsonb_build_object('authenticatedSelect',has_table_privilege('authenticated',
      'public.sales_payment_verification_requests','SELECT'),
    'authenticatedInsert',has_table_privilege('authenticated',
      'public.sales_payment_verification_requests','INSERT'),
    'authenticatedUpdate',has_table_privilege('authenticated',
      'public.sales_payment_verification_requests','UPDATE'))
UNION ALL
SELECT 'pos_retail_non_cash_deferred_guard_postflight_business_boundary',
  'INFO',0,jsonb_build_object(
    'next','Run rollback-only behavior, then authenticated POS Transfer/QRIS smoke',
    'changed',jsonb_build_array('deferred Cash guard execution privilege'),
    'preserved',jsonb_build_array('authenticated table denial',
      'Cash auto-verification','non-cash Finance verification','Tempo',
      'Backoffice','Stock/FIFO','Finance Event/Journal','historical rows'));
