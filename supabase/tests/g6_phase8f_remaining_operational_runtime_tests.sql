-- G6 phase 8F behavioral: post all seven remaining events and roll back.
BEGIN;
DO $test$
DECLARE
 v_actor UUID; v_event public.financial_events%ROWTYPE;
 v_result JSONB; v_replay JSONB; v_journal UUID;
 v_before_count BIGINT; v_after_count BIGINT;
 v_stock INTEGER:=0; v_expense INTEGER:=0; v_deposit INTEGER:=0; v_variance INTEGER:=0;
BEGIN
 SELECT profile.id INTO v_actor FROM public.profiles profile
 WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1;
 IF v_actor IS NULL THEN
  RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required'; END IF;
 FOR v_event IN SELECT event.* FROM public.financial_events event
  WHERE event.status='HOLD'::public.event_status AND event.system_event_key IN(
   'STOCK_GAIN','EXPENSE_DISBURSEMENT','CASH_DEPOSIT','CASH_VARIANCE')
  ORDER BY CASE event.system_event_key WHEN 'STOCK_GAIN' THEN 1
   WHEN 'EXPENSE_DISBURSEMENT' THEN 2 WHEN 'CASH_DEPOSIT' THEN 3 ELSE 4 END,
   event.event_date,event.id
 LOOP
  SELECT count(*) INTO v_before_count FROM public.finance_journals
  WHERE company_id=v_event.company_id AND financial_event_id=v_event.id;
  v_result:=private.post_financial_event_core(
   v_event.company_id,v_event.id,v_event.event_version,v_actor);
  v_replay:=private.post_financial_event_core(
   v_event.company_id,v_event.id,v_event.event_version,v_actor);
  v_journal:=(v_result->>'journalId')::UUID;
  SELECT count(*) INTO v_after_count FROM public.finance_journals
  WHERE company_id=v_event.company_id AND financial_event_id=v_event.id;
  IF v_before_count<>0 OR v_after_count<>1 OR v_result->>'status'<>'POSTED'
   OR COALESCE((v_replay->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE
   OR v_result->>'journalId' IS DISTINCT FROM v_replay->>'journalId' THEN
   RAISE EXCEPTION 'TEST_FAILED: posting identity/replay invalid for %',v_event.id;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.finance_journals journal
   WHERE journal.company_id=v_event.company_id AND journal.id=v_journal
    AND journal.status='POSTED' AND journal.total_debit>0
    AND journal.total_debit=journal.total_credit) THEN
   RAISE EXCEPTION 'TEST_FAILED: Journal balance invalid for %',v_event.id; END IF;

  IF v_event.system_event_key='STOCK_GAIN' THEN
   v_stock:=v_stock+1;
   IF (SELECT count(*) FROM public.finance_journal_lines line
      WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal)<>2
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal
       AND line.account_id=(v_event.amounts->>'inventoryAccountId')::UUID
       AND line.debit=round((v_event.amounts->>'inventoryDebit')::NUMERIC,4))
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal
       AND line.account_id=(v_event.amounts->>'counterAccountId')::UUID
       AND line.credit=round((v_event.amounts->>'stockGainCredit')::NUMERIC,4))
   THEN RAISE EXCEPTION 'TEST_FAILED: Stock Gain Journal invalid'; END IF;
  ELSIF v_event.system_event_key='EXPENSE_DISBURSEMENT' THEN
   v_expense:=v_expense+1;
   IF NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal
       AND line.account_id=(v_event.amounts->>'outstandingAccountId')::UUID
       AND line.debit=round((v_event.amounts->>'disbursedAmount')::NUMERIC,4))
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal
       AND line.account_id=(v_event.amounts->>'paymentAccountId')::UUID
       AND line.credit=round((v_event.amounts->>'disbursedAmount')::NUMERIC,4))
   THEN RAISE EXCEPTION 'TEST_FAILED: Expense Disbursement Journal invalid'; END IF;
  ELSIF v_event.system_event_key='CASH_DEPOSIT' THEN
   v_deposit:=v_deposit+1;
   IF NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal
       AND line.account_id=(v_event.amounts->>'destinationAccountId')::UUID
       AND line.debit=round((v_event.amounts->>'actualDeposit')::NUMERIC,4))
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal
       AND line.account_id=(v_event.amounts->>'cashDrawerAccountId')::UUID
       AND line.credit=round((v_event.amounts->>'expectedDeposit')::NUMERIC,4))
   THEN RAISE EXCEPTION 'TEST_FAILED: Cash Deposit Journal invalid'; END IF;
  ELSE
   v_variance:=v_variance+1;
   IF (SELECT count(*) FROM public.finance_journal_lines line
      WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal)<>2
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal
       AND line.account_id=(v_event.amounts->>'controlAccountId')::UUID)
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal
       AND line.account_id=(v_event.amounts->>'resolutionAccountId')::UUID)
   THEN RAISE EXCEPTION 'TEST_FAILED: Cash Variance Journal invalid'; END IF;
  END IF;
 END LOOP;
 IF v_stock<>2 OR v_expense<>2 OR v_deposit<>2 OR v_variance<>1 THEN
  RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: expected 2/2/2/1, got %/%/%/%',
   v_stock,v_expense,v_deposit,v_variance; END IF;
 RAISE NOTICE 'TEST PASSED: 2 Stock Gain, 2 Expense Disbursement, 2 Cash Deposit and 1 Cash Variance post atomically, balance, replay idempotently, and will roll back.';
END
$test$;
ROLLBACK;
