-- G6 phase 8C: controlled preview/approval/process queue for Sale + Return.
-- Migration installs authority only; it creates no run and posts no Event.

BEGIN;
DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260814120000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Phase 8B mapping fix required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260814130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260814130000';
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
    scope_system_key IN('STOCK_OPENING','SALE_RETURN'));

CREATE FUNCTION public.preview_sale_return_posting_queue(
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
    'SALE_RETURN','PREVIEWED',p_limit,md5('EMPTY|'||v_company||'|'||v_run_id),v_actor);

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
    AND ((event.system_event_key='SALE_POSTED' AND event.event_type::TEXT='SALE_POSTED'
      AND event.source_table='sales_headers' AND EXISTS(SELECT 1
        FROM public.sales_headers sale WHERE sale.company_id=event.company_id
          AND sale.id=event.source_id AND sale.document_status='POSTED'))
      OR (event.system_event_key='SALES_RETURN' AND event.event_type::TEXT='SALES_REFUND'
      AND event.source_table='sales_return_documents' AND EXISTS(SELECT 1
        FROM public.sales_return_documents document
        WHERE document.company_id=event.company_id AND document.id=event.source_id
          AND document.status='POSTED' AND document.financial_event_id=event.id)))
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
      'eventCount',v_count,'previewHash',v_hash,'scopeSystemKey','SALE_RETURN'));
  RETURN jsonb_build_object('queueRunId',v_run.id,'queueNo',v_run.queue_no,
    'status',v_run.status,'masterVersion',v_run.master_version,
    'eventCount',v_count,'previewHash',v_hash,'scopeSystemKey','SALE_RETURN');
END
$$;

REVOKE ALL ON FUNCTION public.preview_sale_return_posting_queue(INTEGER)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.preview_sale_return_posting_queue(INTEGER)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260814130000','g6_phase8c_sale_return_controlled_queue',
  'Adds explicit immutable SALE_RETURN controlled queue preview while reusing audited approval/process and atomic event dispatcher; migration posts nothing');
COMMIT;
