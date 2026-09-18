-- Backoffice Sales Return Step 4/5: Customer Refund settlement.
-- This flow is Finance-owned and deliberately has no POS/cashier-session link.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917131000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Customer Credit Note runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917150000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260917150000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regclass('public.backoffice_sales_customer_refunds') IS NOT NULL
    OR to_regclass('public.backoffice_sales_customer_refund_operations') IS NOT NULL
    OR to_regclass('public.backoffice_sales_customer_refund_audit') IS NOT NULL
    OR to_regclass('private.backoffice_sales_customer_refund_no_seq') IS NOT NULL
    OR to_regprocedure('public.post_backoffice_sales_customer_refund(uuid,bigint,uuid,date,numeric,uuid,text,text,text)') IS NOT NULL
    OR to_regprocedure('public.reverse_backoffice_sales_customer_refund(uuid,bigint,uuid,date,text)') IS NOT NULL
    OR to_regprocedure('private.trg_provision_backoffice_customer_refund_category()') IS NOT NULL
    OR EXISTS(SELECT 1 FROM public.access_permission_catalog
      WHERE permission_key='finance.customer_refunds')
    OR EXISTS(SELECT 1 FROM public.system_events
      WHERE system_key='BACKOFFICE_CUSTOMER_REFUND') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Customer Refund collision';
  END IF;
END
$guard$;

DO $mapping_guard$
DECLARE v_invalid bigint;
BEGIN
  SELECT count(*) INTO v_invalid FROM public.companies company
  WHERE company.status='ACTIVE' AND (
    (SELECT count(*) FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=company.id
        AND fallback.account_function_key='CUSTOMER_REFUND_LIABILITY'
        AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
        AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp()))<>1
    OR (SELECT count(*) FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=company.id AND fallback.account_function_key='CASH_DRAWER'
        AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
        AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp()))<>1
    OR (SELECT count(*) FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=company.id AND fallback.account_function_key='BANK_RECEIPT'
        AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
        AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp()))<>1);
  IF v_invalid<>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Refund account mapping invalid for % active Company',v_invalid;
  END IF;
  SELECT count(*) INTO v_invalid FROM public.payment_methods method
  WHERE method.is_active AND method.settlement_route='DIRECT_BANK'
    AND (nullif(btrim(method.bank_account_function),'') IS NULL
      OR (SELECT count(*) FROM public.company_account_function_fallbacks fallback
        WHERE fallback.company_id=method.company_id
          AND fallback.account_function_key=method.bank_account_function
          AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
          AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp()))<>1);
  IF v_invalid<>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Bank Refund method mapping invalid for % method',v_invalid;
  END IF;
END
$mapping_guard$;

INSERT INTO public.access_permission_catalog(
  permission_key,module_key,permission_label,description,view_roles,
  operator_roles,approver_roles,supported_capabilities,required_any_features,
  is_customizable,enforcement_status
) VALUES(
  'finance.customer_refunds','FINANCE','Refund Customer Backoffice',
  'Pembayaran dan reversal Refund atas liability Credit Note Retur Customer',
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],
  ARRAY['VIEW','POST','REVERSE'],
  ARRAY['backoffice_delivered_qty_sales_enabled'],true,'ENFORCED'
);

INSERT INTO public.system_events(system_key,event_group,event_name,
  required_account_functions,conditional_account_functions,optional_account_functions)
VALUES('BACKOFFICE_CUSTOMER_REFUND','SALES','Backoffice Refund Customer',
  ARRAY['CUSTOMER_REFUND_LIABILITY'],ARRAY['CASH_DRAWER','BANK_RECEIPT'],ARRAY[]::text[]);

DO $finance_master$
DECLARE v_actor uuid;v_company record;v_category uuid;
BEGIN
  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE profile.role::text='super_admin' ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: linked Super Admin profile required';
  END IF;
  FOR v_company IN SELECT company.id FROM public.companies company
    WHERE company.status='ACTIVE' ORDER BY company.id
  LOOP
    IF EXISTS(SELECT 1 FROM public.transaction_categories category
      WHERE category.company_id=v_company.id
        AND (category.category_code='BO-CUSTOMER-REFUND'
          OR category.category_name='Refund Customer Backoffice')) THEN
      RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Refund category collision for Company %',v_company.id;
    END IF;
    INSERT INTO public.transaction_categories(company_id,category_code,category_name,
      system_key,description,is_active,created_by,updated_by)
    VALUES(v_company.id,'BO-CUSTOMER-REFUND','Refund Customer Backoffice',
      'BACKOFFICE_CUSTOMER_REFUND','Pembayaran liability Credit Note Retur Customer',
      true,v_actor,v_actor) RETURNING id INTO v_category;
  END LOOP;
END
$finance_master$;

CREATE FUNCTION private.trg_provision_backoffice_customer_refund_category()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor uuid;v_category uuid;
BEGIN
  IF NEW.status<>'ACTIVE' THEN RETURN NEW; END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE profile.id=auth.uid();
  IF v_actor IS NULL THEN
    SELECT profile.id INTO v_actor FROM public.profiles profile
    WHERE profile.role::text='super_admin' ORDER BY profile.id LIMIT 1;
  END IF;
  IF v_actor IS NULL THEN RAISE EXCEPTION 'CUSTOMER_REFUND_MAPPING_ACTOR_REQUIRED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.transaction_categories category
    WHERE category.company_id=NEW.id AND category.system_key='BACKOFFICE_CUSTOMER_REFUND') THEN
    INSERT INTO public.transaction_categories(company_id,category_code,category_name,
      system_key,description,is_active,created_by,updated_by)
    VALUES(NEW.id,'BO-CUSTOMER-REFUND','Refund Customer Backoffice',
      'BACKOFFICE_CUSTOMER_REFUND','Pembayaran liability Credit Note Retur Customer',
      true,v_actor,v_actor) RETURNING id INTO v_category;
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER zz_provision_backoffice_customer_refund_category
AFTER INSERT OR UPDATE OF status ON public.companies FOR EACH ROW
EXECUTE FUNCTION private.trg_provision_backoffice_customer_refund_category();

