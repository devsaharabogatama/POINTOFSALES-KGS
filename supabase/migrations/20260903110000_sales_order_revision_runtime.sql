-- Atomic pre-dispatch Sales Order replacement runtime.
BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended(
  '20260903110000_sales_order_revision_runtime',0));

DO $guard$
DECLARE v_confirm TEXT;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260903110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260903110000';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260903100000')
    OR to_regclass('public.sales_order_revisions') IS NULL
    OR to_regprocedure(
      'public.confirm_pos_sales_order(uuid,bigint,uuid,text)') IS NULL
    OR to_regprocedure(
      'public.cancel_pos_sales_order(uuid,bigint,uuid,text)') IS NULL
    OR to_regprocedure(
      'public.cancel_pos_sale_draft(uuid,bigint,uuid,text)') IS NULL
    OR to_regprocedure(
      'public.save_pos_sale_draft_with_pricelist(jsonb)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: revision foundation and canonical POS runtime required';
  END IF;
  IF to_regprocedure(
      'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)') IS NOT NULL
    OR to_regprocedure(
      'private.cancel_pos_sale_draft_before_revision_core(uuid,bigint,uuid,text)') IS NOT NULL
    OR to_regprocedure(
      'private.cancel_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: revision core name collision';
  END IF;
  SELECT pg_get_functiondef(
    'public.confirm_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure)
    INTO v_confirm;
  IF v_confirm!~'ensure_confirmed_order_invoice_identity'
    OR v_confirm!~'ensure_confirmed_order_documents'
    OR v_confirm!~'capture_sales_order_payment_requests' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Confirm composition drift';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
END
$guard$;

ALTER FUNCTION public.confirm_pos_sales_order(UUID,BIGINT,UUID,TEXT)
  RENAME TO confirm_pos_sales_order_before_revision_core;
ALTER FUNCTION public.confirm_pos_sales_order_before_revision_core(
  UUID,BIGINT,UUID,TEXT) SET SCHEMA private;

ALTER FUNCTION public.cancel_pos_sale_draft(UUID,BIGINT,UUID,TEXT)
  RENAME TO cancel_pos_sale_draft_before_revision_core;
ALTER FUNCTION public.cancel_pos_sale_draft_before_revision_core(
  UUID,BIGINT,UUID,TEXT) SET SCHEMA private;

ALTER FUNCTION public.cancel_pos_sales_order(UUID,BIGINT,UUID,TEXT)
  RENAME TO cancel_pos_sales_order_before_revision_core;
ALTER FUNCTION public.cancel_pos_sales_order_before_revision_core(
  UUID,BIGINT,UUID,TEXT) SET SCHEMA private;

CREATE FUNCTION public.start_pos_sales_order_revision(
  p_source_sales_id UUID,
  p_source_master_version BIGINT,
  p_cashier_session_id UUID,
  p_idempotency_key UUID,
  p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_source public.sales_headers%ROWTYPE;
  v_reservation public.sales_stock_reservations%ROWTYPE;
  v_revision public.sales_order_revisions%ROWTYPE;
  v_payload JSONB;v_draft JSONB;v_replacement public.sales_headers%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_source_sales_id IS NULL OR p_source_master_version IS NULL
    OR p_cashier_session_id IS NULL OR p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_CONTEXT_REQUIRED';
  END IF;
  IF NULLIF(btrim(p_reason),'') IS NULL OR length(btrim(p_reason))>500 THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_REASON_REQUIRED';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::TEXT||':sales-order-revision:'||p_idempotency_key::TEXT,0));

  SELECT revision.* INTO v_revision
  FROM public.sales_order_revisions revision
  WHERE revision.company_id=v_company
    AND revision.start_idempotency_key=p_idempotency_key;
  IF FOUND THEN
    IF v_revision.source_sales_id IS DISTINCT FROM p_source_sales_id
      OR v_revision.source_master_version_at_start IS DISTINCT FROM
        p_source_master_version
      OR v_revision.reason IS DISTINCT FROM btrim(p_reason)
      OR NOT EXISTS(SELECT 1 FROM public.sales_headers sale
        WHERE sale.company_id=v_company
          AND sale.id=v_revision.replacement_sales_id
          AND sale.created_session_id=p_cashier_session_id) THEN
      RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    SELECT sale.* INTO v_replacement FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=v_revision.replacement_sales_id;
    RETURN jsonb_build_object('revisionId',v_revision.id,
      'sourceSalesId',v_revision.source_sales_id,
      'replacementSalesId',v_revision.replacement_sales_id,
      'replacementDraftNo',v_replacement.draft_no,
      'replacementMasterVersion',v_replacement.master_version,
      'status',v_revision.status,'idempotentReplay',TRUE);
  END IF;

  SELECT sale.* INTO v_source FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=p_source_sales_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_NOT_FOUND'; END IF;
  IF v_source.master_version IS DISTINCT FROM p_source_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_source.document_status<>'DRAFT'
    OR v_source.order_runtime_status NOT IN('CONFIRMED','RESERVED') THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_NOT_ELIGIBLE';
  END IF;
  SELECT reservation.* INTO v_reservation
  FROM public.sales_stock_reservations reservation
  WHERE reservation.company_id=v_company
    AND reservation.sales_id=p_source_sales_id FOR UPDATE;
  IF NOT FOUND OR v_reservation.status<>'OPEN'
    OR v_reservation.total_dispatched_base_qty<>0 THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_DISPATCH_STARTED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
    WHERE request.company_id=v_company AND request.sales_id=p_source_sales_id
      AND request.status='VERIFIED') THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_VERIFIED_PAYMENT';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=v_company AND session.id=p_cashier_session_id
      AND session.cashier_id=v_actor
      AND session.status='OPEN'::public.session_status
      AND session.store_id=v_source.store_id) THEN
    RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_order_revisions revision
    WHERE revision.company_id=v_company
      AND revision.source_sales_id=p_source_sales_id
      AND revision.status='PENDING') THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_ALREADY_PENDING';
  END IF;

  v_payload:=(COALESCE(v_source.payload_snapshot,'{}'::JSONB)
      -'saleId'-'masterVersion'-'payments'-'draftLabel'-'draftNotes'
      -'revisionId'-'revisionSourceSalesId'-'revisionSourceOrderNo')
    ||jsonb_build_object('clientTransactionId',p_idempotency_key,
      'cashierSessionId',p_cashier_session_id,'payments','[]'::JSONB,
      'draftLabel','Revisi '||v_source.draft_no,
      'draftNotes',btrim(p_reason),
      'revisionSourceSalesId',v_source.id,
      'revisionSourceOrderNo',v_source.draft_no);
  v_draft:=public.save_pos_sale_draft_with_pricelist(v_payload);

  UPDATE public.sales_headers SET is_revision=TRUE,
    original_invoice_no=v_source.invoice_no,
    payload_snapshot=payload_snapshot||jsonb_build_object(
      'revisionSourceSalesId',v_source.id,
      'revisionSourceOrderNo',v_source.draft_no),
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=(v_draft->>'salesId')::UUID
  RETURNING * INTO v_replacement;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_REVISION_DRAFT_NOT_FOUND'; END IF;

  INSERT INTO public.sales_order_revisions(company_id,source_sales_id,
    replacement_sales_id,reason,source_master_version_at_start,
    start_idempotency_key,started_by)
  VALUES(v_company,v_source.id,v_replacement.id,btrim(p_reason),
    v_source.master_version,p_idempotency_key,v_actor)
  RETURNING * INTO v_revision;
  INSERT INTO public.sales_order_revision_audit(company_id,revision_id,action,
    actor_id,idempotency_key,after_state)
  VALUES(v_company,v_revision.id,'START',v_actor,p_idempotency_key,
    jsonb_build_object('sourceSalesId',v_source.id,
      'sourceOrderNo',v_source.draft_no,
      'replacementSalesId',v_replacement.id,
      'replacementDraftNo',v_replacement.draft_no,
      'sourceMasterVersion',v_source.master_version,
      'replacementMasterVersion',v_replacement.master_version,
      'reason',v_revision.reason));
  RETURN v_draft||jsonb_build_object('revisionId',v_revision.id,
    'sourceSalesId',v_source.id,'sourceOrderNo',v_source.draft_no,
    'replacementSalesId',v_replacement.id,
    'replacementDraftNo',v_replacement.draft_no,
    'replacementMasterVersion',v_replacement.master_version,
    'status','PENDING','idempotentReplay',FALSE);
END
$$;

CREATE FUNCTION public.cancel_pos_sale_draft(
  p_sales_id UUID,p_master_version BIGINT,p_cashier_session_id UUID,
  p_reason TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_result JSONB;v_revision public.sales_order_revisions%ROWTYPE;
  v_sale public.sales_headers%ROWTYPE;v_before JSONB;
  v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
  SELECT revision.* INTO v_revision FROM public.sales_order_revisions revision
  WHERE revision.company_id=v_company
    AND revision.replacement_sales_id=p_sales_id
    AND revision.status='PENDING' FOR UPDATE;
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND OR v_sale.document_status<>'DRAFT'
    OR v_sale.order_runtime_status NOT IN('DRAFT_INPUT','SCHEDULED') THEN
    RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND';
  END IF;
  IF v_sale.master_version IS DISTINCT FROM p_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=v_company AND session.id=p_cashier_session_id
      AND session.cashier_id=v_actor
      AND session.status='OPEN'::public.session_status
      AND session.store_id=v_sale.store_id) THEN
    RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
  END IF;
  IF v_sale.edit_lock_owner_id IS DISTINCT FROM v_actor
    OR v_sale.edit_lock_session_id IS DISTINCT FROM p_cashier_session_id
    OR v_sale.edit_lock_heartbeat_at<v_now-interval '5 minutes' THEN
    RAISE EXCEPTION 'SALE_DRAFT_EDIT_LOCK_REQUIRED';
  END IF;
  UPDATE public.sales_headers SET document_status='CANCELED',
    order_runtime_status='CANCELED',canceled_at=v_now,canceled_by=v_actor,
    cancel_reason=NULLIF(btrim(p_reason),''),edit_lock_owner_id=NULL,
    edit_lock_session_id=NULL,edit_lock_acquired_at=NULL,
    edit_lock_heartbeat_at=NULL,master_version=master_version+1,
    updated_at=v_now
  WHERE company_id=v_company AND id=p_sales_id;
  INSERT INTO public.sale_master_audit(company_id,sales_id,action,actor_id,
    before_state,after_state)
  VALUES(v_company,p_sales_id,'CANCEL_DRAFT',v_actor,to_jsonb(v_sale),
    jsonb_build_object('documentStatus','CANCELED',
      'orderRuntimeStatus','CANCELED','canceledAt',v_now,
      'reason',NULLIF(btrim(p_reason),''),
      'masterVersion',v_sale.master_version+1));
  v_result:=jsonb_build_object('salesId',p_sales_id,
    'documentStatus','CANCELED','orderRuntimeStatus','CANCELED',
    'masterVersion',v_sale.master_version+1);
  IF v_revision.id IS NOT NULL THEN
    v_before:=to_jsonb(v_revision);
    PERFORM set_config('kgs.sales_order_revision_mutation','1',TRUE);
    UPDATE public.sales_order_revisions SET status='ABANDONED',
      abandoned_by=v_actor,abandoned_at=clock_timestamp(),
      abandoned_reason=COALESCE(NULLIF(btrim(p_reason),''),
        'Draft revisi dibatalkan')
    WHERE company_id=v_company AND id=v_revision.id
    RETURNING * INTO v_revision;
    PERFORM set_config('kgs.sales_order_revision_mutation','',TRUE);
    INSERT INTO public.sales_order_revision_audit(company_id,revision_id,
      action,actor_id,before_state,after_state)
    VALUES(v_company,v_revision.id,'ABANDON',v_actor,v_before,
      to_jsonb(v_revision));
    v_result:=v_result||jsonb_build_object('revisionId',v_revision.id,
      'revisionStatus','ABANDONED');
  END IF;
  RETURN v_result;
END
$$;

CREATE FUNCTION public.cancel_pos_sales_order(
  p_sales_id UUID,p_master_version BIGINT,p_idempotency_key UUID,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM 1 FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_NOT_FOUND'; END IF;
  IF COALESCE(current_setting('kgs.sales_order_revision_apply',TRUE),'')<>'1'
    AND EXISTS(SELECT 1 FROM public.sales_order_revisions revision
      WHERE revision.company_id=v_company
        AND revision.source_sales_id=p_sales_id
        AND revision.status='PENDING') THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_PENDING';
  END IF;
  RETURN private.cancel_pos_sales_order_before_revision_core(
    p_sales_id,p_master_version,p_idempotency_key,p_reason);
END
$$;

CREATE FUNCTION public.confirm_pos_sales_order(
  p_sales_id UUID,p_master_version BIGINT,p_idempotency_key UUID,
  p_negative_stock_reason TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_revision public.sales_order_revisions%ROWTYPE;
  v_source public.sales_headers%ROWTYPE;v_replacement public.sales_headers%ROWTYPE;
  v_reservation public.sales_stock_reservations%ROWTYPE;
  v_cancel JSONB;v_result JSONB;v_before JSONB;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT revision.* INTO v_revision FROM public.sales_order_revisions revision
  WHERE revision.company_id=v_company
    AND revision.replacement_sales_id=p_sales_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN private.confirm_pos_sales_order_before_revision_core(
      p_sales_id,p_master_version,p_idempotency_key,p_negative_stock_reason);
  END IF;
  IF v_revision.status='APPLIED' THEN
    IF v_revision.apply_idempotency_key IS DISTINCT FROM p_idempotency_key THEN
      RAISE EXCEPTION 'SALES_ORDER_REVISION_ALREADY_APPLIED';
    END IF;
    SELECT sale.* INTO v_replacement FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=p_sales_id;
    RETURN jsonb_build_object('salesId',p_sales_id,
      'orderRuntimeStatus',v_replacement.order_runtime_status,
      'invoiceNo',v_replacement.invoice_no,'revisionId',v_revision.id,
      'revisionStatus','APPLIED','replacesSalesId',v_revision.source_sales_id,
      'idempotentReplay',TRUE);
  END IF;
  IF v_revision.status<>'PENDING' THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_NOT_PENDING';
  END IF;
  SELECT sale.* INTO v_replacement FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND OR v_replacement.document_status<>'DRAFT'
    OR v_replacement.order_runtime_status NOT IN('DRAFT_INPUT','SCHEDULED') THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_DRAFT_INVALID';
  END IF;
  IF v_replacement.master_version IS DISTINCT FROM p_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  SELECT sale.* INTO v_source FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=v_revision.source_sales_id
  FOR UPDATE;
  IF NOT FOUND OR v_source.master_version IS DISTINCT FROM
      v_revision.source_master_version_at_start
    OR v_source.document_status<>'DRAFT'
    OR v_source.order_runtime_status NOT IN('CONFIRMED','RESERVED') THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_SOURCE_CHANGED';
  END IF;
  SELECT reservation.* INTO v_reservation
  FROM public.sales_stock_reservations reservation
  WHERE reservation.company_id=v_company AND reservation.sales_id=v_source.id
  FOR UPDATE;
  IF NOT FOUND OR v_reservation.status<>'OPEN'
    OR v_reservation.total_dispatched_base_qty<>0 THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_DISPATCH_STARTED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
    WHERE request.company_id=v_company AND request.sales_id=v_source.id
      AND request.status='VERIFIED') THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_VERIFIED_PAYMENT';
  END IF;

  v_before:=to_jsonb(v_revision);
  PERFORM set_config('kgs.sales_order_revision_apply','1',TRUE);
  v_cancel:=public.cancel_pos_sales_order(v_source.id,v_source.master_version,
    p_idempotency_key,'Direvisi melalui '||v_replacement.draft_no||': '
      ||v_revision.reason);
  v_result:=private.confirm_pos_sales_order_before_revision_core(
    p_sales_id,p_master_version,p_idempotency_key,p_negative_stock_reason);
  PERFORM set_config('kgs.sales_order_revision_apply','',TRUE);

  PERFORM set_config('kgs.sales_order_revision_mutation','1',TRUE);
  UPDATE public.sales_order_revisions SET status='APPLIED',
    apply_idempotency_key=p_idempotency_key,applied_by=v_actor,
    applied_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_revision.id
  RETURNING * INTO v_revision;
  PERFORM set_config('kgs.sales_order_revision_mutation','',TRUE);
  INSERT INTO public.sales_order_revision_audit(company_id,revision_id,action,
    actor_id,idempotency_key,before_state,after_state)
  VALUES(v_company,v_revision.id,'APPLY',v_actor,p_idempotency_key,v_before,
    to_jsonb(v_revision));
  RETURN v_result||jsonb_build_object('revisionId',v_revision.id,
    'revisionStatus','APPLIED','replacesSalesId',v_source.id,
    'sourceCancellation',v_cancel,'idempotentReplay',FALSE);
END
$$;

CREATE FUNCTION public.get_sales_order_revision_links()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','VIEW');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'revisionId',revision.id,'status',revision.status,
      'reason',revision.reason,'sourceSalesId',revision.source_sales_id,
      'sourceOrderNo',source.draft_no,'sourceInvoiceNo',source.invoice_no,
      'replacementSalesId',revision.replacement_sales_id,
      'replacementOrderNo',replacement.draft_no,
      'replacementInvoiceNo',replacement.invoice_no,
      'startedAt',revision.started_at,'appliedAt',revision.applied_at,
      'abandonedAt',revision.abandoned_at)
    ORDER BY revision.created_at DESC)
    FROM (SELECT candidate.* FROM public.sales_order_revisions candidate
      WHERE candidate.company_id=v_company
      ORDER BY candidate.created_at DESC,candidate.id LIMIT 500) revision
    JOIN public.sales_headers source ON source.company_id=revision.company_id
      AND source.id=revision.source_sales_id
    JOIN public.sales_headers replacement
      ON replacement.company_id=revision.company_id
      AND replacement.id=revision.replacement_sales_id
    ),'[]'::JSONB);
