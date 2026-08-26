-- F2 Customer Receipt / AR allocation foundation. Journal posting stays HOLD.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827090000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance F1 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260827100000';
  END IF;
  IF to_regclass('public.customer_receipt_documents') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Receipt objects exist';
  END IF;
END
$guard$;

CREATE SEQUENCE private.customer_receipt_no_seq AS BIGINT START 1;
REVOKE ALL ON SEQUENCE private.customer_receipt_no_seq FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.customer_receipt_no_seq TO service_role;

CREATE TABLE public.customer_receipt_documents(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  receipt_no TEXT NOT NULL,
  customer_id UUID NOT NULL,
  receipt_date DATE NOT NULL,
  payment_method_id UUID NOT NULL,
  payment_method_name_snapshot TEXT NOT NULL,
  payment_method_type_snapshot TEXT NOT NULL,
  settlement_route_snapshot TEXT NOT NULL,
  receipt_account_function_snapshot TEXT,
  receipt_account_id_snapshot UUID,
  receivable_account_id_snapshot UUID,
  reference_no TEXT,
  evidence_url TEXT,
  notes TEXT,
  total_amount NUMERIC(20,4) NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'DRAFT',
  posting_idempotency_key UUID,
  financial_event_id UUID REFERENCES public.financial_events(id) ON DELETE RESTRICT,
  master_version BIGINT NOT NULL DEFAULT 1,
  created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  posted_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  posted_at TIMESTAMPTZ,
  canceled_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  canceled_at TIMESTAMPTZ,
  cancel_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT customer_receipt_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT customer_receipt_company_no_unique UNIQUE(company_id,receipt_no),
  CONSTRAINT customer_receipt_posting_key_unique UNIQUE(company_id,posting_idempotency_key),
  CONSTRAINT customer_receipt_customer_fk FOREIGN KEY(company_id,customer_id)
    REFERENCES public.customers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT customer_receipt_method_fk FOREIGN KEY(company_id,payment_method_id)
    REFERENCES public.payment_methods(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT customer_receipt_account_fk FOREIGN KEY(company_id,receipt_account_id_snapshot)
    REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT customer_receipt_ar_account_fk FOREIGN KEY(company_id,receivable_account_id_snapshot)
    REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT customer_receipt_status_check CHECK(status IN('DRAFT','POSTED','CANCELED')),
  CONSTRAINT customer_receipt_amount_check CHECK(total_amount>=0),
  CONSTRAINT customer_receipt_version_check CHECK(master_version>0),
  CONSTRAINT customer_receipt_evidence_check CHECK(evidence_url IS NULL OR evidence_url~*'^https://'),
  CONSTRAINT customer_receipt_lifecycle_check CHECK(
    (status='DRAFT' AND posted_at IS NULL AND canceled_at IS NULL
      AND financial_event_id IS NULL)
    OR (status='POSTED' AND posted_by IS NOT NULL AND posted_at IS NOT NULL
      AND posting_idempotency_key IS NOT NULL AND financial_event_id IS NOT NULL
      AND receipt_account_id_snapshot IS NOT NULL
      AND receivable_account_id_snapshot IS NOT NULL)
    OR (status='CANCELED' AND canceled_by IS NOT NULL AND canceled_at IS NOT NULL
      AND btrim(COALESCE(cancel_reason,''))<>'' AND financial_event_id IS NULL)
  )
);

CREATE TABLE public.customer_receipt_allocations(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL,
  document_id UUID NOT NULL,
  sales_id UUID NOT NULL,
  client_allocation_key UUID NOT NULL,
  allocated_amount NUMERIC(20,4) NOT NULL,
  invoice_no_snapshot TEXT NOT NULL,
  sale_transaction_date_snapshot TIMESTAMPTZ NOT NULL,
  due_date_snapshot TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT customer_receipt_allocation_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT customer_receipt_allocation_sale_unique UNIQUE(company_id,document_id,sales_id),
  CONSTRAINT customer_receipt_allocation_client_unique UNIQUE(company_id,document_id,client_allocation_key),
  CONSTRAINT customer_receipt_allocation_document_fk FOREIGN KEY(company_id,document_id)
    REFERENCES public.customer_receipt_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT customer_receipt_allocation_sale_fk FOREIGN KEY(company_id,sales_id)
    REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT customer_receipt_allocation_amount_check CHECK(allocated_amount>0)
);

CREATE TABLE public.customer_receipt_audit(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL,
  document_id UUID NOT NULL,
  action TEXT NOT NULL CHECK(action IN('CREATE','UPDATE','POST','CANCEL')),
  actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  before_state JSONB,after_state JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT customer_receipt_audit_document_fk FOREIGN KEY(company_id,document_id)
    REFERENCES public.customer_receipt_documents(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX customer_receipt_customer_date_idx ON public.customer_receipt_documents(
  company_id,customer_id,receipt_date DESC);
CREATE INDEX customer_receipt_allocation_sale_idx ON public.customer_receipt_allocations(
  company_id,sales_id);

CREATE FUNCTION private.trg_customer_receipt_child_guard()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_status TEXT;
BEGIN
  SELECT document.status INTO v_status FROM public.customer_receipt_documents document
  WHERE document.company_id=COALESCE(NEW.company_id,OLD.company_id)
    AND document.id=COALESCE(NEW.document_id,OLD.document_id);
  IF v_status IS NULL THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_NOT_FOUND'; END IF;
  IF v_status<>'DRAFT' THEN RAISE EXCEPTION 'FINAL_CUSTOMER_RECEIPT_IMMUTABLE'; END IF;
  RETURN COALESCE(NEW,OLD);
END
$$;
CREATE TRIGGER customer_receipt_allocation_guard
BEFORE INSERT OR UPDATE OR DELETE ON public.customer_receipt_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_customer_receipt_child_guard();

CREATE FUNCTION private.trg_customer_receipt_audit_immutable()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN RAISE EXCEPTION 'CUSTOMER_RECEIPT_AUDIT_IMMUTABLE'; END
$$;
CREATE TRIGGER customer_receipt_audit_immutable
BEFORE UPDATE OR DELETE ON public.customer_receipt_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_customer_receipt_audit_immutable();

CREATE FUNCTION public.get_finance_customer_receipts()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_permission JSONB;
BEGIN
  v_permission:=private.acp_require_permission_capability(
    v_company,'finance.customer_receipts','VIEW');
  RETURN jsonb_build_object('companyId',v_company,'currentUserId',auth.uid(),
    'effectiveCapabilities',v_permission->'effectiveCapabilities',
    'documents',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.created_at DESC,row_data.id DESC),'[]'::JSONB)
      FROM (SELECT * FROM public.customer_receipt_documents document
        WHERE document.company_id=v_company ORDER BY document.created_at DESC LIMIT 500) row_data),
    'allocations',(SELECT COALESCE(jsonb_agg(to_jsonb(allocation)
      ORDER BY allocation.document_id,allocation.created_at),'[]'::JSONB)
      FROM public.customer_receipt_allocations allocation
      WHERE allocation.company_id=v_company),
    'openInvoices',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'salesId',sale.id,'invoiceNo',invoice.invoice_no,'customerId',sale.customer_id,
      'transactionDate',sale.transaction_date,'dueDate',sale.due_date,
      'originalReceivable',sale.sisa_piutang,'allocatedAmount',COALESCE(receipt.paid,0),
      'remainingAmount',GREATEST(sale.sisa_piutang-COALESCE(receipt.paid,0),0))
      ORDER BY sale.due_date NULLS LAST,sale.transaction_date,sale.id),'[]'::JSONB)
      FROM public.sales_headers sale
      JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=sale.company_id
        AND invoice.sales_id=sale.id
      LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) paid
        FROM public.customer_receipt_allocations allocation
        JOIN public.customer_receipt_documents document
          ON document.company_id=allocation.company_id AND document.id=allocation.document_id
          AND document.status='POSTED'
        WHERE allocation.company_id=sale.company_id AND allocation.sales_id=sale.id) receipt ON TRUE
      WHERE sale.company_id=v_company AND sale.document_status='POSTED' AND sale.is_tempo
        AND sale.sisa_piutang-COALESCE(receipt.paid,0)>0),
    'customers',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',customer.id,
      'code',customer.code,'name',customer.name) ORDER BY customer.name),'[]'::JSONB)
      FROM public.customers customer WHERE customer.company_id=v_company
        AND NOT customer.is_system_customer),
    'paymentMethods',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',method.id,
      'name',method.payment_method_name,'type',method.method_type,
      'settlementRoute',method.settlement_route) ORDER BY method.payment_method_name),'[]'::JSONB)
      FROM public.payment_methods method WHERE method.company_id=v_company AND method.is_active
        AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')));
