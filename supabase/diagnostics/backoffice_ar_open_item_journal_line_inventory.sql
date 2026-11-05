-- SELECT-only Task 2 evidence for KMS, LSM and SMS AR open-item foundation.
-- Purpose: prove whether posted CUSTOMER_RECEIVABLE journal lines can be the
-- canonical debit/credit anchors without creating a second nominal ledger.
-- No active-company context, temp object, DDL, DML, function call with side
-- effects, or production mutation is present.

WITH
target_codes(company_code) AS (
  VALUES ('KMS'::text),('LSM'::text),('SMS'::text)
),
scope AS (
  SELECT company.id AS company_id,company.company_code,company.company_name,
    setting.active_mode
  FROM public.companies company
  JOIN target_codes target ON target.company_code=company.company_code
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=company.id
),
ar_lines AS (
  SELECT journal.company_id,journal.id AS journal_id,journal.source_type,
    journal.source_id,journal.accounting_date,journal.status AS journal_status,
    line.id AS line_id,line.account_id,line.customer_id,line.debit,line.credit,
    line.account_function_key_snapshot
  FROM scope
  JOIN public.finance_journals journal
    ON journal.company_id=scope.company_id AND journal.status='POSTED'
  JOIN public.finance_journal_lines line
    ON line.company_id=journal.company_id AND line.journal_id=journal.id
  WHERE line.account_function_key_snapshot='CUSTOMER_RECEIVABLE'
),
invoice_ar AS (
  SELECT invoice.company_id,invoice.id AS invoice_id,invoice.invoice_no,
    invoice.customer_id,invoice.grand_total,invoice.status,
    count(line.line_id) AS ar_line_rows,
    round(COALESCE(sum(line.debit),0),4) AS ar_debit,
    round(COALESCE(sum(line.credit),0),4) AS ar_credit,
    min(line.account_id::text)::uuid AS ar_account_id,
    min(line.customer_id::text)::uuid AS ar_customer_id
  FROM scope
  JOIN public.backoffice_sales_invoices invoice
    ON invoice.company_id=scope.company_id AND invoice.status='POSTED'
  LEFT JOIN ar_lines line ON line.company_id=invoice.company_id
    AND line.source_id=invoice.id
    AND line.source_type='backoffice_sales_invoices'
  GROUP BY invoice.company_id,invoice.id,invoice.invoice_no,invoice.customer_id,
    invoice.grand_total,invoice.status
),
backoffice_receipt_amounts AS (
  SELECT allocation.company_id,allocation.document_id,
    round(sum(allocation.allocated_amount),4) AS amount
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN scope ON scope.company_id=allocation.company_id
  GROUP BY allocation.company_id,allocation.document_id
),
retail_receipt_amounts AS (
  SELECT allocation.company_id,allocation.document_id,
    round(sum(allocation.allocated_amount),4) AS amount
  FROM public.customer_receipt_allocations allocation
  JOIN scope ON scope.company_id=allocation.company_id
  GROUP BY allocation.company_id,allocation.document_id
),
receipt_amounts AS (
  SELECT receipt.company_id,receipt.id AS receipt_id,receipt.receipt_no,
    receipt.customer_id,receipt.total_amount,receipt.received_amount,
    COALESCE(backoffice.amount,0) AS backoffice_amount,
    COALESCE(retail.amount,0) AS retail_amount
  FROM scope
  JOIN public.customer_receipt_documents receipt
    ON receipt.company_id=scope.company_id AND receipt.status='POSTED'
  JOIN backoffice_receipt_amounts backoffice
    ON backoffice.company_id=receipt.company_id
   AND backoffice.document_id=receipt.id
  LEFT JOIN retail_receipt_amounts retail
    ON retail.company_id=receipt.company_id AND retail.document_id=receipt.id
),
receipt_ar AS (
  SELECT receipt.company_id,receipt.receipt_id,receipt.receipt_no,
    receipt.customer_id,receipt.total_amount,receipt.received_amount,
    receipt.backoffice_amount,receipt.retail_amount,
    count(line.line_id) AS ar_line_rows,
    round(COALESCE(sum(line.debit),0),4) AS ar_debit,
    round(COALESCE(sum(line.credit),0),4) AS ar_credit,
    min(line.account_id::text)::uuid AS ar_account_id,
    min(line.customer_id::text)::uuid AS ar_customer_id
  FROM receipt_amounts receipt
  LEFT JOIN ar_lines line ON line.company_id=receipt.company_id
    AND line.source_id=receipt.receipt_id
    AND line.source_type='customer_receipt_documents'
  GROUP BY receipt.company_id,receipt.receipt_id,receipt.receipt_no,
    receipt.customer_id,receipt.total_amount,receipt.received_amount,
    receipt.backoffice_amount,receipt.retail_amount
),
credit_note_ar AS (
  SELECT note.company_id,note.id AS credit_note_id,note.credit_note_no,
    note.source_invoice_id,note.customer_id,note.grand_total,
    note.ar_reduction_amount,note.refund_liability_amount,note.source_kind,
    count(line.line_id) AS ar_line_rows,
    round(COALESCE(sum(line.debit),0),4) AS ar_debit,
    round(COALESCE(sum(line.credit),0),4) AS ar_credit,
    min(line.account_id::text)::uuid AS ar_account_id,
    min(line.customer_id::text)::uuid AS ar_customer_id
  FROM scope
  JOIN public.backoffice_sales_credit_notes note
    ON note.company_id=scope.company_id AND note.status='POSTED'
   AND note.source_kind='BACKOFFICE'
  LEFT JOIN ar_lines line ON line.company_id=note.company_id
    AND line.source_id=note.id
    AND line.source_type='backoffice_sales_credit_notes'
  GROUP BY note.company_id,note.id,note.credit_note_no,note.source_invoice_id,
    note.customer_id,note.grand_total,note.ar_reduction_amount,
    note.refund_liability_amount,note.source_kind
),
receipt_pairs AS (
  SELECT allocation.company_id,allocation.id AS allocation_id,
    allocation.document_id,allocation.invoice_id,allocation.allocated_amount,
    invoice.ar_line_rows AS invoice_ar_rows,receipt.ar_line_rows AS receipt_ar_rows,
    invoice.ar_account_id AS invoice_account_id,
    receipt.ar_account_id AS receipt_account_id,
    invoice.ar_customer_id AS invoice_customer_id,
    receipt.ar_customer_id AS receipt_customer_id
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN scope ON scope.company_id=allocation.company_id
  JOIN invoice_ar invoice ON invoice.company_id=allocation.company_id
    AND invoice.invoice_id=allocation.invoice_id
  JOIN receipt_ar receipt ON receipt.company_id=allocation.company_id
    AND receipt.receipt_id=allocation.document_id
  JOIN public.customer_receipt_documents document
    ON document.company_id=allocation.company_id
   AND document.id=allocation.document_id AND document.status='POSTED'
),
credit_pairs AS (
  SELECT note.company_id,note.credit_note_id,note.source_invoice_id,
    note.ar_reduction_amount,invoice.ar_line_rows AS invoice_ar_rows,
    note.ar_line_rows AS credit_ar_rows,
    invoice.ar_account_id AS invoice_account_id,
    note.ar_account_id AS credit_account_id,
    invoice.ar_customer_id AS invoice_customer_id,
    note.ar_customer_id AS credit_customer_id
  FROM credit_note_ar note
  JOIN invoice_ar invoice ON invoice.company_id=note.company_id
    AND invoice.invoice_id=note.source_invoice_id
  WHERE note.ar_reduction_amount>0
),
price_corrections AS (
  SELECT scope.company_code,correction.correction_kind,count(*) AS rows,
    round(sum(correction.total_delta),4) AS total_delta,
    round(sum(correction.ar_adjustment_amount),4) AS ar_adjustment,
    round(sum(correction.refund_liability_amount),4) AS refund_liability,
    count(*) FILTER(WHERE line.line_id IS NULL) AS missing_ar_line,
    count(*) FILTER(WHERE line.customer_id IS NULL) AS missing_ar_customer
  FROM scope
  JOIN public.backoffice_sales_invoice_price_corrections correction
    ON correction.company_id=scope.company_id AND correction.status='POSTED'
  LEFT JOIN ar_lines line ON line.company_id=correction.company_id
    AND line.source_id=correction.id
    AND line.source_type='backoffice_sales_invoice_price_corrections'
  GROUP BY scope.company_code,correction.correction_kind
),
revision_inventory AS (
  SELECT scope.company_code,count(*) AS rows,
    round(COALESCE(sum(revision.payable_delta),0),4) AS payable_delta,
    count(*) FILTER(WHERE revision.prior_customer_id<>revision.new_customer_id)
      AS customer_change_rows
  FROM scope
  JOIN private.backoffice_invoice_revisions revision
    ON revision.company_id=scope.company_id
  GROUP BY scope.company_code
)
SELECT 'backoffice_ar_journal_line_company_scope' AS check_name,
  CASE WHEN (SELECT count(*) FROM scope)=3
      AND NOT EXISTS(SELECT 1 FROM scope
        WHERE active_mode<>'BACKOFFICE_DELIVERED_QTY_INVOICE')
    THEN 'PASS' ELSE 'FAIL' END AS status,
  ((3-(SELECT count(*) FROM scope))+
    (SELECT count(*) FROM scope
      WHERE active_mode<>'BACKOFFICE_DELIVERED_QTY_INVOICE'))::bigint AS violation_rows,
  jsonb_build_object('companies',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'code',company_code,'name',company_name,'activeMode',active_mode)
    ORDER BY company_code) FROM scope),'[]'::jsonb)) AS details
