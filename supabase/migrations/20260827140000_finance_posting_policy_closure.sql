-- F4B Finance posting policy and canonical queue closure.
-- The migration installs runtime only. Existing HOLD events remain untouched.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827131000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: F4A reporting fix required';
  END IF;
  IF EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827140000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260827140000';
  END IF;
  IF to_regprocedure(
    'private.post_financial_event_core(uuid,uuid,bigint,uuid)'
  ) IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Finance dispatcher required';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.finance_posting_queue_runs run
    WHERE run.status IN('PREVIEWED','APPROVED','PROCESSING')
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue exists';
  END IF;
END
$guard$;

ALTER TABLE public.finance_posting_queue_runs
  DROP CONSTRAINT finance_posting_queue_runs_scope_check;
ALTER TABLE public.finance_posting_queue_runs
  ADD CONSTRAINT finance_posting_queue_runs_scope_check CHECK(
    scope_system_key IN(
      'STOCK_OPENING','SALE_RETURN','PURCHASE_AP',
      'REMAINING_OPERATIONAL','ALL_SUPPORTED'
    )
  );

CREATE FUNCTION private.f4b_financial_event_supported(
  p_event public.financial_events
) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT p_event.status::TEXT='HOLD' AND CASE p_event.system_event_key
    WHEN 'STOCK_OPENING' THEN p_event.source_table='opening_stock_documents'
    WHEN 'SALE_POSTED' THEN p_event.source_table='sales_headers'
    WHEN 'SALES_RETURN' THEN p_event.source_table='sales_return_documents'
    WHEN 'GOODS_RECEIPT' THEN p_event.source_table='goods_receipt_documents'
    WHEN 'SUPPLIER_INVOICE' THEN p_event.source_table='supplier_invoice_documents'
    WHEN 'SUPPLIER_PAYMENT' THEN p_event.source_table='supplier_payment_documents'
    WHEN 'STOCK_GAIN' THEN p_event.source_table='stock_adjustment_documents'
    WHEN 'EXPENSE_DISBURSEMENT' THEN p_event.source_table='expense_disbursements'
    WHEN 'CASH_DEPOSIT' THEN p_event.source_table='cash_deposit_documents'
    WHEN 'CASH_VARIANCE' THEN p_event.source_table='deposit_variance_resolution_requests'
    WHEN 'SALE_PAYMENT' THEN p_event.source_table='customer_receipt_documents'
    WHEN 'CUSTOMER_BALANCE_RECEIPT' THEN p_event.source_table='customer_receipt_documents'
    ELSE FALSE END
$$;

