-- Direct POS Retail Return/refund finalization.
-- Backoffice process mode and historical REQUIRED Drafts remain unchanged.
BEGIN;
SET LOCAL lock_timeout='5s';

DO $guard$
DECLARE v_definition text;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations WHERE version IN(
      '20260829110000','20260908100000','20260909162000'))<>3 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return/process dependency chain incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261102100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261102100000';
  END IF;
  IF to_regprocedure('private.acp5h_post_sales_return_core(uuid,bigint,uuid)') IS NULL
    OR to_regprocedure('public.save_sales_return_draft_with_delivery_fee(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb,boolean)') IS NULL
    OR to_regclass('public.company_sales_process_settings') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Return runtime incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='sales_return_documents'
        AND column_name='direct_pos_request_hash')
    OR to_regprocedure('public.submit_pos_sales_return_with_delivery_fee(uuid,uuid,text,text,jsonb,jsonb,boolean,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: direct POS Return runtime collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  SELECT pg_get_functiondef(
    'private.acp5h_post_sales_return_core(uuid,bigint,uuid)'::regprocedure)
    INTO v_definition;
  IF v_definition NOT LIKE '%SALES_RETURN_APPROVER_REQUIRED%'
    OR v_definition NOT LIKE '%odr6d_returnable_sales_detail_quantity%'
    OR v_definition NOT LIKE '%sales_dispatch_allocations%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Return Post core anchor changed';
  END IF;
END
$guard$;

ALTER TABLE public.sales_return_documents
  ADD COLUMN direct_pos_request_hash text,
  ADD CONSTRAINT sales_return_documents_direct_pos_request_hash_check CHECK(
    direct_pos_request_hash IS NULL OR (
      approval_mode_snapshot='OPTIONAL'
      AND direct_pos_request_hash~'^[0-9a-f]{64}$'
    )
  );

COMMENT ON COLUMN public.sales_return_documents.direct_pos_request_hash IS
  'Exact request hash for one-step POS Retail Return/refund retry ownership; NULL for Backoffice and historical flows.';

-- Extend only the canonical authorization predicate. All Stock/FIFO/refund/
-- Finance behavior continues through the already-patched canonical core.
DO $patch$
DECLARE
  v_definition text;
  v_start integer;
  v_end integer;
  v_marker text:=') THEN RAISE EXCEPTION ''SALES_RETURN_APPROVER_REQUIRED''; END IF;';
  v_replacement text:=$body$IF NOT (
        (
          v_document.approval_mode_snapshot='OPTIONAL'
          AND v_document.direct_pos_request_hash IS NOT NULL
          AND v_document.created_by=v_actor
          AND EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
            WHERE setting.company_id=v_company
              AND setting.active_mode='RETAIL_CONFIRM_INVOICE')
          AND EXISTS(SELECT 1 FROM public.sales_headers source_sale
            WHERE source_sale.company_id=v_company
              AND source_sale.id=v_document.source_sales_id
              AND source_sale.sales_origin='POS'
              AND source_sale.sales_process_mode='RETAIL_CONFIRM_INVOICE')
          AND EXISTS(SELECT 1 FROM public.cashier_sessions actor_session
            WHERE actor_session.company_id=v_company
              AND actor_session.id=v_document.executing_session_id
              AND actor_session.cashier_id=v_actor
              AND actor_session.store_id=v_document.store_id
              AND actor_session.status='OPEN'::public.session_status)
        )
        OR public.private_user_has_any_company_role(
            v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
        )
        OR public.private_user_has_any_store_role(
            v_document.store_id,ARRAY['STORE_MANAGER']::TEXT[]
        )
    ) THEN RAISE EXCEPTION 'SALES_RETURN_APPROVER_REQUIRED'; END IF;$body$;
BEGIN
  SELECT pg_get_functiondef(
    'private.acp5h_post_sales_return_core(uuid,bigint,uuid)'::regprocedure)
    INTO v_definition;
  v_start:=strpos(v_definition,'IF NOT (');
  v_end:=strpos(v_definition,v_marker);
  IF v_start=0 OR v_end=0 OR v_end<v_start
    OR (length(v_definition)-length(replace(v_definition,
      'SALES_RETURN_APPROVER_REQUIRED','')))/length('SALES_RETURN_APPROVER_REQUIRED')<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return approver predicate anchor changed';
  END IF;
  v_definition:=substr(v_definition,1,v_start-1)||v_replacement||
    substr(v_definition,v_end+length(v_marker));
  EXECUTE v_definition;
END
$patch$;

