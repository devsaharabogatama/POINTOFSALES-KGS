-- SELECT-only verification for 20260919131000.
WITH target AS (
  SELECT note.*,sale.id sales_id,invoice.invoice_no
  FROM public.backoffice_sales_credit_notes note
  JOIN public.companies company ON company.id=note.company_id
  JOIN public.sales_headers sale ON sale.company_id=note.company_id
    AND sale.id=note.source_retail_sales_id
  JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=sale.company_id
    AND invoice.sales_id=sale.id
  WHERE note.credit_note_no='CN-20260919-0000000012'
    AND invoice.invoice_no='INV-20260904-0000000236'
), correction AS (
  SELECT journal.* FROM public.finance_journals journal
  JOIN target ON target.company_id=journal.company_id AND target.id=journal.source_id
  WHERE journal.source_type='RETAINED_CREDIT_SPLIT_RECLASSIFICATION'
), expected_accounts AS (
  SELECT target.company_id,target.id credit_note_id,
    private.resolve_financial_event_account(event,'CUSTOMER_REFUND_LIABILITY') refund_account_id,
    private.resolve_financial_event_account(event,'CUSTOMER_RECEIVABLE') ar_account_id
  FROM target JOIN public.financial_events event
    ON event.company_id=target.company_id AND event.id=target.financial_event_id
), correction_lines AS (
  SELECT line.*,
    CASE WHEN line.account_id=expected.refund_account_id THEN 'CUSTOMER_REFUND_LIABILITY'
      WHEN line.account_id=expected.ar_account_id THEN 'CUSTOMER_RECEIVABLE'
      ELSE 'UNEXPECTED' END account_function
  FROM public.finance_journal_lines line
  JOIN correction journal ON journal.company_id=line.company_id AND journal.id=line.journal_id
  JOIN expected_accounts expected ON expected.company_id=line.company_id
    AND expected.credit_note_id=journal.source_id
), refund_history AS (
  SELECT refund.*,(SELECT journal.id FROM public.finance_journals journal
      WHERE journal.company_id=refund.company_id
        AND journal.financial_event_id=refund.financial_event_id
        AND journal.status='POSTED') journal_id
  FROM public.backoffice_sales_customer_refunds refund
  JOIN target ON target.company_id=refund.company_id AND target.id=refund.credit_note_id
), runtime AS (
  SELECT pg_get_functiondef(
    'private.post_retained_retail_credit_note_core(uuid,bigint,uuid)'::regprocedure) body
)
SELECT 'retained_credit_split_fix_ledger' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,abs(count(*)-1) violation_rows,
  jsonb_build_object('ledgerRows',count(*)) details
FROM private.kgs_schema_migrations WHERE version='20260919131000'
UNION ALL
SELECT 'retained_credit_split_runtime_contract',
  CASE WHEN position('odr6d_dispatched_receivable_before_receipts' IN body)>0
    AND position('v_sale.sisa_piutang-v_receipts-v_prior_ar' IN body)=0 THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN position('odr6d_dispatched_receivable_before_receipts' IN body)>0
    AND position('v_sale.sisa_piutang-v_receipts-v_prior_ar' IN body)=0 THEN 0 ELSE 1 END,
  jsonb_build_object('canonicalReceivable',position('odr6d_dispatched_receivable_before_receipts' IN body)>0,
    'legacySisaPiutang',position('v_sale.sisa_piutang-v_receipts-v_prior_ar' IN body)>0)
FROM runtime
UNION ALL
SELECT 'retained_credit_split_exact_note',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-1),
  jsonb_build_object('rows',count(*),'note',COALESCE(jsonb_agg(jsonb_build_object(
    'invoiceNo',invoice_no,'status',status,'grandTotal',grand_total,
    'arReduction',ar_reduction_amount,'refundLiability',refund_liability_amount)),'[]'::jsonb))
FROM target WHERE status='POSTED' AND grand_total=78400
  AND ar_reduction_amount=78400 AND refund_liability_amount=0
UNION ALL
SELECT 'retained_credit_split_correction_journal',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-1),
  jsonb_build_object('rows',count(*),'journals',COALESCE(jsonb_agg(jsonb_build_object(
    'journalNo',journal_no,'status',status,'debit',total_debit,'credit',total_credit,
    'accountingDate',accounting_date)),'[]'::jsonb))
FROM correction WHERE status='POSTED' AND total_debit=78400 AND total_credit=78400
UNION ALL
SELECT 'retained_credit_split_correction_accounts',
  CASE WHEN count(*)=2
    AND count(*) FILTER(WHERE account_function='CUSTOMER_REFUND_LIABILITY'
      AND debit=78400 AND credit=0)=1
    AND count(*) FILTER(WHERE account_function='CUSTOMER_RECEIVABLE'
      AND debit=0 AND credit=78400)=1 THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN count(*)=2
    AND count(*) FILTER(WHERE account_function='CUSTOMER_REFUND_LIABILITY'
      AND debit=78400 AND credit=0)=1
    AND count(*) FILTER(WHERE account_function='CUSTOMER_RECEIVABLE'
      AND debit=0 AND credit=78400)=1 THEN 0 ELSE 1 END,
  jsonb_build_object('rows',count(*),'lines',COALESCE(jsonb_agg(jsonb_build_object(
    'function',account_function,'debit',debit,'credit',credit)),'[]'::jsonb))
FROM correction_lines
UNION ALL
SELECT 'retained_credit_split_refund_reversal',
  CASE WHEN count(*)=2
    AND count(*) FILTER(WHERE document_kind='REFUND' AND amount=78400)=1
    AND count(*) FILTER(WHERE document_kind='REVERSAL' AND amount=78400
      AND reversal_of_refund_id IS NOT NULL)=1
    AND sum(CASE document_kind WHEN 'REFUND' THEN amount ELSE -amount END)=0
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN count(*)=2
    AND count(*) FILTER(WHERE document_kind='REFUND' AND amount=78400)=1
    AND count(*) FILTER(WHERE document_kind='REVERSAL' AND amount=78400
      AND reversal_of_refund_id IS NOT NULL)=1
    AND sum(CASE document_kind WHEN 'REFUND' THEN amount ELSE -amount END)=0
    THEN 0 ELSE 1 END,
  jsonb_build_object('rows',count(*),'netRefund',COALESCE(sum(
    CASE document_kind WHEN 'REFUND' THEN amount ELSE -amount END),0),
    'history',COALESCE(jsonb_agg(jsonb_build_object('refundNo',refund_no,
      'kind',document_kind,'amount',amount,'reversalOf',reversal_of_refund_id,
      'journalId',journal_id) ORDER BY created_at,id),'[]'::jsonb))
FROM refund_history;