END
$$;

CREATE FUNCTION public.save_customer_receipt_draft(
  p_document_id UUID,p_master_version BIGINT,p_customer_id UUID,p_receipt_date DATE,
  p_payment_method_id UUID,p_reference_no TEXT,p_evidence_url TEXT,p_notes TEXT,
  p_allocations JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_document public.customer_receipt_documents%ROWTYPE;v_method public.payment_methods%ROWTYPE;
  v_before JSONB;v_item JSONB;v_sale public.sales_headers%ROWTYPE;
  v_amount NUMERIC(20,4);v_paid NUMERIC(20,4);v_total NUMERIC(20,4):=0;v_is_new BOOLEAN:=p_document_id IS NULL;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,
    'finance.customer_receipts',CASE WHEN v_is_new THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  IF p_customer_id IS NULL OR p_receipt_date IS NULL OR p_payment_method_id IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_REQUIRED_FIELD_MISSING';
  END IF;
  IF p_receipt_date>current_date THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_DATE_FUTURE'; END IF;
  IF p_evidence_url IS NOT NULL AND p_evidence_url!~*'^https://' THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_EVIDENCE_MUST_USE_HTTPS';
  END IF;
  IF jsonb_typeof(p_allocations)<>'array' OR jsonb_array_length(p_allocations)=0 THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_ALLOCATION_REQUIRED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.customers customer WHERE customer.company_id=v_company
    AND customer.id=p_customer_id AND NOT customer.is_system_customer) THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_CUSTOMER_INVALID';
  END IF;
  SELECT * INTO v_method FROM public.payment_methods method
  WHERE method.company_id=v_company AND method.id=p_payment_method_id AND method.is_active;
  IF NOT FOUND OR v_method.settlement_route NOT IN('CASH_DRAWER','DIRECT_BANK') THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_PAYMENT_METHOD_INVALID';
  END IF;
  IF v_is_new THEN
    INSERT INTO public.customer_receipt_documents(company_id,receipt_no,customer_id,
      receipt_date,payment_method_id,payment_method_name_snapshot,
      payment_method_type_snapshot,settlement_route_snapshot,reference_no,evidence_url,
      notes,created_by)
    VALUES(v_company,'CR/'||to_char(p_receipt_date,'YYYY/MM')||'/'||
      lpad(nextval('private.customer_receipt_no_seq')::TEXT,6,'0'),p_customer_id,
      p_receipt_date,p_payment_method_id,v_method.payment_method_name,v_method.method_type,
      v_method.settlement_route,NULLIF(btrim(p_reference_no),''),p_evidence_url,
      NULLIF(btrim(p_notes),''),v_actor) RETURNING * INTO v_document;
  ELSE
    SELECT * INTO v_document FROM public.customer_receipt_documents document
    WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_NOT_FOUND'; END IF;
    IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'FINAL_CUSTOMER_RECEIPT_IMMUTABLE'; END IF;
    IF p_master_version IS DISTINCT FROM v_document.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    v_before:=to_jsonb(v_document);
    DELETE FROM public.customer_receipt_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.document_id=v_document.id;
    UPDATE public.customer_receipt_documents SET customer_id=p_customer_id,
      receipt_date=p_receipt_date,payment_method_id=p_payment_method_id,
      payment_method_name_snapshot=v_method.payment_method_name,
      payment_method_type_snapshot=v_method.method_type,
      settlement_route_snapshot=v_method.settlement_route,
      reference_no=NULLIF(btrim(p_reference_no),''),evidence_url=p_evidence_url,
      notes=NULLIF(btrim(p_notes),''),master_version=master_version+1,
      updated_at=clock_timestamp() WHERE company_id=v_company AND id=v_document.id
    RETURNING * INTO v_document;
  END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_allocations) LOOP
    v_amount:=(v_item->>'allocatedAmount')::NUMERIC;
    SELECT * INTO v_sale FROM public.sales_headers sale WHERE sale.company_id=v_company
      AND sale.id=(v_item->>'salesId')::UUID AND sale.document_status='POSTED'
      AND sale.is_tempo AND sale.customer_id=p_customer_id;
    IF NOT FOUND OR v_amount<=0 THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_ALLOCATION_INVALID'; END IF;
    SELECT COALESCE(sum(allocation.allocated_amount),0) INTO v_paid
    FROM public.customer_receipt_allocations allocation
    JOIN public.customer_receipt_documents document ON document.company_id=allocation.company_id
      AND document.id=allocation.document_id AND document.status='POSTED'
    WHERE allocation.company_id=v_company AND allocation.sales_id=v_sale.id;
    IF v_amount>v_sale.sisa_piutang-v_paid THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_OVER_ALLOCATION'; END IF;
    INSERT INTO public.customer_receipt_allocations(company_id,document_id,sales_id,
      client_allocation_key,allocated_amount,invoice_no_snapshot,
      sale_transaction_date_snapshot,due_date_snapshot)
    SELECT v_company,v_document.id,v_sale.id,(v_item->>'clientAllocationKey')::UUID,
      v_amount,invoice.invoice_no,v_sale.transaction_date,v_sale.due_date
    FROM public.sales_invoice_snapshots invoice WHERE invoice.company_id=v_company
      AND invoice.sales_id=v_sale.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_INVOICE_SNAPSHOT_REQUIRED'; END IF;
    v_total:=v_total+v_amount;
  END LOOP;
  UPDATE public.customer_receipt_documents SET total_amount=v_total,
    updated_at=clock_timestamp() WHERE company_id=v_company AND id=v_document.id
  RETURNING * INTO v_document;
  INSERT INTO public.customer_receipt_audit(company_id,document_id,action,actor_id,
    before_state,after_state) VALUES(v_company,v_document.id,
      CASE WHEN v_is_new THEN 'CREATE' ELSE 'UPDATE' END,v_actor,v_before,to_jsonb(v_document));
  RETURN jsonb_build_object('documentId',v_document.id,'receiptNo',v_document.receipt_no,
    'status',v_document.status,'totalAmount',v_document.total_amount,
    'masterVersion',v_document.master_version);
