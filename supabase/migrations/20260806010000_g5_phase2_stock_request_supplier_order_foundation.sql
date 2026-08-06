-- KGS POS G5 phase 2: Stock Request + Supplier Order foundation.
-- Requirements: PUR-001; dependency boundary for PUR-002/STK-006 replenishment.
-- No Stock, FIFO, AP, Financial Event, or Journal effect in this phase.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260805234500'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 phase 60 closure missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260806010000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260806010000';
    END IF;
    IF to_regclass('public.stock_request_documents') IS NOT NULL
       OR to_regclass('public.stock_request_lines') IS NOT NULL
       OR to_regclass('public.supplier_order_documents') IS NOT NULL
       OR to_regclass('public.supplier_order_lines') IS NOT NULL
       OR to_regclass('public.supplier_order_request_allocations') IS NOT NULL
    THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: canonical Request/Order table exists';
    END IF;
END
$migration_guard$;

CREATE SEQUENCE private.stock_request_document_no_seq AS BIGINT START WITH 1;
CREATE SEQUENCE private.supplier_order_document_no_seq AS BIGINT START WITH 1;
REVOKE ALL ON SEQUENCE private.stock_request_document_no_seq,
    private.supplier_order_document_no_seq FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.stock_request_document_no_seq,
    private.supplier_order_document_no_seq TO service_role;

