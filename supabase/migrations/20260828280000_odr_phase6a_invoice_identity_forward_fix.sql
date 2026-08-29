-- ODR-6A.1: allocate a final Invoice identity before confirmed Order snapshots.
-- Repairs only ORDER_CONFIRM snapshots that accidentally captured DRAFT identity.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828270000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-6A guard required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828280000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260828280000';
  END IF;
  IF to_regclass('private.pos_invoice_number_seq') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice sequence missing';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_constraint constraint_row
    WHERE constraint_row.conrelid='public.sales_document_audit'::regclass
      AND constraint_row.conname='sales_document_audit_action_check') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: document audit contract missing';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid='public.sales_invoice_snapshots'::regclass
      AND trigger_row.tgname='sld_invoice_history_immutable'
      AND NOT trigger_row.tgisinternal)
    OR NOT EXISTS(SELECT 1 FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid='public.sales_delivery_documents'::regclass
      AND trigger_row.tgname='sld_delivery_update_guard'
      AND NOT trigger_row.tgisinternal) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: document immutability guard missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
    JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
      AND sale.id=invoice.sales_id
    LEFT JOIN public.sales_stock_reservations reservation
      ON reservation.company_id=sale.company_id AND reservation.sales_id=sale.id
    WHERE invoice.snapshot_provenance='ORDER_CONFIRM'
      AND (invoice.invoice_no LIKE 'DRAFT-%'
        OR invoice.snapshot_payload->>'invoiceNo' LIKE 'DRAFT-%')
      AND (sale.document_status<>'DRAFT'
        OR sale.order_runtime_status NOT IN('CONFIRMED','RESERVED','CANCELED')
        OR reservation.id IS NULL
        OR sale.confirmed_by IS NULL OR sale.confirmed_at IS NULL)) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: invalid repair source';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
    WHERE invoice.snapshot_provenance<>'ORDER_CONFIRM'
      AND (invoice.invoice_no LIKE 'DRAFT-%'
        OR invoice.snapshot_payload->>'invoiceNo' LIKE 'DRAFT-%')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: historical Draft Invoice identity';
  END IF;
END
$guard$;

CREATE FUNCTION private.ensure_confirmed_order_invoice_identity(
  p_company_id UUID,p_sales_id UUID
) RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_sale public.sales_headers%ROWTYPE;v_invoice_no TEXT;
  v_document_at TIMESTAMPTZ;
BEGIN
  IF p_company_id IS NULL OR p_sales_id IS NULL THEN
    RAISE EXCEPTION 'SALES_ORDER_INVOICE_CONTEXT_REQUIRED';
  END IF;
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_NOT_FOUND'; END IF;
  IF v_sale.document_status<>'DRAFT'
    OR v_sale.order_runtime_status NOT IN('CONFIRMED','RESERVED')
    OR v_sale.confirmed_at IS NULL OR v_sale.confirmed_by IS NULL THEN
    RAISE EXCEPTION 'SALES_ORDER_NOT_CONFIRMED';
  END IF;
  IF v_sale.invoice_no~'^INV-[0-9]{8}-[0-9]{10}$' THEN
    RETURN v_sale.invoice_no;
  END IF;
  IF v_sale.invoice_no NOT LIKE 'DRAFT-%' THEN
    RAISE EXCEPTION 'SALES_ORDER_INVOICE_IDENTITY_INVALID';
  END IF;
  v_document_at:=v_sale.confirmed_at;
  v_invoice_no:='INV-'||to_char(v_document_at,'YYYYMMDD')||'-'
    ||lpad(nextval('private.pos_invoice_number_seq')::TEXT,10,'0');
  UPDATE public.sales_headers SET invoice_no=v_invoice_no
  WHERE company_id=p_company_id AND id=p_sales_id
    AND invoice_no=v_sale.invoice_no;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_INVOICE_STATE_CHANGED'; END IF;
  RETURN v_invoice_no;
END
$$;

