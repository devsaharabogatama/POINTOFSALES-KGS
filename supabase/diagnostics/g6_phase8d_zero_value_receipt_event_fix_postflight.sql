-- G6 phase 8D zero-value Receipt forward-fix postflight. SELECT-only.

WITH checks(check_name,status,violation_rows,details) AS (
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260814143000'
  UNION ALL
  SELECT 'zero_value_receipt_runtime_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private'
    AND routine.proname='post_purchase_ap_financial_event_core'
    AND pg_get_functiondef(routine.oid) LIKE '%NO_FINANCIAL_EFFECT%'
    AND pg_get_functiondef(routine.oid) LIKE '%status=''CANCELED''%'
    AND pg_get_functiondef(routine.oid) LIKE '%post_purchase_ap_positive_financial_event_core%'
  UNION ALL
  SELECT 'private_purchase_ap_runtime_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private' AND routine.proname IN(
    'post_purchase_ap_financial_event_core',
    'post_purchase_ap_positive_financial_event_core')
    AND has_function_privilege('authenticated',routine.oid,'EXECUTE')
  UNION ALL
  SELECT 'historical_purchase_ap_state_preserved',
    CASE WHEN count(*) FILTER(WHERE status::TEXT<>'HOLD')=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE status::TEXT<>'HOLD'),jsonb_build_object(
      'holdEvents',count(*) FILTER(WHERE status::TEXT='HOLD'),
      'unexpectedNonHold',count(*) FILTER(WHERE status::TEXT<>'HOLD'))
  FROM public.financial_events event
  WHERE event.system_event_key IN(
    'GOODS_RECEIPT','SUPPLIER_INVOICE','SUPPLIER_PAYMENT')
  UNION ALL
  SELECT 'zero_value_goods_receipt_inventory','INFO',0,jsonb_build_object(
    'zeroValueHoldEvents',count(*))
  FROM public.financial_events event
  JOIN public.goods_receipt_documents document
    ON document.company_id=event.company_id AND document.id=event.source_id
   AND document.financial_event_id=event.id AND document.status='POSTED'
  WHERE event.system_event_key='GOODS_RECEIPT'
    AND event.status='HOLD'::public.event_status
    AND document.provisional_ap_total=0
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
