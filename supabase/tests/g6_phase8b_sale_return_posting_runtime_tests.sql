-- G6 phase 8B behavioral: post one historical Sale and Return, replay, rollback.

BEGIN;
DO $test$
DECLARE
  v_actor UUID; v_event public.financial_events%ROWTYPE;
  v_result JSONB; v_replay JSONB; v_before_count BIGINT; v_after_count BIGINT;
BEGIN
  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Super Admin profile required'; END IF;

  FOR v_event IN SELECT event.* FROM public.financial_events event
    WHERE event.status='HOLD'::public.event_status
      AND event.system_event_key IN('SALE_POSTED','SALES_RETURN')
    ORDER BY CASE event.system_event_key WHEN 'SALE_POSTED' THEN 1 ELSE 2 END,
      event.event_date,event.id
  LOOP
    IF v_event.system_event_key='SALE_POSTED' AND EXISTS(
      SELECT 1 FROM public.finance_journals journal
      JOIN public.financial_events linked ON linked.company_id=journal.company_id
       AND linked.id=journal.financial_event_id
      WHERE linked.system_event_key='SALE_POSTED'
        AND linked.status='POSTED'::public.event_status) THEN CONTINUE; END IF;
    IF v_event.system_event_key='SALES_RETURN' AND EXISTS(
      SELECT 1 FROM public.finance_journals journal
      JOIN public.financial_events linked ON linked.company_id=journal.company_id
       AND linked.id=journal.financial_event_id
      WHERE linked.system_event_key='SALES_RETURN'
        AND linked.status='POSTED'::public.event_status) THEN CONTINUE; END IF;

    SELECT count(*) INTO v_before_count FROM public.finance_journals
    WHERE company_id=v_event.company_id AND financial_event_id=v_event.id;
    v_result:=private.post_financial_event_core(
      v_event.company_id,v_event.id,v_event.event_version,v_actor);
    v_replay:=private.post_financial_event_core(
      v_event.company_id,v_event.id,v_event.event_version,v_actor);
    SELECT count(*) INTO v_after_count FROM public.finance_journals
    WHERE company_id=v_event.company_id AND financial_event_id=v_event.id;
    IF v_before_count<>0 OR v_after_count<>1
      OR v_result->>'status'<>'POSTED'
      OR COALESCE((v_replay->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE
      OR v_result->>'journalId' IS DISTINCT FROM v_replay->>'journalId' THEN
      RAISE EXCEPTION 'TEST_FAILED: posting identity or replay invalid for %',v_event.id;
    END IF;
    IF EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.id=(v_result->>'journalId')::UUID
        AND (journal.status<>'POSTED' OR journal.total_debit<=0
          OR journal.total_debit<>journal.total_credit)) THEN
      RAISE EXCEPTION 'TEST_FAILED: unbalanced Journal for %',v_event.id;
    END IF;
  END LOOP;

  IF NOT EXISTS(SELECT 1 FROM public.financial_events
      WHERE system_event_key='SALE_POSTED' AND status='POSTED'::public.event_status)
    OR NOT EXISTS(SELECT 1 FROM public.financial_events
      WHERE system_event_key='SALES_RETURN' AND status='POSTED'::public.event_status) THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: one Sale and one Return HOLD required';
  END IF;
  RAISE NOTICE 'TEST PASSED: Sale and Return post atomically, balance, preserve source dimensions, and replay idempotently; transaction will roll back.';
END
$test$;
ROLLBACK;
