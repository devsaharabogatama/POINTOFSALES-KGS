-- Preserve the source Order business-date identity when starting a revision.
-- Replacement creation/posting timestamps remain new lifecycle timestamps.
BEGIN;

DO $migration$
DECLARE
  v_definition TEXT;
  v_pending_mismatch BIGINT;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260904130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260904130000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260903100000','20260903110000','20260903120000',
        '20260904110000','20260904120000'))<>5
    OR to_regprocedure(
      'public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: revision runtime chain required';
  END IF;
  IF to_regprocedure(
      'private.sales_order_revision_date_payload(jsonb,timestamptz,text)')
      IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: revision date helper already exists without ledger';
  END IF;

  SELECT pg_get_functiondef(
    'public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)'::regprocedure)
  INTO v_definition;
  IF v_definition!~'save_pos_sale_draft_with_pricelist'
    OR v_definition!~'revisionSourceSalesId'
    OR v_definition!~'SALES_ORDER_REVISION_DISPATCH_STARTED'
    OR v_definition!~'SALES_ORDER_REVISION_VERIFIED_PAYMENT' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: revision start runtime drift';
  END IF;

  SELECT count(*) INTO v_pending_mismatch
  FROM public.sales_order_revisions revision
  JOIN public.sales_headers source
    ON source.company_id=revision.company_id
   AND source.id=revision.source_sales_id
  JOIN public.sales_headers replacement
    ON replacement.company_id=revision.company_id
   AND replacement.id=revision.replacement_sales_id
  WHERE revision.status='PENDING'
    AND (replacement.transaction_date IS DISTINCT FROM source.transaction_date
      OR replacement.transaction_date_source IS DISTINCT FROM
        source.transaction_date_source
      OR replacement.transaction_date_selected_by IS DISTINCT FROM
        source.transaction_date_selected_by
      OR replacement.transaction_date_selected_at IS DISTINCT FROM
        source.transaction_date_selected_at);
  IF v_pending_mismatch<>0 THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: % pending revision(s) have date identity mismatch; abandon and restart them after rollout',
      v_pending_mismatch;
  END IF;
END
$migration$;

CREATE OR REPLACE FUNCTION private.sales_order_revision_date_payload(
  p_payload JSONB,
  p_transaction_date TIMESTAMPTZ,
  p_transaction_date_source TEXT
) RETURNS JSONB
LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF p_transaction_date IS NULL OR p_transaction_date_source IS NULL
    OR p_transaction_date_source NOT IN('SERVER_CREATED','CASHIER_SELECTED') THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_DATE_IDENTITY_INVALID';
  END IF;
  RETURN COALESCE(p_payload,'{}'::JSONB)||jsonb_build_object(
    'transactionAt',p_transaction_date,
    'transactionDateIntent',CASE p_transaction_date_source
      WHEN 'CASHIER_SELECTED' THEN 'CASHIER_SELECTED'
      ELSE 'PRESERVE'
    END);
END
$$;

CREATE OR REPLACE FUNCTION public.start_pos_sales_order_revision(
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

  v_payload:=private.sales_order_revision_date_payload(
    (COALESCE(v_source.payload_snapshot,'{}'::JSONB)
        -'saleId'-'masterVersion'-'payments'-'draftLabel'-'draftNotes'
        -'revisionId'-'revisionSourceSalesId'-'revisionSourceOrderNo')
      ||jsonb_build_object('clientTransactionId',p_idempotency_key,
        'cashierSessionId',p_cashier_session_id,'payments','[]'::JSONB,
        'draftLabel','Revisi '||v_source.draft_no,
        'draftNotes',btrim(p_reason),
        'revisionSourceSalesId',v_source.id,
        'revisionSourceOrderNo',v_source.draft_no),
    v_source.transaction_date,v_source.transaction_date_source);
  v_draft:=public.save_pos_sale_draft_with_pricelist(v_payload);

  UPDATE public.sales_headers SET is_revision=TRUE,
    original_invoice_no=v_source.invoice_no,
    transaction_date=v_source.transaction_date,
    transaction_date_source=v_source.transaction_date_source,
    transaction_date_selected_by=v_source.transaction_date_selected_by,
    transaction_date_selected_at=v_source.transaction_date_selected_at,
    payload_snapshot=private.sales_order_revision_date_payload(
      COALESCE(payload_snapshot,'{}'::JSONB)||jsonb_build_object(
        'revisionSourceSalesId',v_source.id,
        'revisionSourceOrderNo',v_source.draft_no),
      v_source.transaction_date,v_source.transaction_date_source),
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
      'transactionDate',v_replacement.transaction_date,
      'transactionDateSource',v_replacement.transaction_date_source,
      'transactionDateSelectedBy',v_replacement.transaction_date_selected_by,
      'transactionDateSelectedAt',v_replacement.transaction_date_selected_at,
      'reason',v_revision.reason));
  RETURN v_draft||jsonb_build_object('revisionId',v_revision.id,
    'sourceSalesId',v_source.id,'sourceOrderNo',v_source.draft_no,
    'replacementSalesId',v_replacement.id,
    'replacementDraftNo',v_replacement.draft_no,
    'replacementMasterVersion',v_replacement.master_version,
    'transactionAt',v_replacement.transaction_date,
    'transactionDateSource',v_replacement.transaction_date_source,
    'status','PENDING','idempotentReplay',FALSE);
END
$$;

REVOKE ALL ON FUNCTION private.sales_order_revision_date_payload(
  JSONB,TIMESTAMPTZ,TEXT) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.sales_order_revision_date_payload(
  JSONB,TIMESTAMPTZ,TEXT) TO service_role;

-- CREATE OR REPLACE retains the existing authenticated grant on the public RPC.
INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260904130000','sales_order_revision_order_date_preservation',
  'Preserves source Order transaction date identity in revision drafts and replacement Invoice snapshots while keeping replacement creation and posting timestamps current');

NOTIFY pgrst,'reload schema';
COMMIT;
