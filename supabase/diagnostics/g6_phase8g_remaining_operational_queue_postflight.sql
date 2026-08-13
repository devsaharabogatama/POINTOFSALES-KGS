-- G6 phase 8G postflight. SAFETY: SELECT-only.
WITH checks(check_name,status,violation_rows,details) AS (
 SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
  abs(1-count(*)),jsonb_build_object('ledgerRows',count(*))
 FROM private.kgs_schema_migrations WHERE version='20260814170000'
 UNION ALL SELECT 'remaining_operational_queue_routine',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
  jsonb_build_object('routineRows',count(*))
 FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
 WHERE namespace.nspname='public'
  AND routine.proname='preview_remaining_operational_posting_queue'
 UNION ALL SELECT 'remaining_operational_queue_rpc_boundary',
  CASE WHEN count(*) FILTER(WHERE has_function_privilege('anon',routine.oid,'EXECUTE'))=0
    AND count(*) FILTER(WHERE has_function_privilege('authenticated',routine.oid,'EXECUTE'))=1
   THEN 'PASS' ELSE 'FAIL' END,
  count(*) FILTER(WHERE has_function_privilege('anon',routine.oid,'EXECUTE')),
  jsonb_build_object(
   'anonRows',count(*) FILTER(WHERE has_function_privilege('anon',routine.oid,'EXECUTE')),
   'authenticatedRows',count(*) FILTER(WHERE has_function_privilege('authenticated',routine.oid,'EXECUTE')))
 FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
 WHERE namespace.nspname='public'
  AND routine.proname='preview_remaining_operational_posting_queue'
 UNION ALL SELECT 'remaining_operational_queue_scope_contract',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
  jsonb_build_object('constraintRows',count(*)) FROM pg_constraint constraint_state
 WHERE constraint_state.conrelid='public.finance_posting_queue_runs'::regclass
  AND constraint_state.conname='finance_posting_queue_runs_scope_check'
  AND pg_get_constraintdef(constraint_state.oid) LIKE '%REMAINING_OPERATIONAL%'
 UNION ALL SELECT 'active_finance_queue',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('runCount',count(*)) FROM public.finance_posting_queue_runs
 WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
 UNION ALL SELECT 'historical_remaining_operational_final_effect_closed',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('journalRows',count(*))
 FROM public.finance_journals journal JOIN public.financial_events event
  ON event.company_id=journal.company_id AND event.id=journal.financial_event_id
 WHERE event.system_event_key IN(
  'STOCK_GAIN','EXPENSE_DISBURSEMENT','CASH_DEPOSIT','CASH_VARIANCE')
 UNION ALL SELECT 'remaining_operational_queue_inventory','INFO',0,
  jsonb_build_object('holdEvents',(SELECT count(*) FROM public.financial_events
   WHERE status='HOLD'::public.event_status AND system_event_key IN(
    'STOCK_GAIN','EXPENSE_DISBURSEMENT','CASH_DEPOSIT','CASH_VARIANCE')))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