CREATE SEQUENCE private.backoffice_sales_customer_refund_no_seq AS bigint START WITH 1;
REVOKE ALL ON SEQUENCE private.backoffice_sales_customer_refund_no_seq
  FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.backoffice_sales_customer_refund_no_seq TO service_role;

CREATE TABLE public.backoffice_sales_customer_refunds(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  credit_note_id uuid NOT NULL,
  return_id uuid NOT NULL,
  source_invoice_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  store_id uuid NOT NULL,
  warehouse_id uuid NOT NULL,
  refund_no text NOT NULL,
  document_kind text NOT NULL DEFAULT 'REFUND',
  status text NOT NULL DEFAULT 'POSTED',
  refund_date date NOT NULL,
  amount numeric(24,4) NOT NULL,
  payment_method_id uuid NOT NULL,
  payment_method_name_snapshot text NOT NULL,
  payment_method_type_snapshot text NOT NULL,
  settlement_route_snapshot text NOT NULL,
  settlement_account_function_snapshot text NOT NULL,
  reference_no text,
  evidence_url text,
  notes text,
  reversal_of_refund_id uuid,
  financial_event_id uuid NOT NULL,
  master_version bigint NOT NULL DEFAULT 1,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  posted_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  posted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_customer_refunds_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_customer_refunds_number_unique UNIQUE(company_id,refund_no),
  CONSTRAINT backoffice_sales_customer_refunds_credit_note_fk FOREIGN KEY(company_id,credit_note_id)
    REFERENCES public.backoffice_sales_credit_notes(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_customer_refunds_return_fk FOREIGN KEY(company_id,return_id)
    REFERENCES public.backoffice_sales_returns(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_customer_refunds_invoice_fk FOREIGN KEY(company_id,source_invoice_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_customer_refunds_customer_fk FOREIGN KEY(company_id,customer_id)
    REFERENCES public.customers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_customer_refunds_store_fk FOREIGN KEY(company_id,store_id)
    REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_customer_refunds_warehouse_fk FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_customer_refunds_method_fk FOREIGN KEY(company_id,payment_method_id)
    REFERENCES public.payment_methods(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_customer_refunds_event_fk FOREIGN KEY(company_id,financial_event_id)
    REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_customer_refunds_reversal_fk FOREIGN KEY(company_id,reversal_of_refund_id)
    REFERENCES public.backoffice_sales_customer_refunds(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_customer_refunds_shape_check CHECK(
    document_kind IN('REFUND','REVERSAL') AND status='POSTED' AND amount>0
    AND master_version>0 AND nullif(btrim(refund_no),'') IS NOT NULL
    AND nullif(btrim(payment_method_name_snapshot),'') IS NOT NULL
    AND nullif(btrim(payment_method_type_snapshot),'') IS NOT NULL
    AND settlement_route_snapshot IN('CASH_DRAWER','DIRECT_BANK')
    AND nullif(btrim(settlement_account_function_snapshot),'') IS NOT NULL
    AND (evidence_url IS NULL OR evidence_url~*'^https://')
    AND ((document_kind='REFUND' AND reversal_of_refund_id IS NULL)
      OR (document_kind='REVERSAL' AND reversal_of_refund_id IS NOT NULL)))
);
CREATE UNIQUE INDEX backoffice_sales_customer_refunds_one_reversal
  ON public.backoffice_sales_customer_refunds(company_id,reversal_of_refund_id)
  WHERE reversal_of_refund_id IS NOT NULL;
CREATE INDEX backoffice_sales_customer_refunds_credit_note
  ON public.backoffice_sales_customer_refunds(company_id,credit_note_id,refund_date,id);

CREATE TABLE public.backoffice_sales_customer_refund_operations(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  operation_id uuid NOT NULL,
  operation_type text NOT NULL,
  credit_note_id uuid NOT NULL,
  refund_id uuid NOT NULL,
  expected_version bigint NOT NULL,
  request_hash text NOT NULL,
  response_snapshot jsonb NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_customer_refund_operations_identity_unique UNIQUE(company_id,operation_id),
  CONSTRAINT backoffice_sales_customer_refund_operations_refund_unique UNIQUE(company_id,refund_id),
  CONSTRAINT backoffice_sales_customer_refund_operations_note_fk FOREIGN KEY(company_id,credit_note_id)
    REFERENCES public.backoffice_sales_credit_notes(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_customer_refund_operations_refund_fk FOREIGN KEY(company_id,refund_id)
    REFERENCES public.backoffice_sales_customer_refunds(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_customer_refund_operations_shape_check CHECK(
    operation_type IN('POST','REVERSE') AND expected_version>0
    AND request_hash~'^[0-9a-f]{64}$' AND jsonb_typeof(response_snapshot)='object')
);

CREATE TABLE public.backoffice_sales_customer_refund_audit(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  credit_note_id uuid NOT NULL,
  refund_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  action text NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  after_state jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_customer_refund_audit_operation_unique UNIQUE(company_id,operation_id),
  CONSTRAINT backoffice_sales_customer_refund_audit_refund_unique UNIQUE(company_id,refund_id),
  CONSTRAINT backoffice_sales_customer_refund_audit_note_fk FOREIGN KEY(company_id,credit_note_id)
    REFERENCES public.backoffice_sales_credit_notes(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_customer_refund_audit_refund_fk FOREIGN KEY(company_id,refund_id)
    REFERENCES public.backoffice_sales_customer_refunds(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_customer_refund_audit_operation_fk FOREIGN KEY(company_id,operation_id)
    REFERENCES public.backoffice_sales_customer_refund_operations(company_id,operation_id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_customer_refund_audit_shape_check CHECK(
    action IN('POST','REVERSE') AND jsonb_typeof(after_state)='object')
);

CREATE FUNCTION private.trg_guard_backoffice_sales_customer_refund_history()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'BACKOFFICE_SALES_CUSTOMER_REFUND_HISTORY_IMMUTABLE';
END
$$;
CREATE TRIGGER backoffice_sales_customer_refunds_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_customer_refunds
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_customer_refund_history();
CREATE TRIGGER backoffice_sales_customer_refund_operations_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_customer_refund_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_customer_refund_history();
CREATE TRIGGER backoffice_sales_customer_refund_audit_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_customer_refund_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_customer_refund_history();
ALTER TABLE public.backoffice_sales_customer_refunds
  ENABLE ALWAYS TRIGGER backoffice_sales_customer_refunds_immutable;
ALTER TABLE public.backoffice_sales_customer_refund_operations
  ENABLE ALWAYS TRIGGER backoffice_sales_customer_refund_operations_immutable;
ALTER TABLE public.backoffice_sales_customer_refund_audit
  ENABLE ALWAYS TRIGGER backoffice_sales_customer_refund_audit_immutable;

CREATE FUNCTION private.backoffice_sales_customer_refund_snapshot(
  p_company_id uuid,p_refund_id uuid
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object('id',refund.id,'creditNoteId',refund.credit_note_id,
    'returnId',refund.return_id,'sourceInvoiceId',refund.source_invoice_id,
    'refundNo',refund.refund_no,'documentKind',refund.document_kind,
    'status',refund.status,'refundDate',refund.refund_date,'amount',refund.amount,
    'paymentMethodId',refund.payment_method_id,
    'paymentMethodName',refund.payment_method_name_snapshot,
    'paymentMethodType',refund.payment_method_type_snapshot,
    'settlementRoute',refund.settlement_route_snapshot,
    'settlementAccountFunction',refund.settlement_account_function_snapshot,
    'referenceNo',refund.reference_no,'evidenceUrl',refund.evidence_url,
    'notes',refund.notes,'reversalOfRefundId',refund.reversal_of_refund_id,
    'financialEventId',refund.financial_event_id,'masterVersion',refund.master_version,
    'postedAt',refund.posted_at)
  FROM public.backoffice_sales_customer_refunds refund
  WHERE refund.company_id=p_company_id AND refund.id=p_refund_id
$$;

CREATE FUNCTION private.backoffice_sales_customer_refund_operation_retry(
  p_company_id uuid,p_operation_id uuid,p_operation_type text,p_request_hash text
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_operation public.backoffice_sales_customer_refund_operations%rowtype;
BEGIN
  SELECT * INTO v_operation FROM public.backoffice_sales_customer_refund_operations
  WHERE company_id=p_company_id AND operation_id=p_operation_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_operation.operation_type<>p_operation_type OR v_operation.request_hash<>p_request_hash THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST';
  END IF;
  RETURN v_operation.response_snapshot||jsonb_build_object('exactRetry',true);
END
$$;

CREATE FUNCTION private.backoffice_sales_credit_note_refunded_amount(
  p_company_id uuid,p_credit_note_id uuid
) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT round(COALESCE(sum(CASE refund.document_kind WHEN 'REFUND' THEN refund.amount
    ELSE -refund.amount END),0),4)
  FROM public.backoffice_sales_customer_refunds refund
  WHERE refund.company_id=p_company_id AND refund.credit_note_id=p_credit_note_id
    AND refund.status='POSTED'
$$;

CREATE FUNCTION private.refresh_backoffice_sales_return_refund_status(
  p_company_id uuid,p_return_id uuid
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_pending numeric(24,4);
BEGIN
  SELECT round(COALESCE(sum(note.refund_liability_amount-
    private.backoffice_sales_credit_note_refunded_amount(note.company_id,note.id)),0),4)
  INTO v_pending FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=p_company_id AND note.return_id=p_return_id AND note.status='POSTED';
  UPDATE public.backoffice_sales_returns SET
    status=CASE WHEN v_pending>0 THEN 'REFUND_PENDING' ELSE 'COMPLETED' END,
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=p_company_id AND id=p_return_id
    AND status IN('REFUND_PENDING','COMPLETED');
END
$$;

CREATE FUNCTION public.post_backoffice_sales_customer_refund(
  p_credit_note_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_refund_date date,p_amount numeric,p_payment_method_id uuid,
  p_reference_no text,p_evidence_url text,p_notes text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_note public.backoffice_sales_credit_notes%rowtype;v_method public.payment_methods%rowtype;
  v_event public.financial_events%rowtype;v_period public.accounting_periods%rowtype;
  v_journal public.finance_journals%rowtype;v_category uuid;v_refund_id uuid:=gen_random_uuid();
  v_refund_no text;v_hash text;v_retry jsonb;v_response jsonb;v_snapshot jsonb;
  v_paid numeric(24,4);v_amount numeric(24,4);v_settlement_function text;
  v_liability_account uuid;v_settlement_account uuid;v_timezone text;
  v_company_today date;v_event_at timestamptz;v_accounting_date date;
  v_journal_type text:='AUTOMATIC';
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_refunds','POST');
  IF p_credit_note_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL
    OR p_refund_date IS NULL OR p_amount IS NULL OR p_amount<=0
    OR p_payment_method_id IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_REFUND_REQUIRED_FIELD_MISSING: pilih Credit Note, tanggal, nilai, dan metode Refund';
  END IF;
  IF p_evidence_url IS NOT NULL AND p_evidence_url!~*'^https://' THEN
    RAISE EXCEPTION 'CUSTOMER_REFUND_EVIDENCE_MUST_USE_HTTPS: bukti harus berupa URL HTTPS';
  END IF;
  v_amount:=round(p_amount,4);
  IF v_amount<=0 OR v_amount<>p_amount THEN
    RAISE EXCEPTION 'CUSTOMER_REFUND_AMOUNT_INVALID: nilai Refund harus positif dan maksimal empat desimal';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'creditNoteId',p_credit_note_id,'expectedVersion',p_expected_version,
    'refundDate',p_refund_date,'amount',v_amount,'paymentMethodId',p_payment_method_id,
    'referenceNo',NULLIF(btrim(p_reference_no),''),'evidenceUrl',p_evidence_url,
    'notes',NULLIF(btrim(p_notes),'') )::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':CUSTOMER_REFUND:'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_customer_refund_operation_retry(
    v_company,p_operation_id,'POST',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_note FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.id=p_credit_note_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_REFUND_CREDIT_NOTE_NOT_FOUND: Credit Note tidak ditemukan pada Company aktif'; END IF;
  IF v_note.status<>'POSTED' OR v_note.refund_liability_amount<=0 THEN
    RAISE EXCEPTION 'CUSTOMER_REFUND_CREDIT_NOTE_NOT_ELIGIBLE: Credit Note belum posted atau tidak memiliki nilai Refund';
  END IF;
  IF v_note.master_version<>p_expected_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT: Credit Note sudah berubah, muat ulang sebelum Refund';
  END IF;
  SELECT company.timezone,(clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO STRICT v_timezone,v_company_today FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF p_refund_date<v_note.credit_note_date OR p_refund_date>v_company_today THEN
    RAISE EXCEPTION 'CUSTOMER_REFUND_DATE_INVALID: tanggal Refund harus sejak Credit Note dan tidak boleh melewati tanggal Company';
  END IF;
  SELECT * INTO v_method FROM public.payment_methods method
  WHERE method.company_id=v_company AND method.id=p_payment_method_id AND method.is_active
    AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')
    AND method.effective_from<=((p_refund_date::text||' 23:59:59')::timestamp AT TIME ZONE v_timezone)
    AND (method.effective_to IS NULL OR method.effective_to>=
      ((p_refund_date::text||' 00:00:00')::timestamp AT TIME ZONE v_timezone))
    AND (method.available_all_stores OR EXISTS(SELECT 1
      FROM public.payment_method_store_assignments assignment
      WHERE assignment.company_id=v_company AND assignment.payment_method_id=method.id
        AND assignment.store_id=v_note.store_id));
  IF NOT FOUND THEN
    RAISE EXCEPTION 'CUSTOMER_REFUND_PAYMENT_METHOD_INVALID: gunakan metode Cash atau Transfer Bank aktif untuk toko Invoice';
  END IF;
  IF v_method.proof_mode='REQUIRED' AND p_evidence_url IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_REFUND_EVIDENCE_REQUIRED: metode pembayaran ini mewajibkan bukti';
  END IF;
  v_settlement_function:=CASE v_method.settlement_route
    WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER'
    WHEN 'DIRECT_BANK' THEN NULLIF(btrim(v_method.bank_account_function),'') END;
  IF v_settlement_function IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_REFUND_SETTLEMENT_ACCOUNT_REQUIRED: metode Transfer belum memiliki fungsi akun Bank';
  END IF;
  v_paid:=private.backoffice_sales_credit_note_refunded_amount(v_company,v_note.id);
  IF v_paid<0 OR v_amount>round(v_note.refund_liability_amount-v_paid,4) THEN
    RAISE EXCEPTION 'CUSTOMER_REFUND_AMOUNT_EXCEEDS_LIABILITY: nilai Refund melebihi sisa kewajiban Credit Note';
  END IF;
  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=v_company AND p_refund_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=v_company AND period.start_date>p_refund_date
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND: buka periode Refund atau periode penyesuaian berikutnya';
    END IF;
    v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';v_accounting_date:=v_period.start_date;
  ELSE v_accounting_date:=p_refund_date; END IF;
  SELECT category.id INTO v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.system_key='BACKOFFICE_CUSTOMER_REFUND'
    AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1;
  IF v_category IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_REFUND_CATEGORY_REQUIRED: aktifkan kategori Refund Customer Backoffice';
  END IF;
  v_refund_no:='RF/'||to_char(p_refund_date,'YYYY/MM')||'/'||
    lpad(nextval('private.backoffice_sales_customer_refund_no_seq')::text,8,'0');
  v_event_at:=(p_refund_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone;
  INSERT INTO public.financial_events(id,event_code,event_type,source_table,source_id,
    event_date,event_version,idempotency_key,payment_method,amounts,status,error_message,
    created_by,company_id,store_id,system_event_key,transaction_category_id,
    transaction_rule_version)
  VALUES(gen_random_uuid(),'BO-RF-'||replace(v_refund_id::text,'-',''),
    'SALES_REFUND'::public.event_type,'backoffice_sales_customer_refunds',v_refund_id,
    v_event_at,1,'BACKOFFICE_CUSTOMER_REFUND|'||v_company||'|'||v_refund_id,
    v_method.payment_method_name,jsonb_build_object('refundId',v_refund_id,
      'creditNoteId',v_note.id,'returnId',v_note.return_id,
      'sourceInvoiceId',v_note.source_invoice_id,'amount',v_amount,
      'settlementAccountFunction',v_settlement_function,'financePostingState','HOLD'),
    'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_PENDING',v_actor,v_company,
    v_note.store_id,'BACKOFFICE_CUSTOMER_REFUND',v_category,20260917150000)
  RETURNING * INTO v_event;
  INSERT INTO public.backoffice_sales_customer_refunds(id,company_id,credit_note_id,
    return_id,source_invoice_id,customer_id,store_id,warehouse_id,refund_no,
    document_kind,status,refund_date,amount,payment_method_id,
    payment_method_name_snapshot,payment_method_type_snapshot,
    settlement_route_snapshot,settlement_account_function_snapshot,reference_no,
    evidence_url,notes,financial_event_id,created_by,posted_by)
  VALUES(v_refund_id,v_company,v_note.id,v_note.return_id,v_note.source_invoice_id,
    v_note.customer_id,v_note.store_id,v_note.warehouse_id,v_refund_no,'REFUND','POSTED',
    p_refund_date,v_amount,v_method.id,v_method.payment_method_name,v_method.method_type,
    v_method.settlement_route,v_settlement_function,NULLIF(btrim(p_reference_no),''),
    p_evidence_url,NULLIF(btrim(p_notes),''),v_event.id,v_actor,v_actor);
  v_liability_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_REFUND_LIABILITY');
  v_settlement_account:=private.resolve_financial_event_account(v_event,v_settlement_function);
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,store_id,warehouse_id,
    description,status,created_by)
  VALUES(v_company,'RFJ-'||replace(v_refund_id::text,'-',''),v_journal_type,v_period.id,
    v_accounting_date,p_refund_date,'backoffice_sales_customer_refunds',v_refund_id,1,
    v_event.id,'BACKOFFICE_CUSTOMER_REFUND_JOURNAL|'||v_company||'|'||v_refund_id,
    'BACKOFFICE_CUSTOMER_REFUND',v_category,20260917150000,v_note.store_id,
    v_note.warehouse_id,'Refund Customer '||v_refund_no,'DRAFT',v_actor)
  RETURNING * INTO v_journal;
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
    debit,credit,store_id,warehouse_id,customer_id,description)
  VALUES(v_company,v_journal.id,10,v_liability_account,v_amount,0,v_note.store_id,
      v_note.warehouse_id,v_note.customer_id,'Pelunasan Utang Refund Customer'),
    (v_company,v_journal.id,20,v_settlement_account,0,v_amount,v_note.store_id,
      v_note.warehouse_id,v_note.customer_id,'Pengeluaran '||v_method.payment_method_name);
  UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor,
    posted_at=clock_timestamp() WHERE company_id=v_company AND id=v_journal.id
    RETURNING * INTO v_journal;
  IF round(v_journal.total_debit,4)<>v_amount OR round(v_journal.total_credit,4)<>v_amount THEN
    RAISE EXCEPTION 'JOURNAL_UNBALANCED: jurnal Refund Customer tidak seimbang';
  END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=clock_timestamp(),error_message=NULL,transaction_rule_version=20260917150000
  WHERE company_id=v_company AND id=v_event.id;
  PERFORM private.refresh_backoffice_sales_return_refund_status(v_company,v_note.return_id);
  v_snapshot:=private.backoffice_sales_customer_refund_snapshot(v_company,v_refund_id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_snapshot,
    'remainingRefundLiability',round(v_note.refund_liability_amount-v_paid-v_amount,4),
    'finance',jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'accountingDate',v_journal.accounting_date,
      'journalType',v_journal.journal_type),'exactRetry',false);
  INSERT INTO public.backoffice_sales_customer_refund_operations(company_id,operation_id,
    operation_type,credit_note_id,refund_id,expected_version,request_hash,
    response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,'POST',v_note.id,v_refund_id,p_expected_version,
    v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_customer_refund_audit(company_id,credit_note_id,
    refund_id,operation_id,action,actor_id,after_state)
  VALUES(v_company,v_note.id,v_refund_id,p_operation_id,'POST',v_actor,v_snapshot);
  RETURN v_response;
END
$$;

CREATE FUNCTION public.reverse_backoffice_sales_customer_refund(
  p_refund_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_reversal_date date,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_original public.backoffice_sales_customer_refunds%rowtype;
  v_note public.backoffice_sales_credit_notes%rowtype;v_original_journal public.finance_journals%rowtype;
  v_event public.financial_events%rowtype;v_period public.accounting_periods%rowtype;
  v_journal public.finance_journals%rowtype;v_category uuid;v_reversal_id uuid:=gen_random_uuid();
  v_refund_no text;v_hash text;v_retry jsonb;v_snapshot jsonb;v_response jsonb;
  v_timezone text;v_today date;v_event_at timestamptz;v_accounting_date date;v_line record;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_refunds','REVERSE');
  IF p_refund_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL
    OR p_reversal_date IS NULL OR nullif(btrim(p_reason),'') IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_REFUND_REVERSAL_REQUIRED_FIELD_MISSING: pilih Refund, tanggal, dan alasan reversal';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object('refundId',p_refund_id,
    'expectedVersion',p_expected_version,'reversalDate',p_reversal_date,
    'reason',btrim(p_reason))::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':CUSTOMER_REFUND:'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_customer_refund_operation_retry(
    v_company,p_operation_id,'REVERSE',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_original FROM public.backoffice_sales_customer_refunds refund
  WHERE refund.company_id=v_company AND refund.id=p_refund_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_REFUND_NOT_FOUND: Refund tidak ditemukan pada Company aktif'; END IF;
  IF v_original.document_kind<>'REFUND' OR v_original.status<>'POSTED' THEN
    RAISE EXCEPTION 'CUSTOMER_REFUND_NOT_REVERSIBLE: hanya Refund posted yang dapat direversal';
  END IF;
  IF v_original.master_version<>p_expected_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT: Refund sudah berubah, muat ulang sebelum reversal';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_customer_refunds reversal
    WHERE reversal.company_id=v_company AND reversal.reversal_of_refund_id=v_original.id) THEN
    RAISE EXCEPTION 'CUSTOMER_REFUND_ALREADY_REVERSED: Refund ini sudah mempunyai reversal';
  END IF;
  SELECT * INTO STRICT v_note FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.id=v_original.credit_note_id FOR UPDATE;
  SELECT company.timezone,(clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO STRICT v_timezone,v_today FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF p_reversal_date<v_original.refund_date OR p_reversal_date>v_today THEN
    RAISE EXCEPTION 'CUSTOMER_REFUND_REVERSAL_DATE_INVALID: tanggal reversal harus sejak Refund dan tidak boleh melewati tanggal Company';
  END IF;
  SELECT * INTO STRICT v_original_journal FROM public.finance_journals journal
  WHERE journal.company_id=v_company AND journal.financial_event_id=v_original.financial_event_id
    AND journal.status='POSTED' FOR SHARE;
  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=v_company AND p_reversal_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=v_company AND period.start_date>p_reversal_date
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND: buka periode reversal Refund atau periode berikutnya'; END IF;
    v_accounting_date:=v_period.start_date;
  ELSE v_accounting_date:=p_reversal_date; END IF;
  SELECT category.id INTO STRICT v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.system_key='BACKOFFICE_CUSTOMER_REFUND'
    AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1;
  v_refund_no:='RFR/'||to_char(p_reversal_date,'YYYY/MM')||'/'||
    lpad(nextval('private.backoffice_sales_customer_refund_no_seq')::text,8,'0');
  v_event_at:=(p_reversal_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone;
  INSERT INTO public.financial_events(id,event_code,event_type,source_table,source_id,
    event_date,event_version,idempotency_key,payment_method,amounts,status,error_message,
    created_by,company_id,store_id,system_event_key,transaction_category_id,
    transaction_rule_version)
  VALUES(gen_random_uuid(),'BO-RFR-'||replace(v_reversal_id::text,'-',''),
    'SALES_REFUND'::public.event_type,'backoffice_sales_customer_refunds',v_reversal_id,
    v_event_at,1,'BACKOFFICE_CUSTOMER_REFUND_REVERSAL|'||v_company||'|'||v_reversal_id,
    v_original.payment_method_name_snapshot,jsonb_build_object('refundId',v_reversal_id,
      'reversalOfRefundId',v_original.id,'creditNoteId',v_note.id,'amount',v_original.amount,
      'financePostingState','HOLD'),
    'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_PENDING',v_actor,v_company,
    v_original.store_id,'BACKOFFICE_CUSTOMER_REFUND',v_category,20260917150000)
  RETURNING * INTO v_event;
  INSERT INTO public.backoffice_sales_customer_refunds(id,company_id,credit_note_id,
    return_id,source_invoice_id,customer_id,store_id,warehouse_id,refund_no,
    document_kind,status,refund_date,amount,payment_method_id,
    payment_method_name_snapshot,payment_method_type_snapshot,
    settlement_route_snapshot,settlement_account_function_snapshot,reference_no,
    notes,reversal_of_refund_id,financial_event_id,created_by,posted_by)
  VALUES(v_reversal_id,v_company,v_original.credit_note_id,v_original.return_id,
    v_original.source_invoice_id,v_original.customer_id,v_original.store_id,
    v_original.warehouse_id,v_refund_no,'REVERSAL','POSTED',p_reversal_date,
    v_original.amount,v_original.payment_method_id,v_original.payment_method_name_snapshot,
    v_original.payment_method_type_snapshot,v_original.settlement_route_snapshot,
    v_original.settlement_account_function_snapshot,v_original.reference_no,btrim(p_reason),
    v_original.id,v_event.id,v_actor,v_actor);
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,store_id,warehouse_id,
    description,status,reversal_of_journal_id,created_by)
  VALUES(v_company,'RFRJ-'||replace(v_reversal_id::text,'-',''),'REVERSAL',v_period.id,
    v_accounting_date,p_reversal_date,'backoffice_sales_customer_refunds',v_reversal_id,1,
    v_event.id,'BACKOFFICE_CUSTOMER_REFUND_REVERSAL_JOURNAL|'||v_company||'|'||v_reversal_id,
    'BACKOFFICE_CUSTOMER_REFUND',v_category,20260917150000,v_original.store_id,
    v_original.warehouse_id,'Reversal Refund Customer '||v_original.refund_no,'DRAFT',
    v_original_journal.id,v_actor) RETURNING * INTO v_journal;
  FOR v_line IN SELECT line.* FROM public.finance_journal_lines line
    WHERE line.company_id=v_company AND line.journal_id=v_original_journal.id
    ORDER BY line.line_no
  LOOP
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,supplier_id,description)
    VALUES(v_company,v_journal.id,v_line.line_no,v_line.account_id,v_line.credit,v_line.debit,
      v_line.store_id,v_line.warehouse_id,v_line.customer_id,v_line.supplier_id,
      'Reversal: '||COALESCE(v_line.description,''));
  END LOOP;
  UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor,
    posted_at=clock_timestamp() WHERE company_id=v_company AND id=v_journal.id
    RETURNING * INTO v_journal;
  IF v_journal.total_debit<>v_original_journal.total_credit
    OR v_journal.total_credit<>v_original_journal.total_debit THEN
    RAISE EXCEPTION 'JOURNAL_UNBALANCED: reversal Refund tidak membalik jurnal sumber';
  END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=clock_timestamp(),error_message=NULL,transaction_rule_version=20260917150000
  WHERE company_id=v_company AND id=v_event.id;
  PERFORM private.refresh_backoffice_sales_return_refund_status(v_company,v_note.return_id);
  v_snapshot:=private.backoffice_sales_customer_refund_snapshot(v_company,v_reversal_id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_snapshot,
    'remainingRefundLiability',round(v_note.refund_liability_amount-
      private.backoffice_sales_credit_note_refunded_amount(v_company,v_note.id),4),
    'finance',jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'accountingDate',v_journal.accounting_date,
      'journalType',v_journal.journal_type),'exactRetry',false);
  INSERT INTO public.backoffice_sales_customer_refund_operations(company_id,operation_id,
    operation_type,credit_note_id,refund_id,expected_version,request_hash,
    response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,'REVERSE',v_note.id,v_reversal_id,p_expected_version,
    v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_customer_refund_audit(company_id,credit_note_id,
    refund_id,operation_id,action,actor_id,after_state)
  VALUES(v_company,v_note.id,v_reversal_id,p_operation_id,'REVERSE',v_actor,v_snapshot);
  RETURN v_response;
END
$$;

CREATE FUNCTION public.get_backoffice_sales_credit_note_refunds(p_credit_note_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_note public.backoffice_sales_credit_notes%rowtype;
  v_paid numeric(24,4);v_permission jsonb;
BEGIN
  v_permission:=private.acp_require_permission_capability(v_company,'finance.customer_refunds','VIEW');
  SELECT * INTO v_note FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.id=p_credit_note_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_REFUND_CREDIT_NOTE_NOT_FOUND: Credit Note tidak ditemukan pada Company aktif'; END IF;
  v_paid:=private.backoffice_sales_credit_note_refunded_amount(v_company,v_note.id);
  RETURN jsonb_build_object('companyId',v_company,'creditNoteId',v_note.id,
    'refundLiabilityAmount',v_note.refund_liability_amount,'refundedAmount',v_paid,
    'remainingRefundLiability',greatest(0,v_note.refund_liability_amount-v_paid),
    'effectiveCapabilities',v_permission->'effectiveCapabilities',
    'refunds',COALESCE((SELECT jsonb_agg(
      private.backoffice_sales_customer_refund_snapshot(v_company,refund.id)
      ORDER BY refund.refund_date,refund.created_at,refund.id)
      FROM public.backoffice_sales_customer_refunds refund
      WHERE refund.company_id=v_company AND refund.credit_note_id=v_note.id),'[]'::jsonb));
END
$$;

-- Extend the Step 3 payment context with net Refund settlement. Existing
-- payment and Credit Note history remains unchanged.
CREATE OR REPLACE FUNCTION public.get_backoffice_sales_invoice_payment_context(p_invoice_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_permission jsonb;
  v_invoice public.backoffice_sales_invoices%rowtype;v_paid numeric(20,4);
  v_credit numeric(20,4);v_refund_liability numeric(20,4);v_refunded numeric(20,4);v_result jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
  v_permission:=private.acp_require_permission_capability(v_company,'finance.customer_receipts','VIEW');
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_paid
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN public.customer_receipt_documents receipt
    ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
   AND receipt.status='POSTED'
  WHERE allocation.company_id=v_company AND allocation.invoice_id=p_invoice_id;
  SELECT round(COALESCE(sum(note.grand_total),0),4),
    round(COALESCE(sum(note.refund_liability_amount),0),4),
    round(COALESCE(sum(private.backoffice_sales_credit_note_refunded_amount(note.company_id,note.id)),0),4)
  INTO v_credit,v_refund_liability,v_refunded
  FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.source_invoice_id=p_invoice_id AND note.status='POSTED';
  SELECT jsonb_build_object(
    'companyDate',(clock_timestamp() AT TIME ZONE company.timezone)::date,
    'effectiveCapabilities',v_permission->'effectiveCapabilities',
    'summary',jsonb_build_object('originalAmount',v_invoice.grand_total,
      'creditNoteAmount',v_credit,'netInvoiceAmount',greatest(0,v_invoice.grand_total-v_credit),
      'paidAmount',v_paid,'outstandingAmount',greatest(0,v_invoice.grand_total-v_credit-v_paid),
      'refundLiabilityAmount',v_refund_liability,'refundedAmount',v_refunded,
      'remainingRefundLiability',greatest(0,v_refund_liability-v_refunded),
      'status',CASE WHEN v_invoice.status<>'POSTED' THEN 'NOT_APPLICABLE'
        WHEN v_invoice.grand_total-v_credit-v_paid>0 THEN 'PARTIALLY_PAID'
        WHEN v_refund_liability-v_refunded>0 THEN 'REFUND_PENDING'
        WHEN v_refund_liability>0 THEN 'REFUNDED'
        WHEN v_paid=0 AND v_credit=0 THEN 'NOT_PAID' ELSE 'PAID' END),
    'payments',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'receiptId',receipt.id,'receiptNo',receipt.receipt_no,'receiptDate',receipt.receipt_date,
      'paymentMethodName',receipt.payment_method_name_snapshot,
      'settlementRoute',receipt.settlement_route_snapshot,'referenceNo',receipt.reference_no,
      'evidenceUrl',receipt.evidence_url,'notes',receipt.notes,'amount',allocation.allocated_amount,
      'postedAt',receipt.posted_at,'journalNo',(SELECT journal.journal_no
        FROM public.finance_journals journal WHERE journal.company_id=receipt.company_id
          AND journal.financial_event_id=receipt.financial_event_id AND journal.status='POSTED'
        ORDER BY journal.id LIMIT 1)) ORDER BY receipt.receipt_date,receipt.posted_at,receipt.id)
      FROM public.customer_receipt_backoffice_invoice_allocations allocation
      JOIN public.customer_receipt_documents receipt
        ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
       AND receipt.status='POSTED'
      WHERE allocation.company_id=v_company AND allocation.invoice_id=p_invoice_id),'[]'::jsonb),
    'creditNotes',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',note.id,
      'creditNoteNo',note.credit_note_no,'creditNoteDate',note.credit_note_date,
      'grandTotal',note.grand_total,'arReductionAmount',note.ar_reduction_amount,
      'refundLiabilityAmount',note.refund_liability_amount,
      'refundedAmount',private.backoffice_sales_credit_note_refunded_amount(note.company_id,note.id),
      'status',note.status) ORDER BY note.credit_note_date,note.created_at,note.id)
      FROM public.backoffice_sales_credit_notes note WHERE note.company_id=v_company
        AND note.source_invoice_id=p_invoice_id AND note.status='POSTED'),'[]'::jsonb),
    'refunds',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',refund.id,
      'refundNo',refund.refund_no,'documentKind',refund.document_kind,
      'refundDate',refund.refund_date,'amount',refund.amount,
      'paymentMethodName',refund.payment_method_name_snapshot,
      'settlementRoute',refund.settlement_route_snapshot,'referenceNo',refund.reference_no,
      'evidenceUrl',refund.evidence_url,'notes',refund.notes,
      'reversalOfRefundId',refund.reversal_of_refund_id,'postedAt',refund.posted_at)
      ORDER BY refund.refund_date,refund.created_at,refund.id)
      FROM public.backoffice_sales_customer_refunds refund
      WHERE refund.company_id=v_company AND refund.source_invoice_id=p_invoice_id),'[]'::jsonb),
    'paymentMethods',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',method.id,
      'name',method.payment_method_name,'type',method.method_type,
      'settlementRoute',method.settlement_route,'proofMode',method.proof_mode)
      ORDER BY method.is_default DESC,method.payment_method_name,method.id)
      FROM public.payment_methods method WHERE method.company_id=v_company AND method.is_active
        AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')),'[]'::jsonb))
  INTO STRICT v_result FROM public.companies company WHERE company.id=v_company;
  RETURN v_result;
END
$$;

-- Add Refund as a debit and its reversal as a credit in Customer Statement.
DO $patch_statement$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(to_regprocedure(
    'public.get_finance_customer_statement(uuid,date,date,uuid)')) INTO STRICT v_definition;
  v_old:='WHERE note.company_id=v_company AND note.customer_id=p_customer_id
      AND note.status=''POSTED'' AND note.credit_note_date<=v_as_of
      AND (p_store_id IS NULL OR note.store_id=p_store_id)
  ),all_rows AS (SELECT * FROM invoice_rows UNION ALL SELECT * FROM receipt_rows)';
  v_new:='WHERE note.company_id=v_company AND note.customer_id=p_customer_id
      AND note.status=''POSTED'' AND note.credit_note_date<=v_as_of
      AND (p_store_id IS NULL OR note.store_id=p_store_id)
    UNION ALL
    SELECT refund.id,''CUSTOMER_REFUND'',''BACKOFFICE'',refund.refund_no,refund.refund_date,
      NULL::date,refund.store_id,store.store_name,
      CASE WHEN refund.document_kind=''REFUND'' THEN refund.amount ELSE 0::numeric END,
      CASE WHEN refund.document_kind=''REVERSAL'' THEN refund.amount ELSE 0::numeric END,
      (CASE WHEN refund.document_kind=''REFUND'' THEN ''Refund Customer untuk ''
        ELSE ''Reversal Refund Customer untuk '' END||note.credit_note_no)::text
    FROM public.backoffice_sales_customer_refunds refund
    JOIN public.backoffice_sales_credit_notes note
      ON note.company_id=refund.company_id AND note.id=refund.credit_note_id
      AND note.customer_id=p_customer_id
    LEFT JOIN public.stores store
      ON store.company_id=refund.company_id AND store.id=refund.store_id
    WHERE refund.company_id=v_company AND refund.status=''POSTED''
      AND refund.refund_date<=v_as_of
      AND (p_store_id IS NULL OR refund.store_id=p_store_id)
  ),all_rows AS (SELECT * FROM invoice_rows UNION ALL SELECT * FROM receipt_rows)';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Statement Refund anchor drift';
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_statement$;

ALTER TABLE public.backoffice_sales_customer_refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_customer_refund_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_customer_refund_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.backoffice_sales_customer_refunds,
  public.backoffice_sales_customer_refund_operations,
  public.backoffice_sales_customer_refund_audit FROM PUBLIC,anon,authenticated;
GRANT ALL ON TABLE public.backoffice_sales_customer_refunds,
  public.backoffice_sales_customer_refund_operations,
  public.backoffice_sales_customer_refund_audit TO service_role;
REVOKE ALL ON FUNCTION
  private.trg_provision_backoffice_customer_refund_category(),
  private.trg_guard_backoffice_sales_customer_refund_history(),
  private.backoffice_sales_customer_refund_snapshot(uuid,uuid),
  private.backoffice_sales_customer_refund_operation_retry(uuid,uuid,text,text),
  private.backoffice_sales_credit_note_refunded_amount(uuid,uuid),
  private.refresh_backoffice_sales_return_refund_status(uuid,uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.trg_provision_backoffice_customer_refund_category(),
  private.trg_guard_backoffice_sales_customer_refund_history(),
  private.backoffice_sales_customer_refund_snapshot(uuid,uuid),
  private.backoffice_sales_customer_refund_operation_retry(uuid,uuid,text,text),
  private.backoffice_sales_credit_note_refunded_amount(uuid,uuid),
  private.refresh_backoffice_sales_return_refund_status(uuid,uuid)
TO service_role;
REVOKE ALL ON FUNCTION
  public.post_backoffice_sales_customer_refund(uuid,bigint,uuid,date,numeric,uuid,text,text,text),
  public.reverse_backoffice_sales_customer_refund(uuid,bigint,uuid,date,text),
  public.get_backoffice_sales_credit_note_refunds(uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.post_backoffice_sales_customer_refund(uuid,bigint,uuid,date,numeric,uuid,text,text,text),
  public.reverse_backoffice_sales_customer_refund(uuid,bigint,uuid,date,text),
  public.get_backoffice_sales_credit_note_refunds(uuid)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260917150000','backoffice_sales_customer_refund',
  'Step 4/5 Finance Customer Refund from Credit Note liability; Cash/Bank settlement without cashier session, partial posting, immutable source-linked reversal and statement lineage');
NOTIFY pgrst,'reload schema';
COMMIT;