END
$$;

CREATE FUNCTION public.get_pos_sales_order_revision_eligibility(
  p_store_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_store_id IS NOT NULL AND NOT (
    public.private_user_has_any_company_role(v_company,
      ARRAY['COMPANY_OWNER','COMPANY_ADMIN','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING']::TEXT[])
    OR public.private_user_has_any_store_role(p_store_id,
      ARRAY['CASHIER','STORE_MANAGER']::TEXT[])) THEN
    RAISE EXCEPTION 'SALES_ORDER_VIEW_FORBIDDEN';
  END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'salesId',sale.id,
      'canRevise',sale.document_status='DRAFT'
        AND sale.order_runtime_status IN('CONFIRMED','RESERVED')
        AND reservation.status='OPEN'
        AND reservation.total_dispatched_base_qty=0
        AND NOT EXISTS(SELECT 1
          FROM public.sales_payment_verification_requests request
          WHERE request.company_id=sale.company_id
            AND request.sales_id=sale.id AND request.status='VERIFIED')
        AND NOT EXISTS(SELECT 1 FROM public.sales_order_revisions revision
          WHERE revision.company_id=sale.company_id
            AND revision.source_sales_id=sale.id
            AND revision.status='PENDING'),
      'hasVerifiedPayment',EXISTS(SELECT 1
        FROM public.sales_payment_verification_requests request
        WHERE request.company_id=sale.company_id
          AND request.sales_id=sale.id AND request.status='VERIFIED'),
      'hasPendingRevision',EXISTS(SELECT 1
        FROM public.sales_order_revisions revision
        WHERE revision.company_id=sale.company_id
          AND revision.source_sales_id=sale.id
          AND revision.status='PENDING')) ORDER BY sale.updated_at DESC)
    FROM public.sales_headers sale
    JOIN public.sales_stock_reservations reservation
      ON reservation.company_id=sale.company_id AND reservation.sales_id=sale.id
    WHERE sale.company_id=v_company
      AND sale.order_runtime_status IN('CONFIRMED','RESERVED',
        'PARTIALLY_DISPATCHED','DISPATCHED','DELIVERED')
      AND (p_store_id IS NULL OR sale.store_id=p_store_id)
      AND (public.private_user_has_any_company_role(v_company,
          ARRAY['COMPANY_OWNER','COMPANY_ADMIN','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING']::TEXT[])
        OR public.private_user_has_any_store_role(sale.store_id,
          ARRAY['CASHIER','STORE_MANAGER']::TEXT[]))), '[]'::JSONB);
