-- READ ONLY: financial-source baseline, not a migration or a readiness PASS.
-- Run the WHOLE SELECT and export all rows. No date/customer change is applied.
-- Columns verified against runtime export 684465b8-f509-4815-9352-02f16f544af8.
-- Inventory is restricted to the existing KMS/LSM/SMS correction rollout.
-- Verified on authorized staging 2026-10-06 with nonzero posted Invoice, DP,
-- partial/full Receipt and Journal fixtures. This is still inventory, not PASS.
-- No account names, customer contact information, credentials or auth rows.
WITH targets(company_id,company_code) AS (
  VALUES ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,'KMS'),
    ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'LSM'),
    ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid,'SMS')
), invoices AS (
  SELECT invoice.*,target.company_code
  FROM public.backoffice_sales_invoices invoice
  JOIN targets target ON target.company_id=invoice.company_id
  WHERE invoice.status='POSTED' AND invoice.invoice_type='REGULAR'
), allocations AS (
  SELECT allocation.company_id,allocation.id allocation_id,
    allocation.invoice_id,allocation.allocated_amount,
    receipt.id receipt_id,receipt.receipt_no,receipt.status receipt_status,
    receipt.customer_id receipt_customer_id,receipt.receipt_date,
    receipt.total_amount receipt_allocated_total,receipt.received_amount,
    receipt.unapplied_amount,receipt.unapplied_disposition,
    receipt.financial_event_id receipt_event_id,
    receipt.receipt_account_id_snapshot,receipt.receivable_account_id_snapshot,
    receipt.advance_liability_account_id_snapshot
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN invoices invoice ON invoice.company_id=allocation.company_id
    AND invoice.id=allocation.invoice_id
  JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
    AND receipt.id=allocation.document_id
), dp AS (
  SELECT application.company_id,application.id application_id,
    application.regular_invoice_id,application.down_payment_invoice_id,
    application.status application_status,application.applied_amount,
    application.applied_basis_amount,application.applied_tax_amount,
    source.invoice_no dp_invoice_no,source.status dp_status,
    source.customer_id dp_customer_id,source.invoice_date dp_invoice_date,
    source.financial_event_id dp_event_id
  FROM public.backoffice_sales_down_payment_applications application
  JOIN invoices invoice ON invoice.company_id=application.company_id
    AND invoice.id=application.regular_invoice_id
  JOIN public.backoffice_sales_invoices source ON source.company_id=application.company_id
    AND source.id=application.down_payment_invoice_id
), source_events AS (
  SELECT invoice.company_id,invoice.id invoice_id,'INVOICE'::text source_kind,
    invoice.id source_id,invoice.financial_event_id event_id FROM invoices invoice
  UNION ALL
  SELECT allocation.company_id,allocation.invoice_id,'RECEIPT',allocation.receipt_id,
    allocation.receipt_event_id FROM allocations allocation WHERE allocation.receipt_status='POSTED'
  UNION ALL
  SELECT application.company_id,application.regular_invoice_id,'DP',application.down_payment_invoice_id,
    application.dp_event_id FROM dp application WHERE application.application_status='POSTED'
  UNION ALL
  SELECT correction.company_id,correction.source_invoice_id,'PRICE_CORRECTION',correction.id,
    correction.financial_event_id FROM public.backoffice_sales_invoice_price_corrections correction
  JOIN invoices invoice ON invoice.company_id=correction.company_id
    AND invoice.id=correction.source_invoice_id WHERE correction.status='POSTED'
  UNION ALL
  SELECT note.company_id,note.source_invoice_id,'RETURN_CREDIT',note.id,note.financial_event_id
  FROM public.backoffice_sales_credit_notes note
  JOIN invoices invoice ON invoice.company_id=note.company_id AND invoice.id=note.source_invoice_id
  WHERE note.status='POSTED'
), sources AS (
  SELECT DISTINCT source.company_id,source.invoice_id,source.source_kind,source.source_id,source.event_id
  FROM source_events source
), source_journals AS (
  SELECT source.*,
    (SELECT count(*) FROM public.finance_journals journal
      WHERE journal.company_id=source.company_id AND journal.financial_event_id=source.event_id
        AND journal.status='POSTED' AND journal.reversal_of_journal_id IS NULL) original_posted_journals,
    COALESCE((SELECT jsonb_agg(jsonb_build_object('journalId',journal.id,
      'journalNo',journal.journal_no,'status',journal.status,'accountingDate',journal.accounting_date,
      'periodId',journal.accounting_period_id,'periodStatus',period.status,
      'reversalOf',journal.reversal_of_journal_id,'debit',journal.total_debit,
      'credit',journal.total_credit,'lines',COALESCE((
        SELECT jsonb_agg(jsonb_build_object('lineId',line.id,'accountId',line.account_id,
          'function',line.account_function_key_snapshot,'customerId',line.customer_id,
          'debit',line.debit,'credit',line.credit) ORDER BY line.line_no)
        FROM public.finance_journal_lines line
        WHERE line.company_id=journal.company_id AND line.journal_id=journal.id),'[]'::jsonb))
      ORDER BY journal.accounting_date,journal.id)
      FROM public.finance_journals journal
      LEFT JOIN public.accounting_periods period ON period.company_id=journal.company_id
        AND period.id=journal.accounting_period_id
      WHERE journal.company_id=source.company_id AND journal.financial_event_id=source.event_id),
      '[]'::jsonb) journals
  FROM sources source
), report AS (
  SELECT '00_snapshot'::text section,NULL::text company_code,NULL::text document_no,
    'INFO'::text status,jsonb_build_object('capturedAt',statement_timestamp(),
      'scope','KMS LSM SMS posted Regular Backoffice invoices',
      'readOnly',true,'purpose','Source-linked settlement and period inventory before expanded correction design') details
  UNION ALL
  SELECT '01_inventory'::text section,target.company_code,NULL::text document_no,'INFO'::text status,
    jsonb_build_object('postedRegularInvoices',count(invoice.id),
      'meaning','Nonzero data is inventory only, not behavior or rollout approval') details
  FROM targets target LEFT JOIN invoices invoice ON invoice.company_id=target.company_id
  GROUP BY target.company_code
  UNION ALL
  SELECT '02_invoice',invoice.company_code,invoice.invoice_no,'INFO',
    jsonb_build_object('invoiceId',invoice.id,'customerId',invoice.customer_id,
      'invoiceDate',invoice.invoice_date,'masterVersion',invoice.master_version,
      'originalTotal',invoice.grand_total,'originalDpDeduction',invoice.down_payment_deduction_total,
      'postedPaymentAmount',COALESCE((SELECT sum(allocation.allocated_amount) FROM allocations allocation
        WHERE allocation.company_id=invoice.company_id AND allocation.invoice_id=invoice.id
          AND allocation.receipt_status='POSTED'),0),
      'priceCorrectionDelta',COALESCE((SELECT sum(correction.total_delta)
        FROM public.backoffice_sales_invoice_price_corrections correction
        WHERE correction.company_id=invoice.company_id AND correction.source_invoice_id=invoice.id
          AND correction.status='POSTED'),0),
      'schedules',COALESCE((SELECT jsonb_agg(jsonb_build_object('installment',schedule.installment_no,
        'dueDate',schedule.due_date,'amount',schedule.amount_due,
        'paid',schedule.allocated_payment_amount,'status',schedule.status) ORDER BY schedule.installment_no)
        FROM public.backoffice_sales_invoice_receivable_schedules schedule
        WHERE schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id),'[]'::jsonb),
      'returnCredits',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',note.id,
        'number',note.credit_note_no,'status',note.status,'amount',note.grand_total,
        'refundLiability',note.refund_liability_amount)) FROM public.backoffice_sales_credit_notes note
        WHERE note.company_id=invoice.company_id AND note.source_invoice_id=invoice.id),'[]'::jsonb))
  FROM invoices invoice
  UNION ALL
  SELECT '03_payment_allocation',invoice.company_code,invoice.invoice_no,
    CASE WHEN allocation.receipt_customer_id<>invoice.customer_id THEN 'REVIEW' ELSE 'INFO' END,
    to_jsonb(allocation)||jsonb_build_object(
      'otherAllocatedAmount',allocation.receipt_allocated_total-allocation.allocated_amount,
      'meaning','Original Receipt must not be reassigned wholesale; preserve other allocations and unapplied funds')
  FROM allocations allocation JOIN invoices invoice ON invoice.company_id=allocation.company_id
    AND invoice.id=allocation.invoice_id
  UNION ALL
  SELECT '04_dp_application',invoice.company_code,invoice.invoice_no,
    CASE WHEN application.dp_customer_id<>invoice.customer_id THEN 'REVIEW' ELSE 'INFO' END,
    to_jsonb(application)||jsonb_build_object('otherPostedApplications',COALESCE((
      SELECT sum(other.applied_amount) FROM public.backoffice_sales_down_payment_applications other
      WHERE other.company_id=application.company_id
        AND other.down_payment_invoice_id=application.down_payment_invoice_id
        AND other.regular_invoice_id<>application.regular_invoice_id AND other.status='POSTED'),0))
  FROM dp application JOIN invoices invoice ON invoice.company_id=application.company_id
    AND invoice.id=application.regular_invoice_id
  UNION ALL
  SELECT '05_source_journal',invoice.company_code,invoice.invoice_no,
    CASE WHEN source.original_posted_journals=1 THEN 'INFO' ELSE 'REVIEW' END,
    to_jsonb(source)||jsonb_build_object('meaning',
      'Check source journals before designing reversal/replacement; count alone is not accounting proof')
  FROM source_journals source JOIN invoices invoice ON invoice.company_id=source.company_id
    AND invoice.id=source.invoice_id
  UNION ALL
  SELECT '06_period',target.company_code,NULL,'INFO',jsonb_build_object(
    'id',period.id,'from',period.start_date,'to',period.end_date,'status',period.status)
  FROM public.accounting_periods period JOIN targets target ON target.company_id=period.company_id
)
SELECT section,company_code,document_no,status,details FROM report
ORDER BY section,company_code,document_no,details::text;