CREATE FUNCTION private.f4b_record_posting_exception(
  p_company_id UUID,p_event_id UUID,p_resolver_level TEXT,p_error TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_event public.financial_events%ROWTYPE;
  v_reason TEXT;
  v_exception_id UUID;
BEGIN
  SELECT event.* INTO v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_reason:=CASE
    WHEN p_error LIKE '%PERIOD%' THEN 'LOCKED_PERIOD'
    WHEN p_error LIKE '%UNBALANCED%' OR p_error LIKE '%AMOUNT%'
      THEN 'UNBALANCED_JOURNAL'
    WHEN p_error LIKE '%VERSION%' THEN 'RULE_VERSION_CONFLICT'
    WHEN p_error LIKE '%ACCOUNT%INVALID%' THEN 'INACTIVE_ACCOUNT'
    WHEN p_error LIKE '%SOURCE%' OR p_error LIKE '%UNSUPPORTED%'
      THEN 'INVALID_DIMENSION'
    ELSE 'MISSING_REQUIRED_FUNCTION' END;
  SELECT exception_state.id INTO v_exception_id
  FROM public.finance_posting_exceptions exception_state
  WHERE exception_state.company_id=p_company_id
    AND exception_state.financial_event_id=p_event_id
    AND exception_state.reason_code=v_reason
    AND exception_state.resolver_level=p_resolver_level
    AND exception_state.status<>'RESOLVED'
  ORDER BY exception_state.created_at DESC,exception_state.id
  LIMIT 1 FOR UPDATE;
  IF FOUND THEN
    UPDATE public.finance_posting_exceptions SET
      status='POSTING_ERROR',retry_count=retry_count+1,
      last_error=left(p_error,1000),updated_at=clock_timestamp()
    WHERE company_id=p_company_id AND id=v_exception_id;
  ELSE
    INSERT INTO public.finance_posting_exceptions(
      company_id,financial_event_id,source_table,source_id,system_key,
      transaction_category_id,reason_code,resolver_level,status,
      retry_count,last_error
    ) VALUES(
      p_company_id,p_event_id,v_event.source_table,v_event.source_id,
      v_event.system_event_key,v_event.transaction_category_id,v_reason,
      p_resolver_level,'POSTING_ERROR',1,left(p_error,1000)
    ) RETURNING id INTO v_exception_id;
  END IF;
  RETURN v_exception_id;
END
$$;

CREATE FUNCTION public.save_finance_posting_policy(
  p_master_version BIGINT,p_posting_mode TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_actor UUID:=auth.uid();
  v_company UUID:=public.private_active_company_id();
  v_mode TEXT:=upper(COALESCE(btrim(p_posting_mode),''));
  v_before JSONB;
  v_policy public.finance_company_policies%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF NOT public.private_is_super_admin(v_actor)
     AND NOT public.private_user_has_any_company_role(
       v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
     ) THEN
    RAISE EXCEPTION 'FINANCE_POSTING_POLICY_ADMIN_REQUIRED';
  END IF;
  IF v_mode NOT IN('CONTROLLED','AUTOMATIC') THEN
    RAISE EXCEPTION 'FINANCE_POSTING_MODE_INVALID';
  END IF;
  PERFORM pg_advisory_xact_lock(
    hashtextextended('FINANCE_POSTING_POLICY|'||v_company::TEXT,0)
  );
  INSERT INTO public.finance_company_policies(company_id,created_by,updated_by)
  VALUES(v_company,v_actor,v_actor) ON CONFLICT(company_id) DO NOTHING;
  SELECT policy.* INTO v_policy FROM public.finance_company_policies policy
  WHERE policy.company_id=v_company FOR UPDATE;
  IF p_master_version IS DISTINCT FROM v_policy.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_mode=v_policy.posting_mode THEN
    RETURN jsonb_build_object('periodCreationMode',v_policy.period_creation_mode,
      'postingMode',v_policy.posting_mode,'masterVersion',v_policy.master_version,
      'idempotentReplay',TRUE);
  END IF;
  IF v_mode='AUTOMATIC' AND EXISTS(
    SELECT 1 FROM public.finance_posting_queue_runs run
    WHERE run.company_id=v_company
      AND run.status IN('PREVIEWED','APPROVED','PROCESSING')
  ) THEN
    RAISE EXCEPTION 'ACTIVE_FINANCE_POSTING_QUEUE_EXISTS';
  END IF;
  v_before:=to_jsonb(v_policy);
  UPDATE public.finance_company_policies SET posting_mode=v_mode,
    master_version=master_version+1,updated_by=v_actor,
    updated_at=clock_timestamp()
  WHERE company_id=v_company RETURNING * INTO v_policy;
  INSERT INTO public.finance_company_policy_audit(
    company_id,action,actor_id,before_state,after_state
  ) VALUES(v_company,'UPDATE',v_actor,v_before,to_jsonb(v_policy));
  RETURN jsonb_build_object('periodCreationMode',v_policy.period_creation_mode,
    'postingMode',v_policy.posting_mode,'masterVersion',v_policy.master_version,
    'idempotentReplay',FALSE);
END
$$;

CREATE OR REPLACE FUNCTION public.preview_financial_event_posting_queue(
  p_limit INTEGER DEFAULT 100
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_actor UUID:=auth.uid();
  v_company UUID:=public.private_active_company_id();
  v_run_id UUID:=gen_random_uuid();
  v_run public.finance_posting_queue_runs%ROWTYPE;
  v_count INTEGER;
  v_hash TEXT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN
    RAISE EXCEPTION 'QUEUE_PREVIEW_LIMIT_INVALID';
  END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.journals_reports','REVIEW'
  );
  IF EXISTS(SELECT 1 FROM public.finance_company_policies policy
    WHERE policy.company_id=v_company AND policy.posting_mode='AUTOMATIC') THEN
    RAISE EXCEPTION 'CONTROLLED_QUEUE_DISABLED_IN_AUTOMATIC_MODE';
  END IF;
  PERFORM pg_advisory_xact_lock(
    hashtextextended('G6_FINANCE_QUEUE|'||v_company::TEXT,0)
  );
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs run
    WHERE run.company_id=v_company
      AND run.status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'ACTIVE_FINANCE_POSTING_QUEUE_ALREADY_EXISTS';
  END IF;
  INSERT INTO public.finance_posting_queue_runs(
    id,company_id,queue_no,scope_system_key,status,preview_limit,
    preview_hash,created_by
  ) VALUES(v_run_id,v_company,
    'FQ-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'
      ||upper(substr(replace(v_run_id::TEXT,'-',''),1,8)),
    'ALL_SUPPORTED','PREVIEWED',p_limit,
    md5('EMPTY|'||v_company::TEXT||'|'||v_run_id::TEXT),v_actor);
  INSERT INTO public.finance_posting_queue_items(
    company_id,queue_run_id,line_no,financial_event_id,
    event_version_snapshot,event_code_snapshot,system_event_key_snapshot,
    source_table_snapshot,source_id_snapshot,
    transaction_category_id_snapshot,event_date_snapshot
  )
  SELECT event.company_id,v_run_id,
    row_number() OVER(ORDER BY event.event_date,event.id)::INTEGER,
    event.id,event.event_version,event.event_code,event.system_event_key,
    event.source_table,event.source_id,event.transaction_category_id,
    event.event_date
  FROM public.financial_events event
  WHERE event.company_id=v_company
    AND private.f4b_financial_event_supported(event)
    AND NOT EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=event.company_id
        AND journal.financial_event_id=event.id)
  ORDER BY event.event_date,event.id LIMIT p_limit;
  GET DIAGNOSTICS v_count=ROW_COUNT;
  IF v_count=0 THEN RAISE EXCEPTION 'NO_SUPPORTED_HOLD_EVENTS'; END IF;
  SELECT md5(string_agg(item.financial_event_id::TEXT||':'
    ||item.event_version_snapshot::TEXT,'|' ORDER BY item.line_no))
  INTO v_hash FROM public.finance_posting_queue_items item
  WHERE item.company_id=v_company AND item.queue_run_id=v_run_id;
  UPDATE public.finance_posting_queue_runs SET
    previewed_event_count=v_count,preview_hash=v_hash
  WHERE company_id=v_company AND id=v_run_id RETURNING * INTO v_run;
  INSERT INTO public.finance_posting_queue_audit(
    company_id,queue_run_id,action,actor_id,after_state
  ) VALUES(v_company,v_run_id,'PREVIEW',v_actor,jsonb_build_object(
    'status',v_run.status,'masterVersion',v_run.master_version,
    'eventCount',v_count,'previewHash',v_hash,
    'scopeSystemKey','ALL_SUPPORTED'));
  RETURN jsonb_build_object('queueRunId',v_run.id,'queueNo',v_run.queue_no,
    'status',v_run.status,'masterVersion',v_run.master_version,
    'eventCount',v_count,'previewHash',v_hash,
    'scopeSystemKey','ALL_SUPPORTED');
END
$$;

CREATE OR REPLACE FUNCTION public.approve_financial_event_posting_queue(
  p_queue_run_id UUID,p_expected_master_version BIGINT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_actor UUID:=auth.uid();
  v_company UUID:=public.private_active_company_id();
  v_run public.finance_posting_queue_runs%ROWTYPE;
  v_before JSONB;
  v_stale_count BIGINT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.journals_reports','APPROVE'
  );
  SELECT run.* INTO v_run FROM public.finance_posting_queue_runs run
  WHERE run.company_id=v_company AND run.id=p_queue_run_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_NOT_FOUND'; END IF;
  IF p_expected_master_version IS DISTINCT FROM v_run.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_run.status<>'PREVIEWED' THEN
    RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_NOT_PREVIEWED';
  END IF;
  SELECT count(*) INTO v_stale_count
  FROM public.finance_posting_queue_items item
  LEFT JOIN public.financial_events event
    ON event.company_id=item.company_id AND event.id=item.financial_event_id
  WHERE item.company_id=v_company AND item.queue_run_id=v_run.id AND(
    event.id IS NULL OR NOT private.f4b_financial_event_supported(event)
    OR event.event_version<>item.event_version_snapshot
    OR event.system_event_key<>item.system_event_key_snapshot
    OR event.source_table<>item.source_table_snapshot
    OR event.source_id<>item.source_id_snapshot
    OR EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=item.company_id
        AND journal.financial_event_id=item.financial_event_id));
  IF v_stale_count<>0 THEN RAISE EXCEPTION 'QUEUE_PREVIEW_STALE'; END IF;
  v_before:=jsonb_build_object('status',v_run.status,
    'masterVersion',v_run.master_version);
  UPDATE public.finance_posting_queue_runs SET status='APPROVED',
    approved_by=v_actor,approved_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_run.id RETURNING * INTO v_run;
  INSERT INTO public.finance_posting_queue_audit(
    company_id,queue_run_id,action,actor_id,before_state,after_state
  ) VALUES(v_company,v_run.id,'APPROVE',v_actor,v_before,
    jsonb_build_object('status',v_run.status,
      'masterVersion',v_run.master_version,'previewHash',v_run.preview_hash));
  RETURN jsonb_build_object('queueRunId',v_run.id,'status',v_run.status,
    'masterVersion',v_run.master_version,
    'eventCount',v_run.previewed_event_count);
