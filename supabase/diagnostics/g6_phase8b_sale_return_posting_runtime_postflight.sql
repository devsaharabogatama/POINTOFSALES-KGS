-- G6 phase 8B postflight: Sale/Return runtime installed, history not processed.
-- SAFETY: SELECT-only.

WITH checks(check_name,status,violation_rows,details) AS (
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260814110000'
  UNION ALL
  SELECT 'settlement_snapshot_columns',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*)),jsonb_build_object('expected',2,'columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND (table_name,column_name) IN(
      ('sales_payments','settlement_account_function_snapshot'),
      ('sales_return_refunds','settlement_account_function_snapshot'))
    AND is_nullable='NO'
  UNION ALL
  SELECT 'settlement_snapshot_coverage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('missingRows',count(*)) FROM(
      SELECT id FROM public.sales_payments WHERE settlement_account_function_snapshot IS NULL
      UNION ALL SELECT id FROM public.sales_return_refunds
      WHERE settlement_account_function_snapshot IS NULL) missing
  UNION ALL
  SELECT 'sale_return_runtime_routines',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(3-count(*)),jsonb_build_object('expected',3,'routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private' AND routine.proname IN(
    'post_financial_event_core','post_financial_event_stock_opening_core',
    'post_sale_return_financial_event_core')
  UNION ALL
  SELECT 'sale_return_runtime_contract',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private' AND routine.proname='post_sale_return_financial_event_core'
    AND pg_get_functiondef(routine.oid) LIKE '%SALE_POSTED%'
    AND pg_get_functiondef(routine.oid) LIKE '%SALES_RETURN%'
    AND pg_get_functiondef(routine.oid) LIKE '%settlement_account_function_snapshot%'
    AND pg_get_functiondef(routine.oid) LIKE '%JOURNAL_UNBALANCED%'
  UNION ALL
  SELECT 'private_sale_return_runtime_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private' AND routine.proname IN(
    'post_sale_return_financial_event_core','post_financial_event_stock_opening_core')
    AND has_function_privilege('authenticated',routine.oid,'EXECUTE')
  UNION ALL
  SELECT 'historical_sale_return_hold_preserved',CASE WHEN count(*)>=14 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)>=14 THEN 0 ELSE 14-count(*) END,
    jsonb_build_object('minimumBaseline',14,'holdEvents',count(*))
  FROM public.financial_events event WHERE event.status='HOLD'::public.event_status
    AND event.system_event_key IN('SALE_POSTED','SALES_RETURN')
  UNION ALL
  SELECT 'sale_return_existing_journal_effect',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('journalRows',count(*))
  FROM public.finance_journals journal JOIN public.financial_events event
    ON event.company_id=journal.company_id AND event.id=journal.financial_event_id
  WHERE event.system_event_key IN('SALE_POSTED','SALES_RETURN')
  UNION ALL
  SELECT 'stock_opening_runtime_preserved',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private' AND routine.proname='post_financial_event_stock_opening_core'
    AND pg_get_functiondef(routine.oid) LIKE '%STOCK_OPENING%'
  UNION ALL
  SELECT 'sale_return_runtime_inventory','INFO',0,jsonb_build_object(
    'saleHolds',(SELECT count(*) FROM public.financial_events WHERE status='HOLD'::public.event_status AND system_event_key='SALE_POSTED'),
    'returnHolds',(SELECT count(*) FROM public.financial_events WHERE status='HOLD'::public.event_status AND system_event_key='SALES_RETURN'),
    'paymentSnapshots',(SELECT count(*) FROM public.sales_payments WHERE settlement_account_function_snapshot IS NOT NULL),
    'refundSnapshots',(SELECT count(*) FROM public.sales_return_refunds WHERE settlement_account_function_snapshot IS NOT NULL))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
