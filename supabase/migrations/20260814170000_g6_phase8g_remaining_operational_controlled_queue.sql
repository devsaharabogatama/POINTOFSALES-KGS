-- G6 phase 8G: controlled queue for the seven remaining operational events.
-- Migration installs preview authority only; it creates no run and posts no Event.

BEGIN;
DO $guard$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
  WHERE version='20260814160000') THEN
  RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Phase 8F runtime required'; END IF;
 IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
  WHERE version='20260814170000') THEN
  RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260814170000'; END IF;
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
  scope_system_key IN(
   'STOCK_OPENING','SALE_RETURN','PURCHASE_AP','REMAINING_OPERATIONAL'));

CREATE FUNCTION public.preview_remaining_operational_posting_queue(
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
  'REMAINING_OPERATIONAL','PREVIEWED',p_limit,
  md5('EMPTY|'||v_company||'|'||v_run_id),v_actor);

 INSERT INTO public.finance_posting_queue_items(company_id,queue_run_id,line_no,
  financial_event_id,event_version_snapshot,event_code_snapshot,
  system_event_key_snapshot,source_table_snapshot,source_id_snapshot,
  transaction_category_id_snapshot,event_date_snapshot)
 SELECT event.company_id,v_run_id,
  row_number() OVER(ORDER BY CASE event.system_event_key
   WHEN 'STOCK_GAIN' THEN 1 WHEN 'EXPENSE_DISBURSEMENT' THEN 2
   WHEN 'CASH_DEPOSIT' THEN 3 ELSE 4 END,event.event_date,event.id)::INTEGER,
  event.id,event.event_version,event.event_code,event.system_event_key,
  event.source_table,event.source_id,event.transaction_category_id,event.event_date
 FROM public.financial_events event
 WHERE event.company_id=v_company AND event.status='HOLD'::public.event_status
  AND (
   (event.system_event_key='STOCK_GAIN' AND event.event_type::TEXT='STOCK_GAIN'
    AND event.source_table='stock_adjustment_documents'
    AND EXISTS(SELECT 1 FROM public.stock_adjustment_documents document
     WHERE document.company_id=event.company_id AND document.id=event.source_id
      AND document.status='POSTED' AND document.gain_financial_event_id=event.id))
   OR (event.system_event_key='EXPENSE_DISBURSEMENT'
    AND event.event_type::TEXT='EXPENSE_DISBURSEMENT'
    AND event.source_table='expense_disbursements'
    AND EXISTS(SELECT 1 FROM public.expense_disbursements disbursement
     JOIN public.expense_documents document
      ON document.company_id=disbursement.company_id
       AND document.id=disbursement.document_id
     WHERE disbursement.company_id=event.company_id
      AND disbursement.id=event.source_id
      AND disbursement.financial_event_id=event.id
      AND document.status IN(
       'DISBURSED','PARTIALLY_SETTLED','SETTLED','SETTLED_NO_EXPENSE')))
   OR (event.system_event_key='CASH_DEPOSIT'
    AND event.event_type::TEXT='BANK_DEPOSIT'
    AND event.source_table='cash_deposit_documents'
    AND EXISTS(SELECT 1 FROM public.cash_deposit_documents document
     WHERE document.company_id=event.company_id AND document.id=event.source_id
      AND document.status='APPROVED' AND document.financial_event_id=event.id))
   OR (event.system_event_key='CASH_VARIANCE'
    AND event.event_type::TEXT='DEPOSIT_VARIANCE_RESOLUTION'
    AND event.source_table='deposit_variance_resolution_requests'
    AND EXISTS(SELECT 1 FROM public.deposit_variance_resolution_requests request
     WHERE request.company_id=event.company_id AND request.id=event.source_id
      AND request.status='APPROVED' AND request.financial_event_id=event.id))
  )
  AND NOT EXISTS(SELECT 1 FROM public.finance_journals journal
   WHERE journal.company_id=event.company_id AND journal.financial_event_id=event.id)
 ORDER BY CASE event.system_event_key WHEN 'STOCK_GAIN' THEN 1
  WHEN 'EXPENSE_DISBURSEMENT' THEN 2 WHEN 'CASH_DEPOSIT' THEN 3 ELSE 4 END,
  event.event_date,event.id LIMIT p_limit;
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
   'eventCount',v_count,'previewHash',v_hash,
   'scopeSystemKey','REMAINING_OPERATIONAL'));
 RETURN jsonb_build_object('queueRunId',v_run.id,'queueNo',v_run.queue_no,
  'status',v_run.status,'masterVersion',v_run.master_version,
  'eventCount',v_count,'previewHash',v_hash,
  'scopeSystemKey','REMAINING_OPERATIONAL');
END
$$;

REVOKE ALL ON FUNCTION public.preview_remaining_operational_posting_queue(INTEGER)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.preview_remaining_operational_posting_queue(INTEGER)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260814170000','g6_phase8g_remaining_operational_controlled_queue',
 'Adds immutable final-source-only preview for the seven remaining operational HOLD events while reusing audited approval and atomic processing; migration posts nothing');
COMMIT;