END
$$;

CREATE FUNCTION public.post_customer_receipt(
  p_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_document public.customer_receipt_documents%ROWTYPE;v_allocation RECORD;
  v_category UUID;v_rule_version BIGINT;v_event public.financial_events%ROWTYPE;
  v_receipt_function TEXT;v_receipt_account UUID;v_ar_account UUID;v_before JSONB;
  v_timezone TEXT;v_event_at TIMESTAMPTZ;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_receipts','POST');
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  SELECT * INTO v_document FROM public.customer_receipt_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_NOT_FOUND'; END IF;
  IF v_document.status='POSTED' AND v_document.posting_idempotency_key=p_idempotency_key THEN
    RETURN jsonb_build_object('documentId',v_document.id,'status','POSTED',
      'financialEventId',v_document.financial_event_id,'idempotentReplay',TRUE);
  END IF;
  IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'FINAL_CUSTOMER_RECEIPT_IMMUTABLE'; END IF;
  IF p_master_version IS DISTINCT FROM v_document.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  FOR v_allocation IN SELECT allocation.* FROM public.customer_receipt_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.document_id=v_document.id
    ORDER BY allocation.sales_id FOR UPDATE
  LOOP
    PERFORM 1 FROM public.sales_headers sale WHERE sale.company_id=v_company
      AND sale.id=v_allocation.sales_id AND sale.document_status='POSTED'
      AND sale.is_tempo AND sale.customer_id=v_document.customer_id
      AND v_allocation.allocated_amount<=sale.sisa_piutang-COALESCE((SELECT sum(other.allocated_amount)
        FROM public.customer_receipt_allocations other JOIN public.customer_receipt_documents receipt
          ON receipt.company_id=other.company_id AND receipt.id=other.document_id
          AND receipt.status='POSTED' WHERE other.company_id=v_company
          AND other.sales_id=sale.id),0) FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_OUTSTANDING_CHANGED'; END IF;
  END LOOP;
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  v_event_at:=(v_document.receipt_date::TEXT||' 12:00:00')::TIMESTAMP
    AT TIME ZONE v_timezone;
  PERFORM 1 FROM public.accounting_periods period WHERE period.company_id=v_company
    AND v_document.receipt_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED');
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_PERIOD_NOT_OPEN'; END IF;
  SELECT category.id INTO v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.system_key='SALE_PAYMENT'
    AND category.is_active;
  IF v_category IS NULL THEN RAISE EXCEPTION 'SALE_PAYMENT_CATEGORY_REQUIRED'; END IF;
  SELECT max(rule.rule_version) INTO v_rule_version FROM public.transaction_account_rules rule
  WHERE rule.company_id=v_company AND rule.transaction_category_id=v_category
    AND rule.status='ACTIVE' AND rule.effective_from<=v_document.receipt_date::TIMESTAMPTZ
    AND (rule.effective_to IS NULL OR rule.effective_to>v_document.receipt_date::TIMESTAMPTZ);
  v_receipt_function:=CASE v_document.settlement_route_snapshot
    WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER' ELSE 'BANK' END;
  INSERT INTO public.financial_events(event_code,event_type,source_table,source_id,
    event_date,event_version,idempotency_key,payment_method,amounts,status,created_by,
    company_id,system_event_key,transaction_category_id,transaction_rule_version)
  VALUES('CR-'||replace(p_idempotency_key::TEXT,'-',''),'PAYMENT_RECEIVED',
    'customer_receipt_documents',v_document.id,v_event_at,
    1,'CUSTOMER_RECEIPT|'||v_company||'|'||p_idempotency_key,
    v_document.payment_method_type_snapshot,jsonb_build_object('receiptAmount',v_document.total_amount,
      'customerId',v_document.customer_id,'receiptNo',v_document.receipt_no,
      'receiptAccountFunction',v_receipt_function,'financePostingState','HOLD'),
    'HOLD',v_actor,v_company,'SALE_PAYMENT',v_category,v_rule_version)
  RETURNING * INTO v_event;
  v_receipt_account:=private.resolve_financial_event_account(v_event,v_receipt_function);
  v_ar_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_RECEIVABLE');
  v_before:=to_jsonb(v_document);
  UPDATE public.customer_receipt_documents SET status='POSTED',posted_by=v_actor,
    posted_at=clock_timestamp(),posting_idempotency_key=p_idempotency_key,
    financial_event_id=v_event.id,receipt_account_function_snapshot=v_receipt_function,
    receipt_account_id_snapshot=v_receipt_account,receivable_account_id_snapshot=v_ar_account,
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_document.id RETURNING * INTO v_document;
  UPDATE public.financial_events SET amounts=amounts||jsonb_build_object(
    'receiptAccountId',v_receipt_account,'receivableAccountId',v_ar_account)
  WHERE company_id=v_company AND id=v_event.id;
  INSERT INTO public.customer_receipt_audit(company_id,document_id,action,actor_id,
    before_state,after_state) VALUES(v_company,v_document.id,'POST',v_actor,
      v_before,to_jsonb(v_document));
  RETURN jsonb_build_object('documentId',v_document.id,'status','POSTED',
    'financialEventId',v_event.id,'masterVersion',v_document.master_version,
    'idempotentReplay',FALSE);
END
$$;

CREATE FUNCTION public.cancel_customer_receipt_draft(
  p_document_id UUID,p_master_version BIGINT,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_document public.customer_receipt_documents%ROWTYPE;v_before JSONB;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_receipts','EDIT_DRAFT');
  SELECT * INTO v_document FROM public.customer_receipt_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_NOT_FOUND'; END IF;
  IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'FINAL_CUSTOMER_RECEIPT_IMMUTABLE'; END IF;
  IF p_master_version IS DISTINCT FROM v_document.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF btrim(COALESCE(p_reason,''))='' THEN RAISE EXCEPTION 'CANCEL_REASON_REQUIRED'; END IF;
  v_before:=to_jsonb(v_document);
  UPDATE public.customer_receipt_documents SET status='CANCELED',canceled_by=v_actor,
    canceled_at=clock_timestamp(),cancel_reason=btrim(p_reason),master_version=master_version+1,
    updated_at=clock_timestamp() WHERE company_id=v_company AND id=v_document.id
  RETURNING * INTO v_document;
  INSERT INTO public.customer_receipt_audit(company_id,document_id,action,actor_id,
    before_state,after_state) VALUES(v_company,v_document.id,'CANCEL',v_actor,
      v_before,to_jsonb(v_document));
  RETURN jsonb_build_object('documentId',v_document.id,'status','CANCELED',
    'masterVersion',v_document.master_version);
END
$$;

INSERT INTO public.access_permission_catalog(permission_key,module_key,permission_label,
  description,view_roles,operator_roles,approver_roles,supported_capabilities,
  required_any_features,is_customizable,enforcement_status)
VALUES('finance.customer_receipts','FINANCE','Penerimaan Customer',
  'Penerimaan pembayaran dan alokasi piutang Customer',
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],
  ARRAY['VIEW','CREATE_DRAFT','EDIT_DRAFT','POST','EXPORT'],'{}',TRUE,'ENFORCED');

ALTER TABLE public.customer_receipt_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_receipt_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_receipt_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_receipt_documents,public.customer_receipt_allocations,
  public.customer_receipt_audit FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.customer_receipt_documents,public.customer_receipt_allocations,
  public.customer_receipt_audit TO service_role;
REVOKE ALL ON FUNCTION public.get_finance_customer_receipts(),
  public.save_customer_receipt_draft(UUID,BIGINT,UUID,DATE,UUID,TEXT,TEXT,TEXT,JSONB),
  public.post_customer_receipt(UUID,BIGINT,UUID),
  public.cancel_customer_receipt_draft(UUID,BIGINT,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_finance_customer_receipts(),
  public.save_customer_receipt_draft(UUID,BIGINT,UUID,DATE,UUID,TEXT,TEXT,TEXT,JSONB),
  public.post_customer_receipt(UUID,BIGINT,UUID),
  public.cancel_customer_receipt_draft(UUID,BIGINT,TEXT) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260827100000','finance_customer_receipt_ar_foundation',
  'Guarded Customer Receipt Draft/POSTED/CANCELED lifecycle, multi-Invoice AR allocations, source account snapshots, exact retry and SALE_PAYMENT HOLD event');
COMMIT;
