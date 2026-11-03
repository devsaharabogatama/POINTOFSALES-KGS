-- SELECT-only preflight for the deferred POS payment guard privilege fix.
WITH dependencies(version) AS (VALUES
  ('20260828210000'::text),
  ('20260923100000'),
  ('20261031100000'),
  ('20261031110000')
), installed AS (
  SELECT dependency.version,
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations ledger
      WHERE ledger.version=dependency.version) installed
  FROM dependencies dependency
), state AS (
  SELECT EXISTS(SELECT 1 FROM private.kgs_schema_migrations ledger
      WHERE ledger.version='20261102140000') ledger,
    COALESCE((SELECT routine.prosecdef
      FROM pg_proc routine
      WHERE routine.oid=to_regprocedure(
        'private.trg_enforce_no_pending_pos_cash()')),false)
      security_definer
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
), routine_state AS (
  SELECT pg_get_userbyid(routine.proowner) owner_name,
    routine.prosecdef,
    pg_get_functiondef(routine.oid) definition
  FROM pg_proc routine
  WHERE routine.oid=to_regprocedure(
    'private.trg_enforce_no_pending_pos_cash()')
)
SELECT 'pos_retail_non_cash_deferred_guard_preflight_dependency_ledger' check_name,
  CASE WHEN bool_and(installed) THEN 'PASS' ELSE 'BLOCKER' END status,
  count(*) FILTER(WHERE NOT installed) violation_rows,
  jsonb_build_object('required',jsonb_agg(version ORDER BY version),
    'missing',COALESCE(jsonb_agg(version ORDER BY version)
      FILTER(WHERE NOT installed),'[]'::jsonb)) details
FROM installed
UNION ALL
SELECT 'pos_retail_non_cash_deferred_guard_preflight_installation_state',
  CASE WHEN NOT ledger AND NOT security_definer THEN 'PASS' ELSE 'BLOCKER' END,
  (ledger OR security_definer)::int,
  jsonb_build_object('classification',CASE
    WHEN NOT ledger AND NOT security_definer THEN 'NOT_INSTALLED'
    WHEN ledger AND security_definer THEN 'INSTALLED_CONSISTENT'
    ELSE 'PARTIAL/INCONSISTENT' END,
    'ledger',ledger,'securityDefiner',security_definer)
FROM state
UNION ALL
SELECT 'pos_retail_non_cash_deferred_guard_preflight_runtime_anchor',
  CASE WHEN count(*)=1 AND bool_and(owner_name='postgres'
      AND NOT prosecdef
      AND definition LIKE '%sales_payment_verification_requests%'
      AND definition LIKE '%POS_CASH_AUTO_VERIFICATION_REQUIRED%')
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN count(*)=1 AND bool_and(owner_name='postgres'
      AND NOT prosecdef
      AND definition LIKE '%sales_payment_verification_requests%'
      AND definition LIKE '%POS_CASH_AUTO_VERIFICATION_REQUIRED%')
    THEN 0 ELSE 1 END,
  jsonb_build_object('rows',count(*),'owner',max(owner_name),
    'securityDefiner',bool_or(prosecdef),'definitionMd5',md5(max(definition)))
FROM routine_state
UNION ALL
SELECT 'pos_retail_non_cash_deferred_guard_preflight_trigger_contract',
  CASE WHEN count(*)=1 AND bool_and(tgdeferrable AND tginitdeferred
      AND tgenabled='O' AND correct_function)
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN count(*)=1 AND bool_and(tgdeferrable AND tginitdeferred
      AND tgenabled='O' AND correct_function)
    THEN 0 ELSE 1 END,
  jsonb_build_object('rows',count(*),'deferrable',bool_or(tgdeferrable),
    'initiallyDeferred',bool_or(tginitdeferred),
    'enabled',max(tgenabled::text),'correctFunction',bool_and(correct_function))
FROM trigger_state
UNION ALL
SELECT 'pos_retail_non_cash_deferred_guard_preflight_table_boundary',
  CASE WHEN NOT has_table_privilege('authenticated',
        'public.sales_payment_verification_requests','SELECT')
      AND has_table_privilege('postgres',
        'public.sales_payment_verification_requests','SELECT')
    THEN 'PASS' ELSE 'BLOCKER' END,
  (has_table_privilege('authenticated',
      'public.sales_payment_verification_requests','SELECT'))::int
    +(NOT has_table_privilege('postgres',
      'public.sales_payment_verification_requests','SELECT'))::int,
  jsonb_build_object('authenticatedSelect',has_table_privilege('authenticated',
      'public.sales_payment_verification_requests','SELECT'),
    'ownerSelect',has_table_privilege('postgres',
      'public.sales_payment_verification_requests','SELECT'))
UNION ALL
SELECT 'pos_retail_non_cash_deferred_guard_preflight_runtime_boundary',
  CASE WHEN NOT EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
    AND NOT EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))
    THEN 'PASS' ELSE 'BLOCKER' END,
  (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
   +(SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')),
  jsonb_build_object('activeFinanceQueue',(SELECT count(*)
      FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')),
    'nonterminalOffline',(SELECT count(*)
      FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')))
UNION ALL
SELECT 'pos_retail_non_cash_deferred_guard_preflight_business_boundary',
  'INFO',0,jsonb_build_object('mutation','NONE',
    'change','deferred Cash guard execution privilege only',
    'preserved',jsonb_build_array('authenticated table denial',
      'Cash auto-verification','non-cash Finance verification','Tempo',
      'Backoffice','Stock/FIFO','Finance Event/Journal','historical rows'));
