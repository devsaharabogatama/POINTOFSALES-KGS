-- G6 phase 8E behavioral: preview, approve, process and rollback all effects.
BEGIN;
DO $test$
DECLARE
  v_actor UUID; v_company UUID; v_preview JSONB; v_approved JSONB;
  v_processed JSONB; v_replay JSONB; v_expected INTEGER; v_expected_zero INTEGER;
BEGIN
 SELECT event.company_id INTO v_company FROM public.financial_events event
 WHERE event.status='HOLD'::public.event_status AND event.system_event_key IN(
  'GOODS_RECEIPT','SUPPLIER_INVOICE','SUPPLIER_PAYMENT')
 GROUP BY event.company_id HAVING count(*)>0 ORDER BY event.company_id LIMIT 1;
 SELECT profile.id INTO v_actor FROM public.profiles profile
 WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1;
 IF v_company IS NULL OR v_actor IS NULL THEN
  RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Purchase/AP HOLD and Super Admin required'; END IF;
 SELECT count(*) INTO v_expected FROM public.financial_events event
 WHERE event.company_id=v_company AND event.status='HOLD'::public.event_status
  AND event.system_event_key IN('GOODS_RECEIPT','SUPPLIER_INVOICE','SUPPLIER_PAYMENT');
 SELECT count(*) INTO v_expected_zero FROM public.financial_events event
 JOIN public.goods_receipt_documents document ON document.company_id=event.company_id
  AND document.id=event.source_id AND document.financial_event_id=event.id
 WHERE event.company_id=v_company AND event.status='HOLD'::public.event_status
  AND event.system_event_key='GOODS_RECEIPT'
  AND round(document.provisional_ap_total,4)=0;
 PERFORM set_config('request.jwt.claims',jsonb_build_object(
  'sub',v_actor,'role','authenticated')::TEXT,TRUE);
 PERFORM public.set_active_company_context(v_company,'BACKOFFICE');
 v_preview:=public.preview_purchase_ap_posting_queue(100);
 IF (v_preview->>'eventCount')::INTEGER<>v_expected
   OR v_preview->>'scopeSystemKey'<>'PURCHASE_AP' THEN
  RAISE EXCEPTION 'TEST_FAILED: preview invalid: %',v_preview; END IF;
 v_approved:=public.approve_financial_event_posting_queue(
  (v_preview->>'queueRunId')::UUID,(v_preview->>'masterVersion')::BIGINT);
 v_processed:=public.process_purchase_ap_posting_queue(
  (v_preview->>'queueRunId')::UUID,(v_approved->>'masterVersion')::BIGINT);
 IF v_processed->>'status'<>'COMPLETED'
   OR (v_processed->>'failedCount')::INTEGER<>0
   OR (v_processed->>'skippedCount')::INTEGER<>v_expected_zero
   OR (v_processed->>'postedCount')::INTEGER<>v_expected-v_expected_zero THEN
  RAISE EXCEPTION 'TEST_FAILED: controlled processing invalid: %',v_processed; END IF;
 IF (SELECT count(*) FROM public.finance_posting_queue_items item
   WHERE item.company_id=v_company
    AND item.queue_run_id=(v_preview->>'queueRunId')::UUID
    AND item.status='SKIPPED' AND item.error_code='NO_FINANCIAL_EFFECT')<>v_expected_zero THEN
  RAISE EXCEPTION 'TEST_FAILED: no-effect queue item classification invalid'; END IF;
 IF EXISTS(SELECT 1 FROM public.finance_journals journal
   WHERE journal.company_id=v_company AND journal.status='POSTED'
    AND journal.total_debit<>journal.total_credit) THEN
  RAISE EXCEPTION 'TEST_FAILED: unbalanced posted Journal'; END IF;
 IF EXISTS(SELECT 1 FROM public.finance_posting_queue_items item
   LEFT JOIN public.finance_journals journal ON journal.company_id=item.company_id
    AND journal.id=item.journal_id
   WHERE item.company_id=v_company
    AND item.queue_run_id=(v_preview->>'queueRunId')::UUID
    AND item.status='POSTED' AND journal.id IS NULL) THEN
  RAISE EXCEPTION 'TEST_FAILED: posted queue item has no Journal'; END IF;
 v_replay:=public.process_purchase_ap_posting_queue(
  (v_preview->>'queueRunId')::UUID,(v_processed->>'masterVersion')::BIGINT);
 IF COALESCE((v_replay->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE
   OR v_replay->>'status'<>'COMPLETED' THEN
  RAISE EXCEPTION 'TEST_FAILED: queue replay invalid: %',v_replay; END IF;
 RAISE NOTICE 'TEST PASSED: % Purchase/AP events processed (% posted, % valid no-effect), balanced and idempotent; transaction will roll back.',
  v_expected,v_expected-v_expected_zero,v_expected_zero;
END
$test$;
ROLLBACK;
