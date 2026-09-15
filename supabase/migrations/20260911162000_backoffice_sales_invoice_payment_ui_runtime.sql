-- Invoice-focused payment registration and read model over canonical Customer Receipt.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260911150000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260911160000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260911161000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice UI and Payment Collection runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260911162000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260911162000';
  END IF;
  IF to_regclass('public.backoffice_sales_invoice_payment_operations') IS NOT NULL
    OR to_regprocedure('public.get_backoffice_sales_invoice_payment_context(uuid)') IS NOT NULL
    OR to_regprocedure('public.register_backoffice_sales_invoice_payment(uuid,uuid,date,uuid,numeric,text,text,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice payment UI runtime collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
END
$guard$;

CREATE TABLE public.backoffice_sales_invoice_payment_operations(
  company_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  invoice_id uuid NOT NULL,
  receipt_id uuid,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  request_snapshot jsonb NOT NULL,
  response_snapshot jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at timestamptz,
  PRIMARY KEY(company_id,operation_id),
  CONSTRAINT bo_invoice_payment_operation_invoice_fk FOREIGN KEY(company_id,invoice_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT bo_invoice_payment_operation_receipt_fk FOREIGN KEY(company_id,receipt_id)
    REFERENCES public.customer_receipt_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT bo_invoice_payment_operation_request_check
    CHECK(jsonb_typeof(request_snapshot)='object'),
  CONSTRAINT bo_invoice_payment_operation_lifecycle_check CHECK(
    (receipt_id IS NULL AND response_snapshot IS NULL AND completed_at IS NULL)
    OR (receipt_id IS NOT NULL AND jsonb_typeof(response_snapshot)='object'
      AND completed_at IS NOT NULL)
  )
);

CREATE FUNCTION private.trg_backoffice_invoice_payment_operation_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'BACKOFFICE_INVOICE_PAYMENT_OPERATION_IMMUTABLE'; END IF;
  IF OLD.company_id IS DISTINCT FROM NEW.company_id
    OR OLD.operation_id IS DISTINCT FROM NEW.operation_id
    OR OLD.invoice_id IS DISTINCT FROM NEW.invoice_id
    OR OLD.actor_id IS DISTINCT FROM NEW.actor_id
    OR OLD.request_snapshot IS DISTINCT FROM NEW.request_snapshot
    OR OLD.created_at IS DISTINCT FROM NEW.created_at
    OR OLD.response_snapshot IS NOT NULL
    OR NEW.receipt_id IS NULL OR NEW.response_snapshot IS NULL OR NEW.completed_at IS NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_INVOICE_PAYMENT_OPERATION_IMMUTABLE';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER backoffice_invoice_payment_operation_guard
BEFORE UPDATE OR DELETE ON public.backoffice_sales_invoice_payment_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_backoffice_invoice_payment_operation_guard();

ALTER TABLE public.backoffice_sales_invoice_payment_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.backoffice_sales_invoice_payment_operations FROM PUBLIC,anon,authenticated;
GRANT ALL ON TABLE public.backoffice_sales_invoice_payment_operations TO service_role;

CREATE FUNCTION public.get_backoffice_sales_invoice_payment_context(p_invoice_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_permission jsonb;
  v_invoice public.backoffice_sales_invoices%rowtype;v_paid numeric(20,4);
  v_result jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
  v_permission:=private.acp_require_permission_capability(
    v_company,'finance.customer_receipts','VIEW');
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_paid
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN public.customer_receipt_documents receipt
    ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
   AND receipt.status='POSTED'
  WHERE allocation.company_id=v_company AND allocation.invoice_id=p_invoice_id;
  SELECT jsonb_build_object(
    'companyDate',(clock_timestamp() AT TIME ZONE company.timezone)::date,
    'effectiveCapabilities',v_permission->'effectiveCapabilities',
    'summary',jsonb_build_object(
      'originalAmount',v_invoice.grand_total,'paidAmount',v_paid,
      'outstandingAmount',greatest(0,v_invoice.grand_total-v_paid),
      'status',CASE WHEN v_invoice.status<>'POSTED' THEN 'NOT_APPLICABLE'
        WHEN v_paid=0 THEN 'NOT_PAID'
        WHEN v_paid<v_invoice.grand_total THEN 'PARTIALLY_PAID' ELSE 'PAID' END),
    'payments',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'receiptId',receipt.id,'receiptNo',receipt.receipt_no,
      'receiptDate',receipt.receipt_date,'paymentMethodName',receipt.payment_method_name_snapshot,
      'settlementRoute',receipt.settlement_route_snapshot,'referenceNo',receipt.reference_no,
      'evidenceUrl',receipt.evidence_url,'notes',receipt.notes,
      'amount',allocation.allocated_amount,'postedAt',receipt.posted_at,
      'journalNo',(SELECT journal.journal_no FROM public.finance_journals journal
        WHERE journal.company_id=receipt.company_id
          AND journal.financial_event_id=receipt.financial_event_id
          AND journal.status='POSTED' ORDER BY journal.id LIMIT 1))
      ORDER BY receipt.receipt_date,receipt.posted_at,receipt.id)
      FROM public.customer_receipt_backoffice_invoice_allocations allocation
      JOIN public.customer_receipt_documents receipt
        ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
       AND receipt.status='POSTED'
      WHERE allocation.company_id=v_company AND allocation.invoice_id=p_invoice_id),'[]'::jsonb),
    'paymentMethods',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',method.id,'name',method.payment_method_name,'type',method.method_type,
      'settlementRoute',method.settlement_route,'proofMode',method.proof_mode)
      ORDER BY method.is_default DESC,method.payment_method_name,method.id)
      FROM public.payment_methods method WHERE method.company_id=v_company AND method.is_active
        AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')),'[]'::jsonb))
  INTO STRICT v_result
  FROM public.companies company WHERE company.id=v_company;
  RETURN v_result;
