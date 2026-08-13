-- G6 phase 8E: controlled Purchase/AP preview, approval and processing queue.
-- Migration installs authority only; it creates no run and posts no Event.

BEGIN;
DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260814143000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Phase 8D zero-value fix required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260814150000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260814150000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue exists';
  END IF;
END
$guard$;

ALTER TABLE public.finance_posting_queue_runs
  DROP CONSTRAINT finance_posting_queue_runs_scope_check;
ALTER TABLE public.finance_posting_queue_runs
  ADD CONSTRAINT finance_posting_queue_runs_scope_check CHECK(
    scope_system_key IN('STOCK_OPENING','SALE_RETURN','PURCHASE_AP'));

CREATE FUNCTION public.preview_purchase_ap_posting_queue(
  p_limit INTEGER DEFAULT 100
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
  v_run_id UUID:=gen_random_uuid(); v_run public.finance_posting_queue_runs%ROWTYPE;
  v_count INTEGER; v_hash TEXT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN
    RAISE EXCEPTION 'QUEUE_PREVIEW_LIMIT_INVALID'; END IF;
  IF NOT private.g6_finance_queue_role_allowed(v_company) THEN
    RAISE EXCEPTION 'FINANCE_QUEUE_ROLE_REQUIRED'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('G6_FINANCE_QUEUE|'||v_company,0));
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs run
    WHERE run.company_id=v_company
      AND run.status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'ACTIVE_FINANCE_POSTING_QUEUE_ALREADY_EXISTS'; END IF;

  INSERT INTO public.finance_posting_queue_runs(id,company_id,queue_no,
    scope_system_key,status,preview_limit,preview_hash,created_by)
  VALUES(v_run_id,v_company,'FQ-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'
    ||upper(substr(replace(v_run_id::TEXT,'-',''),1,8)),
    'PURCHASE_AP','PREVIEWED',p_limit,
    md5('EMPTY|'||v_company||'|'||v_run_id),v_actor);

  INSERT INTO public.finance_posting_queue_items(company_id,queue_run_id,line_no,
    financial_event_id,event_version_snapshot,event_code_snapshot,
    system_event_key_snapshot,source_table_snapshot,source_id_snapshot,
    transaction_category_id_snapshot,event_date_snapshot)
  SELECT event.company_id,v_run_id,
    row_number() OVER(ORDER BY event.event_date,event.id)::INTEGER,event.id,
    event.event_version,event.event_code,event.system_event_key,event.source_table,
    event.source_id,event.transaction_category_id,event.event_date
  FROM public.financial_events event
  WHERE event.company_id=v_company AND event.status='HOLD'::public.event_status
    AND (
      (event.system_event_key='GOODS_RECEIPT'
       AND event.event_type::TEXT='PURCHASE_POSTED'
       AND event.source_table='goods_receipt_documents'
       AND EXISTS(SELECT 1 FROM public.goods_receipt_documents document
         WHERE document.company_id=event.company_id AND document.id=event.source_id
           AND document.status='POSTED' AND document.financial_event_id=event.id))
      OR (event.system_event_key='SUPPLIER_INVOICE'
       AND event.event_type::TEXT='SUPPLIER_INVOICE_VALIDATED'
       AND event.source_table='supplier_invoice_documents'
       AND EXISTS(SELECT 1 FROM public.supplier_invoice_documents document
         WHERE document.company_id=event.company_id AND document.id=event.source_id
           AND document.status='VALIDATED' AND document.financial_event_id=event.id))
      OR (event.system_event_key='SUPPLIER_PAYMENT'
       AND event.event_type::TEXT='SUPPLIER_PAYMENT_VALIDATED'
       AND event.source_table='supplier_payment_documents'
       AND EXISTS(SELECT 1 FROM public.supplier_payment_documents document
         WHERE document.company_id=event.company_id AND document.id=event.source_id
           AND document.status='VALIDATED' AND document.financial_event_id=event.id))
    )
    AND NOT EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=event.company_id AND journal.financial_event_id=event.id)
  ORDER BY event.event_date,event.id LIMIT p_limit;
  GET DIAGNOSTICS v_count=ROW_COUNT;
  IF v_count=0 THEN RAISE EXCEPTION 'NO_SUPPORTED_HOLD_EVENTS'; END IF;
  SELECT md5(string_agg(item.financial_event_id||':'||item.event_version_snapshot,
    '|' ORDER BY item.line_no)) INTO v_hash
  FROM public.finance_posting_queue_items item
  WHERE item.company_id=v_company AND item.queue_run_id=v_run_id;
  UPDATE public.finance_posting_queue_runs SET previewed_event_count=v_count,
    preview_hash=v_hash WHERE company_id=v_company AND id=v_run_id RETURNING * INTO v_run;
  INSERT INTO public.finance_posting_queue_audit(company_id,queue_run_id,action,
    actor_id,after_state) VALUES(v_company,v_run_id,'PREVIEW',v_actor,
    jsonb_build_object('status',v_run.status,'masterVersion',v_run.master_version,
      'eventCount',v_count,'previewHash',v_hash,'scopeSystemKey','PURCHASE_AP'));
  RETURN jsonb_build_object('queueRunId',v_run.id,'queueNo',v_run.queue_no,
    'status',v_run.status,'masterVersion',v_run.master_version,
    'eventCount',v_count,'previewHash',v_hash,'scopeSystemKey','PURCHASE_AP');
