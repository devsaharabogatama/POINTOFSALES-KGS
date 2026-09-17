-- Generated Goods Receipt is a shared Warehouse work document. An authorized
-- operator may continue a Draft created by PO automation or another operator.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914180000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260914180000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260917141000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260917141000';
  END IF;
  IF to_regprocedure('private.claim_generated_backoffice_goods_receipt(uuid,bigint,text)')
      IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: operator handoff helper collision';
  END IF;
  IF to_regprocedure('public.save_generated_backoffice_goods_receipt(uuid,bigint,uuid,text,text,jsonb)')
      IS NULL OR to_regprocedure('public.post_generated_backoffice_goods_receipt(uuid,bigint,uuid)')
      IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: generated Receipt runtime missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs run
      WHERE run.status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue exists';
  END IF;
END
$guard$;

CREATE FUNCTION private.claim_generated_backoffice_goods_receipt(
  p_document_id uuid,p_expected_version bigint,p_capability text
) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_receipt public.goods_receipt_documents%rowtype;v_before jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_capability NOT IN('EDIT_DRAFT','POST') THEN
    RAISE EXCEPTION 'GOODS_RECEIPT_OPERATOR_CAPABILITY_INVALID'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.goods_receipts',p_capability);
  SELECT * INTO v_receipt FROM public.goods_receipt_documents receipt
  WHERE receipt.company_id=v_company AND receipt.id=p_document_id FOR UPDATE;
  IF NOT FOUND OR v_receipt.source_channel<>'BACKOFFICE' THEN
    RAISE EXCEPTION 'GENERATED_GOODS_RECEIPT_NOT_FOUND'; END IF;
  IF v_receipt.status<>'DRAFT' THEN RAISE EXCEPTION 'GOODS_RECEIPT_NOT_POSTABLE'; END IF;
  IF p_expected_version IS DISTINCT FROM v_receipt.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_receipt.received_by IS DISTINCT FROM v_actor THEN
    v_before:=to_jsonb(v_receipt);
    UPDATE public.goods_receipt_documents SET received_by=v_actor,
      master_version=master_version+1,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_receipt.id RETURNING master_version INTO p_expected_version;
    INSERT INTO public.goods_receipt_audit(company_id,document_id,action,actor_id,
      before_state,after_state)
    SELECT v_company,v_receipt.id,'UPDATE',v_actor,v_before,to_jsonb(receipt)
    FROM public.goods_receipt_documents receipt
    WHERE receipt.company_id=v_company AND receipt.id=v_receipt.id;
  END IF;
  RETURN p_expected_version;
END
$$;

CREATE OR REPLACE FUNCTION public.save_generated_backoffice_goods_receipt(
  p_document_id uuid,p_master_version bigint,p_supplier_order_id uuid,
  p_supplier_delivery_no text,p_notes text,p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_receipt record;
  v_effective_version bigint;
BEGIN
  IF p_document_id IS NULL THEN RAISE EXCEPTION 'GENERATED_GOODS_RECEIPT_REQUIRED'; END IF;
  v_effective_version:=private.claim_generated_backoffice_goods_receipt(
    p_document_id,p_master_version,'EDIT_DRAFT');
  SELECT receipt.receipt_scope,receipt.supplier_order_id,receipt.warehouse_id
    INTO v_receipt FROM public.goods_receipt_documents receipt
  WHERE receipt.company_id=v_company AND receipt.id=p_document_id;
  IF NOT FOUND OR v_receipt.supplier_order_id<>p_supplier_order_id THEN
    RAISE EXCEPTION 'GENERATED_GOODS_RECEIPT_NOT_FOUND'; END IF;
  IF v_receipt.receipt_scope='DAILY_WAREHOUSE' THEN
    RETURN public.save_purchase_daily_goods_receipt(p_document_id,
      v_effective_version,p_supplier_order_id,v_receipt.warehouse_id,
      p_supplier_delivery_no,p_notes,p_lines);
  END IF;
  RETURN public.save_backoffice_goods_receipt(p_document_id,
    v_effective_version,p_supplier_order_id,p_supplier_delivery_no,p_notes,p_lines);
END
$$;

CREATE OR REPLACE FUNCTION public.post_generated_backoffice_goods_receipt(
  p_document_id uuid,p_master_version bigint,p_idempotency_key uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_receipt record;
  v_effective_version bigint:=p_master_version;
BEGIN
  SELECT receipt.receipt_scope,receipt.status INTO v_receipt
  FROM public.goods_receipt_documents receipt
  WHERE receipt.company_id=v_company AND receipt.id=p_document_id
    AND receipt.source_channel='BACKOFFICE' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GENERATED_GOODS_RECEIPT_NOT_FOUND'; END IF;
  -- Exact retry of an already posted Receipt delegates without rewriting owner.
  IF v_receipt.status='DRAFT' THEN
    v_effective_version:=private.claim_generated_backoffice_goods_receipt(
      p_document_id,p_master_version,'POST');
  END IF;
  IF v_receipt.receipt_scope='DAILY_WAREHOUSE' THEN
    RETURN public.post_purchase_daily_goods_receipt(
      p_document_id,v_effective_version,p_idempotency_key);
  END IF;
  RETURN public.post_backoffice_goods_receipt(
    p_document_id,v_effective_version,p_idempotency_key);
END
$$;

REVOKE ALL ON FUNCTION private.claim_generated_backoffice_goods_receipt(uuid,bigint,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.claim_generated_backoffice_goods_receipt(uuid,bigint,text)
TO service_role;
REVOKE ALL ON FUNCTION
  public.save_generated_backoffice_goods_receipt(uuid,bigint,uuid,text,text,jsonb),
  public.post_generated_backoffice_goods_receipt(uuid,bigint,uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.save_generated_backoffice_goods_receipt(uuid,bigint,uuid,text,text,jsonb),
  public.post_generated_backoffice_goods_receipt(uuid,bigint,uuid)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260917141000','generated_goods_receipt_operator_handoff',
  'Authorized Warehouse operators can continue generated Receipt Drafts created by PO automation or another operator; current operator is audited; Company, PO, Warehouse, version and capability boundaries remain enforced');
NOTIFY pgrst,'reload schema';
COMMIT;
