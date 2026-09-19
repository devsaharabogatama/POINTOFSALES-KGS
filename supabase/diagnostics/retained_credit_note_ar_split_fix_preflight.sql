-- SELECT-only gate for retained Retail Credit Note AR/refund split correction.
WITH target AS (
  SELECT note.*,sale.sisa_piutang,
    private.odr6d_dispatched_receivable_before_receipts(
      note.company_id,note.source_retail_sales_id,note.credit_note_date) canonical_receivable,
    COALESCE((SELECT sum(allocation.allocated_amount)
      FROM public.customer_receipt_allocations allocation
      JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
        AND receipt.id=allocation.document_id AND receipt.status='POSTED'
        AND receipt.receipt_date<=note.credit_note_date
      WHERE allocation.company_id=note.company_id
        AND allocation.sales_id=note.source_retail_sales_id),0) receipt_amount,
    COALESCE((SELECT sum(allocation.allocated_amount)
      FROM public.customer_receipt_allocations allocation
      JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
        AND receipt.id=allocation.document_id AND receipt.status='POSTED'
      WHERE allocation.company_id=note.company_id
        AND allocation.sales_id=note.source_retail_sales_id),0) total_receipt_amount
  FROM public.backoffice_sales_credit_notes note
  JOIN public.sales_headers sale ON sale.company_id=note.company_id
    AND sale.id=note.source_retail_sales_id
  JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=sale.company_id
    AND invoice.sales_id=sale.id
  WHERE note.credit_note_no='CN-20260919-0000000012'
    AND invoice.invoice_no='INV-20260904-0000000236'
), refund_history AS (
  SELECT refund.*,(SELECT count(*) FROM public.finance_journals journal
      WHERE journal.company_id=refund.company_id
        AND journal.financial_event_id=refund.financial_event_id
        AND journal.status='POSTED') posted_journal_rows
  FROM public.backoffice_sales_customer_refunds refund
  JOIN target ON target.company_id=refund.company_id AND target.id=refund.credit_note_id
), runtime AS (
  SELECT pg_get_functiondef(
    'private.post_retained_retail_credit_note_core(uuid,bigint,uuid)'::regprocedure) body
)
SELECT 'retained_credit_split_exact_target' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
  abs(count(*)-1) violation_rows,
  jsonb_build_object('rows',count(*),'target',COALESCE(jsonb_agg(jsonb_build_object(
    'id',id,'status',status,'grandTotal',grand_total,'storedAr',ar_reduction_amount,
    'storedRefund',refund_liability_amount,'legacySisaPiutang',sisa_piutang,
    'canonicalReceivable',canonical_receivable,'postedReceiptsAtNote',receipt_amount,
    'postedReceiptsTotal',total_receipt_amount)),'[]'::jsonb)) details
FROM target
UNION ALL
SELECT 'retained_credit_split_exact_shape',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,abs(count(*)-1),
  jsonb_build_object('eligibleRows',count(*)) FROM target
WHERE status='POSTED' AND source_kind='RETAINED_RETAIL'
  AND ar_reduction_amount=0 AND refund_liability_amount=grand_total
  AND total_receipt_amount=0
  AND canonical_receivable-receipt_amount>=grand_total
UNION ALL
SELECT 'retained_credit_split_refund_reversal_shape',
  CASE WHEN count(*)=1
    AND count(*) FILTER(WHERE document_kind='REFUND' AND status='POSTED'
      AND amount=78400 AND reversal_of_refund_id IS NULL
      AND posted_journal_rows=1)=1 THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN count(*)=1
    AND count(*) FILTER(WHERE document_kind='REFUND' AND status='POSTED'
      AND amount=78400 AND reversal_of_refund_id IS NULL
      AND posted_journal_rows=1)=1 THEN 0 ELSE 1 END,
  jsonb_build_object('rows',count(*),'history',COALESCE(jsonb_agg(jsonb_build_object(
    'id',id,'refundNo',refund_no,'kind',document_kind,'status',status,
    'date',refund_date,'amount',amount,'route',settlement_route_snapshot,
    'method',payment_method_name_snapshot,'reversalOf',reversal_of_refund_id,
    'postedJournalRows',posted_journal_rows) ORDER BY created_at,id),'[]'::jsonb))
FROM refund_history
UNION ALL
SELECT 'retained_credit_split_correction_absence',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
  jsonb_build_object('correctionJournals',count(*))
FROM public.finance_journals journal
JOIN target ON target.company_id=journal.company_id AND target.id=journal.source_id
WHERE journal.source_type='RETAINED_CREDIT_SPLIT_RECLASSIFICATION'
UNION ALL
SELECT 'retained_credit_split_migration_absence',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
  jsonb_build_object('ledgerRows',count(*))
FROM private.kgs_schema_migrations WHERE version='20260919131000'
UNION ALL
SELECT 'retained_credit_split_dependency_ledger',
  CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,abs(count(*)-3),
  jsonb_build_object('installed',COALESCE(jsonb_agg(version ORDER BY version),'[]'::jsonb),
    'expected',ARRAY['20260917151000','20260918150000','20260919110000'])
FROM private.kgs_schema_migrations
WHERE version IN('20260917151000','20260918150000','20260919110000')
UNION ALL
SELECT 'retained_credit_split_runtime_anchor',
  CASE WHEN position('v_sale.sisa_piutang-v_receipts-v_prior_ar' IN body)>0
    AND position('odr6d_dispatched_receivable_before_receipts' IN body)=0
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN position('v_sale.sisa_piutang-v_receipts-v_prior_ar' IN body)>0
    AND position('odr6d_dispatched_receivable_before_receipts' IN body)=0
    THEN 0 ELSE 1 END,
  jsonb_build_object('legacyAnchor',position('v_sale.sisa_piutang-v_receipts-v_prior_ar' IN body)>0,
    'canonicalAnchorAlreadyPresent',position('odr6d_dispatched_receivable_before_receipts' IN body)>0)
FROM runtime
UNION ALL
SELECT 'retained_credit_split_active_finance_queue',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),jsonb_build_object('rows',count(*))
FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING');
