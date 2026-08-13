-- KGS POS G5 Phase 14: Supplier Payment / AP Settlement foundation.
-- Supplier Invoice (VALIDATED) -> Supplier Payment / AP Settlement.
-- General Ledger posting remains closed until G6.

BEGIN;

DO $guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260806100000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: G5 Phase 11 Supplier Invoice foundation missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260807150000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260807150000';
    END IF;
    IF to_regclass('public.supplier_payment_documents') IS NOT NULL THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Supplier Payment objects exist';
    END IF;
END
$guard$;

ALTER TYPE public.event_type
    ADD VALUE IF NOT EXISTS 'SUPPLIER_PAYMENT_VALIDATED';

CREATE SEQUENCE private.supplier_payment_no_seq AS BIGINT START 1;
REVOKE ALL ON SEQUENCE private.supplier_payment_no_seq FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.supplier_payment_no_seq TO service_role;

CREATE TABLE public.supplier_payment_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    payment_no TEXT NOT NULL,
    supplier_id UUID NOT NULL,
    payment_date DATE NOT NULL,
    payment_method TEXT NOT NULL,
    source_account_id UUID,
    supplier_bank_name TEXT,
    supplier_bank_account_no TEXT,
    supplier_bank_account_holder TEXT,
    reference_no TEXT,
    total_amount NUMERIC(20,4) NOT NULL DEFAULT 0,
    notes TEXT,
    evidence_url TEXT,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    validation_idempotency_key UUID,
    financial_event_id UUID REFERENCES public.financial_events(id) ON DELETE RESTRICT,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    validated_by UUID REFERENCES public.profiles(id),
    validated_at TIMESTAMPTZ,
    canceled_by UUID REFERENCES public.profiles(id),
    canceled_at TIMESTAMPTZ,
    cancel_reason TEXT,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT supplier_payment_documents_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT supplier_payment_documents_company_no_unique
        UNIQUE(company_id,payment_no),
    CONSTRAINT supplier_payment_documents_validation_key_unique
        UNIQUE(company_id,validation_idempotency_key),
    CONSTRAINT fk_supplier_payment_document_company
        FOREIGN KEY(company_id) REFERENCES public.companies(id) ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_payment_document_supplier
        FOREIGN KEY(company_id,supplier_id) REFERENCES public.suppliers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT supplier_payment_document_no_not_blank
        CHECK(btrim(payment_no) <> ''),
    CONSTRAINT supplier_payment_document_method_check
        CHECK(payment_method IN ('CASH','BANK_TRANSFER','CHEQUE')),
    CONSTRAINT supplier_payment_document_status_check
        CHECK(status IN ('DRAFT','VALIDATED','CANCELED')),
    CONSTRAINT supplier_payment_document_total_amount_check
        CHECK(total_amount >= 0),
    CONSTRAINT supplier_payment_document_evidence_https_check
        CHECK(evidence_url IS NULL OR evidence_url ~* '^https://'),
    CONSTRAINT supplier_payment_document_version_check
        CHECK(master_version > 0),
    CONSTRAINT supplier_payment_document_lifecycle_check CHECK(
        (status = 'DRAFT'
         AND validated_by IS NULL AND validated_at IS NULL
         AND financial_event_id IS NULL)
        OR (status = 'VALIDATED'
            AND validated_by IS NOT NULL AND validated_at IS NOT NULL
            AND validation_idempotency_key IS NOT NULL
            AND financial_event_id IS NOT NULL)
        OR (status = 'CANCELED'
            AND canceled_by IS NOT NULL AND canceled_at IS NOT NULL
            AND btrim(COALESCE(cancel_reason,'')) <> '')
    )
);

CREATE UNIQUE INDEX uq_supplier_payment_external_ref
    ON public.supplier_payment_documents(
        company_id,supplier_id,
        upper(regexp_replace(btrim(reference_no),'\s+',' ','g'))
    ) WHERE status <> 'CANCELED' AND reference_no IS NOT NULL;

