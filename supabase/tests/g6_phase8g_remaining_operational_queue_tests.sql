-- G6 phase 8G behavioral: controlled seven-event queue, then rollback.
BEGIN;
DO $test$
DECLARE
 v_actor UUID; v_company UUID; v_preview JSONB; v_approved JSONB;
 v_processed JSONB; v_replay JSONB;
BEGIN
 SELECT event.company_id INTO v_company FROM public.financial_events event
 WHERE event.status='HOLD'::public.event_status AND event.system_event_key IN(
  'STOCK_GAIN','EXPENSE_DISBURSEMENT','CASH_DEPOSIT','CASH_VARIANCE')
 GROUP BY event.company_id HAVING count(*)=7 ORDER BY event.company_id LIMIT 1;
 SELECT profile.id INTO v_actor FROM public.profiles profile
 WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1;
 IF v_company IS NULL OR v_actor IS NULL THEN
  RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: exact seven-event scope and Super Admin required';
 END IF;
 PERFORM set_config('request.jwt.claims',jsonb_build_object(
  'sub',v_actor,'role','authenticated')::TEXT,TRUE);
 PERFORM public.set_active_company_context(v_company,'BACKOFFICE');
 v_preview:=public.preview_remaining_operational_posting_queue(100);
 IF (v_preview->>'eventCount')::INTEGER<>7
  OR v_preview->>'scopeSystemKey'<>'REMAINING_OPERATIONAL' THEN
  RAISE EXCEPTION 'TEST_FAILED: preview invalid: %',v_preview; END IF;
 v_approved:=public.approve_financial_event_posting_queue(
  (v_preview->>'queueRunId')::UUID,(v_preview->>'masterVersion')::BIGINT);
 v_processed:=public.process_financial_event_posting_queue(
  (v_preview->>'queueRunId')::UUID,(v_approved->>'masterVersion')::BIGINT);
 IF v_processed->>'status'<>'COMPLETED'
  OR (v_processed->>'postedCount')::INTEGER<>7
  OR (v_processed->>'failedCount')::INTEGER<>0
  OR (v_processed->>'skippedCount')::INTEGER<>0 THEN
  RAISE EXCEPTION 'TEST_FAILED: controlled processing invalid: %',v_processed; END IF;
 IF EXISTS(SELECT 1 FROM public.finance_posting_queue_items item
  LEFT JOIN public.finance_journals journal ON journal.company_id=item.company_id
   AND journal.id=item.journal_id
  WHERE item.company_id=v_company
   AND item.queue_run_id=(v_preview->>'queueRunId')::UUID
   AND (item.status<>'POSTED' OR journal.id IS NULL
    OR journal.status<>'POSTED' OR journal.total_debit<>journal.total_credit)) THEN
  RAISE EXCEPTION 'TEST_FAILED: queue item or Journal invalid'; END IF;
 v_replay:=public.process_financial_event_posting_queue(
  (v_preview->>'queueRunId')::UUID,(v_processed->>'masterVersion')::BIGINT);
 IF COALESCE((v_replay->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE
  OR v_replay->>'status'<>'COMPLETED' THEN
  RAISE EXCEPTION 'TEST_FAILED: queue replay invalid: %',v_replay; END IF;
 RAISE NOTICE 'TEST PASSED: exact seven-event controlled queue posts cleanly and idempotently; transaction will roll back.';
END
$test$;
ROLLBACK;
