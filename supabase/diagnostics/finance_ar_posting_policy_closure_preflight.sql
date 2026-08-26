-- F4B Finance posting policy and AR closure preflight.
-- SAFETY: SELECT-only. No policy, queue, event, journal or source mutation.
WITH final_event_sources AS (
  SELECT event.id,event.company_id,event.status::TEXT status,event.event_type::TEXT event_type,
    event.system_event_key,event.source_table,event.source_id,event.event_version
  FROM public.financial_events event
),posted_receipt_totals AS (
  SELECT allocation.company_id,allocation.sales_id,sum(allocation.allocated_amount) paid
  FROM public.customer_receipt_allocations allocation
  JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
    AND receipt.id=allocation.document_id AND receipt.status='POSTED'
  GROUP BY allocation.company_id,allocation.sales_id
),checks AS (
  SELECT 'f4b_dependencies' check_name,
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',5,'ledgerRows',count(*),'requiredVersions',
      ARRAY['20260827100000','20260827110000','20260827120000',
        '20260827130000','20260827131000']) details
  FROM private.kgs_schema_migrations WHERE version=ANY(ARRAY[
    '20260827100000','20260827110000','20260827120000',
    '20260827130000','20260827131000'])
  UNION ALL
  SELECT 'active_finance_posting_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs run
  WHERE run.status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'open_finance_posting_exception',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
    jsonb_build_object('exceptionRows',count(*))
  FROM public.finance_posting_exceptions exception_state
  WHERE exception_state.status<>'RESOLVED'
  UNION ALL
  SELECT 'nonposted_financial_event_scope',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('eventCount',count(*),'byStatus',COALESCE(jsonb_object_agg(status,event_count),'{}'::JSONB))
  FROM (SELECT status,count(*) event_count FROM final_event_sources
    WHERE status<>'POSTED' GROUP BY status) state
  UNION ALL
  SELECT 'posted_event_journal_coverage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('eventCount',count(*))
  FROM final_event_sources event
  WHERE event.status='POSTED' AND NOT EXISTS(SELECT 1 FROM public.finance_journals journal
    WHERE journal.company_id=event.company_id AND journal.financial_event_id=event.id
      AND journal.status='POSTED')
  UNION ALL
  SELECT 'duplicate_event_journal',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT journal.company_id,journal.financial_event_id
    FROM public.finance_journals journal WHERE journal.financial_event_id IS NOT NULL
    GROUP BY journal.company_id,journal.financial_event_id HAVING count(*)>1) duplicate
  UNION ALL
  SELECT 'posted_journal_balance',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('journalCount',count(*))
  FROM public.finance_journals journal WHERE journal.status='POSTED'
    AND (journal.total_debit<>journal.total_credit OR journal.total_debit<0)
  UNION ALL
  SELECT 'customer_receipt_event_journal_coverage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('documentCount',count(*))
  FROM public.customer_receipt_documents receipt
  WHERE receipt.status='POSTED' AND (receipt.financial_event_id IS NULL
    OR NOT EXISTS(SELECT 1 FROM public.financial_events event
      JOIN public.finance_journals journal ON journal.company_id=event.company_id
        AND journal.financial_event_id=event.id AND journal.status='POSTED'
      WHERE event.company_id=receipt.company_id AND event.id=receipt.financial_event_id
        AND event.status='POSTED'))
  UNION ALL
  SELECT 'tempo_outstanding_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invoiceCount',count(*))
  FROM public.sales_headers sale LEFT JOIN posted_receipt_totals receipt
    ON receipt.company_id=sale.company_id AND receipt.sales_id=sale.id
  WHERE sale.document_status='POSTED' AND sale.is_tempo
    AND (COALESCE(receipt.paid,0)<0 OR COALESCE(receipt.paid,0)>sale.sisa_piutang)
  UNION ALL
  SELECT 'finance_posting_policy_state','INFO',jsonb_build_object(
    'controlledCompanies',count(*) FILTER(WHERE posting_mode='CONTROLLED'),
    'automaticCompanies',count(*) FILTER(WHERE posting_mode='AUTOMATIC'),
    'policyRows',count(*))
  FROM public.finance_company_policies
  UNION ALL
  SELECT 'canonical_posting_policy_runtime_state','SETUP',jsonb_build_object(
    'requiredDesign',ARRAY[
      'CONTROLLED remains default and uses reviewed preview/approve/process queue',
      'AUTOMATIC posts only supported final events through canonical single-event dispatcher',
      'posting failure preserves source finality, leaves event retryable, and records exception',
      'policy change is versioned, audited and Owner/Admin controlled',
      'no browser direct event, queue or journal write'],
    'savePolicyRoutineExists',to_regprocedure(
      'public.save_finance_posting_policy(bigint,text)') IS NOT NULL,
    'automaticProcessorExists',to_regprocedure(
      'public.process_automatic_financial_events(integer)') IS NOT NULL)
  UNION ALL
  SELECT 'posting_runtime_contract_inventory','INFO',jsonb_build_object(
    'events',(SELECT count(*) FROM final_event_sources),
    'postedEvents',(SELECT count(*) FROM final_event_sources WHERE status='POSTED'),
    'holdEvents',(SELECT count(*) FROM final_event_sources WHERE status='HOLD'),
    'failedEvents',(SELECT count(*) FROM final_event_sources WHERE status='FAILED'),
    'postedJournals',(SELECT count(*) FROM public.finance_journals WHERE status='POSTED'),
    'postedCustomerReceipts',(SELECT count(*) FROM public.customer_receipt_documents WHERE status='POSTED'),
    'openTempoInvoices',(SELECT count(*) FROM public.sales_headers sale
      LEFT JOIN posted_receipt_totals receipt ON receipt.company_id=sale.company_id
        AND receipt.sales_id=sale.id
      WHERE sale.document_status='POSTED' AND sale.is_tempo
        AND sale.sisa_piutang-COALESCE(receipt.paid,0)>0))
)
SELECT check_name,status,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 1 WHEN 'BACKFILL' THEN 2 WHEN 'REVIEW' THEN 3
    WHEN 'SETUP' THEN 4 WHEN 'PASS' THEN 5 ELSE 6 END,check_name;