END
$$;

REVOKE ALL ON FUNCTION
  private.confirm_pos_sales_order_before_revision_core(UUID,BIGINT,UUID,TEXT),
  private.cancel_pos_sale_draft_before_revision_core(UUID,BIGINT,UUID,TEXT),
  private.cancel_pos_sales_order_before_revision_core(UUID,BIGINT,UUID,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.confirm_pos_sales_order_before_revision_core(UUID,BIGINT,UUID,TEXT),
  private.cancel_pos_sale_draft_before_revision_core(UUID,BIGINT,UUID,TEXT),
  private.cancel_pos_sales_order_before_revision_core(UUID,BIGINT,UUID,TEXT)
TO service_role;
REVOKE ALL ON FUNCTION
  public.start_pos_sales_order_revision(UUID,BIGINT,UUID,UUID,TEXT),
  public.cancel_pos_sale_draft(UUID,BIGINT,UUID,TEXT),
  public.cancel_pos_sales_order(UUID,BIGINT,UUID,TEXT),
  public.confirm_pos_sales_order(UUID,BIGINT,UUID,TEXT),
  public.get_sales_order_revision_links(),
  public.get_pos_sales_order_revision_eligibility(UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.start_pos_sales_order_revision(UUID,BIGINT,UUID,UUID,TEXT),
  public.cancel_pos_sale_draft(UUID,BIGINT,UUID,TEXT),
  public.cancel_pos_sales_order(UUID,BIGINT,UUID,TEXT),
  public.confirm_pos_sales_order(UUID,BIGINT,UUID,TEXT),
  public.get_sales_order_revision_links(),
  public.get_pos_sales_order_revision_eligibility(UUID)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260903110000','sales_order_revision_runtime',
  'Create replacement Draft without touching source; atomically cancel source and confirm replacement only after revalidation; preserve ordinary Draft/Confirm/Cancel flow and expose VIEW-guarded lineage');

NOTIFY pgrst,'reload schema';
COMMIT;