UNION ALL
SELECT 'backoffice_ar_journal_line_source_inventory','INFO',0,
  jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'company',scope.company_code,'sourceType',line.source_type,
    'debit',line.debit,'credit',line.credit,'rows',line.rows)
    ORDER BY scope.company_code,line.source_type,line.debit DESC,line.credit DESC)
    FROM scope JOIN (SELECT company_id,source_type,
      round(sum(debit),4) AS debit,round(sum(credit),4) AS credit,count(*) AS rows
      FROM ar_lines GROUP BY company_id,source_type) line
      ON line.company_id=scope.company_id),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_journal_line_invoice_coverage',
  CASE WHEN NOT EXISTS(SELECT 1 FROM invoice_ar
      WHERE ar_line_rows<>1 OR ar_debit<>grand_total OR ar_credit<>0
        OR ar_customer_id IS DISTINCT FROM customer_id)
    THEN 'PASS' ELSE 'FAIL' END,
  (SELECT count(*) FROM invoice_ar
    WHERE ar_line_rows<>1 OR ar_debit<>grand_total OR ar_credit<>0
      OR ar_customer_id IS DISTINCT FROM customer_id),
  jsonb_build_object('postedInvoices',(SELECT count(*) FROM invoice_ar),
    'invalid',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'invoiceNo',invoice_no,'lineRows',ar_line_rows,'grandTotal',grand_total,
      'arDebit',ar_debit,'arCredit',ar_credit,'customerId',customer_id,
      'arCustomerId',ar_customer_id) ORDER BY invoice_no)
      FROM invoice_ar WHERE ar_line_rows<>1 OR ar_debit<>grand_total OR ar_credit<>0
        OR ar_customer_id IS DISTINCT FROM customer_id),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_journal_line_receipt_coverage',
  CASE WHEN NOT EXISTS(SELECT 1 FROM receipt_ar
      WHERE ar_line_rows<>1 OR ar_debit<>0 OR ar_credit<>total_amount
        OR ar_customer_id IS DISTINCT FROM customer_id)
    THEN 'PASS' ELSE 'FAIL' END,
  (SELECT count(*) FROM receipt_ar
    WHERE ar_line_rows<>1 OR ar_debit<>0 OR ar_credit<>total_amount
      OR ar_customer_id IS DISTINCT FROM customer_id),
  jsonb_build_object('postedBackofficeReceipts',(SELECT count(*) FROM receipt_ar),
    'mixedRetailBackofficeRows',(SELECT count(*) FROM receipt_ar
      WHERE backoffice_amount>0 AND retail_amount>0),
    'mixed',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'receiptNo',receipt_no,'totalAmount',total_amount,
      'backofficeAmount',backoffice_amount,'retailAmount',retail_amount)
      ORDER BY receipt_no) FROM receipt_ar
      WHERE backoffice_amount>0 AND retail_amount>0),'[]'::jsonb),
    'invalid',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'receiptNo',receipt_no,'lineRows',ar_line_rows,'totalAmount',total_amount,
      'arDebit',ar_debit,'arCredit',ar_credit,'customerId',customer_id,
      'arCustomerId',ar_customer_id) ORDER BY receipt_no)
      FROM receipt_ar WHERE ar_line_rows<>1 OR ar_debit<>0
        OR ar_credit<>total_amount OR ar_customer_id IS DISTINCT FROM customer_id),
      '[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_journal_line_credit_note_coverage',
  CASE WHEN NOT EXISTS(SELECT 1 FROM credit_note_ar
      WHERE ar_line_rows<>(CASE WHEN ar_reduction_amount>0 THEN 1 ELSE 0 END)
        OR ar_debit<>0 OR ar_credit<>ar_reduction_amount
        OR (ar_reduction_amount>0 AND ar_customer_id IS DISTINCT FROM customer_id))
    THEN 'PASS' ELSE 'FAIL' END,
  (SELECT count(*) FROM credit_note_ar
    WHERE ar_line_rows<>(CASE WHEN ar_reduction_amount>0 THEN 1 ELSE 0 END)
      OR ar_debit<>0 OR ar_credit<>ar_reduction_amount
      OR (ar_reduction_amount>0 AND ar_customer_id IS DISTINCT FROM customer_id)),
  jsonb_build_object('postedNativeCreditNotes',(SELECT count(*) FROM credit_note_ar),
    'invalid',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'creditNoteNo',credit_note_no,'lineRows',ar_line_rows,
      'arReduction',ar_reduction_amount,'refundLiability',refund_liability_amount,
      'arDebit',ar_debit,'arCredit',ar_credit,'customerId',customer_id,
      'arCustomerId',ar_customer_id) ORDER BY credit_note_no)
      FROM credit_note_ar
      WHERE ar_line_rows<>(CASE WHEN ar_reduction_amount>0 THEN 1 ELSE 0 END)
        OR ar_debit<>0 OR ar_credit<>ar_reduction_amount
        OR (ar_reduction_amount>0 AND ar_customer_id IS DISTINCT FROM customer_id)),
      '[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_journal_line_existing_pair_contract',
  CASE WHEN NOT EXISTS(SELECT 1 FROM receipt_pairs
      WHERE invoice_ar_rows<>1 OR receipt_ar_rows<>1
        OR invoice_account_id IS DISTINCT FROM receipt_account_id
        OR invoice_customer_id IS DISTINCT FROM receipt_customer_id)
    AND NOT EXISTS(SELECT 1 FROM credit_pairs
      WHERE invoice_ar_rows<>1 OR credit_ar_rows<>1
        OR invoice_account_id IS DISTINCT FROM credit_account_id
        OR invoice_customer_id IS DISTINCT FROM credit_customer_id)
    THEN 'PASS' ELSE 'REVIEW' END,
  ((SELECT count(*) FROM receipt_pairs
      WHERE invoice_ar_rows<>1 OR receipt_ar_rows<>1
        OR invoice_account_id IS DISTINCT FROM receipt_account_id
        OR invoice_customer_id IS DISTINCT FROM receipt_customer_id)
   +(SELECT count(*) FROM credit_pairs
      WHERE invoice_ar_rows<>1 OR credit_ar_rows<>1
        OR invoice_account_id IS DISTINCT FROM credit_account_id
        OR invoice_customer_id IS DISTINCT FROM credit_customer_id))::bigint,
  jsonb_build_object('receiptAllocationRows',(SELECT count(*) FROM receipt_pairs),
    'creditAllocationRows',(SELECT count(*) FROM credit_pairs),
    'accountOrCustomerMismatch',jsonb_build_object(
      'receipt',(SELECT count(*) FROM receipt_pairs
        WHERE invoice_account_id IS DISTINCT FROM receipt_account_id
          OR invoice_customer_id IS DISTINCT FROM receipt_customer_id),
      'creditNote',(SELECT count(*) FROM credit_pairs
        WHERE invoice_account_id IS DISTINCT FROM credit_account_id
          OR invoice_customer_id IS DISTINCT FROM credit_customer_id)))
