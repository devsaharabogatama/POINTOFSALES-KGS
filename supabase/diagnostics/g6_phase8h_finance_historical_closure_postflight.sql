-- G6 phase 8H final historical Finance closure. SAFETY: SELECT-only.
WITH operational_events AS MATERIALIZED (
 SELECT event.* FROM public.financial_events event
 WHERE event.system_event_key IN(
  'STOCK_OPENING','SALE_POSTED','SALES_RETURN','GOODS_RECEIPT',
  'SUPPLIER_INVOICE','SUPPLIER_PAYMENT','STOCK_GAIN',
  'EXPENSE_DISBURSEMENT','CASH_DEPOSIT','CASH_VARIANCE')
), event_journal AS MATERIALIZED (
 SELECT event.company_id,event.id event_id,event.system_event_key,
  event.status::TEXT event_status,event.error_message,journal.id journal_id,
  journal.status journal_status,journal.total_debit,journal.total_credit
 FROM operational_events event LEFT JOIN public.finance_journals journal
  ON journal.company_id=event.company_id AND journal.financial_event_id=event.id
), validated_invoice AS MATERIALIZED (
 SELECT invoice.company_id,invoice.id,invoice.grand_total,
  COALESCE(sum(allocation.allocated_amount) FILTER(
   WHERE payment.status='VALIDATED'),0) paid_amount
 FROM public.supplier_invoice_documents invoice
 LEFT JOIN public.supplier_payment_allocations allocation
  ON allocation.company_id=invoice.company_id AND allocation.invoice_id=invoice.id
 LEFT JOIN public.supplier_payment_documents payment
  ON payment.company_id=allocation.company_id AND payment.id=allocation.document_id
 WHERE invoice.status='VALIDATED'
 GROUP BY invoice.company_id,invoice.id,invoice.grand_total
), company_values AS MATERIALIZED (
 SELECT company.id company_id,
  round(COALESCE((SELECT sum(batch.qty_remaining*batch.cogs_unit)
   FROM public.product_batches batch WHERE batch.company_id=company.id
    AND batch.qty_remaining>0),0),4) fifo_value,
  round(COALESCE((SELECT sum(line.debit-line.credit)
   FROM public.finance_journal_lines line JOIN public.finance_journals journal
    ON journal.company_id=line.company_id AND journal.id=line.journal_id
    AND journal.status='POSTED'
   WHERE line.company_id=company.id
    AND line.account_function_key_snapshot='INVENTORY_ASSET'),0),4) inventory_gl,
  round(COALESCE((SELECT sum(greatest(invoice.grand_total-invoice.paid_amount,0))
   FROM validated_invoice invoice WHERE invoice.company_id=company.id),0),4) ap_subledger,
  round(COALESCE((SELECT sum(line.credit-line.debit)
   FROM public.finance_journal_lines line JOIN public.finance_journals journal
    ON journal.company_id=line.company_id AND journal.id=line.journal_id
    AND journal.status='POSTED'
   WHERE line.company_id=company.id
    AND line.account_function_key_snapshot='SUPPLIER_AP_FINAL'),0),4) ap_gl,
  round(COALESCE((SELECT sum(customer.current_balance)
   FROM public.customers customer WHERE customer.company_id=company.id
    AND NOT customer.is_system_customer),0),4) customer_balance,
  round(COALESCE((SELECT sum(line.credit-line.debit)
   FROM public.finance_journal_lines line JOIN public.finance_journals journal
    ON journal.company_id=line.company_id AND journal.id=line.journal_id
    AND journal.status='POSTED'
   WHERE line.company_id=company.id
    AND line.account_function_key_snapshot='CUSTOMER_BALANCE_LIABILITY'),0),4)
   customer_balance_gl
 FROM public.companies company WHERE company.status='ACTIVE'
), checks(check_name,status,violation_rows,details) AS (
 SELECT 'all_financial_event_hold_closed',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('holdEvents',count(*),'contracts',COALESCE(
   jsonb_agg(DISTINCT system_event_key),'[]'))
 FROM public.financial_events WHERE status='HOLD'::public.event_status
 UNION ALL SELECT 'operational_event_final_coverage',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('rowCount',count(*)) FROM event_journal
 WHERE NOT(event_status='CANCELED' AND error_message='NO_FINANCIAL_EFFECT'
   AND journal_id IS NULL)
  AND (event_status<>'POSTED' OR journal_id IS NULL OR journal_status<>'POSTED')
 UNION ALL SELECT 'operational_no_effect_contract',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
  jsonb_build_object('closedRows',count(*)) FROM event_journal
 WHERE event_status='CANCELED' AND error_message='NO_FINANCIAL_EFFECT'
  AND journal_id IS NULL AND system_event_key='GOODS_RECEIPT'
 UNION ALL SELECT 'duplicate_operational_event_journal',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('duplicateGroups',count(*)) FROM(
   SELECT company_id,event_id FROM event_journal WHERE journal_id IS NOT NULL
   GROUP BY company_id,event_id HAVING count(*)<>1) duplicate
 UNION ALL SELECT 'all_posted_journal_balance',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('journalCount',count(*)) FROM public.finance_journals journal
 WHERE journal.status='POSTED'
  AND (journal.total_debit<=0 OR journal.total_debit<>journal.total_credit)
 UNION ALL SELECT 'posted_journal_line_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('journalCount',count(*)) FROM public.finance_journals journal
 WHERE journal.status='POSTED' AND (
  journal.total_debit<>COALESCE((SELECT sum(line.debit)
   FROM public.finance_journal_lines line WHERE line.company_id=journal.company_id
    AND line.journal_id=journal.id),0)
  OR journal.total_credit<>COALESCE((SELECT sum(line.credit)
   FROM public.finance_journal_lines line WHERE line.company_id=journal.company_id
    AND line.journal_id=journal.id),0))
 UNION ALL SELECT 'stock_fifo_gl_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('companies',count(*)) FROM company_values
 WHERE fifo_value<>inventory_gl
 UNION ALL SELECT 'supplier_ap_gl_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('companies',count(*)) FROM company_values
 WHERE ap_subledger<>ap_gl
 UNION ALL SELECT 'customer_balance_gl_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('companies',count(*)) FROM company_values
 WHERE customer_balance<>customer_balance_gl
 UNION ALL SELECT 'remaining_operational_queue_result',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
  jsonb_build_object('cleanRunCount',count(*))
 FROM public.finance_posting_queue_runs run
 WHERE run.scope_system_key='REMAINING_OPERATIONAL' AND run.status='COMPLETED'
  AND run.previewed_event_count=7 AND run.posted_count=7
  AND run.failed_count=0 AND run.skipped_count=0
 UNION ALL SELECT 'active_finance_queue',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('runCount',count(*)) FROM public.finance_posting_queue_runs
 WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
 UNION ALL SELECT 'open_finance_posting_exception',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('exceptionRows',count(*))
 FROM public.finance_posting_exceptions WHERE status<>'RESOLVED'
 UNION ALL SELECT 'finance_historical_closure_inventory','INFO',0,
  jsonb_build_object(
   'financialEvents',(SELECT count(*) FROM public.financial_events),
   'postedEvents',(SELECT count(*) FROM public.financial_events
    WHERE status='POSTED'::public.event_status),
   'noEffectEvents',(SELECT count(*) FROM public.financial_events
    WHERE status='CANCELED'::public.event_status
     AND error_message='NO_FINANCIAL_EFFECT'),
   'holdEvents',(SELECT count(*) FROM public.financial_events
    WHERE status='HOLD'::public.event_status),
   'postedJournals',(SELECT count(*) FROM public.finance_journals
    WHERE status='POSTED'),
   'journalLines',(SELECT count(*) FROM public.finance_journal_lines),
   'companyReconciliation',(SELECT jsonb_agg(jsonb_build_object(
    'companyId',company_id,'fifoValue',fifo_value,'inventoryGl',inventory_gl,
    'supplierAp',ap_subledger,'supplierApGl',ap_gl,
    'customerBalance',customer_balance,'customerBalanceGl',customer_balance_gl)
    ORDER BY company_id) FROM company_values))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