END
$$;

CREATE OR REPLACE FUNCTION public.process_financial_event_posting_queue(
  p_queue_run_id UUID,p_expected_master_version BIGINT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_actor UUID:=auth.uid();
  v_company UUID:=public.private_active_company_id();
  v_run public.finance_posting_queue_runs%ROWTYPE;
  v_item public.finance_posting_queue_items%ROWTYPE;
  v_result JSONB;
  v_error TEXT;
  v_exception_id UUID;
  v_posted INTEGER:=0;
  v_failed INTEGER:=0;
  v_skipped INTEGER:=0;
  v_stale INTEGER:=0;
  v_before JSONB;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.journals_reports','POST'
  );
  SELECT run.* INTO v_run FROM public.finance_posting_queue_runs run
  WHERE run.company_id=v_company AND run.id=p_queue_run_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_NOT_FOUND'; END IF;
  IF v_run.status IN('COMPLETED','COMPLETED_WITH_ERRORS') THEN
    RETURN jsonb_build_object('queueRunId',v_run.id,'status',v_run.status,
      'masterVersion',v_run.master_version,'postedCount',v_run.posted_count,
      'failedCount',v_run.failed_count,'skippedCount',v_run.skipped_count,
      'idempotentReplay',TRUE);
  END IF;
  IF p_expected_master_version IS DISTINCT FROM v_run.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_run.status<>'APPROVED' THEN
    RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_NOT_APPROVED';
  END IF;
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
          AND event.event_version=v_item.event_version_snapshot
          AND private.f4b_financial_event_supported(event)) THEN
        UPDATE public.finance_posting_queue_items SET status='SKIPPED',
          attempt_count=attempt_count+1,error_code='QUEUE_PREVIEW_STALE',
          error_message='Event changed after queue approval',
          processed_at=clock_timestamp()
        WHERE company_id=v_company AND id=v_item.id;
        v_skipped:=v_skipped+1;
        v_stale:=v_stale+1;
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
          UPDATE public.finance_posting_exceptions SET status='RESOLVED',
            resolved_by=v_actor,resolved_at=clock_timestamp(),
            updated_at=clock_timestamp()
          WHERE company_id=v_company
            AND financial_event_id=v_item.financial_event_id
            AND status<>'RESOLVED';
          v_posted:=v_posted+1;
        ELSE
          RAISE EXCEPTION 'UNEXPECTED_FINANCIAL_EVENT_RESULT';
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_error:=SQLERRM;
      v_exception_id:=private.f4b_record_posting_exception(
        v_company,v_item.financial_event_id,'CONTROLLED_QUEUE',v_error
      );
      UPDATE public.finance_posting_queue_items SET status='FAILED',
        attempt_count=attempt_count+1,error_code='POSTING_ERROR',
        error_message=left(v_error,1000),processed_at=clock_timestamp()
      WHERE company_id=v_company AND id=v_item.id;
      v_failed:=v_failed+1;
    END;
  END LOOP;
  UPDATE public.finance_posting_queue_runs SET status=CASE
      WHEN v_failed=0 AND v_stale=0 THEN 'COMPLETED'
      ELSE 'COMPLETED_WITH_ERRORS' END,
    posted_count=v_posted,failed_count=v_failed,skipped_count=v_skipped,
    processed_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_run.id RETURNING * INTO v_run;
  INSERT INTO public.finance_posting_queue_audit(
    company_id,queue_run_id,action,actor_id,before_state,after_state
  ) VALUES(v_company,v_run.id,'PROCESS',v_actor,v_before,
    jsonb_build_object('status',v_run.status,
      'masterVersion',v_run.master_version,'postedCount',v_posted,
      'failedCount',v_failed,'skippedCount',v_skipped,
      'staleCount',v_stale));
  RETURN jsonb_build_object('queueRunId',v_run.id,'status',v_run.status,
    'masterVersion',v_run.master_version,'postedCount',v_posted,
    'failedCount',v_failed,'skippedCount',v_skipped,
    'idempotentReplay',FALSE);
