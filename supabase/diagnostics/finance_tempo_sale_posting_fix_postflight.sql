-- Finance TEMPO Sale posting forward-fix postflight.
-- SAFETY: SELECT-only.
WITH tempo_hold AS MATERIALIZED (
  SELECT event.id,event.company_id,event.event_date,event.transaction_category_id,
    event.amounts,sale.id sales_id,sale.customer_id,
    sale.grand_total_after_rounding,sale.paid_amount,sale.sisa_piutang,
    COALESCE((SELECT sum(payment.amount) FROM public.sales_payments payment
      WHERE payment.company_id=event.company_id
        AND payment.sales_id=sale.id),0) payment_total,
    COALESCE((SELECT sum(payment.customer_surcharge_amount)
      FROM public.sales_payments payment
      WHERE payment.company_id=event.company_id
        AND payment.sales_id=sale.id),0) surcharge_total
  FROM public.financial_events event
  JOIN public.sales_headers sale ON sale.company_id=event.company_id
    AND sale.id=event.source_id AND sale.document_status='POSTED'
  WHERE event.status::TEXT='HOLD' AND event.system_event_key='SALE_POSTED'
    AND event.event_type::TEXT='SALE_POSTED' AND event.source_table='sales_headers'
    AND sale.sisa_piutang>0
),checks(check_name,status,violation_rows,details) AS (
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-1),jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260827141000'
  UNION ALL
  SELECT 'tempo_sale_posting_runtime_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-1),
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private'
    AND routine.oid=to_regprocedure(
      'private.post_sale_return_financial_event_core(uuid,uuid,bigint,uuid)')
    AND pg_get_functiondef(routine.oid) LIKE '%CUSTOMER_RECEIVABLE%'
    AND pg_get_functiondef(routine.oid) LIKE '%v_settlement+v_receivable%'
    AND pg_get_functiondef(routine.oid) LIKE '%20260827141000%'
  UNION ALL
  SELECT 'private_tempo_posting_runtime_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM (VALUES('private.post_sale_return_financial_event_core(uuid,uuid,bigint,uuid)'::TEXT))
    expected(signature)
  WHERE has_function_privilege('authenticated',signature,'EXECUTE')
  UNION ALL
  SELECT 'tempo_hold_source_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('violationRows',count(*))
  FROM tempo_hold event
  WHERE event.customer_id IS NULL OR event.sisa_piutang<=0
    OR round(COALESCE((event.amounts->>'receivable')::NUMERIC,-1),4)
      <>round(event.sisa_piutang,4)
    OR round(COALESCE((event.amounts->>'paymentTotal')::NUMERIC,-1),4)
      <>round(event.payment_total,4)
    OR round(event.paid_amount,4)<>round(event.payment_total,4)
    OR round(event.payment_total+event.sisa_piutang,4)
      <>round(event.grand_total_after_rounding+event.surcharge_total,4)
  UNION ALL
  SELECT 'tempo_receivable_account_resolution',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('unresolvedOrAmbiguousRows',count(*))
  FROM tempo_hold event
  WHERE NOT(
    (SELECT count(*) FROM public.transaction_account_rules rule
      WHERE rule.company_id=event.company_id
        AND rule.transaction_category_id=event.transaction_category_id
        AND rule.system_key='SALE_POSTED'
        AND rule.account_function_key='CUSTOMER_RECEIVABLE'
        AND rule.status='ACTIVE' AND rule.effective_from<=event.event_date
        AND (rule.effective_to IS NULL OR rule.effective_to>event.event_date))=1
    OR ((SELECT count(*) FROM public.transaction_account_rules rule
      WHERE rule.company_id=event.company_id
        AND rule.transaction_category_id=event.transaction_category_id
        AND rule.system_key='SALE_POSTED'
        AND rule.account_function_key='CUSTOMER_RECEIVABLE'
        AND rule.status='ACTIVE' AND rule.effective_from<=event.event_date
        AND (rule.effective_to IS NULL OR rule.effective_to>event.event_date))=0
      AND (SELECT count(*) FROM public.company_account_function_fallbacks fallback
        WHERE fallback.company_id=event.company_id
          AND fallback.account_function_key='CUSTOMER_RECEIVABLE'
          AND fallback.status='ACTIVE' AND fallback.effective_from<=event.event_date
          AND (fallback.effective_to IS NULL
            OR fallback.effective_to>event.event_date))=1))
  UNION ALL
  SELECT 'tempo_hold_retry_scope',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,0,
    jsonb_build_object('eventCount',count(*),'companies',count(DISTINCT company_id),
      'receivableTotal',COALESCE(sum(sisa_piutang),0))
  FROM tempo_hold
  UNION ALL
  SELECT 'tempo_event_existing_journal_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('journalRows',count(*))
  FROM tempo_hold event JOIN public.finance_journals journal
    ON journal.company_id=event.company_id AND journal.financial_event_id=event.id
  UNION ALL
  SELECT 'posted_tempo_receivable_journal_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.financial_events event
  JOIN public.sales_headers sale ON sale.company_id=event.company_id
    AND sale.id=event.source_id AND sale.document_status='POSTED'
  WHERE event.status::TEXT='POSTED' AND event.system_event_key='SALE_POSTED'
    AND sale.sisa_piutang>0 AND NOT EXISTS(
      SELECT 1 FROM public.finance_journals journal
      JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
        AND line.journal_id=journal.id
      WHERE journal.company_id=event.company_id
        AND journal.financial_event_id=event.id AND journal.status='POSTED'
        AND line.description='CUSTOMER_RECEIVABLE'
        AND line.customer_id=sale.customer_id
      GROUP BY journal.id HAVING round(sum(line.debit-line.credit),4)=round(sale.sisa_piutang,4))
  UNION ALL
  SELECT 'posted_journal_balance',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('journalCount',count(*))
  FROM public.finance_journals journal WHERE journal.status='POSTED'
    AND (journal.total_debit<>journal.total_credit OR journal.total_debit<0)
  UNION ALL
  SELECT 'duplicate_financial_event_journal',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT company_id,financial_event_id FROM public.finance_journals
    WHERE financial_event_id IS NOT NULL GROUP BY company_id,financial_event_id
    HAVING count(*)>1) duplicate
  UNION ALL
  SELECT 'tempo_posting_exception_scope',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,0,
    jsonb_build_object('openExceptions',count(*))
  FROM public.finance_posting_exceptions exception_state
  JOIN public.financial_events event ON event.company_id=exception_state.company_id
    AND event.id=exception_state.financial_event_id
  WHERE exception_state.status<>'RESOLVED' AND event.system_event_key='SALE_POSTED'
    AND event.status::TEXT='HOLD'
  UNION ALL
  SELECT 'tempo_posting_runtime_inventory','INFO',0,jsonb_build_object(
    'holdTempoEvents',(SELECT count(*) FROM tempo_hold),
    'postedTempoEvents',(SELECT count(*) FROM public.financial_events event
      JOIN public.sales_headers sale ON sale.company_id=event.company_id
        AND sale.id=event.source_id
      WHERE event.status::TEXT='POSTED' AND event.system_event_key='SALE_POSTED'
        AND sale.sisa_piutang>0))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'FAIL' THEN 1 WHEN 'BACKFILL' THEN 2
    WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