CREATE TABLE public.stock_request_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    request_no TEXT NOT NULL,
    store_id UUID NOT NULL,
    requesting_pos_id UUID NOT NULL,
    requesting_session_id UUID NOT NULL,
    requested_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    requested_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    needed_date DATE,
    notes TEXT,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    line_count INTEGER NOT NULL DEFAULT 0,
    requested_total_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
    submitted_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    submitted_at TIMESTAMPTZ,
    closed_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    closed_at TIMESTAMPTZ,
    canceled_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    canceled_at TIMESTAMPTZ,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT stock_request_documents_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT stock_request_documents_company_no_unique
        UNIQUE(company_id,request_no),
    CONSTRAINT fk_stock_request_company_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_stock_request_company_terminal
        FOREIGN KEY(company_id,requesting_pos_id)
        REFERENCES public.pos_terminals(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_stock_request_company_session
        FOREIGN KEY(company_id,requesting_session_id)
        REFERENCES public.cashier_sessions(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT stock_request_no_not_blank CHECK(btrim(request_no)<>''),
    CONSTRAINT stock_request_status_check CHECK(status IN(
        'DRAFT','SUBMITTED','ORDERED','PARTIALLY_RECEIVED','RECEIVED',
        'CLOSED','CANCELED'
    )),
    CONSTRAINT stock_request_totals_nonnegative CHECK(
        line_count>=0 AND requested_total_base_qty>=0
    ),
    CONSTRAINT stock_request_version_positive CHECK(master_version>0),
    CONSTRAINT stock_request_submission_shape CHECK(
        (status='DRAFT' AND submitted_by IS NULL AND submitted_at IS NULL)
        OR status='CANCELED'
        OR (submitted_by IS NOT NULL AND submitted_at IS NOT NULL)
    ),
    CONSTRAINT stock_request_close_shape CHECK(
        (status='CLOSED' AND closed_by IS NOT NULL AND closed_at IS NOT NULL)
        OR (status<>'CLOSED' AND closed_by IS NULL AND closed_at IS NULL)
    ),
    CONSTRAINT stock_request_cancel_shape CHECK(
        (status='CANCELED' AND canceled_by IS NOT NULL AND canceled_at IS NOT NULL)
        OR (status<>'CANCELED' AND canceled_by IS NULL AND canceled_at IS NULL)
    )
);

CREATE INDEX idx_stock_request_company_store_status
    ON public.stock_request_documents(company_id,store_id,status,requested_at DESC);
CREATE INDEX idx_stock_request_requester_status
    ON public.stock_request_documents(company_id,requested_by,status);

CREATE TABLE public.stock_request_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    line_no INTEGER NOT NULL,
    client_line_key UUID NOT NULL,
    product_id UUID NOT NULL,
    requested_uom_id UUID NOT NULL,
    requested_qty NUMERIC(24,6) NOT NULL,
    factor_to_base_snapshot NUMERIC(24,6) NOT NULL,
    requested_base_qty NUMERIC(24,6) NOT NULL,
    product_sku_snapshot TEXT NOT NULL,
    product_name_snapshot TEXT NOT NULL,
    requested_uom_name_snapshot TEXT NOT NULL,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT stock_request_lines_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT stock_request_lines_document_line_unique
        UNIQUE(company_id,document_id,line_no),
    CONSTRAINT stock_request_lines_document_client_key_unique
        UNIQUE(company_id,document_id,client_line_key),
    CONSTRAINT stock_request_lines_document_product_uom_unique
        UNIQUE(company_id,document_id,product_id,requested_uom_id),
    CONSTRAINT fk_stock_request_line_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.stock_request_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_stock_request_line_product
        FOREIGN KEY(company_id,product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_stock_request_line_product_uom
        FOREIGN KEY(company_id,product_id,requested_uom_id)
        REFERENCES public.product_uoms(company_id,product_id,uom_id)
        ON DELETE RESTRICT,
    CONSTRAINT stock_request_line_number_positive CHECK(line_no>0),
    CONSTRAINT stock_request_line_quantity_positive CHECK(
        requested_qty>0 AND factor_to_base_snapshot>0 AND requested_base_qty>0
    ),
    CONSTRAINT stock_request_line_snapshot_not_blank CHECK(
        btrim(product_sku_snapshot)<>'' AND btrim(product_name_snapshot)<>''
        AND btrim(requested_uom_name_snapshot)<>''
    )
);

CREATE INDEX idx_stock_request_lines_document
    ON public.stock_request_lines(company_id,document_id,line_no);
CREATE INDEX idx_stock_request_lines_product
    ON public.stock_request_lines(company_id,product_id);

CREATE TABLE public.supplier_order_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    order_no TEXT NOT NULL,
    store_id UUID NOT NULL,
    destination_warehouse_id UUID NOT NULL,
    supplier_id UUID NOT NULL,
    order_date DATE NOT NULL,
    expected_date DATE,
    ordered_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    notes TEXT,
    cancellation_reason TEXT,
    line_count INTEGER NOT NULL DEFAULT 0,
    total_ordered_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
    estimated_total NUMERIC(20,4) NOT NULL DEFAULT 0,
    confirmed_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    confirmed_at TIMESTAMPTZ,
    confirmation_idempotency_key UUID,
    canceled_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    canceled_at TIMESTAMPTZ,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT supplier_order_documents_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT supplier_order_documents_company_no_unique
        UNIQUE(company_id,order_no),
    CONSTRAINT supplier_order_confirmation_key_unique
        UNIQUE(company_id,confirmation_idempotency_key),
    CONSTRAINT fk_supplier_order_company_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_order_company_warehouse
        FOREIGN KEY(company_id,destination_warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_order_company_supplier
        FOREIGN KEY(company_id,supplier_id)
        REFERENCES public.suppliers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT supplier_order_no_not_blank CHECK(btrim(order_no)<>''),
    CONSTRAINT supplier_order_status_check CHECK(status IN(
        'DRAFT','CONFIRMED','PARTIALLY_RECEIVED','RECEIVED','CANCELED'
    )),
    CONSTRAINT supplier_order_date_check CHECK(
        expected_date IS NULL OR expected_date>=order_date
    ),
    CONSTRAINT supplier_order_totals_nonnegative CHECK(
        line_count>=0 AND total_ordered_base_qty>=0 AND estimated_total>=0
    ),
    CONSTRAINT supplier_order_version_positive CHECK(master_version>0),
    CONSTRAINT supplier_order_confirmation_shape CHECK(
        (status='DRAFT' AND confirmed_by IS NULL AND confirmed_at IS NULL
            AND confirmation_idempotency_key IS NULL)
        OR status='CANCELED'
        OR (confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL
            AND confirmation_idempotency_key IS NOT NULL)
    ),
    CONSTRAINT supplier_order_cancel_shape CHECK(
        (status='CANCELED' AND canceled_by IS NOT NULL AND canceled_at IS NOT NULL)
        OR (status<>'CANCELED' AND canceled_by IS NULL AND canceled_at IS NULL)
    )
);

CREATE INDEX idx_supplier_order_company_store_status
    ON public.supplier_order_documents(company_id,store_id,status,order_date DESC);
CREATE INDEX idx_supplier_order_supplier_status
    ON public.supplier_order_documents(company_id,supplier_id,status);

CREATE TABLE public.supplier_order_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    line_no INTEGER NOT NULL,
    client_line_key UUID NOT NULL,
    product_id UUID NOT NULL,
    ordered_uom_id UUID NOT NULL,
    ordered_qty NUMERIC(24,6) NOT NULL,
    factor_to_base_snapshot NUMERIC(24,6) NOT NULL,
    ordered_base_qty NUMERIC(24,6) NOT NULL,
    estimated_unit_price NUMERIC(20,4) NOT NULL,
    estimated_subtotal NUMERIC(20,4) NOT NULL,
    product_sku_snapshot TEXT NOT NULL,
    product_name_snapshot TEXT NOT NULL,
    ordered_uom_name_snapshot TEXT NOT NULL,
    supplier_product_code_snapshot TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT supplier_order_lines_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT supplier_order_lines_document_line_unique
        UNIQUE(company_id,document_id,line_no),
    CONSTRAINT supplier_order_lines_document_client_key_unique
        UNIQUE(company_id,document_id,client_line_key),
    CONSTRAINT supplier_order_lines_document_product_uom_unique
        UNIQUE(company_id,document_id,product_id,ordered_uom_id),
    CONSTRAINT fk_supplier_order_line_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.supplier_order_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_order_line_product
        FOREIGN KEY(company_id,product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_order_line_product_uom
        FOREIGN KEY(company_id,product_id,ordered_uom_id)
        REFERENCES public.product_uoms(company_id,product_id,uom_id)
        ON DELETE RESTRICT,
    CONSTRAINT supplier_order_line_number_positive CHECK(line_no>0),
    CONSTRAINT supplier_order_line_quantity_positive CHECK(
        ordered_qty>0 AND factor_to_base_snapshot>0 AND ordered_base_qty>0
    ),
    CONSTRAINT supplier_order_line_price_nonnegative CHECK(
        estimated_unit_price>=0 AND estimated_subtotal>=0
    ),
    CONSTRAINT supplier_order_line_snapshot_not_blank CHECK(
        btrim(product_sku_snapshot)<>'' AND btrim(product_name_snapshot)<>''
        AND btrim(ordered_uom_name_snapshot)<>''
        AND (supplier_product_code_snapshot IS NULL
             OR btrim(supplier_product_code_snapshot)<>'')
    )
);

CREATE INDEX idx_supplier_order_lines_document
    ON public.supplier_order_lines(company_id,document_id,line_no);
CREATE INDEX idx_supplier_order_lines_product
    ON public.supplier_order_lines(company_id,product_id);

CREATE TABLE public.supplier_order_request_allocations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    supplier_order_line_id UUID NOT NULL,
    stock_request_line_id UUID NOT NULL,
    allocated_base_qty NUMERIC(24,6) NOT NULL,
    created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT supplier_order_request_alloc_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT supplier_order_request_alloc_source_unique
        UNIQUE(company_id,supplier_order_line_id,stock_request_line_id),
    CONSTRAINT fk_supplier_order_request_alloc_order_line
        FOREIGN KEY(company_id,supplier_order_line_id)
        REFERENCES public.supplier_order_lines(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_order_request_alloc_request_line
        FOREIGN KEY(company_id,stock_request_line_id)
        REFERENCES public.stock_request_lines(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT supplier_order_request_alloc_qty_positive
        CHECK(allocated_base_qty>0)
);

CREATE INDEX idx_supplier_order_request_alloc_request
    ON public.supplier_order_request_allocations(
        company_id,stock_request_line_id
    );

CREATE TABLE public.stock_request_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    action TEXT NOT NULL CHECK(action IN(
        'CREATE','UPDATE','SUBMIT','ORDER_PROGRESS','CLOSE','CANCEL'
    )),
    actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fk_stock_request_audit_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.stock_request_documents(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_stock_request_audit_document
    ON public.stock_request_audit(company_id,document_id,created_at DESC);

CREATE TABLE public.supplier_order_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    action TEXT NOT NULL CHECK(action IN('CREATE','UPDATE','CONFIRM','CANCEL')),
    actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fk_supplier_order_audit_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.supplier_order_documents(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_supplier_order_audit_document
    ON public.supplier_order_audit(company_id,document_id,created_at DESC);

CREATE FUNCTION public.private_purchase_manager_allowed(
    p_company_id UUID,p_store_id UUID
) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
    SELECT public.private_request_company_matches(p_company_id)
       AND (
            public.private_is_super_admin(auth.uid())
            OR public.private_user_has_any_company_role(
                p_company_id,
                ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
            )
            OR EXISTS (
                SELECT 1 FROM public.store_memberships membership
                WHERE membership.company_id=p_company_id
                  AND membership.store_id=p_store_id
                  AND membership.user_id=auth.uid()
                  AND membership.role_code='STORE_MANAGER'
                  AND membership.status='ACTIVE'
            )
       );
$$;

CREATE FUNCTION public.private_purchase_document_visible(
    p_company_id UUID,p_store_id UUID
) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
    SELECT public.private_request_company_matches(p_company_id)
       AND (
            public.private_is_super_admin(auth.uid())
            OR public.private_user_has_any_company_role(
                p_company_id,
                ARRAY[
                    'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'
                ]::TEXT[]
            )
            OR EXISTS (
                SELECT 1 FROM public.store_memberships membership
                WHERE membership.company_id=p_company_id
                  AND membership.store_id=p_store_id
                  AND membership.user_id=auth.uid()
                  AND membership.status='ACTIVE'
            )
       );
$$;

CREATE FUNCTION private.trg_g5_guard_stock_request_history()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'STOCK_REQUEST_DELETE_FORBIDDEN';
    END IF;
    IF NEW.company_id IS DISTINCT FROM OLD.company_id
       OR NEW.id IS DISTINCT FROM OLD.id
       OR NEW.request_no IS DISTINCT FROM OLD.request_no
       OR NEW.store_id IS DISTINCT FROM OLD.store_id
       OR NEW.requesting_pos_id IS DISTINCT FROM OLD.requesting_pos_id
       OR NEW.requesting_session_id IS DISTINCT FROM OLD.requesting_session_id
       OR NEW.requested_by IS DISTINCT FROM OLD.requested_by
       OR NEW.requested_at IS DISTINCT FROM OLD.requested_at THEN
        RAISE EXCEPTION 'STOCK_REQUEST_IDENTITY_IMMUTABLE';
    END IF;
    IF OLD.status IN('CLOSED','CANCELED') THEN
        RAISE EXCEPTION 'FINAL_STOCK_REQUEST_IMMUTABLE';
    END IF;
    IF NOT (
        NEW.status=OLD.status
        OR (OLD.status='DRAFT' AND NEW.status IN('SUBMITTED','CANCELED'))
        OR (OLD.status='SUBMITTED' AND NEW.status IN('ORDERED','CLOSED','CANCELED'))
        OR (OLD.status='ORDERED' AND NEW.status IN(
            'SUBMITTED','PARTIALLY_RECEIVED','RECEIVED','CLOSED','CANCELED'
        ))
        OR (OLD.status='PARTIALLY_RECEIVED' AND NEW.status IN(
            'RECEIVED','CLOSED'
        ))
        OR (OLD.status='RECEIVED' AND NEW.status='CLOSED')
    ) THEN
        RAISE EXCEPTION 'INVALID_STOCK_REQUEST_STATUS_TRANSITION';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g5_guard_supplier_order_history()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'SUPPLIER_ORDER_DELETE_FORBIDDEN';
    END IF;
    IF NEW.company_id IS DISTINCT FROM OLD.company_id
       OR NEW.id IS DISTINCT FROM OLD.id
       OR NEW.order_no IS DISTINCT FROM OLD.order_no
       OR NEW.ordered_by IS DISTINCT FROM OLD.ordered_by
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'SUPPLIER_ORDER_IDENTITY_IMMUTABLE';
    END IF;
    IF OLD.status IN('RECEIVED','CANCELED') THEN
        RAISE EXCEPTION 'FINAL_SUPPLIER_ORDER_IMMUTABLE';
    END IF;
    IF NOT (
        NEW.status=OLD.status
        OR (OLD.status='DRAFT' AND NEW.status IN('CONFIRMED','CANCELED'))
        OR (OLD.status='CONFIRMED' AND NEW.status IN(
            'PARTIALLY_RECEIVED','RECEIVED','CANCELED'
        ))
        OR (OLD.status='PARTIALLY_RECEIVED' AND NEW.status IN(
            'RECEIVED','CANCELED'
        ))
    ) THEN
        RAISE EXCEPTION 'INVALID_SUPPLIER_ORDER_STATUS_TRANSITION';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g5_guard_request_line_mutation()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
DECLARE v_document UUID;
BEGIN
    v_document:=CASE WHEN TG_OP='DELETE' THEN OLD.document_id
        ELSE NEW.document_id END;
    IF NOT EXISTS(
        SELECT 1 FROM public.stock_request_documents document
        WHERE document.id=v_document AND document.status='DRAFT'
    ) THEN RAISE EXCEPTION 'FINAL_STOCK_REQUEST_LINES_IMMUTABLE'; END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g5_guard_order_line_mutation()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
DECLARE v_document UUID;
BEGIN
    v_document:=CASE WHEN TG_OP='DELETE' THEN OLD.document_id
        ELSE NEW.document_id END;
    IF NOT EXISTS(
        SELECT 1 FROM public.supplier_order_documents document
        WHERE document.id=v_document AND document.status='DRAFT'
    ) THEN RAISE EXCEPTION 'FINAL_SUPPLIER_ORDER_LINES_IMMUTABLE'; END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g5_guard_order_allocation_mutation()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
DECLARE v_line UUID;
BEGIN
    v_line:=CASE WHEN TG_OP='DELETE' THEN OLD.supplier_order_line_id
        ELSE NEW.supplier_order_line_id END;
    IF NOT EXISTS(
        SELECT 1 FROM public.supplier_order_lines line
        JOIN public.supplier_order_documents document
          ON document.company_id=line.company_id AND document.id=line.document_id
        WHERE line.id=v_line AND document.status='DRAFT'
    ) THEN RAISE EXCEPTION 'FINAL_SUPPLIER_ORDER_ALLOCATIONS_IMMUTABLE'; END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER g5_guard_stock_request_history
BEFORE UPDATE OR DELETE ON public.stock_request_documents
FOR EACH ROW EXECUTE FUNCTION private.trg_g5_guard_stock_request_history();
CREATE TRIGGER g5_guard_supplier_order_history
BEFORE UPDATE OR DELETE ON public.supplier_order_documents
FOR EACH ROW EXECUTE FUNCTION private.trg_g5_guard_supplier_order_history();
CREATE TRIGGER g5_guard_stock_request_lines
BEFORE INSERT OR UPDATE OR DELETE ON public.stock_request_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_g5_guard_request_line_mutation();
CREATE TRIGGER g5_guard_supplier_order_lines
BEFORE INSERT OR UPDATE OR DELETE ON public.supplier_order_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_g5_guard_order_line_mutation();
CREATE TRIGGER g5_guard_supplier_order_allocations
BEFORE INSERT OR UPDATE OR DELETE ON public.supplier_order_request_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_g5_guard_order_allocation_mutation();

CREATE FUNCTION public.save_stock_request(
    p_document_id UUID,p_master_version BIGINT,p_cashier_session_id UUID,
    p_needed_date DATE,p_notes TEXT,p_lines JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
    v_actor UUID:=auth.uid();
    v_company UUID:=public.private_active_company_id();
    v_store UUID; v_pos UUID; v_document UUID; v_no TEXT;
    v_existing public.stock_request_documents%ROWTYPE;
    v_before JSONB; v_after JSONB; v_line RECORD; v_product RECORD;
    v_line_no INTEGER:=0; v_count INTEGER; v_total NUMERIC(24,6);
    v_base NUMERIC(24,6); v_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    SELECT session.store_id,session.pos_id INTO v_store,v_pos
    FROM public.cashier_sessions session
    WHERE session.company_id=v_company AND session.id=p_cashier_session_id
      AND session.cashier_id=v_actor AND session.status='OPEN'::public.session_status;
    IF v_store IS NULL OR v_pos IS NULL THEN
        RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
    END IF;
    IF p_needed_date IS NOT NULL AND p_needed_date<CURRENT_DATE THEN
        RAISE EXCEPTION 'STOCK_REQUEST_NEEDED_DATE_IN_PAST';
    END IF;
    IF p_lines IS NULL OR jsonb_typeof(p_lines)<>'array'
       OR jsonb_array_length(p_lines)=0 THEN
        RAISE EXCEPTION 'STOCK_REQUEST_LINES_REQUIRED';
    END IF;
    IF jsonb_array_length(p_lines)>1000 THEN
        RAISE EXCEPTION 'STOCK_REQUEST_LINE_LIMIT_EXCEEDED';
    END IF;

    IF p_document_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        v_no:='REQ-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'||
            lpad(nextval('private.stock_request_document_no_seq')::TEXT,10,'0');
        INSERT INTO public.stock_request_documents(
            company_id,request_no,store_id,requesting_pos_id,
            requesting_session_id,requested_by,needed_date,notes
        ) VALUES(
            v_company,v_no,v_store,v_pos,p_cashier_session_id,v_actor,
            p_needed_date,NULLIF(btrim(p_notes),'')
        ) RETURNING id,master_version INTO v_document,v_version;
    ELSE
        SELECT * INTO v_existing FROM public.stock_request_documents document
        WHERE document.company_id=v_company AND document.id=p_document_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_REQUEST_NOT_FOUND'; END IF;
        IF v_existing.status<>'DRAFT' THEN
            RAISE EXCEPTION 'FINAL_STOCK_REQUEST_IMMUTABLE';
        END IF;
        IF v_existing.requested_by<>v_actor OR v_existing.store_id<>v_store THEN
            RAISE EXCEPTION 'STOCK_REQUEST_OWNER_REQUIRED';
        END IF;
        IF p_master_version IS NULL OR p_master_version<>v_existing.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        v_before:=to_jsonb(v_existing); v_document:=p_document_id;
        DELETE FROM public.stock_request_lines
        WHERE company_id=v_company AND document_id=v_document;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_to_recordset(p_lines) AS x(
        "clientLineKey" UUID,"productId" UUID,"uomId" UUID,
        "quantity" NUMERIC,"notes" TEXT
    ) LOOP
        v_line_no:=v_line_no+1;
        IF v_line."clientLineKey" IS NULL OR v_line."productId" IS NULL
           OR v_line."uomId" IS NULL THEN
            RAISE EXCEPTION 'STOCK_REQUEST_LINE_REFERENCE_REQUIRED';
        END IF;
        IF v_line."quantity" IS NULL OR v_line."quantity"<=0 THEN
            RAISE EXCEPTION 'STOCK_REQUEST_QUANTITY_MUST_BE_POSITIVE';
        END IF;
        SELECT p.id,p.sku,p.name,pu.factor_to_base,u.name AS uom_name,
            u.allow_decimal,u.decimal_precision
        INTO v_product
        FROM public.products p
        JOIN public.product_uoms pu ON pu.company_id=p.company_id
          AND pu.product_id=p.id AND pu.uom_id=v_line."uomId"
          AND pu.is_active AND pu.purchase_allowed
        JOIN public.uoms u ON u.company_id=pu.company_id AND u.id=pu.uom_id
          AND u.is_active
        WHERE p.company_id=v_company AND p.id=v_line."productId"
          AND p.is_active AND NOT p.is_bundle;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'ACTIVE_PURCHASE_PRODUCT_UOM_NOT_FOUND';
        END IF;
        IF NOT v_product.allow_decimal
           AND v_line."quantity"<>trunc(v_line."quantity") THEN
            RAISE EXCEPTION 'PURCHASE_UOM_REQUIRES_INTEGER';
        END IF;
        IF v_product.allow_decimal AND v_line."quantity"<>round(
            v_line."quantity",v_product.decimal_precision
        ) THEN RAISE EXCEPTION 'PURCHASE_UOM_PRECISION_EXCEEDED'; END IF;
        v_base:=v_line."quantity"*v_product.factor_to_base;
        BEGIN
            INSERT INTO public.stock_request_lines(
                company_id,document_id,line_no,client_line_key,product_id,
                requested_uom_id,requested_qty,factor_to_base_snapshot,
                requested_base_qty,product_sku_snapshot,product_name_snapshot,
                requested_uom_name_snapshot,notes
            ) VALUES(
                v_company,v_document,v_line_no,v_line."clientLineKey",
                v_product.id,v_line."uomId",v_line."quantity",
                v_product.factor_to_base,v_base,v_product.sku,v_product.name,
                v_product.uom_name,NULLIF(btrim(v_line."notes"),'')
            );
        EXCEPTION WHEN unique_violation THEN
            RAISE EXCEPTION 'DUPLICATE_STOCK_REQUEST_PRODUCT_UOM';
        END;
    END LOOP;

    SELECT count(*),sum(requested_base_qty) INTO v_count,v_total
    FROM public.stock_request_lines
    WHERE company_id=v_company AND document_id=v_document;
    UPDATE public.stock_request_documents SET
        needed_date=p_needed_date,notes=NULLIF(btrim(p_notes),''),
        line_count=v_count,requested_total_base_qty=v_total,
        master_version=CASE WHEN p_document_id IS NULL
            THEN master_version ELSE master_version+1 END,
        updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_document
    RETURNING master_version INTO v_version;
    SELECT to_jsonb(document) INTO v_after
    FROM public.stock_request_documents document
    WHERE document.company_id=v_company AND document.id=v_document;
    INSERT INTO public.stock_request_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES(v_company,v_document,CASE WHEN p_document_id IS NULL
        THEN 'CREATE' ELSE 'UPDATE' END,v_actor,v_before,v_after);
    RETURN jsonb_build_object('documentId',v_document,'requestNo',v_after->>'request_no',
        'status','DRAFT','masterVersion',v_version,'lineCount',v_count,
        'requestedTotalBaseQty',v_total);
END;
$$;

CREATE FUNCTION public.submit_stock_request(
    p_document_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_doc public.stock_request_documents%ROWTYPE; v_before JSONB; v_after JSONB;
    v_version BIGINT;
BEGIN
    SELECT * INTO v_doc FROM public.stock_request_documents document
    WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_REQUEST_NOT_FOUND'; END IF;
    IF v_doc.status<>'DRAFT' THEN RAISE EXCEPTION 'STOCK_REQUEST_NOT_DRAFT'; END IF;
    IF v_doc.requested_by<>v_actor THEN RAISE EXCEPTION 'STOCK_REQUEST_OWNER_REQUIRED'; END IF;
    IF p_master_version IS NULL OR p_master_version<>v_doc.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_doc.line_count<=0 THEN RAISE EXCEPTION 'STOCK_REQUEST_LINES_REQUIRED'; END IF;
    v_before:=to_jsonb(v_doc);
    UPDATE public.stock_request_documents SET status='SUBMITTED',
        submitted_by=v_actor,submitted_at=clock_timestamp(),
        master_version=master_version+1,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=p_document_id
    RETURNING master_version INTO v_version;
    SELECT to_jsonb(document) INTO v_after
    FROM public.stock_request_documents document
    WHERE document.company_id=v_company AND document.id=p_document_id;
    INSERT INTO public.stock_request_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES(v_company,p_document_id,'SUBMIT',v_actor,v_before,v_after);
    RETURN jsonb_build_object('documentId',p_document_id,'requestNo',v_doc.request_no,
        'status','SUBMITTED','masterVersion',v_version);
END;
$$;

CREATE FUNCTION public.close_stock_request(
    p_document_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_doc public.stock_request_documents%ROWTYPE; v_before JSONB; v_after JSONB;
    v_version BIGINT;
BEGIN
    SELECT * INTO v_doc FROM public.stock_request_documents document
    WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_REQUEST_NOT_FOUND'; END IF;
    IF NOT public.private_purchase_manager_allowed(v_company,v_doc.store_id) THEN
        RAISE EXCEPTION 'PURCHASE_MANAGER_REQUIRED';
    END IF;
    IF v_doc.status NOT IN('SUBMITTED','ORDERED') THEN
        RAISE EXCEPTION 'STOCK_REQUEST_NOT_CLOSEABLE';
    END IF;
    IF p_master_version IS NULL OR p_master_version<>v_doc.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before:=to_jsonb(v_doc);
    UPDATE public.stock_request_documents SET status='CLOSED',closed_by=v_actor,
        closed_at=clock_timestamp(),master_version=master_version+1,
        updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=p_document_id
    RETURNING master_version INTO v_version;
    SELECT to_jsonb(document) INTO v_after
    FROM public.stock_request_documents document
    WHERE document.company_id=v_company AND document.id=p_document_id;
    INSERT INTO public.stock_request_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES(v_company,p_document_id,'CLOSE',v_actor,v_before,v_after);
    RETURN jsonb_build_object('documentId',p_document_id,'status','CLOSED',
        'masterVersion',v_version);
END;
$$;

CREATE FUNCTION public.cancel_stock_request(
    p_document_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_doc public.stock_request_documents%ROWTYPE; v_before JSONB; v_after JSONB;
    v_version BIGINT;
BEGIN
    SELECT * INTO v_doc FROM public.stock_request_documents document
    WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_REQUEST_NOT_FOUND'; END IF;
    IF v_doc.requested_by<>v_actor
       AND NOT public.private_purchase_manager_allowed(v_company,v_doc.store_id) THEN
        RAISE EXCEPTION 'STOCK_REQUEST_CANCEL_FORBIDDEN';
    END IF;
    IF v_doc.status NOT IN('DRAFT','SUBMITTED','ORDERED') THEN
        RAISE EXCEPTION 'STOCK_REQUEST_NOT_CANCELABLE';
    END IF;
    IF EXISTS(
        SELECT 1 FROM public.supplier_order_request_allocations allocation
        JOIN public.stock_request_lines request_line
          ON request_line.company_id=allocation.company_id
         AND request_line.id=allocation.stock_request_line_id
        JOIN public.supplier_order_lines order_line
          ON order_line.company_id=allocation.company_id
         AND order_line.id=allocation.supplier_order_line_id
        JOIN public.supplier_order_documents order_document
          ON order_document.company_id=order_line.company_id
         AND order_document.id=order_line.document_id
        WHERE request_line.document_id=p_document_id
          AND order_document.status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
    ) THEN RAISE EXCEPTION 'STOCK_REQUEST_HAS_ACTIVE_ORDER'; END IF;
    IF p_master_version IS NULL OR p_master_version<>v_doc.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before:=to_jsonb(v_doc);
    UPDATE public.stock_request_documents SET status='CANCELED',canceled_by=v_actor,
        canceled_at=clock_timestamp(),master_version=master_version+1,
        updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=p_document_id
    RETURNING master_version INTO v_version;
    SELECT to_jsonb(document) INTO v_after
    FROM public.stock_request_documents document
    WHERE document.company_id=v_company AND document.id=p_document_id;
    INSERT INTO public.stock_request_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES(v_company,p_document_id,'CANCEL',v_actor,v_before,v_after);
    RETURN jsonb_build_object('documentId',p_document_id,'status','CANCELED',
        'masterVersion',v_version);
END;
$$;

CREATE FUNCTION public.save_supplier_order(
    p_document_id UUID,p_master_version BIGINT,p_store_id UUID,
    p_destination_warehouse_id UUID,p_supplier_id UUID,p_order_date DATE,
    p_expected_date DATE,p_notes TEXT,p_lines JSONB,p_allocations JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_doc UUID; v_no TEXT; v_existing public.supplier_order_documents%ROWTYPE;
    v_before JSONB; v_after JSONB; v_line RECORD; v_alloc RECORD;
    v_product RECORD; v_order_line UUID; v_count INTEGER; v_line_no INTEGER:=0;
    v_total_base NUMERIC(24,6); v_total NUMERIC(20,4); v_base NUMERIC(24,6);
    v_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF NOT public.private_purchase_manager_allowed(v_company,p_store_id) THEN
        RAISE EXCEPTION 'PURCHASE_MANAGER_REQUIRED';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.stores store WHERE store.company_id=v_company
        AND store.id=p_store_id AND store.status='ACTIVE') THEN
        RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.warehouses warehouse
        WHERE warehouse.company_id=v_company AND warehouse.id=p_destination_warehouse_id
          AND warehouse.is_active AND (warehouse.store_id=p_store_id
              OR warehouse.store_id IS NULL)) THEN
        RAISE EXCEPTION 'ACTIVE_DESTINATION_WAREHOUSE_NOT_FOUND';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.suppliers supplier
        WHERE supplier.company_id=v_company AND supplier.id=p_supplier_id
          AND supplier.is_active) THEN RAISE EXCEPTION 'ACTIVE_SUPPLIER_NOT_FOUND'; END IF;
    IF p_order_date IS NULL THEN RAISE EXCEPTION 'SUPPLIER_ORDER_DATE_REQUIRED'; END IF;
    IF p_expected_date IS NOT NULL AND p_expected_date<p_order_date THEN
        RAISE EXCEPTION 'SUPPLIER_ORDER_EXPECTED_DATE_INVALID';
    END IF;
    IF p_lines IS NULL OR jsonb_typeof(p_lines)<>'array'
       OR jsonb_array_length(p_lines)=0 THEN RAISE EXCEPTION 'SUPPLIER_ORDER_LINES_REQUIRED'; END IF;
    IF jsonb_array_length(p_lines)>1000 THEN RAISE EXCEPTION 'SUPPLIER_ORDER_LINE_LIMIT_EXCEEDED'; END IF;
    IF p_allocations IS NULL OR jsonb_typeof(p_allocations)<>'array' THEN
        RAISE EXCEPTION 'SUPPLIER_ORDER_ALLOCATIONS_REQUIRED';
    END IF;

    IF p_document_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE'; END IF;
        v_no:='PO-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'||
            lpad(nextval('private.supplier_order_document_no_seq')::TEXT,10,'0');
        INSERT INTO public.supplier_order_documents(
            company_id,order_no,store_id,destination_warehouse_id,supplier_id,
            order_date,expected_date,ordered_by,notes
        ) VALUES(v_company,v_no,p_store_id,p_destination_warehouse_id,p_supplier_id,
            p_order_date,p_expected_date,v_actor,NULLIF(btrim(p_notes),''))
        RETURNING id,master_version INTO v_doc,v_version;
    ELSE
        SELECT * INTO v_existing FROM public.supplier_order_documents document
        WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_ORDER_NOT_FOUND'; END IF;
        IF v_existing.status<>'DRAFT' THEN RAISE EXCEPTION 'FINAL_SUPPLIER_ORDER_IMMUTABLE'; END IF;
        IF v_existing.store_id<>p_store_id THEN RAISE EXCEPTION 'SUPPLIER_ORDER_STORE_IMMUTABLE'; END IF;
        IF p_master_version IS NULL OR p_master_version<>v_existing.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        v_before:=to_jsonb(v_existing); v_doc:=p_document_id;
        DELETE FROM public.supplier_order_request_allocations allocation
        USING public.supplier_order_lines line
        WHERE allocation.company_id=v_company
          AND allocation.supplier_order_line_id=line.id
          AND line.document_id=v_doc;
        DELETE FROM public.supplier_order_lines
        WHERE company_id=v_company AND document_id=v_doc;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_to_recordset(p_lines) AS x(
        "clientLineKey" UUID,"productId" UUID,"uomId" UUID,
        "quantity" NUMERIC,"estimatedUnitPrice" NUMERIC
    ) LOOP
        v_line_no:=v_line_no+1;
        IF v_line."clientLineKey" IS NULL OR v_line."productId" IS NULL
           OR v_line."uomId" IS NULL THEN RAISE EXCEPTION 'SUPPLIER_ORDER_LINE_REFERENCE_REQUIRED'; END IF;
        IF v_line."quantity" IS NULL OR v_line."quantity"<=0 THEN
            RAISE EXCEPTION 'SUPPLIER_ORDER_QUANTITY_MUST_BE_POSITIVE';
        END IF;
        IF v_line."estimatedUnitPrice" IS NULL OR v_line."estimatedUnitPrice"<0 THEN
            RAISE EXCEPTION 'SUPPLIER_ORDER_PRICE_INVALID';
        END IF;
        SELECT p.id,p.sku,p.name,pu.factor_to_base,u.name AS uom_name,
            u.allow_decimal,u.decimal_precision,ps.supplier_product_code
        INTO v_product
        FROM public.products p
        JOIN public.product_uoms pu ON pu.company_id=p.company_id
          AND pu.product_id=p.id AND pu.uom_id=v_line."uomId"
          AND pu.is_active AND pu.purchase_allowed
        JOIN public.uoms u ON u.company_id=pu.company_id AND u.id=pu.uom_id
          AND u.is_active
        LEFT JOIN public.product_suppliers ps ON ps.company_id=p.company_id
          AND ps.product_id=p.id AND ps.supplier_id=p_supplier_id AND ps.is_active
        WHERE p.company_id=v_company AND p.id=v_line."productId"
          AND p.is_active AND NOT p.is_bundle;
        IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_PURCHASE_PRODUCT_UOM_NOT_FOUND'; END IF;
        IF NOT v_product.allow_decimal AND v_line."quantity"<>trunc(v_line."quantity") THEN
            RAISE EXCEPTION 'PURCHASE_UOM_REQUIRES_INTEGER';
        END IF;
        IF v_product.allow_decimal AND v_line."quantity"<>round(
            v_line."quantity",v_product.decimal_precision
        ) THEN RAISE EXCEPTION 'PURCHASE_UOM_PRECISION_EXCEEDED'; END IF;
        v_base:=v_line."quantity"*v_product.factor_to_base;
        BEGIN
            INSERT INTO public.supplier_order_lines(
                company_id,document_id,line_no,client_line_key,product_id,
                ordered_uom_id,ordered_qty,factor_to_base_snapshot,ordered_base_qty,
                estimated_unit_price,estimated_subtotal,product_sku_snapshot,
                product_name_snapshot,ordered_uom_name_snapshot,
                supplier_product_code_snapshot
            ) VALUES(v_company,v_doc,v_line_no,v_line."clientLineKey",v_product.id,
                v_line."uomId",v_line."quantity",v_product.factor_to_base,v_base,
                v_line."estimatedUnitPrice",
                round(v_line."quantity"*v_line."estimatedUnitPrice",4),
                v_product.sku,v_product.name,v_product.uom_name,
                v_product.supplier_product_code);
        EXCEPTION WHEN unique_violation THEN
            RAISE EXCEPTION 'DUPLICATE_SUPPLIER_ORDER_PRODUCT_UOM';
        END;
    END LOOP;

    FOR v_alloc IN SELECT * FROM jsonb_to_recordset(p_allocations) AS x(
        "orderLineKey" UUID,"requestLineId" UUID,"allocatedBaseQty" NUMERIC
    ) LOOP
        IF v_alloc."orderLineKey" IS NULL OR v_alloc."requestLineId" IS NULL
           OR v_alloc."allocatedBaseQty" IS NULL OR v_alloc."allocatedBaseQty"<=0 THEN
            RAISE EXCEPTION 'SUPPLIER_ORDER_ALLOCATION_INVALID';
        END IF;
        SELECT order_line.id INTO v_order_line
        FROM public.supplier_order_lines order_line
        JOIN public.stock_request_lines request_line
          ON request_line.company_id=order_line.company_id
         AND request_line.id=v_alloc."requestLineId"
         AND request_line.product_id=order_line.product_id
        JOIN public.stock_request_documents request_document
          ON request_document.company_id=request_line.company_id
         AND request_document.id=request_line.document_id
         AND request_document.store_id=p_store_id
         AND request_document.status IN('SUBMITTED','ORDERED')
        WHERE order_line.company_id=v_company AND order_line.document_id=v_doc
          AND order_line.client_line_key=v_alloc."orderLineKey";
        IF v_order_line IS NULL THEN
            RAISE EXCEPTION 'ELIGIBLE_STOCK_REQUEST_LINE_NOT_FOUND';
        END IF;
        BEGIN
            INSERT INTO public.supplier_order_request_allocations(
                company_id,supplier_order_line_id,stock_request_line_id,
                allocated_base_qty,created_by
            ) VALUES(v_company,v_order_line,v_alloc."requestLineId",
                v_alloc."allocatedBaseQty",v_actor);
        EXCEPTION WHEN unique_violation THEN
            RAISE EXCEPTION 'DUPLICATE_SUPPLIER_ORDER_REQUEST_ALLOCATION';
        END;
    END LOOP;

    IF EXISTS(
        SELECT 1 FROM public.supplier_order_lines line
        LEFT JOIN public.supplier_order_request_allocations allocation
          ON allocation.company_id=line.company_id
         AND allocation.supplier_order_line_id=line.id
        WHERE line.company_id=v_company AND line.document_id=v_doc
        GROUP BY line.id,line.ordered_base_qty
        HAVING COALESCE(sum(allocation.allocated_base_qty),0)>line.ordered_base_qty
    ) THEN RAISE EXCEPTION 'ORDER_ALLOCATION_EXCEEDS_ORDERED_QUANTITY'; END IF;

    SELECT count(*),sum(ordered_base_qty),sum(estimated_subtotal)
    INTO v_count,v_total_base,v_total FROM public.supplier_order_lines
    WHERE company_id=v_company AND document_id=v_doc;
    UPDATE public.supplier_order_documents SET
        destination_warehouse_id=p_destination_warehouse_id,supplier_id=p_supplier_id,
        order_date=p_order_date,expected_date=p_expected_date,
        notes=NULLIF(btrim(p_notes),''),line_count=v_count,
        total_ordered_base_qty=v_total_base,estimated_total=v_total,
        master_version=CASE WHEN p_document_id IS NULL THEN master_version
            ELSE master_version+1 END,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_doc RETURNING master_version INTO v_version;
    SELECT to_jsonb(document) INTO v_after FROM public.supplier_order_documents document
    WHERE document.company_id=v_company AND document.id=v_doc;
    INSERT INTO public.supplier_order_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES(v_company,v_doc,CASE WHEN p_document_id IS NULL THEN 'CREATE'
        ELSE 'UPDATE' END,v_actor,v_before,v_after);
    RETURN jsonb_build_object('documentId',v_doc,'orderNo',v_after->>'order_no',
        'status','DRAFT','masterVersion',v_version,'lineCount',v_count,
        'estimatedTotal',v_total);
END;
$$;

CREATE FUNCTION private.g5_refresh_stock_request_order_status(
    p_company_id UUID,p_document_id UUID,p_actor_id UUID
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_doc public.stock_request_documents%ROWTYPE; v_ordered NUMERIC(24,6);
    v_status TEXT; v_before JSONB; v_after JSONB;
BEGIN
    SELECT * INTO v_doc FROM public.stock_request_documents document
    WHERE document.company_id=p_company_id AND document.id=p_document_id FOR UPDATE;
    IF NOT FOUND OR v_doc.status NOT IN('SUBMITTED','ORDERED') THEN RETURN; END IF;
    SELECT COALESCE(sum(allocation.allocated_base_qty),0) INTO v_ordered
    FROM public.supplier_order_request_allocations allocation
    JOIN public.stock_request_lines request_line
      ON request_line.company_id=allocation.company_id
     AND request_line.id=allocation.stock_request_line_id
    JOIN public.supplier_order_lines order_line
      ON order_line.company_id=allocation.company_id
     AND order_line.id=allocation.supplier_order_line_id
    JOIN public.supplier_order_documents order_document
      ON order_document.company_id=order_line.company_id
     AND order_document.id=order_line.document_id
    WHERE allocation.company_id=p_company_id
      AND request_line.document_id=p_document_id
      AND order_document.status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED');
    v_status:=CASE WHEN v_ordered>=v_doc.requested_total_base_qty
        THEN 'ORDERED' ELSE 'SUBMITTED' END;
    IF v_status<>v_doc.status THEN
        v_before:=to_jsonb(v_doc);
        UPDATE public.stock_request_documents SET status=v_status,
            master_version=master_version+1,updated_at=clock_timestamp()
        WHERE company_id=p_company_id AND id=p_document_id;
        SELECT to_jsonb(document) INTO v_after
        FROM public.stock_request_documents document
        WHERE document.company_id=p_company_id AND document.id=p_document_id;
        INSERT INTO public.stock_request_audit(
            company_id,document_id,action,actor_id,before_state,after_state
        ) VALUES(p_company_id,p_document_id,'ORDER_PROGRESS',p_actor_id,v_before,v_after);
    END IF;
END;
$$;

CREATE FUNCTION public.confirm_supplier_order(
    p_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_doc public.supplier_order_documents%ROWTYPE; v_before JSONB; v_after JSONB;
    v_alloc RECORD; v_requested NUMERIC(24,6); v_other NUMERIC(24,6);
    v_version BIGINT; v_request UUID;
BEGIN
    IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
    SELECT * INTO v_doc FROM public.supplier_order_documents document
    WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_ORDER_NOT_FOUND'; END IF;
    IF NOT public.private_purchase_manager_allowed(v_company,v_doc.store_id) THEN
        RAISE EXCEPTION 'PURCHASE_MANAGER_REQUIRED';
    END IF;
    IF v_doc.status='CONFIRMED' AND v_doc.confirmation_idempotency_key=p_idempotency_key THEN
        RETURN jsonb_build_object('documentId',v_doc.id,'orderNo',v_doc.order_no,
            'status',v_doc.status,'masterVersion',v_doc.master_version,
            'idempotentReplay',TRUE);
    END IF;
    IF v_doc.status<>'DRAFT' THEN RAISE EXCEPTION 'SUPPLIER_ORDER_NOT_DRAFT'; END IF;
    IF p_master_version IS NULL OR p_master_version<>v_doc.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_doc.line_count<=0 OR EXISTS(
        SELECT 1 FROM public.supplier_order_lines line
        LEFT JOIN public.supplier_order_request_allocations allocation
          ON allocation.company_id=line.company_id
         AND allocation.supplier_order_line_id=line.id
        WHERE line.company_id=v_company AND line.document_id=p_document_id
        GROUP BY line.id HAVING count(allocation.id)=0
    ) THEN RAISE EXCEPTION 'SUPPLIER_ORDER_REQUEST_ALLOCATION_REQUIRED'; END IF;

    FOR v_alloc IN
        SELECT allocation.stock_request_line_id,
            sum(allocation.allocated_base_qty) AS current_qty
        FROM public.supplier_order_request_allocations allocation
        JOIN public.supplier_order_lines line
          ON line.company_id=allocation.company_id
         AND line.id=allocation.supplier_order_line_id
        WHERE line.company_id=v_company AND line.document_id=p_document_id
        GROUP BY allocation.stock_request_line_id
        ORDER BY allocation.stock_request_line_id
    LOOP
        SELECT line.requested_base_qty INTO v_requested
        FROM public.stock_request_lines line
        JOIN public.stock_request_documents document
          ON document.company_id=line.company_id AND document.id=line.document_id
        WHERE line.company_id=v_company AND line.id=v_alloc.stock_request_line_id
          AND document.status IN('SUBMITTED','ORDERED') FOR UPDATE OF line,document;
        IF v_requested IS NULL THEN RAISE EXCEPTION 'ELIGIBLE_STOCK_REQUEST_LINE_NOT_FOUND'; END IF;
        SELECT COALESCE(sum(allocation.allocated_base_qty),0) INTO v_other
        FROM public.supplier_order_request_allocations allocation
        JOIN public.supplier_order_lines line
          ON line.company_id=allocation.company_id
         AND line.id=allocation.supplier_order_line_id
        JOIN public.supplier_order_documents document
          ON document.company_id=line.company_id AND document.id=line.document_id
        WHERE allocation.company_id=v_company
          AND allocation.stock_request_line_id=v_alloc.stock_request_line_id
          AND document.id<>p_document_id
          AND document.status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED');
        IF v_other+v_alloc.current_qty>v_requested THEN
            RAISE EXCEPTION 'STOCK_REQUEST_QUANTITY_ALREADY_ORDERED';
        END IF;
    END LOOP;

    v_before:=to_jsonb(v_doc);
    BEGIN
        UPDATE public.supplier_order_documents SET status='CONFIRMED',
            confirmed_by=v_actor,confirmed_at=clock_timestamp(),
            confirmation_idempotency_key=p_idempotency_key,
            master_version=master_version+1,updated_at=clock_timestamp()
        WHERE company_id=v_company AND id=p_document_id
        RETURNING master_version INTO v_version;
        SELECT to_jsonb(document) INTO v_after
        FROM public.supplier_order_documents document
        WHERE document.company_id=v_company AND document.id=p_document_id;
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT';
    END;
    INSERT INTO public.supplier_order_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES(v_company,p_document_id,'CONFIRM',v_actor,v_before,v_after);
    FOR v_request IN
        SELECT DISTINCT request_line.document_id
        FROM public.supplier_order_request_allocations allocation
        JOIN public.supplier_order_lines order_line
          ON order_line.company_id=allocation.company_id
         AND order_line.id=allocation.supplier_order_line_id
        JOIN public.stock_request_lines request_line
          ON request_line.company_id=allocation.company_id
         AND request_line.id=allocation.stock_request_line_id
        WHERE order_line.company_id=v_company AND order_line.document_id=p_document_id
        ORDER BY request_line.document_id
    LOOP
        PERFORM private.g5_refresh_stock_request_order_status(
            v_company,v_request,v_actor
        );
    END LOOP;
    RETURN jsonb_build_object('documentId',p_document_id,'orderNo',v_doc.order_no,
        'status','CONFIRMED','masterVersion',v_version,'idempotentReplay',FALSE);
END;
$$;

CREATE FUNCTION public.cancel_supplier_order(
    p_document_id UUID,p_master_version BIGINT,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_doc public.supplier_order_documents%ROWTYPE; v_before JSONB; v_after JSONB;
    v_version BIGINT; v_request UUID;
BEGIN
    SELECT * INTO v_doc FROM public.supplier_order_documents document
    WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_ORDER_NOT_FOUND'; END IF;
    IF NOT public.private_purchase_manager_allowed(v_company,v_doc.store_id) THEN
        RAISE EXCEPTION 'PURCHASE_MANAGER_REQUIRED';
    END IF;
    IF v_doc.status NOT IN('DRAFT','CONFIRMED') THEN
        RAISE EXCEPTION 'SUPPLIER_ORDER_NOT_CANCELABLE';
    END IF;
    IF p_master_version IS NULL OR p_master_version<>v_doc.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before:=to_jsonb(v_doc);
    UPDATE public.supplier_order_documents SET status='CANCELED',
        cancellation_reason=NULLIF(btrim(p_reason),''),canceled_by=v_actor,
        canceled_at=clock_timestamp(),master_version=master_version+1,
        updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=p_document_id
    RETURNING master_version INTO v_version;
    SELECT to_jsonb(document) INTO v_after
    FROM public.supplier_order_documents document
    WHERE document.company_id=v_company AND document.id=p_document_id;
    INSERT INTO public.supplier_order_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES(v_company,p_document_id,'CANCEL',v_actor,v_before,v_after);
    IF v_doc.status='CONFIRMED' THEN
        FOR v_request IN
            SELECT DISTINCT request_line.document_id
            FROM public.supplier_order_request_allocations allocation
            JOIN public.supplier_order_lines order_line
              ON order_line.company_id=allocation.company_id
             AND order_line.id=allocation.supplier_order_line_id
            JOIN public.stock_request_lines request_line
              ON request_line.company_id=allocation.company_id
             AND request_line.id=allocation.stock_request_line_id
            WHERE order_line.company_id=v_company AND order_line.document_id=p_document_id
            ORDER BY request_line.document_id
        LOOP
            PERFORM private.g5_refresh_stock_request_order_status(
                v_company,v_request,v_actor
            );
        END LOOP;
    END IF;
    RETURN jsonb_build_object('documentId',p_document_id,'status','CANCELED',
        'masterVersion',v_version);
END;
$$;

ALTER TABLE public.stock_request_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_request_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_order_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_order_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_order_request_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_request_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_order_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Stock Request documents readable in Store"
ON public.stock_request_documents FOR SELECT TO authenticated
USING(public.private_purchase_document_visible(company_id,store_id));
CREATE POLICY "Stock Request lines readable in Store"
ON public.stock_request_lines FOR SELECT TO authenticated
USING(EXISTS(SELECT 1 FROM public.stock_request_documents document
    WHERE document.company_id=stock_request_lines.company_id
      AND document.id=stock_request_lines.document_id
      AND public.private_purchase_document_visible(document.company_id,document.store_id)));
CREATE POLICY "Supplier Order documents readable in Store"
ON public.supplier_order_documents FOR SELECT TO authenticated
USING(public.private_purchase_document_visible(company_id,store_id));
CREATE POLICY "Supplier Order lines readable in Store"
ON public.supplier_order_lines FOR SELECT TO authenticated
USING(EXISTS(SELECT 1 FROM public.supplier_order_documents document
    WHERE document.company_id=supplier_order_lines.company_id
      AND document.id=supplier_order_lines.document_id
      AND public.private_purchase_document_visible(document.company_id,document.store_id)));
CREATE POLICY "Supplier Order allocations readable in Store"
ON public.supplier_order_request_allocations FOR SELECT TO authenticated
USING(EXISTS(SELECT 1 FROM public.supplier_order_lines line
    JOIN public.supplier_order_documents document
      ON document.company_id=line.company_id AND document.id=line.document_id
    WHERE line.company_id=supplier_order_request_allocations.company_id
      AND line.id=supplier_order_request_allocations.supplier_order_line_id
      AND public.private_purchase_document_visible(document.company_id,document.store_id)));
CREATE POLICY "Stock Request audit readable in Store"
ON public.stock_request_audit FOR SELECT TO authenticated
USING(EXISTS(SELECT 1 FROM public.stock_request_documents document
    WHERE document.company_id=stock_request_audit.company_id
      AND document.id=stock_request_audit.document_id
      AND public.private_purchase_document_visible(document.company_id,document.store_id)));
CREATE POLICY "Supplier Order audit readable in Store"
ON public.supplier_order_audit FOR SELECT TO authenticated
USING(EXISTS(SELECT 1 FROM public.supplier_order_documents document
    WHERE document.company_id=supplier_order_audit.company_id
      AND document.id=supplier_order_audit.document_id
      AND public.private_purchase_document_visible(document.company_id,document.store_id)));

REVOKE ALL ON public.stock_request_documents,public.stock_request_lines,
    public.supplier_order_documents,public.supplier_order_lines,
    public.supplier_order_request_allocations,public.stock_request_audit,
    public.supplier_order_audit FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.stock_request_documents,public.stock_request_lines,
    public.supplier_order_documents,public.supplier_order_lines,
    public.supplier_order_request_allocations,public.stock_request_audit,
    public.supplier_order_audit TO authenticated;
GRANT ALL ON public.stock_request_documents,public.stock_request_lines,
    public.supplier_order_documents,public.supplier_order_lines,
    public.supplier_order_request_allocations,public.stock_request_audit,
    public.supplier_order_audit TO service_role;

REVOKE ALL ON FUNCTION public.private_purchase_manager_allowed(UUID,UUID),
    public.private_purchase_document_visible(UUID,UUID),
    public.save_stock_request(UUID,BIGINT,UUID,DATE,TEXT,JSONB),
    public.submit_stock_request(UUID,BIGINT),
    public.close_stock_request(UUID,BIGINT),
    public.cancel_stock_request(UUID,BIGINT),
    public.save_supplier_order(UUID,BIGINT,UUID,UUID,UUID,DATE,DATE,TEXT,JSONB,JSONB),
    public.confirm_supplier_order(UUID,BIGINT,UUID),
    public.cancel_supplier_order(UUID,BIGINT,TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.private_purchase_manager_allowed(UUID,UUID),
    public.private_purchase_document_visible(UUID,UUID),
    public.save_stock_request(UUID,BIGINT,UUID,DATE,TEXT,JSONB),
    public.submit_stock_request(UUID,BIGINT),
    public.close_stock_request(UUID,BIGINT),
    public.cancel_stock_request(UUID,BIGINT),
    public.save_supplier_order(UUID,BIGINT,UUID,UUID,UUID,DATE,DATE,TEXT,JSONB,JSONB),
    public.confirm_supplier_order(UUID,BIGINT,UUID),
    public.cancel_supplier_order(UUID,BIGINT,TEXT)
TO authenticated,service_role;

REVOKE ALL ON FUNCTION private.trg_g5_guard_stock_request_history(),
    private.trg_g5_guard_supplier_order_history(),
    private.trg_g5_guard_request_line_mutation(),
    private.trg_g5_guard_order_line_mutation(),
    private.trg_g5_guard_order_allocation_mutation(),
    private.g5_refresh_stock_request_order_status(UUID,UUID,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g5_guard_stock_request_history(),
    private.trg_g5_guard_supplier_order_history(),
    private.trg_g5_guard_request_line_mutation(),
    private.trg_g5_guard_order_line_mutation(),
    private.trg_g5_guard_order_allocation_mutation(),
    private.g5_refresh_stock_request_order_status(UUID,UUID,UUID)
TO service_role;

DO $retire_legacy$
BEGIN
    IF to_regprocedure('public.confirm_purchase_order(uuid,uuid)') IS NOT NULL THEN
        EXECUTE 'REVOKE ALL ON FUNCTION public.confirm_purchase_order(UUID,UUID) '
            || 'FROM PUBLIC,anon,authenticated,service_role';
    END IF;
END
$retire_legacy$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260806010000','g5_phase2_stock_request_supplier_order_foundation',
    'PUR-001 guarded Stock Request and Supplier Order Draft/Submit/Confirm/Cancel with Base-UOM snapshots, request allocation, concurrency locks, idempotency, audit, and zero Stock/FIFO/AP effect');

COMMIT;
