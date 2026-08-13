-- G6 phase 8E controlled live operation: close exactly 4 GR + 3 Invoice + 2 Payment.
-- WARNING: MUTATES LIVE FINANCE STATE. Successful Journals are append-only.

BEGIN;
DO $live$
DECLARE
  v_actor UUID; v_company UUID; v_company_count BIGINT;
  v_receipt_count BIGINT; v_invoice_count BIGINT; v_payment_count BIGINT;
  v_zero_receipt_count BIGINT; v_expected_hash TEXT;
  v_preview JSONB; v_approval JSONB; v_process JSONB;
BEGIN
  SELECT count(DISTINCT event.company_id),min(event.company_id::TEXT)::UUID,
    count(*) FILTER(WHERE event.system_event_key='GOODS_RECEIPT'),
    count(*) FILTER(WHERE event.system_event_key='SUPPLIER_INVOICE'),
    count(*) FILTER(WHERE event.system_event_key='SUPPLIER_PAYMENT')
  INTO v_company_count,v_company,v_receipt_count,v_invoice_count,v_payment_count
  FROM public.financial_events event
  WHERE event.status='HOLD'::public.event_status
    AND event.system_event_key IN(
      'GOODS_RECEIPT','SUPPLIER_INVOICE','SUPPLIER_PAYMENT')
    AND NOT EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=event.company_id
        AND journal.financial_event_id=event.id);
  IF v_company_count<>1 OR v_receipt_count<>4 OR v_invoice_count<>3
     OR v_payment_count<>2 THEN
    RAISE EXCEPTION
      'LIVE_SCOPE_CHANGED: expected one Company, 4 Receipt, 3 Invoice and 2 Payment; got companies %, Receipt %, Invoice %, Payment %',
      v_company_count,v_receipt_count,v_invoice_count,v_payment_count;
  END IF;

  SELECT count(*) INTO v_zero_receipt_count
  FROM public.financial_events event
  JOIN public.goods_receipt_documents document
    ON document.company_id=event.company_id AND document.id=event.source_id
   AND document.financial_event_id=event.id AND document.status='POSTED'
  WHERE event.company_id=v_company AND event.status='HOLD'::public.event_status
    AND event.system_event_key='GOODS_RECEIPT'
    AND round(document.provisional_ap_total,4)=0
    AND round((event.amounts->>'inventoryDebit')::NUMERIC,4)=0
    AND round((event.amounts->>'supplierApProvisionalCredit')::NUMERIC,4)=0;
  IF v_zero_receipt_count<>1 THEN
    RAISE EXCEPTION
      'LIVE_ZERO_EFFECT_SCOPE_CHANGED: expected exactly one zero-value Receipt; got %',
      v_zero_receipt_count;
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs run
    WHERE run.company_id=v_company
      AND run.status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'ACTIVE_FINANCE_POSTING_QUEUE_ALREADY_EXISTS'; END IF;

  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN RAISE EXCEPTION 'LINKED_SUPER_ADMIN_PROFILE_REQUIRED'; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(v_company,'BACKOFFICE');

  v_preview:=public.preview_purchase_ap_posting_queue(100);
  IF (v_preview->>'eventCount')::BIGINT<>9
    OR v_preview->>'scopeSystemKey'<>'PURCHASE_AP' THEN
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
  v_process:=public.process_purchase_ap_posting_queue(
    (v_approval->>'queueRunId')::UUID,(v_approval->>'masterVersion')::BIGINT);
  IF v_process->>'status'<>'COMPLETED'
    OR (v_process->>'postedCount')::BIGINT<>8
    OR (v_process->>'failedCount')::BIGINT<>0
    OR (v_process->>'skippedCount')::BIGINT<>1 THEN
    RAISE EXCEPTION 'LIVE_PROCESS_NOT_CLEAN: %',v_process; END IF;
  RAISE NOTICE 'CONTROLLED LIVE PURCHASE/AP RESULT: %',v_process;
END
$live$;
COMMIT;

SELECT run.display_no,run.queue_no,run.status,run.previewed_event_count,
  run.posted_count,run.failed_count,run.skipped_count,run.master_version,
  run.processed_at
FROM public.finance_posting_queue_runs run
WHERE run.scope_system_key='PURCHASE_AP'
ORDER BY run.created_at DESC,run.id DESC LIMIT 1;
