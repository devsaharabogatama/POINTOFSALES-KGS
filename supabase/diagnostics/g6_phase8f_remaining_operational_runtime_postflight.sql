-- G6 phase 8F postflight: runtime installed; seven historical HOLD preserved.
-- SAFETY: SELECT-only.
WITH target_events AS MATERIALIZED (
 SELECT event.* FROM public.financial_events event
 WHERE event.system_event_key IN(
  'STOCK_GAIN','EXPENSE_DISBURSEMENT','CASH_DEPOSIT','CASH_VARIANCE')
), checks(check_name,status,violation_rows,details) AS (
 SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
  abs(1-count(*)),jsonb_build_object('ledgerRows',count(*))
 FROM private.kgs_schema_migrations WHERE version='20260814160000'
 UNION ALL SELECT 'remaining_operational_runtime_routines',
  CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,abs(2-count(*)),
  jsonb_build_object('expected',2,'routineRows',count(*))
 FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
 WHERE namespace.nspname='private' AND routine.proname IN(
  'g6_require_active_postable_snapshot_account',
  'post_remaining_operational_financial_event_core')
 UNION ALL SELECT 'remaining_operational_runtime_contract',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
  jsonb_build_object('routineRows',count(*))
 FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
 WHERE namespace.nspname='private'
  AND routine.proname='post_remaining_operational_financial_event_core'
  AND pg_get_functiondef(routine.oid) LIKE '%STOCK_GAIN%'
  AND pg_get_functiondef(routine.oid) LIKE '%EXPENSE_DISBURSEMENT%'
  AND pg_get_functiondef(routine.oid) LIKE '%CASH_DEPOSIT%'
  AND pg_get_functiondef(routine.oid) LIKE '%CASH_VARIANCE%'
  AND pg_get_functiondef(routine.oid) LIKE '%FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH%'
  AND pg_get_functiondef(routine.oid) LIKE '%JOURNAL_UNBALANCED%'
 UNION ALL SELECT 'remaining_operational_dispatcher_contract',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
  jsonb_build_object('routineRows',count(*))
 FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
 WHERE namespace.nspname='private' AND routine.proname='post_financial_event_core'
  AND pg_get_functiondef(routine.oid) LIKE
   '%post_remaining_operational_financial_event_core%'
  AND pg_get_functiondef(routine.oid) LIKE '%post_purchase_ap_financial_event_core%'
  AND pg_get_functiondef(routine.oid) LIKE '%post_sale_return_financial_event_core%'
  AND pg_get_functiondef(routine.oid) LIKE '%post_financial_event_stock_opening_core%'
 UNION ALL SELECT 'private_remaining_operational_runtime_boundary',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('authenticatedExecutableRows',count(*))
 FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
 WHERE namespace.nspname='private' AND routine.proname IN(
  'g6_require_active_postable_snapshot_account',
  'post_remaining_operational_financial_event_core')
  AND has_function_privilege('authenticated',routine.oid,'EXECUTE')
 UNION ALL SELECT 'historical_remaining_operational_hold_preserved',
  CASE WHEN count(*)=7 THEN 'PASS' ELSE 'FAIL' END,abs(7-count(*)),
  jsonb_build_object('expected',7,'holdEvents',count(*))
 FROM target_events WHERE status='HOLD'::public.event_status
 UNION ALL SELECT 'remaining_operational_existing_journal_effect',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('journalRows',count(*))
 FROM public.finance_journals journal JOIN target_events event
  ON event.company_id=journal.company_id AND event.id=journal.financial_event_id
 UNION ALL SELECT 'active_finance_queue',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('runCount',count(*)) FROM public.finance_posting_queue_runs
 WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
 UNION ALL SELECT 'remaining_operational_runtime_inventory','INFO',0,
  jsonb_build_object(
   'stockGainHolds',(SELECT count(*) FROM target_events
    WHERE system_event_key='STOCK_GAIN' AND status='HOLD'::public.event_status),
   'expenseDisbursementHolds',(SELECT count(*) FROM target_events
    WHERE system_event_key='EXPENSE_DISBURSEMENT' AND status='HOLD'::public.event_status),
   'cashDepositHolds',(SELECT count(*) FROM target_events
    WHERE system_event_key='CASH_DEPOSIT' AND status='HOLD'::public.event_status),
   'cashVarianceHolds',(SELECT count(*) FROM target_events
    WHERE system_event_key='CASH_VARIANCE' AND status='HOLD'::public.event_status))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
