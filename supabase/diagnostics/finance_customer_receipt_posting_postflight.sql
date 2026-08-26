-- F2B Customer Receipt / SALE_PAYMENT journal runtime postflight.
-- SAFETY: SELECT-only.
WITH routine_state AS (
  SELECT count(*) FILTER(WHERE namespace.nspname='private' AND routine.proname='post_customer_receipt_financial_event_core') core_rows,
    count(*) FILTER(WHERE namespace.nspname='public' AND routine.proname='post_customer_receipt') public_rows
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
), checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*)::BIGINT violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260827110000'
  UNION ALL SELECT 'required_customer_receipt_posting_routines',
    CASE WHEN core_rows=1 AND public_rows=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN core_rows=1 AND public_rows=1 THEN 0 ELSE 1 END,
    jsonb_build_object('coreRows',core_rows,'publicRows',public_rows) FROM routine_state
  UNION ALL SELECT 'customer_receipt_event_journal_coverage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('rowCount',count(*))
  FROM public.customer_receipt_documents document JOIN public.financial_events event
    ON event.company_id=document.company_id AND event.id=document.financial_event_id
  LEFT JOIN public.finance_journals journal ON journal.company_id=event.company_id AND journal.financial_event_id=event.id
  WHERE document.status='POSTED' AND event.status='POSTED' AND (journal.id IS NULL OR journal.status<>'POSTED')
  UNION ALL SELECT 'customer_receipt_journal_balance',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('journalCount',count(*)) FROM public.finance_journals journal
  JOIN public.financial_events event ON event.company_id=journal.company_id AND event.id=journal.financial_event_id
  WHERE event.system_event_key='SALE_PAYMENT' AND (journal.status<>'POSTED' OR journal.total_debit<>journal.total_credit OR journal.total_debit<=0)
  UNION ALL SELECT 'customer_receipt_journal_amount_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('documentCount',count(*))
  FROM public.customer_receipt_documents document JOIN public.finance_journals journal
    ON journal.company_id=document.company_id AND journal.financial_event_id=document.financial_event_id
  WHERE document.status='POSTED' AND (round(journal.total_debit,4)<>round(document.total_amount,4)
    OR round(journal.total_credit,4)<>round(document.total_amount,4))
  UNION ALL SELECT 'customer_receipt_runtime_inventory','INFO',0,jsonb_build_object(
    'documents',(SELECT count(*) FROM public.customer_receipt_documents),
    'posted',(SELECT count(*) FROM public.customer_receipt_documents WHERE status='POSTED'),
    'holdEvents',(SELECT count(*) FROM public.financial_events WHERE system_event_key='SALE_PAYMENT' AND status='HOLD'),
    'postedEvents',(SELECT count(*) FROM public.financial_events WHERE system_event_key='SALE_PAYMENT' AND status='POSTED'),
    'journals',(SELECT count(*) FROM public.finance_journals journal JOIN public.financial_events event ON event.company_id=journal.company_id AND event.id=journal.financial_event_id WHERE event.system_event_key='SALE_PAYMENT'))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
