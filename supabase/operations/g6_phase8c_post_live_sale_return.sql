-- G6 phase 8C controlled live operation: post exactly 13 Sale + 1 Return HOLD.
-- WARNING: MUTATES LIVE FINANCE STATE. Successful Journals are append-only.

BEGIN;
DO $live$
DECLARE
  v_actor UUID; v_company UUID; v_company_count BIGINT;
  v_sale_count BIGINT; v_return_count BIGINT; v_expected_hash TEXT;
  v_preview JSONB; v_approval JSONB; v_process JSONB;
BEGIN
  SELECT count(DISTINCT event.company_id),min(event.company_id::TEXT)::UUID,
    count(*) FILTER(WHERE event.system_event_key='SALE_POSTED'),
    count(*) FILTER(WHERE event.system_event_key='SALES_RETURN')
  INTO v_company_count,v_company,v_sale_count,v_return_count
  FROM public.financial_events event
  WHERE event.status='HOLD'::public.event_status
    AND event.system_event_key IN('SALE_POSTED','SALES_RETURN')
    AND NOT EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=event.company_id AND journal.financial_event_id=event.id);
  IF v_company_count<>1 OR v_sale_count<>13 OR v_return_count<>1 THEN
    RAISE EXCEPTION
      'LIVE_SCOPE_CHANGED: expected one Company, 13 Sale and 1 Return; got companies %, Sale %, Return %',
      v_company_count,v_sale_count,v_return_count;
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs run
    WHERE run.company_id=v_company AND run.status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'ACTIVE_FINANCE_POSTING_QUEUE_ALREADY_EXISTS'; END IF;

  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN RAISE EXCEPTION 'LINKED_SUPER_ADMIN_PROFILE_REQUIRED'; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(v_company,'BACKOFFICE');

  v_preview:=public.preview_sale_return_posting_queue(100);
  IF (v_preview->>'eventCount')::BIGINT<>14
    OR v_preview->>'scopeSystemKey'<>'SALE_RETURN' THEN
    RAISE EXCEPTION 'LIVE_PREVIEW_SCOPE_INVALID: %',v_preview; END IF;
  SELECT md5(string_agg(item.financial_event_id||':'||item.event_version_snapshot,
    '|' ORDER BY item.line_no)) INTO v_expected_hash
  FROM public.finance_posting_queue_items item
  WHERE item.company_id=v_company
    AND item.queue_run_id=(v_preview->>'queueRunId')::UUID;
  IF v_expected_hash IS DISTINCT FROM v_preview->>'previewHash' THEN
    RAISE EXCEPTION 'LIVE_PREVIEW_HASH_MISMATCH'; END IF;

  v_approval:=public.approve_financial_event_posting_queue(
    (v_preview->>'queueRunId')::UUID,(v_preview->>'masterVersion')::BIGINT);
  v_process:=public.process_financial_event_posting_queue(
    (v_approval->>'queueRunId')::UUID,(v_approval->>'masterVersion')::BIGINT);
  IF v_process->>'status'<>'COMPLETED'
    OR (v_process->>'postedCount')::BIGINT<>14
    OR (v_process->>'failedCount')::BIGINT<>0
    OR (v_process->>'skippedCount')::BIGINT<>0 THEN
    RAISE EXCEPTION 'LIVE_PROCESS_NOT_CLEAN: %',v_process; END IF;
  RAISE NOTICE 'CONTROLLED LIVE SALE/RETURN RESULT: %',v_process;
END
$live$;
COMMIT;

SELECT run.display_no,run.queue_no,run.status,run.previewed_event_count,
  run.posted_count,run.failed_count,run.skipped_count,run.master_version,
  run.processed_at
FROM public.finance_posting_queue_runs run
WHERE run.scope_system_key='SALE_RETURN'
ORDER BY run.created_at DESC,run.id DESC LIMIT 1;