END
$$;

CREATE FUNCTION public.process_purchase_ap_posting_queue(
  p_queue_run_id UUID,p_expected_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
  v_run public.finance_posting_queue_runs%ROWTYPE;
  v_item public.finance_posting_queue_items%ROWTYPE;
  v_result JSONB; v_error TEXT; v_reason TEXT; v_exception_id UUID;
  v_posted INTEGER:=0; v_failed INTEGER:=0; v_skipped INTEGER:=0;
  v_stale INTEGER:=0; v_before JSONB;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF NOT private.g6_finance_queue_role_allowed(v_company) THEN
    RAISE EXCEPTION 'FINANCE_QUEUE_ROLE_REQUIRED'; END IF;
  SELECT * INTO v_run FROM public.finance_posting_queue_runs run
  WHERE run.company_id=v_company AND run.id=p_queue_run_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_NOT_FOUND'; END IF;
  IF v_run.scope_system_key<>'PURCHASE_AP' THEN
    RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_SCOPE_MISMATCH'; END IF;
  IF v_run.status IN('COMPLETED','COMPLETED_WITH_ERRORS') THEN
    RETURN jsonb_build_object('queueRunId',v_run.id,'status',v_run.status,
      'masterVersion',v_run.master_version,'postedCount',v_run.posted_count,
      'failedCount',v_run.failed_count,'skippedCount',v_run.skipped_count,
      'idempotentReplay',TRUE);
  END IF;
  IF p_expected_master_version IS NULL
     OR p_expected_master_version<>v_run.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_run.status<>'APPROVED' THEN
    RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_NOT_APPROVED'; END IF;

  v_before:=jsonb_build_object('status',v_run.status,
    'masterVersion',v_run.master_version);
  UPDATE public.finance_posting_queue_runs SET status='PROCESSING',
    processing_by=v_actor,processing_started_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_run.id RETURNING * INTO v_run;

  FOR v_item IN SELECT item.* FROM public.finance_posting_queue_items item
    WHERE item.company_id=v_company AND item.queue_run_id=v_run.id
      AND item.status='READY' ORDER BY item.line_no FOR UPDATE
  LOOP
    BEGIN
      IF NOT EXISTS(SELECT 1 FROM public.financial_events event
        WHERE event.company_id=v_company AND event.id=v_item.financial_event_id
          AND event.status='HOLD'::public.event_status
          AND event.event_version=v_item.event_version_snapshot) THEN
        UPDATE public.finance_posting_queue_items SET status='SKIPPED',
          attempt_count=attempt_count+1,error_code='QUEUE_PREVIEW_STALE',
          error_message='Event changed after queue approval',
          processed_at=clock_timestamp()
        WHERE company_id=v_company AND id=v_item.id;
        v_skipped:=v_skipped+1; v_stale:=v_stale+1;
      ELSE
        v_result:=private.post_financial_event_core(v_company,
          v_item.financial_event_id,v_item.event_version_snapshot,v_actor);
        IF v_result->>'status'='CANCELED'
           AND v_result->>'reason'='NO_FINANCIAL_EFFECT' THEN
          UPDATE public.finance_posting_queue_items SET status='SKIPPED',
            attempt_count=attempt_count+1,error_code='NO_FINANCIAL_EFFECT',
            error_message='Source is final but has zero accounting value',
            processed_at=clock_timestamp()
          WHERE company_id=v_company AND id=v_item.id;
          v_skipped:=v_skipped+1;
        ELSIF v_result->>'status'='POSTED'
          AND NULLIF(v_result->>'journalId','') IS NOT NULL THEN
          UPDATE public.finance_posting_queue_items SET status='POSTED',
            attempt_count=attempt_count+1,
            journal_id=(v_result->>'journalId')::UUID,
            processed_at=clock_timestamp()
          WHERE company_id=v_company AND id=v_item.id;
          v_posted:=v_posted+1;
        ELSE
          RAISE EXCEPTION 'UNEXPECTED_FINANCIAL_EVENT_RESULT';
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_error:=SQLERRM;
      v_reason:=CASE
        WHEN v_error LIKE '%PERIOD%' THEN 'LOCKED_PERIOD'
        WHEN v_error LIKE '%UNBALANCED%' OR v_error LIKE '%AMOUNT%'
          THEN 'UNBALANCED_JOURNAL'
        WHEN v_error LIKE '%VERSION%' THEN 'RULE_VERSION_CONFLICT'
        WHEN v_error LIKE '%ACCOUNT%INVALID%' THEN 'INACTIVE_ACCOUNT'
        WHEN v_error LIKE '%SOURCE%' OR v_error LIKE '%UNSUPPORTED%'
          THEN 'INVALID_DIMENSION'
        ELSE 'MISSING_REQUIRED_FUNCTION' END;
      SELECT exception_state.id INTO v_exception_id
      FROM public.finance_posting_exceptions exception_state
      WHERE exception_state.company_id=v_company
        AND exception_state.financial_event_id=v_item.financial_event_id
        AND exception_state.reason_code=v_reason
        AND exception_state.resolver_level='CONTROLLED_QUEUE'
        AND exception_state.status<>'RESOLVED'
      ORDER BY exception_state.created_at DESC,exception_state.id LIMIT 1 FOR UPDATE;
      IF FOUND THEN
        UPDATE public.finance_posting_exceptions SET status='POSTING_ERROR',
          retry_count=retry_count+1,last_error=left(v_error,1000),
          updated_at=clock_timestamp()
        WHERE company_id=v_company AND id=v_exception_id;
      ELSE
        INSERT INTO public.finance_posting_exceptions(company_id,
          financial_event_id,source_table,source_id,system_key,
          transaction_category_id,reason_code,resolver_level,status,
          retry_count,last_error)
        VALUES(v_company,v_item.financial_event_id,v_item.source_table_snapshot,
          v_item.source_id_snapshot,v_item.system_event_key_snapshot,
          v_item.transaction_category_id_snapshot,v_reason,'CONTROLLED_QUEUE',
          'POSTING_ERROR',1,left(v_error,1000))
        RETURNING id INTO v_exception_id;
      END IF;
      UPDATE public.finance_posting_queue_items SET status='FAILED',
        attempt_count=attempt_count+1,error_code=v_reason,
        error_message=left(v_error,1000),processed_at=clock_timestamp()
      WHERE company_id=v_company AND id=v_item.id;
      v_failed:=v_failed+1;
    END;
  END LOOP;

  UPDATE public.finance_posting_queue_runs SET
    status=CASE WHEN v_failed=0 AND v_stale=0 THEN 'COMPLETED'
      ELSE 'COMPLETED_WITH_ERRORS' END,
    posted_count=v_posted,failed_count=v_failed,skipped_count=v_skipped,
    processed_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_run.id RETURNING * INTO v_run;
  INSERT INTO public.finance_posting_queue_audit(company_id,queue_run_id,
    action,actor_id,before_state,after_state)
  VALUES(v_company,v_run.id,'PROCESS',v_actor,v_before,
    jsonb_build_object('status',v_run.status,'masterVersion',v_run.master_version,
      'postedCount',v_posted,'failedCount',v_failed,'skippedCount',v_skipped,
      'staleCount',v_stale));
  RETURN jsonb_build_object('queueRunId',v_run.id,'status',v_run.status,
    'masterVersion',v_run.master_version,'postedCount',v_posted,
    'failedCount',v_failed,'skippedCount',v_skipped,
    'idempotentReplay',FALSE);
END
$$;

REVOKE ALL ON FUNCTION public.preview_purchase_ap_posting_queue(INTEGER),
  public.process_purchase_ap_posting_queue(UUID,BIGINT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.preview_purchase_ap_posting_queue(INTEGER),
  public.process_purchase_ap_posting_queue(UUID,BIGINT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260814150000','g6_phase8e_purchase_ap_controlled_queue',
  'Adds immutable PURCHASE_AP preview plus a dedicated audited processor that posts positive Purchase/AP effects and closes exact zero-value Goods Receipt as a successful no-effect skip; migration posts nothing');
COMMIT;