CREATE INDEX idx_supplier_payment_supplier_status
    ON public.supplier_payment_documents(company_id,supplier_id,status,payment_date DESC);

CREATE TABLE public.supplier_payment_allocations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    invoice_id UUID NOT NULL,
    client_allocation_key UUID NOT NULL,
    allocated_amount NUMERIC(20,4) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT supplier_payment_allocations_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT supplier_payment_allocations_invoice_unique
        UNIQUE(company_id,document_id,invoice_id),
    CONSTRAINT supplier_payment_allocations_client_key_unique
        UNIQUE(company_id,document_id,client_allocation_key),
    CONSTRAINT fk_supplier_payment_allocation_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.supplier_payment_documents(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_payment_allocation_invoice
        FOREIGN KEY(company_id,invoice_id)
        REFERENCES public.supplier_invoice_documents(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT supplier_payment_allocation_amount_positive
        CHECK(allocated_amount > 0)
);

CREATE INDEX idx_supplier_payment_allocations_doc
    ON public.supplier_payment_allocations(company_id,document_id);
CREATE INDEX idx_supplier_payment_allocations_invoice
    ON public.supplier_payment_allocations(company_id,invoice_id);

CREATE TABLE public.supplier_payment_audit (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    action TEXT NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fk_supplier_payment_audit_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.supplier_payment_documents(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_supplier_payment_audit_doc
    ON public.supplier_payment_audit(company_id,document_id,created_at DESC);

CREATE FUNCTION private.trg_g5_supplier_payment_child_guard()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_status TEXT;
BEGIN
    SELECT document.status INTO v_status
    FROM public.supplier_payment_documents document
    WHERE document.company_id = COALESCE(NEW.company_id,OLD.company_id)
      AND document.id = COALESCE(NEW.document_id,OLD.document_id);
    IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_PAYMENT_NOT_FOUND'; END IF;
    IF v_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'FINAL_SUPPLIER_PAYMENT_IMMUTABLE';
    END IF;
    RETURN COALESCE(NEW,OLD);
END;
$$;

CREATE TRIGGER g5_guard_supplier_payment_allocations
BEFORE INSERT OR UPDATE OR DELETE ON public.supplier_payment_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_g5_supplier_payment_child_guard();

CREATE FUNCTION private.private_supplier_payment_finance_allowed(
    p_company_id UUID
) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT public.private_request_company_matches(p_company_id)
       AND (
            public.private_is_super_admin(auth.uid())
            OR public.private_user_has_any_company_role(
                p_company_id,
                ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE']::TEXT[]
            )
       );
$$;

CREATE FUNCTION private.refresh_supplier_payment_totals(
    p_company_id UUID,p_document_id UUID
) RETURNS NUMERIC
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_total NUMERIC(20,4);
BEGIN
    SELECT COALESCE(sum(allocated_amount),0) INTO v_total
    FROM public.supplier_payment_allocations
    WHERE company_id = p_company_id AND document_id = p_document_id;

    UPDATE public.supplier_payment_documents SET
        total_amount = v_total,
        updated_at = clock_timestamp()
    WHERE company_id = p_company_id AND id = p_document_id;

    RETURN v_total;
END;
$$;

CREATE FUNCTION public.save_supplier_payment_draft(
    p_document_id UUID,
    p_master_version BIGINT,
    p_supplier_id UUID,
    p_payment_date DATE,
    p_payment_method TEXT,
    p_source_account_id UUID,
    p_supplier_bank_name TEXT,
    p_supplier_bank_account_no TEXT,
    p_supplier_bank_account_holder TEXT,
    p_reference_no TEXT,
    p_notes TEXT,
    p_evidence_url TEXT,
    p_allocations JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_document public.supplier_payment_documents%ROWTYPE;
    v_is_new BOOLEAN := (p_document_id IS NULL);
    v_payment_no TEXT;
    v_before JSONB;
    v_alloc RECORD;
    v_invoice public.supplier_invoice_documents%ROWTYPE;
    v_paid_so_far NUMERIC(20,4);
    v_alloc_amount NUMERIC(20,4);
    v_client_key UUID;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF NOT private.private_supplier_payment_finance_allowed(v_company) THEN
        RAISE EXCEPTION 'SUPPLIER_PAYMENT_FINANCE_ACCESS_DENIED';
    END IF;
    IF p_supplier_id IS NULL THEN RAISE EXCEPTION 'SUPPLIER_ID_REQUIRED'; END IF;
    IF p_payment_date IS NULL THEN RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED'; END IF;
    IF p_payment_method NOT IN ('CASH','BANK_TRANSFER','CHEQUE') THEN
        RAISE EXCEPTION 'PAYMENT_METHOD_INVALID';
    END IF;
    IF p_evidence_url IS NOT NULL AND p_evidence_url !~* '^https://' THEN
        RAISE EXCEPTION 'SUPPLIER_PAYMENT_EVIDENCE_MUST_USE_HTTPS';
    END IF;
    IF p_allocations IS NULL OR jsonb_array_length(p_allocations) = 0 THEN
        RAISE EXCEPTION 'SUPPLIER_PAYMENT_ALLOCATIONS_REQUIRED';
    END IF;

    -- Verify active supplier
    PERFORM 1 FROM public.suppliers
    WHERE company_id = v_company AND id = p_supplier_id AND is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_SUPPLIER_NOT_FOUND'; END IF;

    IF v_is_new THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        v_payment_no := 'SPAY-' || to_char(v_now,'YYYYMMDD') || '-'
            || lpad(nextval('private.supplier_payment_no_seq')::TEXT,6,'0');

        INSERT INTO public.supplier_payment_documents(
            company_id,payment_no,supplier_id,payment_date,payment_method,
            source_account_id,supplier_bank_name,supplier_bank_account_no,
            supplier_bank_account_holder,reference_no,total_amount,notes,
            evidence_url,status,created_by,master_version
        ) VALUES (
            v_company,v_payment_no,p_supplier_id,p_payment_date,p_payment_method,
            p_source_account_id,
            NULLIF(btrim(COALESCE(p_supplier_bank_name,'')),''),
            NULLIF(btrim(COALESCE(p_supplier_bank_account_no,'')),''),
            NULLIF(btrim(COALESCE(p_supplier_bank_account_holder,'')),''),
            NULLIF(btrim(COALESCE(p_reference_no,'')),''),
            0,
            NULLIF(btrim(COALESCE(p_notes,'')),''),
            NULLIF(btrim(COALESCE(p_evidence_url,'')),''),
            'DRAFT',v_actor,1
        ) RETURNING * INTO v_document;
        v_before := NULL;
    ELSE
        SELECT * INTO v_document
        FROM public.supplier_payment_documents
        WHERE company_id = v_company AND id = p_document_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_PAYMENT_NOT_FOUND'; END IF;
        IF v_document.status <> 'DRAFT' THEN
            RAISE EXCEPTION 'FINAL_SUPPLIER_PAYMENT_IMMUTABLE';
        END IF;
        IF p_master_version IS DISTINCT FROM v_document.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        v_before := to_jsonb(v_document);

        UPDATE public.supplier_payment_documents SET
            supplier_id = p_supplier_id,
            payment_date = p_payment_date,
            payment_method = p_payment_method,
            source_account_id = p_source_account_id,
            supplier_bank_name = NULLIF(btrim(COALESCE(p_supplier_bank_name,'')),''),
            supplier_bank_account_no = NULLIF(btrim(COALESCE(p_supplier_bank_account_no,'')),''),
            supplier_bank_account_holder = NULLIF(btrim(COALESCE(p_supplier_bank_account_holder,'')),''),
            reference_no = NULLIF(btrim(COALESCE(p_reference_no,'')),''),
            notes = NULLIF(btrim(COALESCE(p_notes,'')),''),
            evidence_url = NULLIF(btrim(COALESCE(p_evidence_url,'')),''),
            master_version = master_version + 1,
            updated_at = v_now
        WHERE company_id = v_company AND id = v_document.id
        RETURNING * INTO v_document;

        DELETE FROM public.supplier_payment_allocations
        WHERE company_id = v_company AND document_id = v_document.id;
    END IF;

    -- Process invoice payment allocations
    FOR v_alloc IN SELECT * FROM jsonb_to_recordset(p_allocations) AS x(
        "clientAllocationKey" UUID, "invoiceId" UUID, "allocatedAmount" NUMERIC
    ) LOOP
        IF v_alloc."invoiceId" IS NULL THEN RAISE EXCEPTION 'INVOICE_ID_REQUIRED'; END IF;
        IF v_alloc."clientAllocationKey" IS NULL THEN RAISE EXCEPTION 'CLIENT_ALLOCATION_KEY_REQUIRED'; END IF;
        v_alloc_amount := round(COALESCE(v_alloc."allocatedAmount",0),4);
        IF v_alloc_amount <= 0 THEN RAISE EXCEPTION 'SUPPLIER_PAYMENT_ALLOCATION_AMOUNT_INVALID'; END IF;

        SELECT * INTO v_invoice
        FROM public.supplier_invoice_documents
        WHERE company_id = v_company AND id = v_alloc."invoiceId";

        IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_INVOICE_NOT_FOUND'; END IF;
        IF v_invoice.supplier_id <> p_supplier_id THEN
            RAISE EXCEPTION 'SUPPLIER_PAYMENT_INVOICE_SUPPLIER_MISMATCH';
        END IF;
        IF v_invoice.status <> 'VALIDATED' THEN
            RAISE EXCEPTION 'SUPPLIER_PAYMENT_INVOICE_NOT_VALIDATED';
        END IF;

        -- Calculate existing validated payments for this invoice
        SELECT COALESCE(sum(alloc.allocated_amount),0) INTO v_paid_so_far
        FROM public.supplier_payment_allocations alloc
        JOIN public.supplier_payment_documents payment
          ON payment.company_id = alloc.company_id
         AND payment.id = alloc.document_id
         AND payment.status = 'VALIDATED'
        WHERE alloc.company_id = v_company AND alloc.invoice_id = v_invoice.id;

        IF (v_paid_so_far + v_alloc_amount) > (v_invoice.grand_total + 0.01) THEN
            RAISE EXCEPTION 'SUPPLIER_PAYMENT_EXCEEDS_INVOICE_BALANCE';
        END IF;

        INSERT INTO public.supplier_payment_allocations(
            company_id,document_id,invoice_id,client_allocation_key,allocated_amount
        ) VALUES (
            v_company,v_document.id,v_invoice.id,v_alloc."clientAllocationKey",v_alloc_amount
        );
    END LOOP;

    PERFORM private.refresh_supplier_payment_totals(v_company, v_document.id);

    SELECT * INTO v_document
    FROM public.supplier_payment_documents
    WHERE company_id = v_company AND id = v_document.id;

    INSERT INTO public.supplier_payment_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_document.id,CASE WHEN v_is_new THEN 'CREATE_DRAFT' ELSE 'UPDATE_DRAFT' END,
        v_actor,v_before,to_jsonb(v_document)
    );

    RETURN jsonb_build_object(
        'documentId',v_document.id,
        'paymentNo',v_document.payment_no,
        'status',v_document.status,
        'totalAmount',v_document.total_amount,
        'masterVersion',v_document.master_version
    );
END;
$$;

CREATE FUNCTION public.validate_supplier_payment(
    p_document_id UUID,
    p_master_version BIGINT,
    p_idempotency_key UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_document public.supplier_payment_documents%ROWTYPE;
    v_before JSONB;
    v_category UUID;
    v_ap_final_account UUID;
    v_source_account UUID;
    v_event UUID;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
    IF NOT private.private_supplier_payment_finance_allowed(v_company) THEN
        RAISE EXCEPTION 'SUPPLIER_PAYMENT_FINANCE_ACCESS_DENIED';
    END IF;

    SELECT * INTO v_document
    FROM public.supplier_payment_documents
    WHERE company_id = v_company AND id = p_document_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_PAYMENT_NOT_FOUND'; END IF;

    IF v_document.status = 'VALIDATED' THEN
        IF v_document.validation_idempotency_key = p_idempotency_key THEN
            RETURN jsonb_build_object(
                'documentId',v_document.id,
                'paymentNo',v_document.payment_no,
                'status','VALIDATED',
                'masterVersion',v_document.master_version,
                'financialEventId',v_document.financial_event_id,
                'idempotentReplay',TRUE
            );
        END IF;
        RAISE EXCEPTION 'SUPPLIER_PAYMENT_ALREADY_VALIDATED';
    END IF;

    IF v_document.status <> 'DRAFT' THEN
        RAISE EXCEPTION 'SUPPLIER_PAYMENT_NOT_VALIDATABLE';
    END IF;

    IF p_master_version IS DISTINCT FROM v_document.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;

    IF v_document.total_amount <= 0 THEN
        RAISE EXCEPTION 'SUPPLIER_PAYMENT_AMOUNT_MUST_BE_POSITIVE';
    END IF;

    -- Transaction category & COA Account resolution
    SELECT category.id INTO v_category
    FROM public.transaction_categories category
    WHERE category.company_id = v_company
      AND category.system_key = 'SUPPLIER_PAYMENT'
      AND category.is_active
    ORDER BY category.id LIMIT 1;

    IF v_category IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_PAYMENT_TRANSACTION_CATEGORY_NOT_FOUND';
    END IF;

    v_ap_final_account := private.resolve_opening_stock_account(
        v_company,v_category,'SUPPLIER_AP_FINAL',v_now
    );

    v_source_account := v_document.source_account_id;
    IF v_source_account IS NULL THEN
        v_source_account := private.resolve_opening_stock_account(
            v_company,v_category,
            CASE WHEN v_document.payment_method = 'CASH' THEN 'MAIN_CASH' ELSE 'BANK' END,
            v_now
        );
    END IF;

    v_before := to_jsonb(v_document);

    -- Create Financial Event (HOLD_UNTIL_G6)
    INSERT INTO public.financial_events(
        event_code,event_type,source_table,source_id,root_sales_id,event_date,
        event_version,idempotency_key,amounts,status,error_message,created_by,
        company_id,store_id,system_event_key,transaction_category_id
    ) VALUES (
        'SPAY-' || replace(v_document.id::TEXT,'-',''),
        'SUPPLIER_PAYMENT_VALIDATED'::public.event_type,
        'supplier_payment_documents',v_document.id,NULL,v_now,1,
        'SUPPLIER_PAYMENT|' || v_company::TEXT || '|' || p_idempotency_key::TEXT,
        jsonb_build_object(
            'supplierId',v_document.supplier_id,
            'paymentNo',v_document.payment_no,
            'paymentMethod',v_document.payment_method,
            'totalAmount',v_document.total_amount,
            'apFinalDebitAccount',v_ap_final_account,
            'cashOrBankCreditAccount',v_source_account,
            'financePostingState','HOLD_UNTIL_G6'
        ),'HOLD'::public.event_status,
        'CANONICAL_FINANCE_POSTING_NOT_ENABLED',v_actor,v_company,NULL,
        'SUPPLIER_PAYMENT',v_category
    ) RETURNING id INTO v_event;

    UPDATE public.supplier_payment_documents SET
        status = 'VALIDATED',
        validation_idempotency_key = p_idempotency_key,
        financial_event_id = v_event,
        validated_by = v_actor,
        validated_at = v_now,
        master_version = master_version + 1,
        updated_at = v_now
    WHERE company_id = v_company AND id = v_document.id
    RETURNING * INTO v_document;

    INSERT INTO public.supplier_payment_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_document.id,'VALIDATE',v_actor,v_before,to_jsonb(v_document)
    );

    RETURN jsonb_build_object(
        'documentId',v_document.id,
        'paymentNo',v_document.payment_no,
        'status','VALIDATED',
        'masterVersion',v_document.master_version,
        'financialEventId',v_event,
        'idempotentReplay',FALSE
    );
END;
$$;

CREATE FUNCTION public.cancel_supplier_payment(
    p_document_id UUID,
    p_master_version BIGINT,
    p_reason TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_document public.supplier_payment_documents%ROWTYPE;
    v_before JSONB;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF NOT private.private_supplier_payment_finance_allowed(v_company) THEN
        RAISE EXCEPTION 'SUPPLIER_PAYMENT_FINANCE_ACCESS_DENIED';
    END IF;
    IF btrim(COALESCE(p_reason,'')) = '' THEN
        RAISE EXCEPTION 'CANCEL_REASON_REQUIRED';
    END IF;

    SELECT * INTO v_document
    FROM public.supplier_payment_documents
    WHERE company_id = v_company AND id = p_document_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_PAYMENT_NOT_FOUND'; END IF;
    IF v_document.status = 'CANCELED' THEN
        RAISE EXCEPTION 'SUPPLIER_PAYMENT_ALREADY_CANCELED';
    END IF;

    IF p_master_version IS DISTINCT FROM v_document.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;

    v_before := to_jsonb(v_document);

    UPDATE public.supplier_payment_documents SET
        status = 'CANCELED',
        canceled_by = v_actor,
        canceled_at = v_now,
        cancel_reason = btrim(p_reason),
        master_version = master_version + 1,
        updated_at = v_now
    WHERE company_id = v_company AND id = v_document.id
    RETURNING * INTO v_document;

    INSERT INTO public.supplier_payment_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_document.id,'CANCEL',v_actor,v_before,to_jsonb(v_document)
    );

    RETURN jsonb_build_object(
        'documentId',v_document.id,
        'paymentNo',v_document.payment_no,
        'status','CANCELED',
        'masterVersion',v_document.master_version
    );
END;
$$;

-- Enable RLS and setup read policies
ALTER TABLE public.supplier_payment_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_payment_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_payment_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY supplier_payment_document_read ON public.supplier_payment_documents
    FOR SELECT TO authenticated
    USING (private.private_supplier_payment_finance_allowed(company_id));

CREATE POLICY supplier_payment_allocation_read ON public.supplier_payment_allocations
    FOR SELECT TO authenticated
    USING (EXISTS (
        SELECT 1 FROM public.supplier_payment_documents document
        WHERE document.company_id = supplier_payment_allocations.company_id
          AND document.id = supplier_payment_allocations.document_id
          AND private.private_supplier_payment_finance_allowed(document.company_id)
    ));

CREATE POLICY supplier_payment_audit_read ON public.supplier_payment_audit
    FOR SELECT TO authenticated
    USING (private.private_supplier_payment_finance_allowed(company_id));

REVOKE ALL ON public.supplier_payment_documents,
    public.supplier_payment_allocations,
    public.supplier_payment_audit FROM PUBLIC,anon,authenticated;

GRANT SELECT ON public.supplier_payment_documents,
    public.supplier_payment_allocations,
    public.supplier_payment_audit TO authenticated;

GRANT ALL ON public.supplier_payment_documents,
    public.supplier_payment_allocations,
    public.supplier_payment_audit TO service_role;

REVOKE ALL ON FUNCTION public.save_supplier_payment_draft(UUID,BIGINT,UUID,DATE,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB),
    public.validate_supplier_payment(UUID,BIGINT,UUID),
    public.cancel_supplier_payment(UUID,BIGINT,TEXT) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.save_supplier_payment_draft(UUID,BIGINT,UUID,DATE,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB),
    public.validate_supplier_payment(UUID,BIGINT,UUID),
    public.cancel_supplier_payment(UUID,BIGINT,TEXT) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260807150000',
    'g5_phase14_supplier_payment_foundation',
    'Guarded Supplier Payment Draft/VALIDATED/CANCELED lifecycle, invoice AP settlement allocations, supplier bank reference, and G6 Finance HOLD'
);

COMMIT;
