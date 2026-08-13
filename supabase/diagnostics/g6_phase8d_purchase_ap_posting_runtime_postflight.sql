-- G6 phase 8D postflight: runtime installed; historical Purchase/AP HOLD preserved.
-- SAFETY: SELECT-only.

WITH target_events AS MATERIALIZED (
  SELECT event.* FROM public.financial_events event
  WHERE event.system_event_key IN(
    'GOODS_RECEIPT','SUPPLIER_INVOICE','SUPPLIER_PAYMENT')
),
checks(check_name,status,violation_rows,details) AS (
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260814140000'

  UNION ALL
  SELECT 'purchase_ap_runtime_routines',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(3-count(*)),jsonb_build_object('expected',3,'routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private' AND routine.proname IN(
    'post_purchase_ap_financial_event_core','post_purchase_ap_positive_financial_event_core',
    'g6_require_event_snapshot_account')

  UNION ALL
  SELECT 'purchase_ap_runtime_contract',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private'
    AND routine.proname='post_purchase_ap_positive_financial_event_core'
    AND pg_get_functiondef(routine.oid) LIKE '%GOODS_RECEIPT%'
    AND pg_get_functiondef(routine.oid) LIKE '%SUPPLIER_INVOICE%'
    AND pg_get_functiondef(routine.oid) LIKE '%SUPPLIER_PAYMENT%'
    AND pg_get_functiondef(routine.oid) LIKE '%FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH%'
    AND pg_get_functiondef(routine.oid) LIKE '%JOURNAL_UNBALANCED%'

  UNION ALL
  SELECT 'purchase_ap_dispatcher_contract',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private' AND routine.proname='post_financial_event_core'
    AND pg_get_functiondef(routine.oid) LIKE '%post_sale_return_financial_event_core%'
    AND pg_get_functiondef(routine.oid) LIKE '%post_purchase_ap_financial_event_core%'
    AND pg_get_functiondef(routine.oid) LIKE '%post_financial_event_stock_opening_core%'

  UNION ALL
  SELECT 'private_purchase_ap_runtime_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private' AND routine.proname IN(
    'post_purchase_ap_financial_event_core',
    'post_purchase_ap_positive_financial_event_core',
    'g6_require_event_snapshot_account')
    AND has_function_privilege('authenticated',routine.oid,'EXECUTE')

  UNION ALL
  SELECT 'historical_purchase_ap_hold_preserved',
    CASE WHEN count(*)=9 THEN 'PASS' ELSE 'FAIL' END,abs(9-count(*)),
    jsonb_build_object('expected',9,'holdEvents',count(*))
  FROM target_events WHERE status='HOLD'::public.event_status

  UNION ALL
  SELECT 'purchase_ap_existing_journal_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('journalRows',count(*))
  FROM public.finance_journals journal JOIN target_events event
    ON event.company_id=journal.company_id AND event.id=journal.financial_event_id

  UNION ALL
  SELECT 'sale_return_posted_runtime_preserved',
    CASE WHEN count(*)=14 THEN 'PASS' ELSE 'FAIL' END,abs(14-count(*)),
    jsonb_build_object('expected',14,'postedEvents',count(*))
  FROM public.financial_events event
  WHERE event.system_event_key IN('SALE_POSTED','SALES_RETURN')
    AND event.status='POSTED'::public.event_status

  UNION ALL
  SELECT 'purchase_ap_runtime_inventory','INFO',0,jsonb_build_object(
    'goodsReceiptHolds',(SELECT count(*) FROM target_events
      WHERE system_event_key='GOODS_RECEIPT' AND status='HOLD'::public.event_status),
    'supplierInvoiceHolds',(SELECT count(*) FROM target_events
      WHERE system_event_key='SUPPLIER_INVOICE' AND status='HOLD'::public.event_status),
    'supplierPaymentHolds',(SELECT count(*) FROM target_events
      WHERE system_event_key='SUPPLIER_PAYMENT' AND status='HOLD'::public.event_status))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