UNION ALL
SELECT 'backoffice_ar_journal_line_correction_inventory','INFO',0,
  jsonb_build_object('priceCorrections',COALESCE((SELECT jsonb_agg(
    jsonb_build_object('company',company_code,'kind',correction_kind,'rows',rows,
      'totalDelta',total_delta,'arAdjustment',ar_adjustment,
      'refundLiability',refund_liability,'missingArLine',missing_ar_line,
      'missingArCustomer',missing_ar_customer)
    ORDER BY company_code,correction_kind) FROM price_corrections),'[]'::jsonb),
    'invoiceRevisions',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'company',company_code,'rows',rows,'payableDelta',payable_delta,
      'customerChangeRows',customer_change_rows) ORDER BY company_code)
      FROM revision_inventory),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_journal_line_business_boundary','INFO',0,
  jsonb_build_object('mutation','NONE','scope',jsonb_build_array('KMS','LSM','SMS'),
    'tests',jsonb_build_array('posted Invoice AR debit','posted Receipt AR credit',
      'posted native Credit Note AR credit','existing allocation pair account/customer',
      'mixed Retail/Backoffice Receipt','posted price correction','unified Invoice revision'),
    'preserved',jsonb_build_array('posted Journal','Return','Stock/FIFO','POS Retail',
      'Customer Balance','Payment','production data'),
    'next','Use output only to close Task 2 foundation design and do not mutate production');