CREATE FUNCTION public.submit_pos_sales_return_with_delivery_fee(
  p_source_sales_id uuid,
  p_executing_session_id uuid,
  p_rounding_direction text,
  p_notes text,
  p_lines jsonb,
  p_refunds jsonb,
  p_refund_delivery_fee boolean,
  p_operation_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();
  v_actor uuid:=auth.uid();
  v_setting public.company_sales_process_settings%rowtype;
  v_sale public.sales_headers%rowtype;
  v_existing public.sales_return_documents%rowtype;
  v_created public.sales_return_documents%rowtype;
  v_saved jsonb;
  v_result jsonb;
  v_hash text;
  v_direct boolean;
  v_before jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_operation_id IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF p_source_sales_id IS NULL OR p_executing_session_id IS NULL
    OR p_lines IS NULL OR p_refunds IS NULL THEN
    RAISE EXCEPTION 'SALES_RETURN_INPUT_REQUIRED';
  END IF;

  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'sourceSalesId',p_source_sales_id,
    'executingSessionId',p_executing_session_id,
    'roundingDirection',p_rounding_direction,
    'notes',nullif(btrim(coalesce(p_notes,'')),''),
    'lines',p_lines,
    'refunds',p_refunds,
    'refundDeliveryFee',coalesce(p_refund_delivery_fee,false)
  )::text,'UTF8'),'sha256'),'hex');

  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':POS_RETURN:'||p_operation_id::text,0));

  SELECT document.* INTO v_existing
  FROM public.sales_return_documents document
  WHERE document.company_id=v_company
    AND document.posting_idempotency_key=p_operation_id;
  IF FOUND THEN
    IF v_existing.created_by IS DISTINCT FROM v_actor
      OR v_existing.direct_pos_request_hash IS DISTINCT FROM v_hash THEN
      RAISE EXCEPTION 'POS_SALES_RETURN_CHANGED_RETRY';
    END IF;
    RETURN jsonb_build_object(
      'documentId',v_existing.id,'returnNo',v_existing.return_no,
      'status',v_existing.status,'masterVersion',v_existing.master_version,
      'financialEventId',v_existing.financial_event_id,
      'refundTotal',v_existing.refund_total,'approvalMode',
      v_existing.approval_mode_snapshot,'idempotentReplay',true
    );
  END IF;

  SELECT setting.* INTO v_setting
  FROM public.company_sales_process_settings setting
  WHERE setting.company_id=v_company FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_PROCESS_SETTING_NOT_FOUND'; END IF;

  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=p_source_sales_id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RETURN_SOURCE_SALE_NOT_FOUND'; END IF;

  v_direct:=v_setting.active_mode='RETAIL_CONFIRM_INVOICE'
    AND v_sale.sales_origin='POS'
    AND v_sale.sales_process_mode='RETAIL_CONFIRM_INVOICE';

  v_saved:=public.save_sales_return_draft_with_delivery_fee(
    NULL,NULL,p_source_sales_id,p_executing_session_id,p_rounding_direction,
    p_notes,p_lines,p_refunds,coalesce(p_refund_delivery_fee,false));

  IF NOT v_direct THEN
    RETURN v_saved||jsonb_build_object(
      'status','DRAFT','approvalMode','REQUIRED','idempotentReplay',false);
  END IF;

  SELECT document.* INTO STRICT v_created
  FROM public.sales_return_documents document
  WHERE document.company_id=v_company
    AND document.id=(v_saved->>'documentId')::uuid FOR UPDATE;
  IF v_created.created_by IS DISTINCT FROM v_actor
    OR v_created.source_sales_id IS DISTINCT FROM p_source_sales_id
    OR v_created.executing_session_id IS DISTINCT FROM p_executing_session_id
    OR v_created.status<>'DRAFT' THEN
    RAISE EXCEPTION 'POS_SALES_RETURN_DRAFT_OWNERSHIP_INVALID';
  END IF;

  v_before:=to_jsonb(v_created);
  UPDATE public.sales_return_documents SET
    approval_mode_snapshot='OPTIONAL',direct_pos_request_hash=v_hash,
    updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_created.id;
  INSERT INTO public.sales_return_audit(
    company_id,document_id,action,actor_id,before_state,after_state
  ) SELECT v_company,v_created.id,'UPDATE_DRAFT',v_actor,
    v_before,to_jsonb(document)
  FROM public.sales_return_documents document
  WHERE document.company_id=v_company AND document.id=v_created.id;

  v_result:=private.acp5h_post_sales_return_core(
    v_created.id,(v_saved->>'masterVersion')::bigint,p_operation_id);
  RETURN v_result||jsonb_build_object(
    'approvalMode','OPTIONAL','idempotentReplay',false);
END
$$;

REVOKE ALL ON FUNCTION public.submit_pos_sales_return_with_delivery_fee(
  uuid,uuid,text,text,jsonb,jsonb,boolean,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.submit_pos_sales_return_with_delivery_fee(
  uuid,uuid,text,text,jsonb,jsonb,boolean,uuid) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261102100000','pos_retail_direct_sales_return_refund',
  'Atomically save and finalize direct POS Retail Return/refund while preserving Backoffice REQUIRED approval, canonical Stock/FIFO/Finance and exact retry');

NOTIFY pgrst,'reload schema';
COMMIT;