CREATE OR REPLACE FUNCTION public.confirm_pos_sales_order(
  p_sales_id UUID,p_master_version BIGINT,p_idempotency_key UUID,
  p_negative_stock_reason TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_result JSONB;v_documents JSONB;v_demand JSONB;v_payment JSONB;
  v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_invoice_no TEXT;
BEGIN
  v_result:=private.confirm_pos_sales_order_core(p_sales_id,p_master_version,
    p_idempotency_key,p_negative_stock_reason);
  v_invoice_no:=private.ensure_confirmed_order_invoice_identity(v_company,p_sales_id);
  v_documents:=private.ensure_confirmed_order_documents(v_company,p_sales_id);
  v_demand:=private.refresh_sales_order_procurement_demand(
    v_company,p_sales_id,v_actor,p_idempotency_key,'CONFIRM');
  v_payment:=private.capture_sales_order_payment_requests(
    v_company,p_sales_id,v_actor);
  RETURN v_result||jsonb_build_object('invoiceNo',v_invoice_no,
    'documents',v_documents,'procurementDemand',v_demand,
    'paymentVerification',v_payment);
END
$$;

ALTER TABLE public.sales_document_audit
  DROP CONSTRAINT sales_document_audit_action_check,
  ADD CONSTRAINT sales_document_audit_action_check CHECK(action IN(
    'CONFIGURE_FULFILLMENT','CREATE','PRINT','DISPATCH','DELIVER','CANCEL',
    'REPAIR_IDENTITY'));

ALTER TABLE public.sales_invoice_snapshots
  DISABLE TRIGGER sld_invoice_history_immutable;
ALTER TABLE public.sales_delivery_documents
  DISABLE TRIGGER sld_delivery_update_guard;

DO $repair$
DECLARE item RECORD;v_new TEXT;v_at TIMESTAMPTZ:=clock_timestamp();
BEGIN
  FOR item IN
    SELECT invoice.id invoice_id,invoice.company_id,invoice.sales_id,
      invoice.invoice_no old_invoice_no,invoice.snapshot_version,
      sale.invoice_no sale_invoice_no,sale.confirmed_at,sale.confirmed_by,
      delivery.id delivery_id
    FROM public.sales_invoice_snapshots invoice
    JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
      AND sale.id=invoice.sales_id
    LEFT JOIN public.sales_delivery_documents delivery
      ON delivery.company_id=invoice.company_id AND delivery.sales_id=invoice.sales_id
    WHERE invoice.snapshot_provenance='ORDER_CONFIRM'
      AND (invoice.invoice_no LIKE 'DRAFT-%'
        OR invoice.snapshot_payload->>'invoiceNo' LIKE 'DRAFT-%')
    ORDER BY invoice.created_at,invoice.id
    FOR UPDATE OF invoice,sale
  LOOP
    IF item.sale_invoice_no~'^INV-[0-9]{8}-[0-9]{10}$' THEN
      v_new:=item.sale_invoice_no;
    ELSE
      v_new:='INV-'||to_char(item.confirmed_at,'YYYYMMDD')||'-'
        ||lpad(nextval('private.pos_invoice_number_seq')::TEXT,10,'0');
      UPDATE public.sales_headers SET invoice_no=v_new
      WHERE company_id=item.company_id AND id=item.sales_id;
    END IF;

    UPDATE public.sales_invoice_snapshots SET invoice_no=v_new,
      snapshot_version=snapshot_version+1,
      snapshot_payload=jsonb_set(jsonb_set(snapshot_payload,
        '{invoiceNo}',to_jsonb(v_new),TRUE),'{snapshotVersion}',
        to_jsonb(snapshot_version+1),TRUE)
    WHERE company_id=item.company_id AND id=item.invoice_id;

    IF item.delivery_id IS NOT NULL THEN
      UPDATE public.sales_delivery_documents
      SET snapshot_payload=jsonb_set(snapshot_payload,'{invoiceNo}',
        to_jsonb(v_new),TRUE)
      WHERE company_id=item.company_id AND id=item.delivery_id;
    END IF;

    INSERT INTO public.sales_document_audit(company_id,document_type,
      document_id,sales_id,action,actor_id,before_state,after_state,created_at)
    VALUES(item.company_id,'SALES_INVOICE',item.invoice_id,item.sales_id,
      'REPAIR_IDENTITY',item.confirmed_by,
      jsonb_build_object('invoiceNo',item.old_invoice_no,
        'snapshotVersion',item.snapshot_version),
      jsonb_build_object('invoiceNo',v_new,
        'snapshotVersion',item.snapshot_version+1,
        'reason','ODR_CONFIRMED_ORDER_DRAFT_IDENTITY'),v_at);
    IF item.delivery_id IS NOT NULL THEN
      INSERT INTO public.sales_document_audit(company_id,document_type,
        document_id,sales_id,action,actor_id,before_state,after_state,created_at)
      VALUES(item.company_id,'SALES_DELIVERY',item.delivery_id,item.sales_id,
        'REPAIR_IDENTITY',item.confirmed_by,
        jsonb_build_object('invoiceNo',item.old_invoice_no),
        jsonb_build_object('invoiceNo',v_new,
          'reason','ODR_CONFIRMED_ORDER_DRAFT_IDENTITY'),v_at);
    END IF;
  END LOOP;
END
$repair$;

ALTER TABLE public.sales_invoice_snapshots
  ENABLE TRIGGER sld_invoice_history_immutable;
ALTER TABLE public.sales_delivery_documents
  ENABLE TRIGGER sld_delivery_update_guard;

REVOKE ALL ON FUNCTION
  private.ensure_confirmed_order_invoice_identity(UUID,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.ensure_confirmed_order_invoice_identity(UUID,UUID)
TO service_role;
REVOKE ALL ON FUNCTION
  public.confirm_pos_sales_order(UUID,BIGINT,UUID,TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.confirm_pos_sales_order(UUID,BIGINT,UUID,TEXT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828280000','odr_phase6a_invoice_identity_forward_fix',
  'Allocate final INV identity after atomic Order reservation and before immutable ORDER_CONFIRM Invoice/SJ snapshots; repair only affected DRAFT identities with audit and no Stock or Finance effect');

NOTIFY pgrst,'reload schema';
COMMIT;