END
$$;

CREATE FUNCTION public.register_backoffice_sales_invoice_payment(
  p_invoice_id uuid,p_operation_id uuid,p_receipt_date date,p_payment_method_id uuid,
  p_amount numeric,p_reference_no text,p_evidence_url text,p_notes text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='20s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_invoice public.backoffice_sales_invoices%rowtype;v_operation record;
  v_request jsonb;v_saved jsonb;v_posted jsonb;v_response jsonb;v_receipt_id uuid;
  v_amount numeric(20,4):=round(COALESCE(p_amount,0),4);
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_receipts','CREATE_DRAFT');
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_receipts','POST');
  IF p_operation_id IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  v_request:=jsonb_build_object('invoiceId',p_invoice_id,'receiptDate',p_receipt_date,
    'paymentMethodId',p_payment_method_id,'amount',v_amount,
    'referenceNo',NULLIF(btrim(p_reference_no),''),'evidenceUrl',NULLIF(btrim(p_evidence_url),''),
    'notes',NULLIF(btrim(p_notes),''));
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'BACKOFFICE_INVOICE_PAYMENT|'||v_company||'|'||p_operation_id,0));
  SELECT * INTO v_operation FROM public.backoffice_sales_invoice_payment_operations operation
  WHERE operation.company_id=v_company AND operation.operation_id=p_operation_id;
  IF FOUND THEN
    IF v_operation.invoice_id IS DISTINCT FROM p_invoice_id
      OR v_operation.request_snapshot IS DISTINCT FROM v_request THEN
      RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    IF v_operation.response_snapshot IS NULL THEN
      RAISE EXCEPTION 'BACKOFFICE_INVOICE_PAYMENT_OPERATION_INCOMPLETE';
    END IF;
    RETURN v_operation.response_snapshot||jsonb_build_object('exactRetry',true);
  END IF;
  IF p_invoice_id IS NULL OR p_receipt_date IS NULL OR p_payment_method_id IS NULL OR v_amount<=0 THEN
    RAISE EXCEPTION 'BACKOFFICE_INVOICE_PAYMENT_REQUIRED_FIELD_INVALID';
  END IF;
  IF EXISTS(SELECT 1 FROM public.payment_methods method
    WHERE method.company_id=v_company AND method.id=p_payment_method_id
      AND method.is_active AND method.proof_mode='REQUIRED')
    AND NULLIF(btrim(p_evidence_url),'') IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_EVIDENCE_REQUIRED';
  END IF;
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  IF v_invoice.status<>'POSTED' THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_PAYMENT_ELIGIBLE'; END IF;
  INSERT INTO public.backoffice_sales_invoice_payment_operations(
    company_id,operation_id,invoice_id,actor_id,request_snapshot)
  VALUES(v_company,p_operation_id,p_invoice_id,v_actor,v_request);
  v_saved:=public.save_customer_receipt_allocated_draft(NULL,NULL,v_invoice.customer_id,
    p_receipt_date,p_payment_method_id,NULLIF(btrim(p_reference_no),''),
    NULLIF(btrim(p_evidence_url),''),NULLIF(btrim(p_notes),''),v_amount,
    jsonb_build_array(jsonb_build_object('sourceType','BACKOFFICE_SALES_INVOICE',
      'sourceId',p_invoice_id,'clientAllocationKey',p_operation_id,'allocatedAmount',v_amount)));
  v_receipt_id:=(v_saved->>'documentId')::uuid;
  v_posted:=public.post_customer_receipt_allocated(v_receipt_id,
    (v_saved->>'masterVersion')::bigint,p_operation_id);
  SELECT jsonb_build_object('payment',jsonb_build_object(
      'receiptId',receipt.id,'receiptNo',receipt.receipt_no,'status',receipt.status,
      'receiptDate',receipt.receipt_date,'amount',v_amount,
      'paymentMethodName',receipt.payment_method_name_snapshot,
      'referenceNo',receipt.reference_no,'postedAt',receipt.posted_at,
      'journalNo',v_posted->>'journalNo'),
    'paymentContext',public.get_backoffice_sales_invoice_payment_context(p_invoice_id),
    'exactRetry',false)
  INTO STRICT v_response
  FROM public.customer_receipt_documents receipt
  WHERE receipt.company_id=v_company AND receipt.id=v_receipt_id;
  UPDATE public.backoffice_sales_invoice_payment_operations
  SET receipt_id=v_receipt_id,response_snapshot=v_response,completed_at=clock_timestamp()
  WHERE company_id=v_company AND operation_id=p_operation_id;
  RETURN v_response;
END
$$;

REVOKE ALL ON FUNCTION private.trg_backoffice_invoice_payment_operation_guard()
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_backoffice_invoice_payment_operation_guard() TO service_role;
REVOKE ALL ON FUNCTION public.get_backoffice_sales_invoice_payment_context(uuid),
  public.register_backoffice_sales_invoice_payment(uuid,uuid,date,uuid,numeric,text,text,text)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_backoffice_sales_invoice_payment_context(uuid),
  public.register_backoffice_sales_invoice_payment(uuid,uuid,date,uuid,numeric,text,text,text)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260911162000','backoffice_sales_invoice_payment_ui_runtime',
  'Add Finance-authorized Invoice payment context and one atomic idempotent Register Payment entry point over canonical Customer Receipt; no Invoice, POS, Stock, DO, FIFO, template or Retail runtime replacement');
NOTIFY pgrst,'reload schema';
COMMIT;
