-- F2B Customer Receipt / SALE_PAYMENT journal runtime preflight.
-- SAFETY: SELECT-only.
WITH checks AS (
  SELECT 'f2_foundation_dependency' check_name,
    CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260827100000')
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('ledgerRows',(SELECT count(*) FROM private.kgs_schema_migrations WHERE version='20260827100000')) details
  UNION ALL
  SELECT 'canonical_customer_receipt_runtime','SETUP',jsonb_build_object(
    'postingCoreExists',to_regprocedure('private.post_customer_receipt_financial_event_core(uuid,uuid,bigint,uuid)') IS NOT NULL,
    'dispatcherSupportsSalePayment',COALESCE((SELECT pg_get_functiondef(routine.oid) ILIKE '%SALE_PAYMENT%'
      FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
      WHERE namespace.nspname='private' AND routine.proname='post_financial_event_core'
        AND pg_get_function_identity_arguments(routine.oid)='p_company_id uuid, p_event_id uuid, p_expected_event_version bigint, p_actor_id uuid'),FALSE))
  UNION ALL
  SELECT 'customer_receipt_hold_inventory','INFO',jsonb_build_object(
    'postedReceipts',(SELECT count(*) FROM public.customer_receipt_documents WHERE status='POSTED'),
    'holdEvents',(SELECT count(*) FROM public.financial_events WHERE system_event_key='SALE_PAYMENT' AND status='HOLD'),
    'postedEvents',(SELECT count(*) FROM public.financial_events WHERE system_event_key='SALE_PAYMENT' AND status='POSTED'))
  UNION ALL
  SELECT 'customer_receipt_source_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,jsonb_build_object('rowCount',count(*))
  FROM public.customer_receipt_documents document
  JOIN public.financial_events event ON event.company_id=document.company_id AND event.id=document.financial_event_id
  WHERE document.status='POSTED' AND (
    event.system_event_key<>'SALE_PAYMENT' OR event.source_table<>'customer_receipt_documents'
    OR event.source_id<>document.id OR round((event.amounts->>'receiptAmount')::numeric,4)<>round(document.total_amount,4))
  UNION ALL
  SELECT 'customer_receipt_existing_journal_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,jsonb_build_object('journalCount',count(*))
  FROM public.finance_journals journal JOIN public.financial_events event
    ON event.company_id=journal.company_id AND event.id=journal.financial_event_id
  WHERE event.system_event_key='SALE_PAYMENT'
)
SELECT check_name,status,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2 WHEN 'PASS' THEN 3 ELSE 4 END,check_name;

