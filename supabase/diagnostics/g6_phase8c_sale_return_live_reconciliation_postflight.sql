-- G6 phase 8C live reconciliation. SAFETY: SELECT-only.
WITH target_events AS MATERIALIZED (
 SELECT event.* FROM public.financial_events event
 WHERE event.system_event_key IN('SALE_POSTED','SALES_RETURN')
), event_journal AS MATERIALIZED (
 SELECT event.company_id,event.id event_id,event.system_event_key,event.status::TEXT event_status,
  journal.id journal_id,journal.status journal_status,journal.total_debit,journal.total_credit
 FROM target_events event LEFT JOIN public.finance_journals journal
  ON journal.company_id=event.company_id AND journal.financial_event_id=event.id
), sale_expected AS MATERIALIZED (
 SELECT event.company_id,event.id event_id,event.source_id sale_id,
  sale.grand_total_after_rounding,COALESCE(sum(detail.tax_amount),0) tax_amount,
  COALESCE(sum(detail.fifo_cost_total),0) fifo_cost,
  sale.delivery_fee_amount,sale.rounding_adjustment,
  COALESCE((SELECT sum(payment.amount) FROM public.sales_payments payment
    WHERE payment.company_id=event.company_id AND payment.sales_id=event.source_id),0) settlement,
  COALESCE((SELECT sum(payment.customer_surcharge_amount) FROM public.sales_payments payment
    WHERE payment.company_id=event.company_id AND payment.sales_id=event.source_id),0) surcharge,
  round((event.amounts->>'netSalesInclusiveTax')::NUMERIC-
    COALESCE(sum(detail.tax_amount),0),4) net_revenue
 FROM target_events event JOIN public.sales_headers sale
  ON sale.company_id=event.company_id AND sale.id=event.source_id
 JOIN public.sales_details detail ON detail.company_id=sale.company_id AND detail.sales_id=sale.id
 WHERE event.system_event_key='SALE_POSTED'
 GROUP BY event.company_id,event.id,event.source_id,event.amounts,
  sale.grand_total_after_rounding,sale.delivery_fee_amount,sale.rounding_adjustment
), return_expected AS MATERIALIZED (
 SELECT event.company_id,event.id event_id,event.source_id return_id,
  document.refund_total,document.refund_before_rounding,
  document.delivery_fee_refund_amount,document.rounding_adjustment,
  COALESCE(sum(line.tax_refund_amount),0) tax_refund,
  COALESCE(sum(line.fifo_cost_restored),0) fifo_restored,
  COALESCE((SELECT sum(refund.amount) FROM public.sales_return_refunds refund
    WHERE refund.company_id=event.company_id AND refund.document_id=event.source_id),0) settlement
 FROM target_events event JOIN public.sales_return_documents document
  ON document.company_id=event.company_id AND document.id=event.source_id
 JOIN public.sales_return_lines line ON line.company_id=document.company_id
  AND line.document_id=document.id WHERE event.system_event_key='SALES_RETURN'
 GROUP BY event.company_id,event.id,event.source_id,document.refund_total,
  document.refund_before_rounding,document.delivery_fee_refund_amount,
  document.rounding_adjustment
), checks(check_name,status,violation_rows,details) AS (
 SELECT 'sale_return_event_journal_coverage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
  count(*),jsonb_build_object('rowCount',count(*)) FROM event_journal
 WHERE event_status<>'POSTED' OR journal_id IS NULL OR journal_status<>'POSTED'
 UNION ALL SELECT 'sale_return_journal_balance',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
  count(*),jsonb_build_object('journalCount',count(*)) FROM event_journal
 WHERE total_debit<=0 OR total_debit<>total_credit
 UNION ALL SELECT 'duplicate_sale_return_journal',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
  count(*),jsonb_build_object('duplicateGroups',count(*)) FROM(
   SELECT company_id,event_id FROM event_journal GROUP BY company_id,event_id HAVING count(*)<>1) duplicate
 UNION ALL SELECT 'sale_settlement_journal_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),jsonb_build_object('saleCount',count(*))
 FROM sale_expected expected JOIN public.finance_journals journal
  ON journal.company_id=expected.company_id AND journal.financial_event_id=expected.event_id
 WHERE round(expected.settlement,4)<>round((SELECT COALESCE(sum(line.debit),0)
   FROM public.finance_journal_lines line WHERE line.company_id=journal.company_id
    AND line.journal_id=journal.id AND position(':' IN COALESCE(line.description,''))>0),4)
 UNION ALL SELECT 'return_settlement_journal_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),jsonb_build_object('returnCount',count(*))
 FROM return_expected expected JOIN public.finance_journals journal
  ON journal.company_id=expected.company_id AND journal.financial_event_id=expected.event_id
 WHERE round(expected.settlement,4)<>round((SELECT COALESCE(sum(line.credit),0)
   FROM public.finance_journal_lines line WHERE line.company_id=journal.company_id
    AND line.journal_id=journal.id AND position(':' IN COALESCE(line.description,''))>0),4)
 UNION ALL SELECT 'sale_return_inventory_gl_delta',
  CASE WHEN expected_delta=actual_delta THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN expected_delta=actual_delta THEN 0 ELSE 1 END,
  jsonb_build_object('expectedDelta',expected_delta,'actualDelta',actual_delta)
 FROM (SELECT round(-(SELECT COALESCE(sum(fifo_cost),0) FROM sale_expected)
    +(SELECT COALESCE(sum(fifo_restored),0) FROM return_expected),4) expected_delta,
   round(COALESCE(sum(line.debit-line.credit),0),4) actual_delta
  FROM public.finance_journal_lines line JOIN public.finance_journals journal
   ON journal.company_id=line.company_id AND journal.id=line.journal_id
  JOIN target_events event ON event.company_id=journal.company_id
   AND event.id=journal.financial_event_id
  WHERE line.account_function_key_snapshot='INVENTORY_ASSET') delta
 UNION ALL SELECT 'controlled_live_queue_result',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
  jsonb_build_object('cleanRunCount',count(*))
 FROM public.finance_posting_queue_runs run WHERE run.scope_system_key='SALE_RETURN'
  AND run.status='COMPLETED' AND run.previewed_event_count=14 AND run.posted_count=14
  AND run.failed_count=0 AND run.skipped_count=0
 UNION ALL SELECT 'active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
  count(*),jsonb_build_object('runCount',count(*)) FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
 UNION ALL SELECT 'sale_return_live_inventory','INFO',0,jsonb_build_object(
  'postedSaleEvents',(SELECT count(*) FROM target_events WHERE system_event_key='SALE_POSTED' AND status='POSTED'::public.event_status),
  'postedReturnEvents',(SELECT count(*) FROM target_events WHERE system_event_key='SALES_RETURN' AND status='POSTED'::public.event_status),
  'journalRows',(SELECT count(*) FROM event_journal WHERE journal_id IS NOT NULL),
  'remainingHoldEvents',(SELECT count(*) FROM public.financial_events WHERE status='HOLD'::public.event_status))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