END
$$;

CREATE FUNCTION public.process_automatic_financial_events(
  p_limit INTEGER DEFAULT 100
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_actor UUID:=auth.uid();
  v_company UUID:=public.private_active_company_id();
  v_event public.financial_events%ROWTYPE;
  v_result JSONB;
  v_error TEXT;
  v_scanned INTEGER:=0;
  v_posted INTEGER:=0;
  v_failed INTEGER:=0;
  v_skipped INTEGER:=0;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN
    RAISE EXCEPTION 'AUTOMATIC_POSTING_LIMIT_INVALID';
  END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.journals_reports','POST'
  );
  IF NOT EXISTS(SELECT 1 FROM public.finance_company_policies policy
    WHERE policy.company_id=v_company AND policy.posting_mode='AUTOMATIC') THEN
    RAISE EXCEPTION 'FINANCE_AUTOMATIC_POSTING_DISABLED';
  END IF;
  PERFORM pg_advisory_xact_lock(
    hashtextextended('FINANCE_AUTOMATIC_POSTING|'||v_company::TEXT,0)
  );
  FOR v_event IN SELECT event.* FROM public.financial_events event
    WHERE event.company_id=v_company
      AND private.f4b_financial_event_supported(event)
      AND NOT EXISTS(SELECT 1 FROM public.finance_journals journal
        WHERE journal.company_id=event.company_id
          AND journal.financial_event_id=event.id)
    ORDER BY event.event_date,event.id LIMIT p_limit FOR UPDATE SKIP LOCKED
  LOOP
    v_scanned:=v_scanned+1;
    BEGIN
      v_result:=private.post_financial_event_core(v_company,v_event.id,
        v_event.event_version,v_actor);
      IF v_result->>'status'='POSTED'
         AND NULLIF(v_result->>'journalId','') IS NOT NULL THEN
        UPDATE public.finance_posting_exceptions SET status='RESOLVED',
          resolved_by=v_actor,resolved_at=clock_timestamp(),
          updated_at=clock_timestamp()
        WHERE company_id=v_company AND financial_event_id=v_event.id
          AND status<>'RESOLVED';
        v_posted:=v_posted+1;
      ELSIF v_result->>'status'='CANCELED'
         AND v_result->>'reason'='NO_FINANCIAL_EFFECT' THEN
        v_skipped:=v_skipped+1;
      ELSE
        RAISE EXCEPTION 'UNEXPECTED_FINANCIAL_EVENT_RESULT';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_error:=SQLERRM;
      PERFORM private.f4b_record_posting_exception(
        v_company,v_event.id,'AUTOMATIC_POSTING',v_error
      );
      v_failed:=v_failed+1;
    END;
  END LOOP;
  RETURN jsonb_build_object('companyId',v_company,'scannedCount',v_scanned,
    'postedCount',v_posted,'failedCount',v_failed,
    'skippedCount',v_skipped);
