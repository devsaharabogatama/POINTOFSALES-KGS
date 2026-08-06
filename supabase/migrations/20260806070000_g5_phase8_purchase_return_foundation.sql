-- KGS POS G5 phase 8: canonical Purchase Return foundation.
BEGIN;

DO $guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260806050000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Goods Receipt chain missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260806070000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260806070000';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'purchase_return_documents'
          AND c.relkind IN ('r','p')
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Purchase Return objects exist';
    END IF;
END
$guard$;

ALTER TYPE public.event_type
    ADD VALUE IF NOT EXISTS 'PURCHASE_RETURN_POSTED';

CREATE SEQUENCE private.purchase_return_no_seq AS BIGINT START 1;
REVOKE ALL ON SEQUENCE private.purchase_return_no_seq
FROM PUBLIC, anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE private.purchase_return_no_seq TO service_role;

CREATE TABLE public.purchase_return_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    return_no TEXT NOT NULL,
    source_receipt_id UUID NOT NULL,
    supplier_order_id UUID NOT NULL,
    supplier_id UUID NOT NULL,
    store_id UUID NOT NULL,
    source_warehouse_id UUID NOT NULL,
    created_session_id UUID NOT NULL,
    created_pos_id UUID NOT NULL,
    return_date DATE NOT NULL DEFAULT current_date,
    return_reason TEXT NOT NULL,
    supplier_document_no TEXT,
    notes TEXT,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    review_status TEXT NOT NULL DEFAULT 'PENDING',
    line_count INTEGER NOT NULL DEFAULT 0,
    total_return_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
    provisional_ap_adjustment_total NUMERIC(20,4) NOT NULL DEFAULT 0,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    reviewed_by UUID REFERENCES public.profiles(id),
    reviewed_at TIMESTAMPTZ,
    review_reason TEXT,
    handed_over_at TIMESTAMPTZ,
    posting_idempotency_key UUID,
    financial_event_id UUID
        REFERENCES public.financial_events(id) ON DELETE RESTRICT,
    posted_by UUID REFERENCES public.profiles(id),
    posted_at TIMESTAMPTZ,
    canceled_by UUID REFERENCES public.profiles(id),
    canceled_at TIMESTAMPTZ,
    cancel_reason TEXT,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT purchase_return_documents_company_id_id_unique
        UNIQUE (company_id,id),
    CONSTRAINT purchase_return_documents_company_no_unique
        UNIQUE (company_id,return_no),
    CONSTRAINT purchase_return_documents_company_post_key_unique
        UNIQUE (company_id,posting_idempotency_key),
    CONSTRAINT fk_purchase_return_receipt FOREIGN KEY (
        company_id,source_receipt_id
    ) REFERENCES public.goods_receipt_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_order FOREIGN KEY (
        company_id,supplier_order_id
    ) REFERENCES public.supplier_order_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_supplier FOREIGN KEY (
        company_id,supplier_id
    ) REFERENCES public.suppliers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_store FOREIGN KEY (
        company_id,store_id
    ) REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_warehouse FOREIGN KEY (
        company_id,source_warehouse_id
    ) REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_session FOREIGN KEY (
        company_id,created_session_id
    ) REFERENCES public.cashier_sessions(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_pos FOREIGN KEY (
        company_id,created_pos_id
    ) REFERENCES public.pos_terminals(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT purchase_return_no_not_blank
        CHECK (btrim(return_no) <> ''),
    CONSTRAINT purchase_return_reason_not_blank
        CHECK (btrim(return_reason) <> ''),
    CONSTRAINT purchase_return_status_check
        CHECK (status IN ('DRAFT','POSTED','CANCELED')),
    CONSTRAINT purchase_return_review_status_check
        CHECK (review_status IN ('PENDING','APPROVED','REJECTED')),
    CONSTRAINT purchase_return_totals_check CHECK (
        line_count >= 0
        AND total_return_base_qty >= 0
        AND provisional_ap_adjustment_total >= 0
    ),
    CONSTRAINT purchase_return_master_version_positive
        CHECK (master_version > 0),
    CONSTRAINT purchase_return_review_shape CHECK (
        (review_status = 'PENDING'
            AND reviewed_by IS NULL AND reviewed_at IS NULL)
        OR (review_status IN ('APPROVED','REJECTED')
            AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL)
    ),
    CONSTRAINT purchase_return_final_shape CHECK (
        (status = 'DRAFT'
            AND posted_by IS NULL AND posted_at IS NULL
            AND posting_idempotency_key IS NULL
            AND financial_event_id IS NULL
            AND canceled_by IS NULL AND canceled_at IS NULL)
        OR (status = 'POSTED'
            AND review_status = 'APPROVED'
            AND posted_by IS NOT NULL AND posted_at IS NOT NULL
            AND handed_over_at IS NOT NULL
            AND posting_idempotency_key IS NOT NULL
            AND financial_event_id IS NOT NULL
            AND canceled_by IS NULL AND canceled_at IS NULL)
        OR (status = 'CANCELED'
            AND canceled_by IS NOT NULL AND canceled_at IS NOT NULL
            AND NULLIF(btrim(cancel_reason),'') IS NOT NULL
            AND posted_by IS NULL AND posted_at IS NULL
            AND posting_idempotency_key IS NULL
            AND financial_event_id IS NULL)
    )
);

CREATE TABLE public.purchase_return_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    line_no INTEGER NOT NULL,
    client_line_key UUID NOT NULL,
    source_receipt_line_id UUID NOT NULL,
    source_condition_allocation_id UUID NOT NULL,
    source_product_batch_id UUID NOT NULL,
    product_id UUID NOT NULL,
    return_uom_id UUID NOT NULL,
    return_qty NUMERIC(24,6) NOT NULL,
    factor_to_base_snapshot NUMERIC(24,6) NOT NULL,
    return_base_qty NUMERIC(24,6) NOT NULL,
    provisional_base_unit_cost_snapshot NUMERIC(20,4) NOT NULL,
    provisional_return_value NUMERIC(20,4) NOT NULL,
    source_condition_snapshot TEXT NOT NULL,
    product_sku_snapshot TEXT NOT NULL,
    product_name_snapshot TEXT NOT NULL,
    return_uom_name_snapshot TEXT NOT NULL,
    base_uom_id UUID NOT NULL,
    base_uom_name_snapshot TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT purchase_return_lines_company_id_id_unique
        UNIQUE (company_id,id),
    CONSTRAINT purchase_return_lines_document_line_unique
        UNIQUE (company_id,document_id,line_no),
    CONSTRAINT purchase_return_lines_document_client_unique
        UNIQUE (company_id,document_id,client_line_key),
    CONSTRAINT purchase_return_lines_document_source_unique
        UNIQUE (company_id,document_id,source_condition_allocation_id),
    CONSTRAINT fk_purchase_return_line_document FOREIGN KEY (
        company_id,document_id
    ) REFERENCES public.purchase_return_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_line_receipt FOREIGN KEY (
        company_id,source_receipt_line_id
    ) REFERENCES public.goods_receipt_lines(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_line_condition FOREIGN KEY (
        company_id,source_condition_allocation_id
    ) REFERENCES public.goods_receipt_condition_allocations(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_line_batch FOREIGN KEY (
        company_id,source_product_batch_id
    ) REFERENCES public.product_batches(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_line_product FOREIGN KEY (
        company_id,product_id
    ) REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_line_product_uom FOREIGN KEY (
        company_id,product_id,return_uom_id
    ) REFERENCES public.product_uoms(company_id,product_id,uom_id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_line_base_uom FOREIGN KEY (
        company_id,base_uom_id
    ) REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT purchase_return_line_number_positive CHECK (line_no > 0),
    CONSTRAINT purchase_return_line_quantity_positive CHECK (
        return_qty > 0 AND factor_to_base_snapshot > 0
        AND return_base_qty > 0
    ),
    CONSTRAINT purchase_return_line_value_nonnegative CHECK (
        provisional_base_unit_cost_snapshot >= 0
        AND provisional_return_value >= 0
    ),
    CONSTRAINT purchase_return_line_condition_check
        CHECK (source_condition_snapshot IN ('GOOD','DAMAGED')),
    CONSTRAINT purchase_return_line_snapshot_not_blank CHECK (
        btrim(product_sku_snapshot) <> ''
        AND btrim(product_name_snapshot) <> ''
        AND btrim(return_uom_name_snapshot) <> ''
        AND btrim(base_uom_name_snapshot) <> ''
    )
);

CREATE TABLE public.purchase_return_fifo_allocations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    return_line_id UUID NOT NULL,
    source_product_batch_id UUID NOT NULL,
    product_id UUID NOT NULL,
    warehouse_id UUID NOT NULL,
    quantity_base NUMERIC(24,6) NOT NULL,
    fifo_unit_cost NUMERIC(20,4) NOT NULL,
    fifo_cost_total NUMERIC(20,4) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT purchase_return_fifo_company_id_id_unique
        UNIQUE (company_id,id),
    CONSTRAINT purchase_return_fifo_line_unique
        UNIQUE (company_id,return_line_id),
    CONSTRAINT fk_purchase_return_fifo_document FOREIGN KEY (
        company_id,document_id
    ) REFERENCES public.purchase_return_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_fifo_line FOREIGN KEY (
        company_id,return_line_id
    ) REFERENCES public.purchase_return_lines(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_fifo_batch FOREIGN KEY (
        company_id,source_product_batch_id
    ) REFERENCES public.product_batches(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_fifo_product FOREIGN KEY (
        company_id,product_id
    ) REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_fifo_warehouse FOREIGN KEY (
        company_id,warehouse_id
    ) REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT purchase_return_fifo_quantity_positive
        CHECK (quantity_base > 0),
    CONSTRAINT purchase_return_fifo_cost_nonnegative CHECK (
        fifo_unit_cost >= 0 AND fifo_cost_total >= 0
    )
);

CREATE TABLE public.purchase_return_ap_adjustments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    return_line_id UUID NOT NULL,
    source_ap_provisional_id UUID NOT NULL,
    supplier_id UUID NOT NULL,
    adjustment_route TEXT NOT NULL,
    amount NUMERIC(20,4) NOT NULL,
    status TEXT NOT NULL DEFAULT 'HOLD',
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT purchase_return_ap_company_id_id_unique
        UNIQUE (company_id,id),
    CONSTRAINT purchase_return_ap_line_unique
        UNIQUE (company_id,return_line_id),
    CONSTRAINT fk_purchase_return_ap_document FOREIGN KEY (
        company_id,document_id
    ) REFERENCES public.purchase_return_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_ap_line FOREIGN KEY (
        company_id,return_line_id
    ) REFERENCES public.purchase_return_lines(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_ap_source FOREIGN KEY (
        company_id,source_ap_provisional_id
    ) REFERENCES public.goods_receipt_ap_provisionals(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_purchase_return_ap_supplier FOREIGN KEY (
        company_id,supplier_id
    ) REFERENCES public.suppliers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT purchase_return_ap_route_check CHECK (
        adjustment_route IN ('AP_PROVISIONAL','SUPPLIER_CREDIT_PENDING')
    ),
    CONSTRAINT purchase_return_ap_amount_positive CHECK (amount > 0),
    CONSTRAINT purchase_return_ap_status_check
        CHECK (status IN ('HOLD','POSTED','REVERSED'))
);

CREATE TABLE public.purchase_return_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    action TEXT NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fk_purchase_return_audit_document FOREIGN KEY (
        company_id,document_id
    ) REFERENCES public.purchase_return_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT purchase_return_audit_action_check CHECK (
        action IN ('CREATE','UPDATE','APPROVE','REJECT','POST','CANCEL')
    )
);

CREATE INDEX idx_purchase_return_source_status
    ON public.purchase_return_documents(company_id,source_receipt_id,status);
CREATE INDEX idx_purchase_return_store_status
    ON public.purchase_return_documents(company_id,store_id,status,return_date);
CREATE INDEX idx_purchase_return_lines_source
    ON public.purchase_return_lines(
        company_id,source_condition_allocation_id,document_id
    );
CREATE INDEX idx_purchase_return_fifo_batch
    ON public.purchase_return_fifo_allocations(
        company_id,source_product_batch_id
    );

CREATE FUNCTION private.trg_g5_purchase_return_history_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_document_id UUID;
    v_status TEXT;
BEGIN
    IF TG_TABLE_NAME = 'purchase_return_documents' THEN
        IF TG_OP <> 'INSERT' AND OLD.status IN ('POSTED','CANCELED') THEN
            RAISE EXCEPTION 'FINAL_PURCHASE_RETURN_IMMUTABLE';
        END IF;
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    ELSIF TG_TABLE_NAME = 'purchase_return_lines' THEN
        v_document_id := CASE WHEN TG_OP = 'DELETE'
            THEN OLD.document_id ELSE NEW.document_id END;
    ELSIF TG_TABLE_NAME = 'purchase_return_fifo_allocations' THEN
        v_document_id := CASE WHEN TG_OP = 'DELETE'
            THEN OLD.document_id ELSE NEW.document_id END;
    ELSIF TG_TABLE_NAME = 'purchase_return_ap_adjustments' THEN
        v_document_id := CASE WHEN TG_OP = 'DELETE'
            THEN OLD.document_id ELSE NEW.document_id END;
    ELSE
        RAISE EXCEPTION 'PURCHASE_RETURN_HISTORY_TABLE_UNSUPPORTED';
    END IF;

    SELECT document.status INTO v_status
    FROM public.purchase_return_documents document
    WHERE document.id = v_document_id;
    IF v_status IS DISTINCT FROM 'DRAFT' THEN
        RAISE EXCEPTION 'FINAL_PURCHASE_RETURN_IMMUTABLE';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g5_purchase_return_audit_immutable()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'PURCHASE_RETURN_AUDIT_IMMUTABLE';
END;
$$;

CREATE TRIGGER g5_guard_purchase_return_documents
BEFORE UPDATE OR DELETE ON public.purchase_return_documents
FOR EACH ROW EXECUTE FUNCTION private.trg_g5_purchase_return_history_guard();
CREATE TRIGGER g5_guard_purchase_return_lines
BEFORE INSERT OR UPDATE OR DELETE ON public.purchase_return_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_g5_purchase_return_history_guard();
CREATE TRIGGER g5_guard_purchase_return_fifo
BEFORE INSERT OR UPDATE OR DELETE ON public.purchase_return_fifo_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_g5_purchase_return_history_guard();
CREATE TRIGGER g5_guard_purchase_return_ap
BEFORE INSERT OR UPDATE OR DELETE ON public.purchase_return_ap_adjustments
FOR EACH ROW EXECUTE FUNCTION private.trg_g5_purchase_return_history_guard();
CREATE TRIGGER g5_guard_purchase_return_audit
BEFORE UPDATE OR DELETE ON public.purchase_return_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_g5_purchase_return_audit_immutable();

CREATE FUNCTION public.save_purchase_return_draft(
    p_document_id UUID,
    p_master_version BIGINT,
    p_cashier_session_id UUID,
    p_source_receipt_id UUID,
    p_source_warehouse_id UUID,
    p_return_date DATE,
    p_return_reason TEXT,
    p_supplier_document_no TEXT,
    p_notes TEXT,
    p_lines JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_session RECORD;
    v_receipt RECORD;
    v_document public.purchase_return_documents%ROWTYPE;
    v_document_id UUID;
    v_return_no TEXT;
    v_line RECORD;
    v_source RECORD;
    v_uom RECORD;
    v_line_no INTEGER := 0;
    v_return_base NUMERIC(24,6);
    v_prior_return NUMERIC(24,6);
    v_total_base NUMERIC(24,6) := 0;
    v_total_value NUMERIC(20,4) := 0;
    v_before JSONB;
    v_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NULLIF(btrim(p_return_reason),'') IS NULL THEN
        RAISE EXCEPTION 'PURCHASE_RETURN_REASON_REQUIRED';
    END IF;
    IF p_return_date IS NULL THEN RAISE EXCEPTION 'RETURN_DATE_REQUIRED'; END IF;
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array'
       OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'PURCHASE_RETURN_LINES_REQUIRED';
    END IF;
    SELECT session.store_id,session.pos_id
      INTO v_session
    FROM public.cashier_sessions session
    WHERE session.company_id = v_company
      AND session.id = p_cashier_session_id
      AND session.cashier_id = v_actor
      AND session.status = 'OPEN'::public.session_status;
    IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;
    SELECT receipt.*,orders.supplier_id
      INTO v_receipt
    FROM public.goods_receipt_documents receipt
    JOIN public.supplier_order_documents orders
      ON orders.company_id = receipt.company_id
     AND orders.id = receipt.supplier_order_id
    WHERE receipt.company_id = v_company
      AND receipt.id = p_source_receipt_id
      AND receipt.status = 'POSTED';
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTED_GOODS_RECEIPT_NOT_FOUND'; END IF;
    IF v_receipt.store_id <> v_session.store_id THEN
        RAISE EXCEPTION 'PURCHASE_RETURN_STORE_SCOPE_INVALID';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.warehouses warehouse
        WHERE warehouse.company_id = v_company
          AND warehouse.id = p_source_warehouse_id
          AND warehouse.is_active
          AND (warehouse.store_id = v_receipt.store_id
               OR warehouse.store_id IS NULL)
    ) THEN RAISE EXCEPTION 'ACTIVE_RETURN_SOURCE_WAREHOUSE_NOT_FOUND'; END IF;

    IF p_document_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        v_return_no := 'PR-' || to_char(clock_timestamp(),'YYYYMMDD') || '-'
            || lpad(nextval('private.purchase_return_no_seq')::TEXT,10,'0');
        INSERT INTO public.purchase_return_documents(
            company_id,return_no,source_receipt_id,supplier_order_id,
            supplier_id,store_id,source_warehouse_id,created_session_id,
            created_pos_id,return_date,return_reason,supplier_document_no,
            notes,created_by
        ) VALUES (
            v_company,v_return_no,v_receipt.id,v_receipt.supplier_order_id,
            v_receipt.supplier_id,v_receipt.store_id,p_source_warehouse_id,
            p_cashier_session_id,v_session.pos_id,p_return_date,
            btrim(p_return_reason),NULLIF(btrim(p_supplier_document_no),''),
            NULLIF(btrim(p_notes),''),v_actor
        ) RETURNING id,master_version INTO v_document_id,v_version;
    ELSE
        SELECT * INTO v_document
        FROM public.purchase_return_documents document
        WHERE document.company_id = v_company AND document.id = p_document_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_RETURN_NOT_FOUND'; END IF;
        IF v_document.status <> 'DRAFT' THEN
            RAISE EXCEPTION 'FINAL_PURCHASE_RETURN_IMMUTABLE';
        END IF;
        IF v_document.created_by <> v_actor
           OR v_document.created_session_id <> p_cashier_session_id THEN
            RAISE EXCEPTION 'PURCHASE_RETURN_OWNER_SCOPE_INVALID';
        END IF;
        IF v_document.source_receipt_id <> p_source_receipt_id
           OR v_document.source_warehouse_id <> p_source_warehouse_id THEN
            RAISE EXCEPTION 'PURCHASE_RETURN_SOURCE_IMMUTABLE';
        END IF;
        IF p_master_version IS DISTINCT FROM v_document.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        v_before := to_jsonb(v_document);
        v_document_id := v_document.id;
        v_return_no := v_document.return_no;
        DELETE FROM public.purchase_return_lines
        WHERE company_id = v_company AND document_id = v_document_id;
    END IF;

    FOR v_line IN
        SELECT * FROM jsonb_to_recordset(p_lines) AS input(
            "clientLineKey" UUID,
            "sourceConditionAllocationId" UUID,
            "returnUomId" UUID,
            "returnQty" NUMERIC
        )
    LOOP
        v_line_no := v_line_no + 1;
        IF v_line."clientLineKey" IS NULL THEN
            RAISE EXCEPTION 'PURCHASE_RETURN_CLIENT_LINE_KEY_REQUIRED';
        END IF;
        SELECT allocation.id AS allocation_id,allocation.condition_type,
               allocation.warehouse_id,allocation.quantity_base,
               allocation.product_batch_id,line.id AS receipt_line_id,
               line.product_id,line.base_uom_id,line.base_uom_name_snapshot,
               line.estimated_base_unit_cost,line.product_sku_snapshot,
               line.product_name_snapshot,batch.qty_remaining
          INTO v_source
        FROM public.goods_receipt_condition_allocations allocation
        JOIN public.goods_receipt_lines line
          ON line.company_id = allocation.company_id
         AND line.id = allocation.receipt_line_id
        JOIN public.product_batches batch
          ON batch.company_id = allocation.company_id
         AND batch.id = allocation.product_batch_id
        WHERE allocation.company_id = v_company
          AND allocation.id = v_line."sourceConditionAllocationId"
          AND line.document_id = v_receipt.id
          AND allocation.condition_type IN ('GOOD','DAMAGED')
          AND allocation.warehouse_id = p_source_warehouse_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'RETURNABLE_RECEIPT_ALLOCATION_NOT_FOUND';
        END IF;
        SELECT product_uom.factor_to_base,uom.name,uom.allow_decimal
          INTO v_uom
        FROM public.product_uoms product_uom
        JOIN public.uoms uom
          ON uom.company_id = product_uom.company_id
         AND uom.id = product_uom.uom_id
        WHERE product_uom.company_id = v_company
          AND product_uom.product_id = v_source.product_id
          AND product_uom.uom_id = v_line."returnUomId"
          AND product_uom.is_active
          AND product_uom.purchase_allowed
          AND uom.is_active;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'ACTIVE_RETURN_PRODUCT_UOM_NOT_FOUND';
        END IF;
        IF v_line."returnQty" IS NULL OR v_line."returnQty" <= 0 THEN
            RAISE EXCEPTION 'PURCHASE_RETURN_QUANTITY_INVALID';
        END IF;
        IF NOT v_uom.allow_decimal
           AND v_line."returnQty" <> trunc(v_line."returnQty") THEN
            RAISE EXCEPTION 'RETURN_UOM_REQUIRES_INTEGER';
        END IF;
        v_return_base := v_line."returnQty" * v_uom.factor_to_base;
        SELECT COALESCE(sum(return_line.return_base_qty),0)
          INTO v_prior_return
        FROM public.purchase_return_lines return_line
        JOIN public.purchase_return_documents return_document
          ON return_document.company_id = return_line.company_id
         AND return_document.id = return_line.document_id
         AND return_document.status = 'POSTED'
        WHERE return_line.company_id = v_company
          AND return_line.source_condition_allocation_id = v_source.allocation_id;
        IF v_prior_return + v_return_base > v_source.quantity_base
           OR v_return_base > v_source.qty_remaining THEN
            RAISE EXCEPTION 'PURCHASE_RETURN_QUANTITY_EXCEEDS_AVAILABLE';
        END IF;
        INSERT INTO public.purchase_return_lines(
            company_id,document_id,line_no,client_line_key,
            source_receipt_line_id,source_condition_allocation_id,
            source_product_batch_id,product_id,return_uom_id,return_qty,
            factor_to_base_snapshot,return_base_qty,
            provisional_base_unit_cost_snapshot,provisional_return_value,
            source_condition_snapshot,product_sku_snapshot,
            product_name_snapshot,return_uom_name_snapshot,base_uom_id,
            base_uom_name_snapshot
        ) VALUES (
            v_company,v_document_id,v_line_no,v_line."clientLineKey",
            v_source.receipt_line_id,v_source.allocation_id,
            v_source.product_batch_id,v_source.product_id,
            v_line."returnUomId",v_line."returnQty",v_uom.factor_to_base,
            v_return_base,v_source.estimated_base_unit_cost,
            round(v_return_base*v_source.estimated_base_unit_cost,4),
            v_source.condition_type,v_source.product_sku_snapshot,
            v_source.product_name_snapshot,v_uom.name,v_source.base_uom_id,
            v_source.base_uom_name_snapshot
        );
        v_total_base := v_total_base + v_return_base;
        v_total_value := v_total_value
            + round(v_return_base*v_source.estimated_base_unit_cost,4);
    END LOOP;

    UPDATE public.purchase_return_documents SET
        return_date = p_return_date,
        return_reason = btrim(p_return_reason),
        supplier_document_no = NULLIF(btrim(p_supplier_document_no),''),
        notes = NULLIF(btrim(p_notes),''),
        review_status = 'PENDING',reviewed_by = NULL,reviewed_at = NULL,
        review_reason = NULL,line_count = v_line_no,
        total_return_base_qty = v_total_base,
        provisional_ap_adjustment_total = v_total_value,
        master_version = CASE WHEN p_document_id IS NULL
            THEN master_version ELSE master_version + 1 END,
        updated_at = clock_timestamp()
    WHERE company_id = v_company AND id = v_document_id
    RETURNING master_version INTO v_version;
    INSERT INTO public.purchase_return_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) SELECT v_company,v_document_id,
             CASE WHEN p_document_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
             v_actor,v_before,to_jsonb(document)
      FROM public.purchase_return_documents document
      WHERE document.company_id = v_company AND document.id = v_document_id;
    RETURN jsonb_build_object(
        'documentId',v_document_id,'returnNo',v_return_no,
        'status','DRAFT','reviewStatus','PENDING',
        'masterVersion',v_version,'provisionalReturnValue',v_total_value
    );
END;
$$;

CREATE FUNCTION public.review_purchase_return(
    p_document_id UUID,
    p_master_version BIGINT,
    p_decision TEXT,
    p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_document public.purchase_return_documents%ROWTYPE;
    v_before JSONB;
    v_version BIGINT;
    v_decision TEXT := upper(btrim(COALESCE(p_decision,'')));
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    SELECT * INTO v_document
    FROM public.purchase_return_documents document
    WHERE document.company_id = v_company AND document.id = p_document_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_RETURN_NOT_FOUND'; END IF;
    IF v_document.status <> 'DRAFT' THEN
        RAISE EXCEPTION 'PURCHASE_RETURN_NOT_REVIEWABLE';
    END IF;
    IF p_master_version IS DISTINCT FROM v_document.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF NOT public.private_purchase_manager_allowed(
        v_company,v_document.store_id
    ) THEN RAISE EXCEPTION 'PURCHASE_RETURN_APPROVER_REQUIRED'; END IF;
    IF v_decision NOT IN ('APPROVE','REJECT') THEN
        RAISE EXCEPTION 'PURCHASE_RETURN_REVIEW_DECISION_INVALID';
    END IF;
    IF v_decision = 'REJECT' AND NULLIF(btrim(p_reason),'') IS NULL THEN
        RAISE EXCEPTION 'REJECTION_REASON_REQUIRED';
    END IF;
    v_before := to_jsonb(v_document);
    IF v_decision = 'APPROVE' THEN
        UPDATE public.purchase_return_documents SET
            review_status = 'APPROVED',reviewed_by = v_actor,
            reviewed_at = clock_timestamp(),review_reason = NULL,
            master_version = master_version + 1,
            updated_at = clock_timestamp()
        WHERE company_id = v_company AND id = v_document.id
        RETURNING master_version INTO v_version;
    ELSE
        UPDATE public.purchase_return_documents SET
            status = 'CANCELED',review_status = 'REJECTED',
            reviewed_by = v_actor,reviewed_at = clock_timestamp(),
            review_reason = btrim(p_reason),canceled_by = v_actor,
            canceled_at = clock_timestamp(),cancel_reason = btrim(p_reason),
            master_version = master_version + 1,
            updated_at = clock_timestamp()
        WHERE company_id = v_company AND id = v_document.id
        RETURNING master_version INTO v_version;
    END IF;
    INSERT INTO public.purchase_return_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) SELECT v_company,v_document.id,
             CASE WHEN v_decision='APPROVE' THEN 'APPROVE' ELSE 'REJECT' END,
             v_actor,v_before,to_jsonb(document)
      FROM public.purchase_return_documents document
      WHERE document.company_id = v_company AND document.id = v_document.id;
    RETURN jsonb_build_object(
        'documentId',v_document.id,
        'status',CASE WHEN v_decision='APPROVE' THEN 'DRAFT' ELSE 'CANCELED' END,
        'reviewStatus',CASE WHEN v_decision='APPROVE'
            THEN 'APPROVED' ELSE 'REJECTED' END,
        'masterVersion',v_version
    );
END;
$$;

CREATE FUNCTION public.post_purchase_return(
    p_document_id UUID,
    p_master_version BIGINT,
    p_idempotency_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_document public.purchase_return_documents%ROWTYPE;
    v_line public.purchase_return_lines%ROWTYPE;
    v_batch public.product_batches%ROWTYPE;
    v_source_ap public.goods_receipt_ap_provisionals%ROWTYPE;
    v_prior_return NUMERIC(24,6);
    v_prior_ap NUMERIC(20,4);
    v_stock_after NUMERIC(24,6);
    v_fifo_allocation_id UUID;
    v_category_id UUID;
    v_inventory_account_id UUID;
    v_event_id UUID;
    v_version BIGINT;
    v_before JSONB;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_route TEXT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
    SELECT * INTO v_document
    FROM public.purchase_return_documents document
    WHERE document.company_id = v_company AND document.id = p_document_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_RETURN_NOT_FOUND'; END IF;
    IF v_document.status = 'POSTED' THEN
        IF v_document.posting_idempotency_key = p_idempotency_key THEN
            RETURN jsonb_build_object(
                'documentId',v_document.id,'returnNo',v_document.return_no,
                'status','POSTED','masterVersion',v_document.master_version,
                'financialEventId',v_document.financial_event_id,
                'idempotentReplay',TRUE
            );
        END IF;
        RAISE EXCEPTION 'PURCHASE_RETURN_ALREADY_POSTED';
    END IF;
    IF v_document.status <> 'DRAFT'
       OR v_document.review_status <> 'APPROVED' THEN
        RAISE EXCEPTION 'APPROVED_PURCHASE_RETURN_REQUIRED';
    END IF;
    IF p_master_version IS DISTINCT FROM v_document.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF NOT public.private_purchase_manager_allowed(
        v_company,v_document.store_id
    ) THEN RAISE EXCEPTION 'PURCHASE_RETURN_APPROVER_REQUIRED'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.goods_receipt_documents receipt
        WHERE receipt.company_id = v_company
          AND receipt.id = v_document.source_receipt_id
          AND receipt.status = 'POSTED'
    ) THEN RAISE EXCEPTION 'POSTED_GOODS_RECEIPT_NOT_FOUND'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.warehouses warehouse
        WHERE warehouse.company_id = v_company
          AND warehouse.id = v_document.source_warehouse_id
          AND warehouse.is_active
    ) THEN RAISE EXCEPTION 'ACTIVE_RETURN_SOURCE_WAREHOUSE_NOT_FOUND'; END IF;
    SELECT category.id INTO v_category_id
    FROM public.transaction_categories category
    WHERE category.company_id = v_company
      AND category.system_key = 'PURCHASE_RETURN'
      AND category.is_active
    ORDER BY category.id LIMIT 1;
    IF v_category_id IS NULL THEN
        RAISE EXCEPTION 'PURCHASE_RETURN_TRANSACTION_CATEGORY_NOT_FOUND';
    END IF;
    v_inventory_account_id := private.resolve_opening_stock_account(
        v_company,v_category_id,'INVENTORY_ASSET',v_now
    );
    v_before := to_jsonb(v_document);

    FOR v_line IN
        SELECT * FROM public.purchase_return_lines line
        WHERE line.company_id = v_company
          AND line.document_id = v_document.id
        ORDER BY line.product_id,line.id
    LOOP
        PERFORM pg_advisory_xact_lock(hashtextextended(
            v_company::TEXT || ':STOCK:' || v_line.product_id::TEXT || ':'
            || v_document.source_warehouse_id::TEXT,0
        ));
        PERFORM 1 FROM public.goods_receipt_condition_allocations allocation
        WHERE allocation.company_id = v_company
          AND allocation.id = v_line.source_condition_allocation_id
        FOR UPDATE;
        SELECT COALESCE(sum(return_line.return_base_qty),0)
          INTO v_prior_return
        FROM public.purchase_return_lines return_line
        JOIN public.purchase_return_documents return_document
          ON return_document.company_id = return_line.company_id
         AND return_document.id = return_line.document_id
         AND return_document.status = 'POSTED'
        WHERE return_line.company_id = v_company
          AND return_line.source_condition_allocation_id
              = v_line.source_condition_allocation_id;
        IF v_prior_return + v_line.return_base_qty > (
            SELECT allocation.quantity_base
            FROM public.goods_receipt_condition_allocations allocation
            WHERE allocation.company_id = v_company
              AND allocation.id = v_line.source_condition_allocation_id
        ) THEN RAISE EXCEPTION 'PURCHASE_RETURN_QUANTITY_CHANGED_DURING_POST'; END IF;
        SELECT * INTO v_batch FROM public.product_batches batch
        WHERE batch.company_id = v_company
          AND batch.id = v_line.source_product_batch_id
          AND batch.product_id = v_line.product_id
          AND batch.warehouse_id = v_document.source_warehouse_id
        FOR UPDATE;
        IF NOT FOUND OR v_batch.qty_remaining < v_line.return_base_qty THEN
            RAISE EXCEPTION 'PURCHASE_RETURN_FIFO_NOT_AVAILABLE';
        END IF;
        UPDATE public.product_batches SET
            qty_remaining = qty_remaining - v_line.return_base_qty
        WHERE company_id = v_company AND id = v_batch.id;
        UPDATE public.product_stocks SET
            stock_qty = stock_qty - v_line.return_base_qty,
            updated_at = v_now
        WHERE company_id = v_company
          AND product_id = v_line.product_id
          AND warehouse_id = v_document.source_warehouse_id
          AND stock_qty >= v_line.return_base_qty
        RETURNING stock_qty INTO v_stock_after;
        IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_RETURN_STOCK_NOT_AVAILABLE'; END IF;
        INSERT INTO public.purchase_return_fifo_allocations(
            company_id,document_id,return_line_id,source_product_batch_id,
            product_id,warehouse_id,quantity_base,fifo_unit_cost,fifo_cost_total
        ) VALUES (
            v_company,v_document.id,v_line.id,v_batch.id,v_line.product_id,
            v_document.source_warehouse_id,v_line.return_base_qty,
            v_batch.cogs_unit,round(v_line.return_base_qty*v_batch.cogs_unit,4)
        ) RETURNING id INTO v_fifo_allocation_id;
        INSERT INTO public.stock_movements(
            product_id,warehouse_id,qty_change,movement_type,reference_table,
            reference_id,company_id,base_uom_id,base_uom_name_snapshot,
            balance_after_base_qty,actor_id,posted_at,movement_status,
            source_line_id,notes
        ) VALUES (
            v_line.product_id,v_document.source_warehouse_id,
            -v_line.return_base_qty,'PURCHASE_RETURN'::public.stock_movement_type,
            'purchase_return_documents',v_document.id,v_company,
            v_line.base_uom_id,v_line.base_uom_name_snapshot,v_stock_after,
            v_actor,v_now,'POSTED',v_fifo_allocation_id,
            'Returned to Supplier from Goods Receipt FIFO'
        );

        SELECT * INTO v_source_ap
        FROM public.goods_receipt_ap_provisionals provisional
        WHERE provisional.company_id = v_company
          AND provisional.receipt_line_id = v_line.source_receipt_line_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'SOURCE_AP_PROVISIONAL_NOT_FOUND'; END IF;
        SELECT COALESCE(sum(adjustment.amount),0) INTO v_prior_ap
        FROM public.purchase_return_ap_adjustments adjustment
        JOIN public.purchase_return_documents return_document
          ON return_document.company_id = adjustment.company_id
         AND return_document.id = adjustment.document_id
         AND return_document.status = 'POSTED'
        WHERE adjustment.company_id = v_company
          AND adjustment.source_ap_provisional_id = v_source_ap.id;
        IF v_prior_ap + v_line.provisional_return_value > v_source_ap.amount THEN
            RAISE EXCEPTION 'PURCHASE_RETURN_AP_ADJUSTMENT_EXCEEDS_SOURCE';
        END IF;
        v_route := CASE WHEN v_source_ap.status = 'OPEN'
            THEN 'AP_PROVISIONAL' ELSE 'SUPPLIER_CREDIT_PENDING' END;
        INSERT INTO public.purchase_return_ap_adjustments(
            company_id,document_id,return_line_id,source_ap_provisional_id,
            supplier_id,adjustment_route,amount
        ) VALUES (
            v_company,v_document.id,v_line.id,v_source_ap.id,
            v_document.supplier_id,v_route,v_line.provisional_return_value
        );
    END LOOP;

    IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_RETURN_LINES_REQUIRED'; END IF;
    INSERT INTO public.financial_events(
        event_code,event_type,source_table,source_id,root_sales_id,event_date,
        event_version,idempotency_key,amounts,status,error_message,created_by,
        company_id,store_id,system_event_key,transaction_category_id
    ) VALUES (
        'PR-' || replace(v_document.id::TEXT,'-',''),
        'PURCHASE_RETURN_POSTED'::public.event_type,
        'purchase_return_documents',v_document.id,NULL,v_now,1,
        'PURCHASE_RETURN|' || v_company::TEXT || '|'
            || p_idempotency_key::TEXT,
        jsonb_build_object(
            'sourceReceiptId',v_document.source_receipt_id,
            'inventoryCredit',v_document.provisional_ap_adjustment_total,
            'supplierApOrCreditDebit',
                v_document.provisional_ap_adjustment_total,
            'inventoryAccountId',v_inventory_account_id,
            'returnedBaseQty',v_document.total_return_base_qty,
            'containsSupplierCreditPending',EXISTS(
                SELECT 1 FROM public.purchase_return_ap_adjustments adjustment
                WHERE adjustment.company_id = v_company
                  AND adjustment.document_id = v_document.id
                  AND adjustment.adjustment_route = 'SUPPLIER_CREDIT_PENDING'
            ),
            'financePostingState','HOLD_UNTIL_G6'
        ),'HOLD'::public.event_status,
        'CANONICAL_FINANCE_POSTING_NOT_ENABLED',v_actor,v_company,
        v_document.store_id,'PURCHASE_RETURN',v_category_id
    ) RETURNING id INTO v_event_id;
    UPDATE public.purchase_return_documents SET
        status = 'POSTED',handed_over_at = v_now,
        posting_idempotency_key = p_idempotency_key,
        financial_event_id = v_event_id,posted_by = v_actor,posted_at = v_now,
        master_version = master_version + 1,updated_at = v_now
    WHERE company_id = v_company AND id = v_document.id
    RETURNING master_version INTO v_version;
    INSERT INTO public.purchase_return_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) SELECT v_company,v_document.id,'POST',v_actor,v_before,to_jsonb(document)
      FROM public.purchase_return_documents document
      WHERE document.company_id = v_company AND document.id = v_document.id;
    RETURN jsonb_build_object(
        'documentId',v_document.id,'returnNo',v_document.return_no,
        'status','POSTED','masterVersion',v_version,
        'financialEventId',v_event_id,'idempotentReplay',FALSE
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'PURCHASE_RETURN_IDEMPOTENCY_CONFLICT';
END;
$$;

CREATE FUNCTION public.cancel_purchase_return_draft(
    p_document_id UUID,
    p_master_version BIGINT,
    p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_document public.purchase_return_documents%ROWTYPE;
    v_before JSONB;
    v_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF NULLIF(btrim(p_reason),'') IS NULL THEN
        RAISE EXCEPTION 'CANCEL_REASON_REQUIRED';
    END IF;
    SELECT * INTO v_document
    FROM public.purchase_return_documents document
    WHERE document.company_id = v_company AND document.id = p_document_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_RETURN_NOT_FOUND'; END IF;
    IF v_document.status <> 'DRAFT' THEN
        RAISE EXCEPTION 'ONLY_DRAFT_PURCHASE_RETURN_CANCELABLE';
    END IF;
    IF p_master_version IS DISTINCT FROM v_document.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_document.created_by <> v_actor
       AND NOT public.private_purchase_manager_allowed(
           v_company,v_document.store_id
       ) THEN RAISE EXCEPTION 'PURCHASE_RETURN_CANCEL_NOT_ALLOWED'; END IF;
    v_before := to_jsonb(v_document);
    UPDATE public.purchase_return_documents SET
        status = 'CANCELED',canceled_by = v_actor,
        canceled_at = clock_timestamp(),cancel_reason = btrim(p_reason),
        master_version = master_version + 1,updated_at = clock_timestamp()
    WHERE company_id = v_company AND id = v_document.id
    RETURNING master_version INTO v_version;
    INSERT INTO public.purchase_return_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) SELECT v_company,v_document.id,'CANCEL',v_actor,v_before,to_jsonb(document)
      FROM public.purchase_return_documents document
      WHERE document.company_id = v_company AND document.id = v_document.id;
    RETURN jsonb_build_object(
        'documentId',v_document.id,'status','CANCELED',
        'masterVersion',v_version
    );
END;
$$;

ALTER TABLE public.purchase_return_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_return_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_return_fifo_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_return_ap_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_return_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Purchase Return documents readable in Store"
ON public.purchase_return_documents FOR SELECT TO authenticated
USING (
    public.private_purchase_document_visible(company_id,store_id)
);
CREATE POLICY "Purchase Return lines readable in Store"
ON public.purchase_return_lines FOR SELECT TO authenticated
USING (EXISTS (
    SELECT 1 FROM public.purchase_return_documents document
    WHERE document.company_id = purchase_return_lines.company_id
      AND document.id = purchase_return_lines.document_id
      AND public.private_purchase_document_visible(
          document.company_id,document.store_id
      )
));
CREATE POLICY "Purchase Return FIFO readable in Store"
ON public.purchase_return_fifo_allocations FOR SELECT TO authenticated
USING (EXISTS (
    SELECT 1 FROM public.purchase_return_documents document
    WHERE document.company_id = purchase_return_fifo_allocations.company_id
      AND document.id = purchase_return_fifo_allocations.document_id
      AND public.private_purchase_document_visible(
          document.company_id,document.store_id
      )
));
CREATE POLICY "Purchase Return AP readable by managers"
ON public.purchase_return_ap_adjustments FOR SELECT TO authenticated
USING (EXISTS (
    SELECT 1 FROM public.purchase_return_documents document
    WHERE document.company_id = purchase_return_ap_adjustments.company_id
      AND document.id = purchase_return_ap_adjustments.document_id
      AND public.private_purchase_document_visible(
          document.company_id,document.store_id
      )
));
CREATE POLICY "Purchase Return audit readable by managers"
ON public.purchase_return_audit FOR SELECT TO authenticated
USING (EXISTS (
    SELECT 1 FROM public.purchase_return_documents document
    WHERE document.company_id = purchase_return_audit.company_id
      AND document.id = purchase_return_audit.document_id
      AND public.private_purchase_document_visible(
          document.company_id,document.store_id
      )
));

REVOKE ALL ON public.purchase_return_documents,
    public.purchase_return_lines,public.purchase_return_fifo_allocations,
    public.purchase_return_ap_adjustments,public.purchase_return_audit
FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.purchase_return_documents,
    public.purchase_return_lines,public.purchase_return_fifo_allocations,
    public.purchase_return_ap_adjustments,public.purchase_return_audit
TO authenticated;
GRANT ALL ON public.purchase_return_documents,
    public.purchase_return_lines,public.purchase_return_fifo_allocations,
    public.purchase_return_ap_adjustments,public.purchase_return_audit
TO service_role;

REVOKE ALL ON FUNCTION public.save_purchase_return_draft(
    UUID,BIGINT,UUID,UUID,UUID,DATE,TEXT,TEXT,TEXT,JSONB
), public.review_purchase_return(UUID,BIGINT,TEXT,TEXT),
public.post_purchase_return(UUID,BIGINT,UUID),
public.cancel_purchase_return_draft(UUID,BIGINT,TEXT)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_purchase_return_draft(
    UUID,BIGINT,UUID,UUID,UUID,DATE,TEXT,TEXT,TEXT,JSONB
), public.review_purchase_return(UUID,BIGINT,TEXT,TEXT),
public.post_purchase_return(UUID,BIGINT,UUID),
public.cancel_purchase_return_draft(UUID,BIGINT,TEXT)
TO authenticated, service_role;
REVOKE ALL ON FUNCTION private.trg_g5_purchase_return_history_guard(),
    private.trg_g5_purchase_return_audit_immutable()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g5_purchase_return_history_guard(),
    private.trg_g5_purchase_return_audit_immutable()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260806070000','g5_phase8_purchase_return_foundation',
    'PUR-004 guarded Purchase Return Draft/review/post, original Receipt FIFO consumption, Stock Movement, AP adjustment, Finance HOLD, idempotency, audit, and browser write closure'
);

COMMIT;
