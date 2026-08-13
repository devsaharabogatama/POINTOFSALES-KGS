-- G6 phase 8C behavioral: preview, approve, process and rollback all effects.
BEGIN;
DO $test$
DECLARE v_actor UUID; v_company UUID; v_preview JSONB; v_approved JSONB; v_processed JSONB;
BEGIN
 SELECT event.company_id INTO v_company FROM public.financial_events event
 WHERE event.status='HOLD'::public.event_status
  AND event.system_event_key IN('SALE_POSTED','SALES_RETURN')
 GROUP BY event.company_id HAVING count(*)>0 ORDER BY event.company_id LIMIT 1;
 SELECT profile.id INTO v_actor FROM public.profiles profile
 WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1;
 IF v_company IS NULL OR v_actor IS NULL THEN
  RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Sale/Return HOLD and Super Admin required'; END IF;
 PERFORM set_config('request.jwt.claims',jsonb_build_object(
  'sub',v_actor,'role','authenticated')::TEXT,TRUE);
 PERFORM public.set_active_company_context(v_company,'BACKOFFICE');
 v_preview:=public.preview_sale_return_posting_queue(100);
 IF (v_preview->>'eventCount')::INTEGER<1 OR v_preview->>'scopeSystemKey'<>'SALE_RETURN' THEN
  RAISE EXCEPTION 'TEST_FAILED: preview invalid'; END IF;
 v_approved:=public.approve_financial_event_posting_queue(
  (v_preview->>'queueRunId')::UUID,(v_preview->>'masterVersion')::BIGINT);
 v_processed:=public.process_financial_event_posting_queue(
  (v_preview->>'queueRunId')::UUID,(v_approved->>'masterVersion')::BIGINT);
 IF v_processed->>'status'<>'COMPLETED' OR (v_processed->>'failedCount')::INTEGER<>0
   OR (v_processed->>'skippedCount')::INTEGER<>0
   OR (v_processed->>'postedCount')::INTEGER<>(v_preview->>'eventCount')::INTEGER THEN
  RAISE EXCEPTION 'TEST_FAILED: controlled processing invalid: %',v_processed; END IF;
 IF EXISTS(SELECT 1 FROM public.finance_journals journal
   WHERE journal.company_id=v_company AND journal.status='POSTED'
     AND journal.total_debit<>journal.total_credit) THEN
  RAISE EXCEPTION 'TEST_FAILED: unbalanced posted Journal'; END IF;
 RAISE NOTICE 'TEST PASSED: immutable Sale/Return preview, approval and processing complete with zero failure; transaction will roll back.';
END
$test$;
ROLLBACK;