END
$$;

CREATE FUNCTION private.trg_f4b_automatic_financial_event()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_event public.financial_events%ROWTYPE;
  v_actor UUID;
  v_result JSONB;
  v_error TEXT;
BEGIN
  SELECT event.* INTO v_event FROM public.financial_events event
  WHERE event.company_id=NEW.company_id AND event.id=NEW.id FOR UPDATE;
  IF NOT FOUND OR NOT private.f4b_financial_event_supported(v_event) THEN
    RETURN NEW;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.finance_company_policies policy
    WHERE policy.company_id=v_event.company_id
      AND policy.posting_mode='AUTOMATIC') THEN
    RETURN NEW;
  END IF;
  v_actor:=COALESCE(v_event.created_by,auth.uid());
  IF v_actor IS NULL THEN
    PERFORM private.f4b_record_posting_exception(v_event.company_id,
      v_event.id,'AUTOMATIC_POSTING','AUTOMATIC_POSTING_ACTOR_REQUIRED');
    RETURN NEW;
  END IF;
  BEGIN
    v_result:=private.post_financial_event_core(v_event.company_id,v_event.id,
      v_event.event_version,v_actor);
    IF NOT (v_result->>'status'='POSTED'
      OR (v_result->>'status'='CANCELED'
        AND v_result->>'reason'='NO_FINANCIAL_EFFECT')) THEN
      RAISE EXCEPTION 'UNEXPECTED_FINANCIAL_EVENT_RESULT';
    END IF;
    UPDATE public.finance_posting_exceptions SET status='RESOLVED',
      resolved_by=v_actor,resolved_at=clock_timestamp(),
      updated_at=clock_timestamp()
    WHERE company_id=v_event.company_id AND financial_event_id=v_event.id
      AND status<>'RESOLVED';
  EXCEPTION WHEN OTHERS THEN
    v_error:=SQLERRM;
    PERFORM private.f4b_record_posting_exception(v_event.company_id,
      v_event.id,'AUTOMATIC_POSTING',v_error);
  END;
  RETURN NEW;
END
$$;

CREATE CONSTRAINT TRIGGER financial_event_automatic_posting
AFTER INSERT ON public.financial_events
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION private.trg_f4b_automatic_financial_event();

REVOKE ALL ON FUNCTION
  private.f4b_financial_event_supported(public.financial_events),
  private.f4b_record_posting_exception(UUID,UUID,TEXT,TEXT),
  private.trg_f4b_automatic_financial_event()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.f4b_financial_event_supported(public.financial_events),
  private.f4b_record_posting_exception(UUID,UUID,TEXT,TEXT),
  private.trg_f4b_automatic_financial_event()
TO service_role;

REVOKE ALL ON FUNCTION
  public.save_finance_posting_policy(BIGINT,TEXT),
  public.process_automatic_financial_events(INTEGER)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.save_finance_posting_policy(BIGINT,TEXT),
  public.process_automatic_financial_events(INTEGER)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260827140000','finance_posting_policy_closure',
  'Adds Owner/Admin controlled posting policy, deferred automatic final-event posting, canonical all-contract controlled queue, exception retry trace, and leaves existing HOLD untouched');

COMMIT;
