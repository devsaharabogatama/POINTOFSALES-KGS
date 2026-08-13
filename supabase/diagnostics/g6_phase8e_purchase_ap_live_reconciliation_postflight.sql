-- G6 phase 8E Purchase/AP live reconciliation. SAFETY: SELECT-only.
WITH target_events AS MATERIALIZED (
 SELECT event.* FROM public.financial_events event
 WHERE event.system_event_key IN(
  'GOODS_RECEIPT','SUPPLIER_INVOICE','SUPPLIER_PAYMENT')
), event_journal AS MATERIALIZED (
 SELECT event.company_id,event.id event_id,event.system_event_key,
  event.status::TEXT event_status,event.error_message,
  journal.id journal_id,journal.status journal_status,
  journal.total_debit,journal.total_credit
 FROM target_events event LEFT JOIN public.finance_journals journal
  ON journal.company_id=event.company_id AND journal.financial_event_id=event.id
), receipt_expected AS MATERIALIZED (
 SELECT event.company_id,event.id event_id,event.source_id,
  round(document.provisional_ap_total,4) expected_amount,
  NULLIF(event.amounts->>'inventoryAccountId','')::UUID inventory_account_id,
  NULLIF(event.amounts->>'supplierApAccountId','')::UUID ap_account_id
 FROM target_events event JOIN public.goods_receipt_documents document
  ON document.company_id=event.company_id AND document.id=event.source_id
 WHERE event.system_event_key='GOODS_RECEIPT'
), invoice_expected AS MATERIALIZED (
 SELECT event.company_id,event.id event_id,event.source_id,
  round(document.provisional_value_allocated,4) provisional_amount,
  round(document.purchase_price_variance,4) variance_amount,
  round(COALESCE((SELECT sum(line.tax_amount) FROM public.supplier_invoice_lines line
    WHERE line.company_id=document.company_id AND line.document_id=document.id
      AND line.tax_is_recoverable_snapshot),0),4) recoverable_tax,
  round(COALESCE((SELECT sum(line.tax_amount) FROM public.supplier_invoice_lines line
    WHERE line.company_id=document.company_id AND line.document_id=document.id
      AND line.tax_is_recoverable_snapshot=FALSE),0),4) nonrecoverable_tax,
  round(document.grand_total,4) final_amount,
  NULLIF(event.amounts->>'apProvisionalAccountId','')::UUID provisional_account_id,
  NULLIF(event.amounts->>'apFinalAccountId','')::UUID final_account_id,
  NULLIF(event.amounts->>'purchasePriceVarianceAccountId','')::UUID variance_account_id,
  NULLIF(event.amounts->>'inputTaxAccountId','')::UUID tax_account_id
 FROM target_events event JOIN public.supplier_invoice_documents document
  ON document.company_id=event.company_id AND document.id=event.source_id
 WHERE event.system_event_key='SUPPLIER_INVOICE'
), payment_expected AS MATERIALIZED (
 SELECT event.company_id,event.id event_id,event.source_id,
  round(document.total_amount,4) expected_amount,
  NULLIF(event.amounts->>'apFinalDebitAccount','')::UUID ap_account_id,
  NULLIF(event.amounts->>'cashOrBankCreditAccount','')::UUID source_account_id
 FROM target_events event JOIN public.supplier_payment_documents document
  ON document.company_id=event.company_id AND document.id=event.source_id
 WHERE event.system_event_key='SUPPLIER_PAYMENT'
), checks(check_name,status,violation_rows,details) AS (
 SELECT 'purchase_ap_positive_event_journal_coverage',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('rowCount',count(*)) FROM event_journal
 WHERE NOT(event_status='CANCELED' AND error_message='NO_FINANCIAL_EFFECT')
  AND (event_status<>'POSTED' OR journal_id IS NULL OR journal_status<>'POSTED')
 UNION ALL SELECT 'zero_effect_receipt_closure',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
  jsonb_build_object('closedRows',count(*)) FROM event_journal
 WHERE system_event_key='GOODS_RECEIPT' AND event_status='CANCELED'
  AND error_message='NO_FINANCIAL_EFFECT' AND journal_id IS NULL
 UNION ALL SELECT 'purchase_ap_journal_balance',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('journalCount',count(*)) FROM event_journal
 WHERE journal_id IS NOT NULL
  AND (journal_status<>'POSTED' OR total_debit<=0 OR total_debit<>total_credit)
 UNION ALL SELECT 'duplicate_purchase_ap_journal',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('duplicateGroups',count(*)) FROM(
   SELECT company_id,event_id FROM event_journal WHERE journal_id IS NOT NULL
   GROUP BY company_id,event_id HAVING count(*)<>1) duplicate
 UNION ALL SELECT 'goods_receipt_journal_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('receiptCount',count(*))
 FROM receipt_expected expected JOIN public.finance_journals journal
  ON journal.company_id=expected.company_id AND journal.financial_event_id=expected.event_id
 WHERE expected.expected_amount<=0
  OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
    WHERE line.company_id=journal.company_id AND line.journal_id=journal.id
      AND line.account_id=expected.inventory_account_id
      AND line.debit=expected.expected_amount AND line.credit=0)
  OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
    WHERE line.company_id=journal.company_id AND line.journal_id=journal.id
      AND line.account_id=expected.ap_account_id
      AND line.credit=expected.expected_amount AND line.debit=0)
 UNION ALL SELECT 'supplier_invoice_journal_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('invoiceCount',count(*))
 FROM invoice_expected expected JOIN public.finance_journals journal
  ON journal.company_id=expected.company_id AND journal.financial_event_id=expected.event_id
 WHERE NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
    WHERE line.company_id=journal.company_id AND line.journal_id=journal.id
      AND line.account_id=expected.final_account_id
      AND line.credit=expected.final_amount AND line.debit=0)
  OR (expected.provisional_amount>0 AND NOT EXISTS(SELECT 1
    FROM public.finance_journal_lines line WHERE line.company_id=journal.company_id
      AND line.journal_id=journal.id AND line.account_id=expected.provisional_account_id
      AND line.debit=expected.provisional_amount AND line.credit=0))
  OR (expected.recoverable_tax>0 AND NOT EXISTS(SELECT 1
    FROM public.finance_journal_lines line WHERE line.company_id=journal.company_id
      AND line.journal_id=journal.id AND line.account_id=expected.tax_account_id
      AND line.debit=expected.recoverable_tax AND line.credit=0))
  OR (expected.variance_amount+expected.nonrecoverable_tax<>0 AND NOT EXISTS(
    SELECT 1 FROM public.finance_journal_lines line
    WHERE line.company_id=journal.company_id AND line.journal_id=journal.id
      AND line.account_id=expected.variance_account_id
      AND line.debit=CASE WHEN expected.variance_amount+expected.nonrecoverable_tax>0
        THEN expected.variance_amount+expected.nonrecoverable_tax ELSE 0 END
      AND line.credit=CASE WHEN expected.variance_amount+expected.nonrecoverable_tax<0
        THEN abs(expected.variance_amount+expected.nonrecoverable_tax) ELSE 0 END))
 UNION ALL SELECT 'supplier_payment_journal_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('paymentCount',count(*))
 FROM payment_expected expected JOIN public.finance_journals journal
  ON journal.company_id=expected.company_id AND journal.financial_event_id=expected.event_id
 WHERE NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
    WHERE line.company_id=journal.company_id AND line.journal_id=journal.id
      AND line.account_id=expected.ap_account_id
      AND line.debit=expected.expected_amount AND line.credit=0)
  OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
    WHERE line.company_id=journal.company_id AND line.journal_id=journal.id
      AND line.account_id=expected.source_account_id
      AND line.credit=expected.expected_amount AND line.debit=0)
 UNION ALL SELECT 'purchase_ap_supplier_dimension_coverage',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('lineCount',count(*))
 FROM public.finance_journal_lines line JOIN public.finance_journals journal
  ON journal.company_id=line.company_id AND journal.id=line.journal_id
 JOIN target_events event ON event.company_id=journal.company_id
  AND event.id=journal.financial_event_id WHERE line.supplier_id IS NULL
 UNION ALL SELECT 'controlled_purchase_ap_queue_result',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
  jsonb_build_object('cleanRunCount',count(*))
 FROM public.finance_posting_queue_runs run WHERE run.scope_system_key='PURCHASE_AP'
  AND run.status='COMPLETED' AND run.previewed_event_count=9
  AND run.posted_count=8 AND run.failed_count=0 AND run.skipped_count=1
 UNION ALL SELECT 'zero_effect_queue_item_contract',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
  jsonb_build_object('skippedRows',count(*))
 FROM public.finance_posting_queue_items item
 JOIN public.finance_posting_queue_runs run ON run.company_id=item.company_id
  AND run.id=item.queue_run_id
 WHERE run.scope_system_key='PURCHASE_AP' AND item.status='SKIPPED'
  AND item.error_code='NO_FINANCIAL_EFFECT' AND item.journal_id IS NULL
 UNION ALL SELECT 'active_finance_queue',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('runCount',count(*)) FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
 UNION ALL SELECT 'purchase_ap_live_inventory','INFO',0,jsonb_build_object(
  'postedGoodsReceiptEvents',(SELECT count(*) FROM target_events
    WHERE system_event_key='GOODS_RECEIPT' AND status='POSTED'::public.event_status),
  'noEffectGoodsReceiptEvents',(SELECT count(*) FROM target_events
    WHERE system_event_key='GOODS_RECEIPT' AND status='CANCELED'::public.event_status
      AND error_message='NO_FINANCIAL_EFFECT'),
  'postedSupplierInvoiceEvents',(SELECT count(*) FROM target_events
    WHERE system_event_key='SUPPLIER_INVOICE' AND status='POSTED'::public.event_status),
  'postedSupplierPaymentEvents',(SELECT count(*) FROM target_events
    WHERE system_event_key='SUPPLIER_PAYMENT' AND status='POSTED'::public.event_status),
  'journalRows',(SELECT count(*) FROM event_journal WHERE journal_id IS NOT NULL),
  'remainingHoldEvents',(SELECT count(*) FROM public.financial_events
    WHERE status='HOLD'::public.event_status))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
