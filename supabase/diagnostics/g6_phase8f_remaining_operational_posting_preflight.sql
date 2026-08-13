-- G6 phase 8F: exact-source preflight for the seven remaining operational HOLD events.
-- SAFETY: one SELECT statement; no business state is changed.

WITH target_events AS MATERIALIZED (
 SELECT event.* FROM public.financial_events event
 WHERE event.status='HOLD'::public.event_status
  AND (event.system_event_key,event.event_type::TEXT,event.source_table) IN(
   ('STOCK_GAIN','STOCK_GAIN','stock_adjustment_documents'),
   ('EXPENSE_DISBURSEMENT','EXPENSE_DISBURSEMENT','expense_disbursements'),
   ('CASH_DEPOSIT','BANK_DEPOSIT','cash_deposit_documents'),
   ('CASH_VARIANCE','DEPOSIT_VARIANCE_RESOLUTION',
    'deposit_variance_resolution_requests'))
), stock_source AS MATERIALIZED (
 SELECT event.company_id,event.id event_id,event.source_id,
  document.total_gain_value,
  round(COALESCE((SELECT sum(line.total_value)
    FROM public.stock_adjustment_lines line
    WHERE line.company_id=document.company_id AND line.document_id=document.id
      AND line.calculated_difference>0),0),4) line_gain_value,
  round((event.amounts->>'inventoryDebit')::NUMERIC,4) event_inventory,
  round((event.amounts->>'stockGainCredit')::NUMERIC,4) event_gain,
  NULLIF(event.amounts->>'inventoryAccountId','')::UUID inventory_account_id,
  NULLIF(event.amounts->>'counterAccountId','')::UUID gain_account_id
 FROM target_events event JOIN public.stock_adjustment_documents document
  ON document.company_id=event.company_id AND document.id=event.source_id
  AND document.status='POSTED' AND document.gain_financial_event_id=event.id
 WHERE event.system_event_key='STOCK_GAIN'
), expense_source AS MATERIALIZED (
 SELECT event.company_id,event.id event_id,event.source_id,
  disbursement.document_id,disbursement.amount,
  document.requested_amount,document.disbursed_amount,document.status,
  round((event.amounts->>'requestedAmount')::NUMERIC,4) event_requested,
  round((event.amounts->>'disbursedAmount')::NUMERIC,4) event_disbursed,
  NULLIF(event.amounts->>'outstandingAccountId','')::UUID outstanding_account_id,
  NULLIF(event.amounts->>'paymentAccountId','')::UUID payment_account_id,
  NULLIF(event.amounts->>'cashierSessionId','')::UUID event_session_id,
  disbursement.cashier_session_id
 FROM target_events event JOIN public.expense_disbursements disbursement
  ON disbursement.company_id=event.company_id AND disbursement.id=event.source_id
  AND disbursement.financial_event_id=event.id
 JOIN public.expense_documents document ON document.company_id=disbursement.company_id
  AND document.id=disbursement.document_id
 WHERE event.system_event_key='EXPENSE_DISBURSEMENT'
), deposit_source AS MATERIALIZED (
 SELECT event.company_id,event.id event_id,event.source_id,
  document.actual_deposit_amount,document.total_expected_deposit,
  document.deposit_variance,document.variance_type,
  round(COALESCE((SELECT sum(line.expected_deposit_amount)
    FROM public.cash_deposit_session_lines line
    WHERE line.company_id=document.company_id
      AND line.deposit_document_id=document.id
      AND line.allocation_status='POSTED'),0),4) line_expected,
  round((event.amounts->>'actualDeposit')::NUMERIC,4) event_actual,
  round((event.amounts->>'expectedDeposit')::NUMERIC,4) event_expected,
  round((event.amounts->>'depositVariance')::NUMERIC,4) event_variance,
  NULLIF(event.amounts->>'cashDrawerAccountId','')::UUID drawer_account_id,
  NULLIF(event.amounts->>'destinationAccountId','')::UUID destination_account_id,
  NULLIF(event.amounts->>'varianceAccountId','')::UUID variance_account_id
 FROM target_events event JOIN public.cash_deposit_documents document
  ON document.company_id=event.company_id AND document.id=event.source_id
  AND document.status='APPROVED' AND document.financial_event_id=event.id
 WHERE event.system_event_key='CASH_DEPOSIT'
), variance_source AS MATERIALIZED (
 SELECT event.company_id,event.id event_id,event.source_id,
  request.variance_exception_id,request.allocation_amount,request.resolution_type,
  request.status,request.allocation_id,allocation.financial_event_id,
  allocation.allocation_amount allocation_effect_amount,
  exception.cash_deposit_document_id,exception.variance_type,
  round((event.amounts->>'allocationAmount')::NUMERIC,4) event_amount,
  event.amounts->>'resolutionType' event_resolution_type,
  event.amounts->>'varianceType' event_variance_type,
  NULLIF(event.amounts->>'controlAccountId','')::UUID control_account_id,
  NULLIF(event.amounts->>'resolutionAccountId','')::UUID resolution_account_id
 FROM target_events event
 JOIN public.deposit_variance_resolution_requests request
  ON request.company_id=event.company_id AND request.id=event.source_id
  AND request.status='APPROVED' AND request.financial_event_id=event.id
 JOIN public.deposit_variance_allocations allocation
  ON allocation.company_id=request.company_id AND allocation.id=request.allocation_id
  AND allocation.resolution_request_id=request.id
  AND allocation.financial_event_id=event.id
 JOIN public.deposit_variance_exceptions exception
  ON exception.company_id=request.company_id
  AND exception.id=request.variance_exception_id
 WHERE event.system_event_key='CASH_VARIANCE'
), account_snapshots AS MATERIALIZED (
 SELECT company_id,event_id,'INVENTORY_ASSET' function_key,
  inventory_account_id account_id FROM stock_source
 UNION ALL SELECT company_id,event_id,'STOCK_GAIN_INCOME',gain_account_id FROM stock_source
 UNION ALL SELECT company_id,event_id,'OUTSTANDING_EXPENSE',outstanding_account_id
  FROM expense_source
 UNION ALL SELECT company_id,event_id,'PAYMENT_SOURCE',payment_account_id
  FROM expense_source
 UNION ALL SELECT company_id,event_id,'CASH_DRAWER',drawer_account_id FROM deposit_source
 UNION ALL SELECT company_id,event_id,'DEPOSIT_DESTINATION',destination_account_id
  FROM deposit_source
 UNION ALL SELECT company_id,event_id,'DEPOSIT_VARIANCE',variance_account_id
  FROM deposit_source WHERE event_variance<>0
 UNION ALL SELECT company_id,event_id,'VARIANCE_CONTROL',control_account_id
  FROM variance_source
 UNION ALL SELECT company_id,event_id,'VARIANCE_RESOLUTION',resolution_account_id
  FROM variance_source
), account_state AS MATERIALIZED (
 SELECT snapshot.*,account.id IS NOT NULL account_exists,
  COALESCE(account.is_active,FALSE) account_active,
  COALESCE(account.is_postable,FALSE) account_postable
 FROM account_snapshots snapshot LEFT JOIN public.chart_of_accounts account
  ON account.company_id=snapshot.company_id AND account.id=snapshot.account_id
), checks(check_name,status,details) AS (
 SELECT 'remaining_operational_target_inventory',
  CASE WHEN (SELECT count(*) FROM target_events)=7
    AND (SELECT count(*) FROM stock_source)=2
    AND (SELECT count(*) FROM expense_source)=2
    AND (SELECT count(*) FROM deposit_source)=2
    AND (SELECT count(*) FROM variance_source)=1 THEN 'PASS' ELSE 'BLOCKER' END,
  jsonb_build_object('stockGainEvents',(SELECT count(*) FROM stock_source),
   'expenseDisbursementEvents',(SELECT count(*) FROM expense_source),
   'cashDepositEvents',(SELECT count(*) FROM deposit_source),
   'cashVarianceEvents',(SELECT count(*) FROM variance_source),
   'totalEvents',(SELECT count(*) FROM target_events))
 UNION ALL SELECT 'remaining_operational_event_source_linkage',
  CASE WHEN (SELECT count(*) FROM target_events)=
    ((SELECT count(*) FROM stock_source)+(SELECT count(*) FROM expense_source)+
     (SELECT count(*) FROM deposit_source)+(SELECT count(*) FROM variance_source))
   THEN 'PASS' ELSE 'BLOCKER' END,
  jsonb_build_object('targetEvents',(SELECT count(*) FROM target_events),
   'linkedFinalSources',((SELECT count(*) FROM stock_source)+
    (SELECT count(*) FROM expense_source)+(SELECT count(*) FROM deposit_source)+
    (SELECT count(*) FROM variance_source)))
 UNION ALL SELECT 'stock_gain_source_amount_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  jsonb_build_object('eventCount',(SELECT count(*) FROM stock_source),
   'violationRows',count(*)) FROM stock_source
 WHERE total_gain_value<=0 OR round(total_gain_value,4)<>line_gain_value
  OR round(total_gain_value,4)<>event_inventory OR event_inventory<>event_gain
 UNION ALL SELECT 'expense_disbursement_source_amount_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  jsonb_build_object('eventCount',(SELECT count(*) FROM expense_source),
   'violationRows',count(*)) FROM expense_source
 WHERE amount<=0 OR round(amount,4)<>event_disbursed
  OR round(requested_amount,4)<>event_requested
  OR round(disbursed_amount,4)<round(amount,4)
  OR status NOT IN('DISBURSED','PARTIALLY_SETTLED','SETTLED','SETTLED_NO_EXPENSE')
  OR event_session_id IS DISTINCT FROM cashier_session_id
 UNION ALL SELECT 'cash_deposit_source_amount_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  jsonb_build_object('eventCount',(SELECT count(*) FROM deposit_source),
   'violationRows',count(*)) FROM deposit_source
 WHERE actual_deposit_amount<=0
  OR round(total_expected_deposit,4)<>line_expected
  OR round(actual_deposit_amount,4)<>event_actual
  OR round(total_expected_deposit,4)<>event_expected
  OR round(deposit_variance,4)<>event_variance
  OR round(actual_deposit_amount-total_expected_deposit,4)<>event_variance
  OR variance_type<>CASE WHEN event_variance<0 THEN 'UNDER_DEPOSIT'
    WHEN event_variance>0 THEN 'OVER_DEPOSIT' ELSE 'MATCHED' END
 UNION ALL SELECT 'cash_variance_source_amount_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  jsonb_build_object('eventCount',(SELECT count(*) FROM variance_source),
   'violationRows',count(*)) FROM variance_source
 WHERE allocation_amount<=0 OR allocation_amount<>allocation_effect_amount
  OR round(allocation_amount,4)<>event_amount
  OR resolution_type<>event_resolution_type OR variance_type<>event_variance_type
  OR financial_event_id IS NULL
 UNION ALL SELECT 'remaining_operational_account_snapshot_readiness',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  jsonb_build_object('requiredRows',(SELECT count(*) FROM account_state),
   'invalidRows',count(*),'functions',COALESCE(jsonb_agg(DISTINCT function_key),'[]'))
 FROM account_state WHERE account_id IS NULL OR NOT account_exists
  OR NOT account_active OR NOT account_postable
 UNION ALL SELECT 'remaining_operational_period_readiness',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  jsonb_build_object('companies',count(*)) FROM(
   SELECT DISTINCT event.company_id FROM target_events event
   WHERE NOT EXISTS(SELECT 1 FROM public.accounting_periods period
    WHERE period.company_id=event.company_id
     AND period.status IN('OPEN','REOPENED')
     AND (event.event_date::DATE BETWEEN period.start_date AND period.end_date
       OR period.start_date>event.event_date::DATE))) missing
 UNION ALL SELECT 'remaining_operational_existing_journal_effect',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  jsonb_build_object('journalCount',count(*))
 FROM public.finance_journals journal JOIN target_events event
  ON event.company_id=journal.company_id AND event.id=journal.financial_event_id
 UNION ALL SELECT 'active_finance_posting_queue',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  jsonb_build_object('runCount',count(*)) FROM public.finance_posting_queue_runs
 WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
 UNION ALL SELECT 'remaining_operational_posting_runtime','SETUP',
  jsonb_build_object('targetContracts',ARRAY[
   'STOCK_GAIN','EXPENSE_DISBURSEMENT','CASH_DEPOSIT','CASH_VARIANCE'],
   'historicalEvents',(SELECT count(*) FROM target_events),
   'executionOrder',ARRAY[
    'Stock Gain','Expense Disbursement','Cash Deposit','Cash Variance'])
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2 ELSE 3 END,
 check_name;
