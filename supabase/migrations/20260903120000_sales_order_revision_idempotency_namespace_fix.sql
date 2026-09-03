-- Give the two atomic suboperations of Revision Apply distinct deterministic
-- idempotency identities. The public operation key remains the revision key.

BEGIN;

DO $guard$
DECLARE v_definition TEXT;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260903120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260903120000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260903100000','20260903110000'))<>2
    OR to_regclass('public.sales_order_revisions') IS NULL
    OR to_regprocedure(
      'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)') IS NULL
    OR to_regprocedure(
      'public.confirm_pos_sales_order(uuid,bigint,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: revision runtime required';
  END IF;
  IF to_regprocedure(
      'private.sales_order_revision_child_idempotency_key(uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: child-key helper collision';
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
    'public.confirm_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure)
    INTO v_definition;
  IF v_definition IS NULL
    OR v_definition!~'sales_order_revision_apply'
    OR v_definition!~'cancel_pos_sales_order'
    OR v_definition!~'confirm_pos_sales_order_before_revision_core'
    OR v_definition!~'apply_idempotency_key=p_idempotency_key' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: revision Confirm composition drift';
  END IF;
END
$guard$;

CREATE FUNCTION private.sales_order_revision_child_idempotency_key(
  p_root_key UUID,p_operation TEXT
) RETURNS UUID LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=pg_catalog AS $$
  SELECT (substr(v_hash,1,8)||'-'||substr(v_hash,9,4)||'-'
    ||substr(v_hash,13,4)||'-'||substr(v_hash,17,4)||'-'
    ||substr(v_hash,21,12))::UUID
  FROM (SELECT md5(p_root_key::TEXT||':SALES_ORDER_REVISION:'
    ||upper(btrim(p_operation))) v_hash) key_hash
$$;

CREATE OR REPLACE FUNCTION public.confirm_pos_sales_order(
  p_sales_id UUID,p_master_version BIGINT,p_idempotency_key UUID,
  p_negative_stock_reason TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_revision public.sales_order_revisions%ROWTYPE;
  v_source public.sales_headers%ROWTYPE;v_replacement public.sales_headers%ROWTYPE;
  v_reservation public.sales_stock_reservations%ROWTYPE;
  v_cancel JSONB;v_result JSONB;v_before JSONB;
  v_cancel_key UUID;v_confirm_key UUID;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT revision.* INTO v_revision FROM public.sales_order_revisions revision
  WHERE revision.company_id=v_company
    AND revision.replacement_sales_id=p_sales_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN private.confirm_pos_sales_order_before_revision_core(
      p_sales_id,p_master_version,p_idempotency_key,p_negative_stock_reason);
  END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
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

  -- A Revision Apply is one public operation but composes two independent
  -- Sales aggregate mutations. Their keys must be stable and distinct.
  v_cancel_key:=private.sales_order_revision_child_idempotency_key(
    p_idempotency_key,'CANCEL_SOURCE');
  v_confirm_key:=private.sales_order_revision_child_idempotency_key(
    p_idempotency_key,'CONFIRM_REPLACEMENT');
  IF v_cancel_key=v_confirm_key OR v_cancel_key=p_idempotency_key
    OR v_confirm_key=p_idempotency_key THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_CHILD_IDEMPOTENCY_INVALID';
  END IF;

  v_before:=to_jsonb(v_revision);
  PERFORM set_config('kgs.sales_order_revision_apply','1',TRUE);
  v_cancel:=public.cancel_pos_sales_order(v_source.id,v_source.master_version,
    v_cancel_key,'Direvisi melalui '||v_replacement.draft_no||': '
      ||v_revision.reason);
  v_result:=private.confirm_pos_sales_order_before_revision_core(
    p_sales_id,p_master_version,v_confirm_key,p_negative_stock_reason);
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

REVOKE ALL ON FUNCTION
  private.sales_order_revision_child_idempotency_key(UUID,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.sales_order_revision_child_idempotency_key(UUID,TEXT)
TO service_role;
REVOKE ALL ON FUNCTION
  public.confirm_pos_sales_order(UUID,BIGINT,UUID,TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.confirm_pos_sales_order(UUID,BIGINT,UUID,TEXT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260903120000','sales_order_revision_idempotency_namespace_fix',
  'Derive distinct deterministic child idempotency keys for source cancellation and replacement confirmation while retaining the public Revision Apply key; no operational data backfill');

NOTIFY pgrst,'reload schema';
COMMIT;
