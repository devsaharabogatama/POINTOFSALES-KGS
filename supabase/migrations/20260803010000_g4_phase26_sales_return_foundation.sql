-- KGS POS G4 phase 26: canonical Sales Return and refund foundation.
-- Dependency: atomic Sale, Payment-leg identity, and Offline final sync.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260729210000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 phase 12 is incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260803010000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260803010000';
    END IF;
    IF to_regclass('public.sales_return_documents') IS NOT NULL
       OR to_regclass('public.sales_return_lines') IS NOT NULL
       OR to_regclass('public.sales_return_fifo_restorations') IS NOT NULL
       OR to_regclass('public.sales_return_refunds') IS NOT NULL
       OR to_regclass('public.sales_return_audit') IS NOT NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Sales Return object already exists';
    END IF;
END
$migration_guard$;

CREATE SEQUENCE private.sales_return_number_seq AS BIGINT START WITH 1;
REVOKE ALL ON SEQUENCE private.sales_return_number_seq
FROM PUBLIC, anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE private.sales_return_number_seq
TO service_role;

ALTER TABLE public.sale_fifo_allocations
    ADD CONSTRAINT sale_fifo_allocations_company_id_id_unique
        UNIQUE(company_id,id);

CREATE TABLE public.sales_return_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    return_no TEXT NOT NULL,
    source_sales_id UUID NOT NULL,
    source_invoice_no_snapshot TEXT NOT NULL,
    store_id UUID NOT NULL,
    source_session_id UUID NOT NULL,
    executing_session_id UUID NOT NULL,
    customer_id UUID,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    approval_mode_snapshot TEXT NOT NULL DEFAULT 'REQUIRED',
    notes TEXT,
    refund_before_rounding NUMERIC(20,4) NOT NULL DEFAULT 0,
    rounding_direction TEXT NOT NULL DEFAULT 'NONE',
    rounding_increment NUMERIC(20,4) NOT NULL DEFAULT 100,
    rounding_adjustment NUMERIC(20,4) NOT NULL DEFAULT 0,
    refund_total NUMERIC(20,4) NOT NULL DEFAULT 0,
    posting_idempotency_key UUID,
    transaction_category_id UUID,
    financial_event_id UUID,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    updated_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    posted_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    canceled_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    posted_at TIMESTAMPTZ,
    canceled_at TIMESTAMPTZ,
    cancel_reason TEXT,
    CONSTRAINT sales_return_documents_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT sales_return_documents_company_no_unique
        UNIQUE(company_id,return_no),
    CONSTRAINT sales_return_documents_source_identity_unique
        UNIQUE(company_id,source_sales_id,id),
    CONSTRAINT sales_return_documents_status_check CHECK (
        status IN ('DRAFT','POSTED','CANCELED')
    ),
    CONSTRAINT sales_return_documents_approval_mode_check CHECK (
        approval_mode_snapshot IN ('REQUIRED','OPTIONAL')
    ),
    CONSTRAINT sales_return_documents_rounding_check CHECK (
        rounding_direction IN ('NONE','DOWN','UP')
        AND rounding_increment > 0
    ),
    CONSTRAINT sales_return_documents_amount_check CHECK (
        refund_before_rounding >= 0 AND refund_total >= 0
    ),
    CONSTRAINT sales_return_documents_version_positive
        CHECK(master_version > 0),
    CONSTRAINT sales_return_documents_source_invoice_not_blank
        CHECK(btrim(source_invoice_no_snapshot) <> ''),
    CONSTRAINT sales_return_documents_notes_not_blank
        CHECK(notes IS NULL OR btrim(notes) <> ''),
    CONSTRAINT sales_return_documents_final_contract CHECK (
        (status = 'DRAFT'
         AND posting_idempotency_key IS NULL
         AND posted_by IS NULL AND posted_at IS NULL
         AND canceled_by IS NULL AND canceled_at IS NULL)
        OR
        (status = 'POSTED'
         AND posting_idempotency_key IS NOT NULL
         AND transaction_category_id IS NOT NULL
         AND financial_event_id IS NOT NULL
         AND posted_by IS NOT NULL AND posted_at IS NOT NULL
         AND canceled_by IS NULL AND canceled_at IS NULL)
        OR
        (status = 'CANCELED'
         AND posting_idempotency_key IS NULL
         AND posted_by IS NULL AND posted_at IS NULL
         AND canceled_by IS NOT NULL AND canceled_at IS NOT NULL
         AND btrim(cancel_reason) <> '')
    ),
    CONSTRAINT fk_sales_return_source_sale
        FOREIGN KEY(company_id,source_sales_id)
        REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_source_session
        FOREIGN KEY(company_id,source_session_id)
        REFERENCES public.cashier_sessions(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_executing_session
        FOREIGN KEY(company_id,executing_session_id)
        REFERENCES public.cashier_sessions(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_customer
        FOREIGN KEY(company_id,customer_id)
        REFERENCES public.customers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_category
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_financial_event
        FOREIGN KEY(company_id,financial_event_id)
        REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX uq_sales_return_posting_idempotency
    ON public.sales_return_documents(company_id,posting_idempotency_key)
    WHERE posting_idempotency_key IS NOT NULL;
CREATE INDEX idx_sales_return_source_status
    ON public.sales_return_documents(company_id,source_sales_id,status);
CREATE INDEX idx_sales_return_store_updated
    ON public.sales_return_documents(company_id,store_id,updated_at DESC);

CREATE TABLE public.sales_return_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    source_sales_detail_id UUID NOT NULL,
    product_id UUID NOT NULL,
    product_sku_snapshot TEXT NOT NULL,
    product_name_snapshot TEXT NOT NULL,
    sale_uom_id UUID NOT NULL,
    sale_uom_name_snapshot TEXT NOT NULL,
    uom_factor_to_base_snapshot NUMERIC(24,6) NOT NULL,
    quantity_uom NUMERIC(24,6) NOT NULL,
    quantity_base NUMERIC(24,6) NOT NULL,
    return_condition TEXT NOT NULL,
    destination_warehouse_id UUID,
    refund_before_rounding NUMERIC(20,4) NOT NULL,
    tax_refund_amount NUMERIC(20,4) NOT NULL DEFAULT 0,
    fifo_cost_restored NUMERIC(20,4) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT sales_return_lines_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT sales_return_line_source_unique
        UNIQUE(company_id,document_id,source_sales_detail_id),
    CONSTRAINT sales_return_line_quantity_positive CHECK (
        quantity_uom > 0 AND quantity_base > 0
        AND uom_factor_to_base_snapshot > 0
    ),
    CONSTRAINT sales_return_line_amount_nonnegative CHECK (
        refund_before_rounding >= 0
        AND tax_refund_amount >= 0
        AND fifo_cost_restored >= 0
    ),
    CONSTRAINT sales_return_line_condition_check CHECK (
        return_condition IN ('SALEABLE','DAMAGED','NO_PHYSICAL_RETURN')
    ),
    CONSTRAINT sales_return_line_warehouse_shape CHECK (
        (return_condition = 'NO_PHYSICAL_RETURN'
         AND destination_warehouse_id IS NULL)
        OR
        (return_condition IN ('SALEABLE','DAMAGED')
         AND destination_warehouse_id IS NOT NULL)
    ),
    CONSTRAINT sales_return_line_snapshots_not_blank CHECK (
        btrim(product_sku_snapshot) <> ''
        AND btrim(product_name_snapshot) <> ''
        AND btrim(sale_uom_name_snapshot) <> ''
    ),
    CONSTRAINT fk_sales_return_line_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.sales_return_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_line_source_detail
        FOREIGN KEY(company_id,source_sales_detail_id)
        REFERENCES public.sales_details(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_line_product
        FOREIGN KEY(company_id,product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_line_uom
        FOREIGN KEY(company_id,sale_uom_id)
        REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_line_warehouse
        FOREIGN KEY(company_id,destination_warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_sales_return_line_source
    ON public.sales_return_lines(company_id,source_sales_detail_id);

CREATE TABLE public.sales_return_refunds (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    client_refund_key UUID NOT NULL,
    source_sales_payment_id UUID,
    payment_method_id UUID NOT NULL,
    payment_method_code_snapshot TEXT NOT NULL,
    payment_method_name_snapshot TEXT NOT NULL,
    payment_method_type_snapshot TEXT NOT NULL,
    settlement_route_snapshot TEXT NOT NULL,
    amount NUMERIC(20,4) NOT NULL,
    transfer_destination TEXT,
    transfer_reference TEXT,
    proof_url TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT sales_return_refunds_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT sales_return_refund_client_unique
        UNIQUE(company_id,document_id,client_refund_key),
    CONSTRAINT sales_return_refund_amount_positive CHECK(amount > 0),
    CONSTRAINT sales_return_refund_snapshot_not_blank CHECK (
        btrim(payment_method_code_snapshot) <> ''
        AND btrim(payment_method_name_snapshot) <> ''
        AND btrim(payment_method_type_snapshot) <> ''
        AND btrim(settlement_route_snapshot) <> ''
    ),
    CONSTRAINT sales_return_refund_transfer_contract CHECK (
        (payment_method_type_snapshot = 'TRANSFER'
         AND btrim(transfer_destination) <> ''
         AND btrim(transfer_reference) <> '')
        OR
        (payment_method_type_snapshot <> 'TRANSFER'
         AND transfer_destination IS NULL AND transfer_reference IS NULL)
    ),
    CONSTRAINT sales_return_refund_proof_https CHECK (
        proof_url IS NULL OR proof_url ~* '^https://'
    ),
    CONSTRAINT fk_sales_return_refund_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.sales_return_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_refund_source_payment
        FOREIGN KEY(company_id,source_sales_payment_id)
        REFERENCES public.sales_payments(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_refund_method
        FOREIGN KEY(company_id,payment_method_id)
        REFERENCES public.payment_methods(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.sales_return_fifo_restorations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    return_line_id UUID NOT NULL,
    source_sale_fifo_allocation_id UUID NOT NULL,
    source_product_batch_id UUID NOT NULL,
    restored_product_batch_id UUID NOT NULL,
    product_id UUID NOT NULL,
    warehouse_id UUID NOT NULL,
    quantity_base NUMERIC(24,6) NOT NULL,
    fifo_unit_cost NUMERIC(20,4) NOT NULL,
    fifo_cost_total NUMERIC(20,4) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT sales_return_restorations_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT sales_return_restoration_batch_unique
        UNIQUE(company_id,return_line_id,source_sale_fifo_allocation_id),
    CONSTRAINT sales_return_restoration_quantity_positive
        CHECK(quantity_base > 0),
    CONSTRAINT sales_return_restoration_cost_nonnegative CHECK (
        fifo_unit_cost >= 0 AND fifo_cost_total >= 0
    ),
    CONSTRAINT fk_sales_return_restoration_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.sales_return_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_restoration_line
        FOREIGN KEY(company_id,return_line_id)
        REFERENCES public.sales_return_lines(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_restoration_sale_fifo
        FOREIGN KEY(company_id,source_sale_fifo_allocation_id)
        REFERENCES public.sale_fifo_allocations(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_restoration_source_batch
        FOREIGN KEY(company_id,source_product_batch_id)
        REFERENCES public.product_batches(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_restoration_restored_batch
        FOREIGN KEY(company_id,restored_product_batch_id)
        REFERENCES public.product_batches(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_restoration_product
        FOREIGN KEY(company_id,product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_return_restoration_warehouse
        FOREIGN KEY(company_id,warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.sales_return_audit (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    action TEXT NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT sales_return_audit_action_check CHECK (
        action IN ('CREATE_DRAFT','UPDATE_DRAFT','POST','CANCEL')
    ),
    CONSTRAINT fk_sales_return_audit_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.sales_return_documents(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_sales_return_audit_document_created
    ON public.sales_return_audit(company_id,document_id,created_at DESC);

ALTER TABLE public.product_batches
    ADD COLUMN sales_return_line_id UUID,
    ADD CONSTRAINT fk_product_batches_company_sales_return_line
        FOREIGN KEY(company_id,sales_return_line_id)
        REFERENCES public.sales_return_lines(company_id,id) ON DELETE RESTRICT;

CREATE FUNCTION private.trg_g4_sales_return_history_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_document_id UUID;
BEGIN
    IF TG_TABLE_NAME = 'sales_return_documents' THEN
        IF OLD.status IN ('POSTED','CANCELED') THEN
            RAISE EXCEPTION 'FINAL_SALES_RETURN_IMMUTABLE';
        END IF;
        RETURN NEW;
    END IF;
    v_document_id := CASE WHEN TG_OP = 'DELETE'
        THEN OLD.document_id ELSE NEW.document_id END;
    IF EXISTS (
        SELECT 1 FROM public.sales_return_documents d
        WHERE d.id = v_document_id AND d.status <> 'DRAFT'
    ) THEN
        RAISE EXCEPTION 'FINAL_SALES_RETURN_CHILD_IMMUTABLE';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER guard_final_sales_return_document
BEFORE UPDATE OR DELETE ON public.sales_return_documents
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_sales_return_history_guard();
CREATE TRIGGER guard_final_sales_return_lines
BEFORE INSERT OR UPDATE OR DELETE ON public.sales_return_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_sales_return_history_guard();
CREATE TRIGGER guard_final_sales_return_refunds
BEFORE INSERT OR UPDATE OR DELETE ON public.sales_return_refunds
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_sales_return_history_guard();
CREATE TRIGGER guard_final_sales_return_restorations
BEFORE INSERT OR UPDATE OR DELETE ON public.sales_return_fifo_restorations
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_sales_return_history_guard();

CREATE FUNCTION private.trg_g4_sales_return_audit_immutable()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'SALES_RETURN_AUDIT_IMMUTABLE';
END;
$$;

CREATE TRIGGER guard_sales_return_audit_immutable
BEFORE UPDATE OR DELETE ON public.sales_return_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_sales_return_audit_immutable();

CREATE FUNCTION public.list_returnable_sales(
    p_search TEXT DEFAULT NULL,
    p_limit INTEGER DEFAULT 50
)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    WITH scope AS (
        SELECT public.private_active_company_id() AS company_id,auth.uid() actor
    ), candidates AS (
        SELECT
            sale.id,sale.invoice_no,sale.transaction_date,sale.store_id,
            sale.customer_id,sale.grand_total_after_rounding,
            COALESCE(jsonb_agg(jsonb_build_object(
                'sourceSalesDetailId',detail.id,
                'productId',detail.product_id,
                'productName',detail.product_name_snapshot,
                'uomName',detail.sale_uom_name_snapshot,
                'soldQuantity',detail.qty,
                'returnedQuantity',COALESCE(returned.quantity,0),
                'remainingQuantity',detail.qty-COALESCE(returned.quantity,0)
            ) ORDER BY detail.id) FILTER (
                WHERE detail.qty > COALESCE(returned.quantity,0)
            ),'[]'::JSONB) lines
        FROM scope
        JOIN public.sales_headers sale
          ON sale.company_id = scope.company_id
         AND sale.document_status = 'POSTED'
        JOIN public.sales_details detail
          ON detail.company_id = sale.company_id AND detail.sales_id = sale.id
        LEFT JOIN LATERAL (
            SELECT COALESCE(sum(line.quantity_uom),0) quantity
            FROM public.sales_return_lines line
            JOIN public.sales_return_documents document
              ON document.company_id = line.company_id
             AND document.id = line.document_id
             AND document.status = 'POSTED'
            WHERE line.company_id = detail.company_id
              AND line.source_sales_detail_id = detail.id
        ) returned ON TRUE
        WHERE scope.actor IS NOT NULL
          AND public.private_cashier_session_visible(sale.posted_session_id)
          AND (
              NULLIF(btrim(p_search),'') IS NULL
              OR sale.invoice_no ILIKE '%' || btrim(p_search) || '%'
          )
        GROUP BY sale.id,sale.invoice_no,sale.transaction_date,sale.store_id,
                 sale.customer_id,sale.grand_total_after_rounding
        HAVING bool_or(detail.qty > COALESCE(returned.quantity,0))
        ORDER BY sale.transaction_date DESC,sale.id DESC
        LIMIT LEAST(GREATEST(COALESCE(p_limit,50),1),100)
    )
    SELECT jsonb_build_object(
        'sales',COALESCE(jsonb_agg(to_jsonb(candidates)),'[]'::JSONB)
    )
    FROM candidates;
$$;

CREATE FUNCTION public.save_sales_return_draft(
    p_document_id UUID,
    p_master_version BIGINT,
    p_source_sales_id UUID,
    p_executing_session_id UUID,
    p_rounding_direction TEXT,
    p_notes TEXT,
    p_lines JSONB,
    p_refunds JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_sale public.sales_headers%ROWTYPE;
    v_session public.cashier_sessions%ROWTYPE;
    v_document public.sales_return_documents%ROWTYPE;
    v_detail public.sales_details%ROWTYPE;
    v_method public.payment_methods%ROWTYPE;
    v_line JSONB;
    v_refund JSONB;
    v_id UUID;
    v_before JSONB;
    v_action TEXT;
    v_quantity NUMERIC(24,6);
    v_prior_quantity NUMERIC(24,6);
    v_line_refund NUMERIC(20,4);
    v_refund_before NUMERIC(20,4) := 0;
    v_tax_refund NUMERIC(20,4);
    v_refund_input_total NUMERIC(20,4) := 0;
    v_refund_total NUMERIC(20,4);
    v_rounding_adjustment NUMERIC(20,4);
    v_all_fully_returned BOOLEAN;
    v_prior_refund_total NUMERIC(20,4);
    v_destination UUID;
    v_condition TEXT;
    v_return_no TEXT;
    v_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'SALES_RETURN_LINES_REQUIRED';
    END IF;
    IF jsonb_typeof(p_refunds) <> 'array'
       OR jsonb_array_length(p_refunds) = 0 THEN
        RAISE EXCEPTION 'SALES_RETURN_REFUNDS_REQUIRED';
    END IF;
    IF upper(COALESCE(p_rounding_direction,'NONE')) NOT IN (
        'NONE','DOWN','UP'
    ) THEN RAISE EXCEPTION 'INVALID_REFUND_ROUNDING_DIRECTION'; END IF;

    SELECT * INTO v_sale FROM public.sales_headers
    WHERE company_id = v_company AND id = p_source_sales_id
      AND document_status = 'POSTED';
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTED_SOURCE_SALE_NOT_FOUND'; END IF;

    SELECT * INTO v_session FROM public.cashier_sessions
    WHERE company_id = v_company AND id = p_executing_session_id
      AND store_id = v_sale.store_id
      AND status = 'OPEN'::public.session_status;
    IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_RETURN_SESSION_REQUIRED'; END IF;
    IF v_session.cashier_id <> v_actor
       AND NOT (
           public.private_user_has_any_company_role(
               v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
           )
           OR public.private_user_has_any_store_role(
               v_sale.store_id,ARRAY['STORE_MANAGER']::TEXT[]
           )
       ) THEN RAISE EXCEPTION 'RETURN_SESSION_OPERATOR_REQUIRED'; END IF;

    IF p_document_id IS NULL THEN
        v_id := gen_random_uuid();
        v_return_no := 'RET-' || to_char(clock_timestamp(),'YYYYMMDD') || '-'
            || lpad(nextval('private.sales_return_number_seq')::TEXT,10,'0');
        INSERT INTO public.sales_return_documents(
            id,company_id,return_no,source_sales_id,
            source_invoice_no_snapshot,store_id,source_session_id,
            executing_session_id,customer_id,status,notes,
            rounding_direction,created_by,updated_by
        ) VALUES (
            v_id,v_company,v_return_no,v_sale.id,v_sale.invoice_no,
            v_sale.store_id,v_sale.posted_session_id,v_session.id,
            v_sale.customer_id,'DRAFT',NULLIF(btrim(p_notes),''),
            upper(COALESCE(p_rounding_direction,'NONE')),v_actor,v_actor
        );
        v_action := 'CREATE_DRAFT';
        v_before := NULL;
    ELSE
        SELECT * INTO v_document FROM public.sales_return_documents
        WHERE company_id = v_company AND id = p_document_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'SALES_RETURN_NOT_FOUND'; END IF;
        IF v_document.status <> 'DRAFT' THEN
            RAISE EXCEPTION 'FINAL_SALES_RETURN_IMMUTABLE';
        END IF;
        IF v_document.source_sales_id <> v_sale.id THEN
            RAISE EXCEPTION 'SALES_RETURN_SOURCE_IMMUTABLE';
        END IF;
        IF p_master_version IS NULL
           OR p_master_version <> v_document.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        v_id := v_document.id;
        v_return_no := v_document.return_no;
        v_before := to_jsonb(v_document);
        v_action := 'UPDATE_DRAFT';
        DELETE FROM public.sales_return_refunds
        WHERE company_id = v_company AND document_id = v_id;
        DELETE FROM public.sales_return_lines
        WHERE company_id = v_company AND document_id = v_id;
    END IF;

    FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
    LOOP
        SELECT * INTO v_detail FROM public.sales_details
        WHERE company_id = v_company
          AND id = (v_line->>'sourceSalesDetailId')::UUID
          AND sales_id = v_sale.id;
        IF NOT FOUND THEN RAISE EXCEPTION 'SOURCE_SALE_LINE_NOT_FOUND'; END IF;
        BEGIN v_quantity := (v_line->>'quantity')::NUMERIC;
        EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_RETURN_QUANTITY';
        END;
        IF v_quantity <= 0 THEN RAISE EXCEPTION 'INVALID_RETURN_QUANTITY'; END IF;
        SELECT COALESCE(sum(line.quantity_uom),0) INTO v_prior_quantity
        FROM public.sales_return_lines line
        JOIN public.sales_return_documents document
          ON document.company_id = line.company_id
         AND document.id = line.document_id
         AND document.status = 'POSTED'
        WHERE line.company_id = v_company
          AND line.source_sales_detail_id = v_detail.id;
        IF v_prior_quantity + v_quantity > v_detail.qty THEN
            RAISE EXCEPTION 'RETURN_QUANTITY_EXCEEDS_REFUNDABLE';
        END IF;
        v_condition := upper(COALESCE(
            NULLIF(btrim(v_line->>'condition'),''),'SALEABLE'
        ));
        IF v_condition NOT IN ('SALEABLE','DAMAGED','NO_PHYSICAL_RETURN') THEN
            RAISE EXCEPTION 'INVALID_RETURN_CONDITION';
        END IF;
        IF v_condition = 'SALEABLE' THEN
            v_destination := v_sale.sales_warehouse_id;
            IF NOT EXISTS (
                SELECT 1 FROM public.warehouses
                WHERE company_id=v_company AND id=v_destination
                  AND store_id=v_sale.store_id AND is_active
                  AND warehouse_type='STORE'
            ) THEN
                RAISE EXCEPTION 'ACTIVE_STORE_RETURN_WAREHOUSE_REQUIRED';
            END IF;
        ELSIF v_condition = 'DAMAGED' THEN
            BEGIN v_destination := (v_line->>'destinationWarehouseId')::UUID;
            EXCEPTION WHEN OTHERS THEN
                RAISE EXCEPTION 'DAMAGED_WAREHOUSE_REQUIRED';
            END;
            IF NOT EXISTS (
                SELECT 1 FROM public.warehouses
                WHERE company_id = v_company AND id = v_destination
                  AND is_active AND warehouse_type = 'DAMAGED'
            ) THEN RAISE EXCEPTION 'ACTIVE_DAMAGED_WAREHOUSE_REQUIRED'; END IF;
        ELSE
            v_destination := NULL;
        END IF;
        v_line_refund := round(
            (v_detail.line_total + v_detail.allocated_document_rounding)
            * v_quantity / v_detail.qty,4
        );
        v_tax_refund := round(
            COALESCE(v_detail.tax_amount,0) * v_quantity / v_detail.qty,4
        );
        v_refund_before := v_refund_before + v_line_refund;
        INSERT INTO public.sales_return_lines(
            company_id,document_id,source_sales_detail_id,product_id,
            product_sku_snapshot,product_name_snapshot,sale_uom_id,
            sale_uom_name_snapshot,uom_factor_to_base_snapshot,
            quantity_uom,quantity_base,return_condition,
            destination_warehouse_id,refund_before_rounding,
            tax_refund_amount
        ) VALUES (
            v_company,v_id,v_detail.id,v_detail.product_id,
            v_detail.product_sku_snapshot,v_detail.product_name_snapshot,
            v_detail.sale_uom_id,v_detail.sale_uom_name_snapshot,
            v_detail.uom_factor_to_base_snapshot,v_quantity,
            round(v_quantity*v_detail.uom_factor_to_base_snapshot,6),
            v_condition,v_destination,v_line_refund,v_tax_refund
        );
    END LOOP;

    SELECT NOT EXISTS (
        SELECT 1 FROM public.sales_details detail
        WHERE detail.company_id = v_company AND detail.sales_id = v_sale.id
          AND detail.qty > COALESCE((
              SELECT sum(line.quantity_uom)
              FROM public.sales_return_lines line
              JOIN public.sales_return_documents document
                ON document.company_id = line.company_id
               AND document.id = line.document_id
              WHERE line.company_id = v_company
                AND line.source_sales_detail_id = detail.id
                AND (document.status = 'POSTED' OR document.id = v_id)
          ),0)
    ) INTO v_all_fully_returned;
    SELECT COALESCE(sum(refund_total),0) INTO v_prior_refund_total
    FROM public.sales_return_documents
    WHERE company_id = v_company AND source_sales_id = v_sale.id
      AND status = 'POSTED';
    IF v_all_fully_returned THEN
        v_refund_total := v_sale.grand_total_after_rounding-v_prior_refund_total;
    ELSIF upper(COALESCE(p_rounding_direction,'NONE')) = 'DOWN' THEN
        v_refund_total := floor(v_refund_before/100)*100;
    ELSIF upper(COALESCE(p_rounding_direction,'NONE')) = 'UP' THEN
        v_refund_total := ceil(v_refund_before/100)*100;
    ELSE
        v_refund_total := v_refund_before;
    END IF;
    IF v_refund_total <= 0
       OR v_prior_refund_total + v_refund_total
            > v_sale.grand_total_after_rounding THEN
        RAISE EXCEPTION 'REFUND_TOTAL_EXCEEDS_REFUNDABLE';
    END IF;
    v_rounding_adjustment := v_refund_total-v_refund_before;

    FOR v_refund IN SELECT value FROM jsonb_array_elements(p_refunds)
    LOOP
        SELECT * INTO v_method FROM public.payment_methods
        WHERE company_id = v_company
          AND id = (v_refund->>'paymentMethodId')::UUID
          AND is_active
          AND effective_from <= clock_timestamp()
          AND (effective_to IS NULL OR effective_to >= clock_timestamp())
          AND method_type IN ('CASH','TRANSFER')
          AND (
              available_all_stores
              OR EXISTS (
                  SELECT 1
                  FROM public.payment_method_store_assignments assignment
                  WHERE assignment.company_id=payment_methods.company_id
                    AND assignment.payment_method_id=payment_methods.id
                    AND assignment.store_id=v_sale.store_id
              )
          );
        IF NOT FOUND THEN RAISE EXCEPTION 'ELIGIBLE_REFUND_METHOD_REQUIRED'; END IF;
        BEGIN
            v_quantity := (v_refund->>'amount')::NUMERIC;
        EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_REFUND_AMOUNT'; END;
        IF v_quantity <= 0 THEN RAISE EXCEPTION 'INVALID_REFUND_AMOUNT'; END IF;
        IF v_method.method_type = 'TRANSFER' AND (
            NULLIF(btrim(v_refund->>'transferDestination'),'') IS NULL
            OR NULLIF(btrim(v_refund->>'transferReference'),'') IS NULL
        ) THEN RAISE EXCEPTION 'TRANSFER_REFUND_REFERENCE_REQUIRED'; END IF;
        IF NULLIF(btrim(v_refund->>'proofUrl'),'') IS NOT NULL
           AND btrim(v_refund->>'proofUrl') !~* '^https://' THEN
            RAISE EXCEPTION 'REFUND_PROOF_HTTPS_REQUIRED';
        END IF;
        IF NULLIF(v_refund->>'sourceSalesPaymentId','') IS NOT NULL
           AND NOT EXISTS (
               SELECT 1 FROM public.sales_payments payment
               WHERE payment.company_id = v_company
                 AND payment.id = (v_refund->>'sourceSalesPaymentId')::UUID
                 AND payment.sales_id = v_sale.id AND NOT payment.is_reversal
           ) THEN RAISE EXCEPTION 'SOURCE_SALE_PAYMENT_NOT_FOUND'; END IF;
        INSERT INTO public.sales_return_refunds(
            company_id,document_id,client_refund_key,
            source_sales_payment_id,payment_method_id,
            payment_method_code_snapshot,payment_method_name_snapshot,
            payment_method_type_snapshot,settlement_route_snapshot,
            amount,transfer_destination,transfer_reference,proof_url
        ) VALUES (
            v_company,v_id,COALESCE(
                NULLIF(v_refund->>'clientRefundKey','')::UUID,
                gen_random_uuid()
            ),NULLIF(v_refund->>'sourceSalesPaymentId','')::UUID,
            v_method.id,v_method.payment_method_code,
            v_method.payment_method_name,v_method.method_type,
            v_method.settlement_route,v_quantity,
            CASE WHEN v_method.method_type='TRANSFER' THEN
                btrim(v_refund->>'transferDestination') END,
            CASE WHEN v_method.method_type='TRANSFER' THEN
                btrim(v_refund->>'transferReference') END,
            NULLIF(btrim(v_refund->>'proofUrl'),'')
        );
        v_refund_input_total := v_refund_input_total + v_quantity;
    END LOOP;
    IF v_refund_input_total <> v_refund_total THEN
        RAISE EXCEPTION 'REFUND_PAYMENT_TOTAL_MISMATCH';
    END IF;

    UPDATE public.sales_return_documents SET
        executing_session_id = v_session.id,
        notes = NULLIF(btrim(p_notes),''),
        refund_before_rounding = v_refund_before,
        rounding_direction = upper(COALESCE(p_rounding_direction,'NONE')),
        rounding_adjustment = v_rounding_adjustment,
        refund_total = v_refund_total,
        updated_by = v_actor,updated_at = clock_timestamp(),
        master_version = CASE WHEN p_document_id IS NULL
            THEN master_version ELSE master_version + 1 END
    WHERE company_id = v_company AND id = v_id
    RETURNING master_version INTO v_version;
    INSERT INTO public.sales_return_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) SELECT v_company,v_id,v_action,v_actor,v_before,to_jsonb(document)
      FROM public.sales_return_documents document
      WHERE document.company_id=v_company AND document.id=v_id;
    RETURN jsonb_build_object(
        'documentId',v_id,'returnNo',v_return_no,'status','DRAFT',
        'masterVersion',v_version,'refundTotal',v_refund_total
    );
END;
$$;

CREATE FUNCTION public.post_sales_return(
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
    v_document public.sales_return_documents%ROWTYPE;
    v_sale public.sales_headers%ROWTYPE;
    v_line public.sales_return_lines%ROWTYPE;
    v_requirement public.sale_stock_requirements%ROWTYPE;
    v_allocation public.sale_fifo_allocations%ROWTYPE;
    v_category_id UUID;
    v_event_id UUID;
    v_remaining NUMERIC(24,6);
    v_available NUMERIC(24,6);
    v_take NUMERIC(24,6);
    v_prior NUMERIC(24,6);
    v_batch_id UUID;
    v_restoration_id UUID;
    v_stock_after NUMERIC(24,6);
    v_line_cost NUMERIC(20,4);
    v_total_cost NUMERIC(20,4) := 0;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_before JSONB;
    v_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
    SELECT * INTO v_document FROM public.sales_return_documents
    WHERE company_id=v_company AND id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SALES_RETURN_NOT_FOUND'; END IF;
    IF v_document.status='POSTED' THEN
        IF v_document.posting_idempotency_key=p_idempotency_key THEN
            RETURN jsonb_build_object(
                'documentId',v_document.id,'returnNo',v_document.return_no,
                'status','POSTED','masterVersion',v_document.master_version,
                'financialEventId',v_document.financial_event_id,
                'idempotentReplay',TRUE
            );
        END IF;
        RAISE EXCEPTION 'SALES_RETURN_ALREADY_POSTED';
    END IF;
    IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'SALES_RETURN_NOT_POSTABLE'; END IF;
    IF p_master_version IS NULL OR p_master_version<>v_document.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF NOT (
        public.private_user_has_any_company_role(
            v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
        )
        OR public.private_user_has_any_store_role(
            v_document.store_id,ARRAY['STORE_MANAGER']::TEXT[]
        )
    ) THEN RAISE EXCEPTION 'SALES_RETURN_APPROVER_REQUIRED'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.cashier_sessions session
        WHERE session.company_id=v_company
          AND session.id=v_document.executing_session_id
          AND session.store_id=v_document.store_id
          AND session.status='OPEN'::public.session_status
    ) THEN RAISE EXCEPTION 'OPEN_RETURN_SESSION_REQUIRED'; END IF;
    SELECT * INTO v_sale FROM public.sales_headers
    WHERE company_id=v_company AND id=v_document.source_sales_id
      AND document_status='POSTED' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTED_SOURCE_SALE_NOT_FOUND'; END IF;
    SELECT id INTO v_category_id FROM public.transaction_categories
    WHERE company_id=v_company AND system_key='SALES_RETURN'
      AND is_active AND is_system_default ORDER BY id LIMIT 1;
    IF v_category_id IS NULL THEN
        RAISE EXCEPTION 'SALES_RETURN_TRANSACTION_CATEGORY_NOT_FOUND';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.sales_return_lines
        WHERE company_id=v_company AND document_id=v_document.id
    ) OR NOT EXISTS (
        SELECT 1 FROM public.sales_return_refunds
        WHERE company_id=v_company AND document_id=v_document.id
    ) THEN RAISE EXCEPTION 'SALES_RETURN_DRAFT_INCOMPLETE'; END IF;
    IF EXISTS (
        SELECT 1
        FROM public.sales_return_lines line
        LEFT JOIN public.warehouses warehouse
          ON warehouse.company_id=line.company_id
         AND warehouse.id=line.destination_warehouse_id
        WHERE line.company_id=v_company AND line.document_id=v_document.id
          AND line.return_condition<>'NO_PHYSICAL_RETURN'
          AND (
              warehouse.id IS NULL OR NOT warehouse.is_active
              OR (line.return_condition='SALEABLE' AND (
                  warehouse.warehouse_type IS DISTINCT FROM 'STORE'
                  OR warehouse.store_id IS DISTINCT FROM v_document.store_id
                  OR warehouse.id IS DISTINCT FROM v_sale.sales_warehouse_id
              ))
              OR (line.return_condition='DAMAGED'
                  AND warehouse.warehouse_type IS DISTINCT FROM 'DAMAGED')
          )
    ) THEN RAISE EXCEPTION 'RETURN_WAREHOUSE_CHANGED_DURING_POST'; END IF;
    IF EXISTS (
        SELECT 1
        FROM public.sales_return_refunds refund
        LEFT JOIN public.payment_methods method
          ON method.company_id=refund.company_id
         AND method.id=refund.payment_method_id
        WHERE refund.company_id=v_company AND refund.document_id=v_document.id
          AND (
              method.id IS NULL OR NOT method.is_active
              OR method.method_type NOT IN ('CASH','TRANSFER')
              OR method.effective_from>v_now
              OR (method.effective_to IS NOT NULL AND method.effective_to<v_now)
              OR NOT (
                  method.available_all_stores OR EXISTS (
                      SELECT 1
                      FROM public.payment_method_store_assignments assignment
                      WHERE assignment.company_id=method.company_id
                        AND assignment.payment_method_id=method.id
                        AND assignment.store_id=v_document.store_id
                  )
              )
          )
    ) THEN RAISE EXCEPTION 'REFUND_METHOD_CHANGED_DURING_POST'; END IF;
    v_before := to_jsonb(v_document);

    FOR v_line IN SELECT * FROM public.sales_return_lines
        WHERE company_id=v_company AND document_id=v_document.id
        ORDER BY product_id,id
    LOOP
        PERFORM 1 FROM public.sales_details detail
        WHERE detail.company_id=v_company AND detail.id=v_line.source_sales_detail_id
        FOR UPDATE;
        SELECT COALESCE(sum(line.quantity_uom),0) INTO v_prior
        FROM public.sales_return_lines line
        JOIN public.sales_return_documents document
          ON document.company_id=line.company_id AND document.id=line.document_id
         AND document.status='POSTED'
        WHERE line.company_id=v_company
          AND line.source_sales_detail_id=v_line.source_sales_detail_id;
        IF v_prior+v_line.quantity_uom > (
            SELECT qty FROM public.sales_details
            WHERE company_id=v_company AND id=v_line.source_sales_detail_id
        ) THEN RAISE EXCEPTION 'RETURN_QUANTITY_CHANGED_DURING_POST'; END IF;
        v_line_cost := 0;
        IF v_line.return_condition <> 'NO_PHYSICAL_RETURN' THEN
            FOR v_requirement IN SELECT * FROM public.sale_stock_requirements
                WHERE company_id=v_company AND sales_id=v_sale.id
                  AND sales_detail_id=v_line.source_sales_detail_id
                ORDER BY stock_product_id,id
            LOOP
                v_remaining := round(
                    v_requirement.quantity_base * v_line.quantity_uom /
                    (SELECT qty FROM public.sales_details
                     WHERE company_id=v_company
                       AND id=v_line.source_sales_detail_id),6
                );
                PERFORM pg_advisory_xact_lock(hashtextextended(
                    v_company::TEXT||':STOCK:'||v_requirement.stock_product_id::TEXT
                    ||':'||v_line.destination_warehouse_id::TEXT,0
                ));
                FOR v_allocation IN SELECT * FROM public.sale_fifo_allocations
                    WHERE company_id=v_company
                      AND stock_requirement_id=v_requirement.id
                    ORDER BY created_at,id
                LOOP
                    EXIT WHEN v_remaining<=0;
                    SELECT v_allocation.quantity_base-COALESCE(sum(quantity_base),0)
                    INTO v_available
                    FROM public.sales_return_fifo_restorations
                    WHERE company_id=v_company
                      AND source_sale_fifo_allocation_id=v_allocation.id;
                    v_available := COALESCE(v_available,v_allocation.quantity_base);
                    IF v_available<=0 THEN CONTINUE; END IF;
                    v_take := LEAST(v_remaining,v_available);
                    INSERT INTO public.product_batches(
                        product_id,warehouse_id,purchase_detail_id,
                        qty_purchased,qty_remaining,cogs_unit,company_id,
                        source_batch_id,sales_return_line_id
                    ) VALUES (
                        v_requirement.stock_product_id,
                        v_line.destination_warehouse_id,NULL,
                        v_take,v_take,v_allocation.fifo_unit_cost,v_company,
                        v_allocation.product_batch_id,v_line.id
                    ) RETURNING id INTO v_batch_id;
                    INSERT INTO public.sales_return_fifo_restorations(
                        company_id,document_id,return_line_id,
                        source_sale_fifo_allocation_id,source_product_batch_id,
                        restored_product_batch_id,product_id,warehouse_id,
                        quantity_base,fifo_unit_cost,fifo_cost_total
                    ) VALUES (
                        v_company,v_document.id,v_line.id,v_allocation.id,
                        v_allocation.product_batch_id,v_batch_id,
                        v_requirement.stock_product_id,
                        v_line.destination_warehouse_id,v_take,
                        v_allocation.fifo_unit_cost,
                        round(v_take*v_allocation.fifo_unit_cost,4)
                    ) RETURNING id INTO v_restoration_id;
                    INSERT INTO public.product_stocks(
                        product_id,warehouse_id,stock_qty,company_id
                    ) VALUES (
                        v_requirement.stock_product_id,
                        v_line.destination_warehouse_id,v_take,v_company
                    ) ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
                        stock_qty=public.product_stocks.stock_qty+EXCLUDED.stock_qty,
                        updated_at=v_now
                    RETURNING stock_qty INTO v_stock_after;
                    INSERT INTO public.stock_movements(
                        product_id,warehouse_id,qty_change,movement_type,
                        reference_table,reference_id,company_id,
                        base_uom_id,base_uom_name_snapshot,
                        balance_after_base_qty,actor_id,posted_at,
                        movement_status,source_line_id,notes
                    ) VALUES (
                        v_requirement.stock_product_id,
                        v_line.destination_warehouse_id,v_take,
                        'SALES_RETURN'::public.stock_movement_type,
                        'sales_return_documents',v_document.id,v_company,
                        v_requirement.stock_uom_id,
                        v_requirement.stock_uom_name_snapshot,v_stock_after,
                        v_actor,v_now,'POSTED',v_restoration_id,
                        'Restored from original Sale FIFO allocation'
                    );
                    v_line_cost := v_line_cost
                        + round(v_take*v_allocation.fifo_unit_cost,4);
                    v_remaining := v_remaining-v_take;
                END LOOP;
                IF v_remaining<>0 THEN
                    RAISE EXCEPTION 'SOURCE_SALE_FIFO_RESTORATION_EXHAUSTED';
                END IF;
            END LOOP;
        END IF;
        UPDATE public.sales_return_lines
        SET fifo_cost_restored=v_line_cost
        WHERE company_id=v_company AND id=v_line.id;
        v_total_cost := v_total_cost+v_line_cost;
    END LOOP;

    INSERT INTO public.financial_events(
        event_code,event_type,source_table,source_id,root_sales_id,
        event_date,event_version,idempotency_key,payment_method,amounts,
        status,error_message,created_by,company_id,store_id,
        system_event_key,transaction_category_id
    ) VALUES (
        'RETURN-'||replace(v_document.id::TEXT,'-',''),
        'SALES_REFUND'::public.event_type,'sales_return_documents',
        v_document.id,v_sale.id,v_now,1,
        'SALES_RETURN|'||v_company::TEXT||'|'||p_idempotency_key::TEXT,
        CASE WHEN (SELECT count(*) FROM public.sales_return_refunds
             WHERE company_id=v_company AND document_id=v_document.id)=1
             THEN (SELECT payment_method_name_snapshot
                   FROM public.sales_return_refunds
                   WHERE company_id=v_company AND document_id=v_document.id
                   LIMIT 1) ELSE 'SPLIT' END,
        jsonb_build_object(
            'sourceSalesId',v_sale.id,'refundBeforeRounding',
            v_document.refund_before_rounding,'roundingAdjustment',
            v_document.rounding_adjustment,'refundTotal',v_document.refund_total,
            'taxRefund',(
                SELECT COALESCE(sum(tax_refund_amount),0)
                FROM public.sales_return_lines
                WHERE company_id=v_company AND document_id=v_document.id
            ),'fifoCostRestored',v_total_cost,
            'financePostingState','HOLD_UNTIL_G6'
        ),'HOLD'::public.event_status,
        'CANONICAL_FINANCE_POSTING_NOT_ENABLED',v_actor,v_company,
        v_document.store_id,'SALES_RETURN',v_category_id
    ) RETURNING id INTO v_event_id;

    UPDATE public.sales_return_documents SET
        status='POSTED',posting_idempotency_key=p_idempotency_key,
        transaction_category_id=v_category_id,financial_event_id=v_event_id,
        posted_by=v_actor,posted_at=v_now,updated_by=v_actor,updated_at=v_now,
        master_version=master_version+1
    WHERE company_id=v_company AND id=v_document.id
    RETURNING master_version INTO v_version;
    INSERT INTO public.sales_return_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) SELECT v_company,v_document.id,'POST',v_actor,v_before,to_jsonb(document)
      FROM public.sales_return_documents document
      WHERE document.company_id=v_company AND document.id=v_document.id;
    RETURN jsonb_build_object(
        'documentId',v_document.id,'returnNo',v_document.return_no,
        'status','POSTED','masterVersion',v_version,
        'financialEventId',v_event_id,'refundTotal',v_document.refund_total,
        'idempotentReplay',FALSE
    );
END;
$$;

CREATE FUNCTION public.cancel_sales_return_draft(
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
    v_actor UUID:=auth.uid();
    v_company UUID:=public.private_active_company_id();
    v_document public.sales_return_documents%ROWTYPE;
    v_before JSONB;
    v_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF NULLIF(btrim(p_reason),'') IS NULL THEN
        RAISE EXCEPTION 'CANCEL_REASON_REQUIRED';
    END IF;
    SELECT * INTO v_document FROM public.sales_return_documents
    WHERE company_id=v_company AND id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SALES_RETURN_NOT_FOUND'; END IF;
    IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'ONLY_DRAFT_RETURN_CANCELABLE'; END IF;
    IF p_master_version IS NULL OR p_master_version<>v_document.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_document.created_by<>v_actor
       AND NOT (
           public.private_user_has_any_company_role(
               v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
           )
           OR public.private_user_has_any_store_role(
               v_document.store_id,ARRAY['STORE_MANAGER']::TEXT[]
           )
       ) THEN RAISE EXCEPTION 'SALES_RETURN_CANCEL_NOT_ALLOWED'; END IF;
    v_before:=to_jsonb(v_document);
    UPDATE public.sales_return_documents SET
        status='CANCELED',cancel_reason=btrim(p_reason),
        canceled_by=v_actor,canceled_at=clock_timestamp(),
        updated_by=v_actor,updated_at=clock_timestamp(),
        master_version=master_version+1
    WHERE company_id=v_company AND id=v_document.id
    RETURNING master_version INTO v_version;
    INSERT INTO public.sales_return_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) SELECT v_company,v_document.id,'CANCEL',v_actor,v_before,to_jsonb(document)
      FROM public.sales_return_documents document
      WHERE document.company_id=v_company AND document.id=v_document.id;
    RETURN jsonb_build_object(
        'documentId',v_document.id,'status','CANCELED',
        'masterVersion',v_version
    );
END;
$$;

-- Cash refunds reduce expected drawer cash in the executing Session.
CREATE OR REPLACE FUNCTION private.calculate_cashier_session_expected_cash(
    p_company_id UUID,
    p_cashier_session_id UUID
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT cs.opening_cash_actual
        + COALESCE((
            SELECT sum(CASE WHEN sp.is_reversal THEN -sp.amount ELSE sp.amount END)
            FROM public.sales_payments sp
            JOIN public.sales_headers sh
              ON sh.company_id=sp.company_id AND sh.id=sp.sales_id
            LEFT JOIN public.payment_methods pm
              ON pm.company_id=sp.company_id AND pm.id=sp.payment_method_id
            WHERE sp.company_id=cs.company_id AND sp.session_id=cs.id
              AND sh.invoice_status::TEXT='GENERATED'
              AND (pm.method_type='CASH' OR (
                  sp.payment_method_id IS NULL
                  AND sp.payment_method::TEXT='Cash'
              ))
        ),0)
        - COALESCE((
            SELECT sum(refund.amount)
            FROM public.sales_return_refunds refund
            JOIN public.sales_return_documents document
              ON document.company_id=refund.company_id
             AND document.id=refund.document_id
             AND document.status='POSTED'
            WHERE refund.company_id=cs.company_id
              AND document.executing_session_id=cs.id
              AND refund.payment_method_type_snapshot='CASH'
        ),0)
    FROM public.cashier_sessions cs
    WHERE cs.company_id=p_company_id AND cs.id=p_cashier_session_id;
$$;

ALTER TABLE public.sales_return_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_return_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_return_refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_return_fifo_restorations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_return_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Sales Return documents visible in active Company"
ON public.sales_return_documents FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_cashier_session_visible(executing_session_id)
);
CREATE POLICY "Sales Return lines visible in active Company"
ON public.sales_return_lines FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND EXISTS (
        SELECT 1 FROM public.sales_return_documents document
        WHERE document.company_id=sales_return_lines.company_id
          AND document.id=sales_return_lines.document_id
          AND public.private_cashier_session_visible(
              document.executing_session_id
          )
    )
);
CREATE POLICY "Sales Return refunds visible to return managers"
ON public.sales_return_refunds FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND EXISTS (
        SELECT 1 FROM public.sales_return_documents document
        WHERE document.company_id=sales_return_refunds.company_id
          AND document.id=sales_return_refunds.document_id
          AND public.private_cashier_session_visible(
              document.executing_session_id
          )
    )
);
CREATE POLICY "Sales Return FIFO visible in active Company"
ON public.sales_return_fifo_restorations FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND EXISTS (
        SELECT 1 FROM public.sales_return_documents document
        WHERE document.company_id=sales_return_fifo_restorations.company_id
          AND document.id=sales_return_fifo_restorations.document_id
          AND public.private_cashier_session_visible(
              document.executing_session_id
          )
    )
);
CREATE POLICY "Sales Return audit visible to return managers"
ON public.sales_return_audit FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND EXISTS (
        SELECT 1 FROM public.sales_return_documents document
        WHERE document.company_id=sales_return_audit.company_id
          AND document.id=sales_return_audit.document_id
          AND public.private_cashier_session_visible(
              document.executing_session_id
          )
    )
);

REVOKE ALL ON public.sales_return_documents,public.sales_return_lines,
    public.sales_return_refunds,public.sales_return_fifo_restorations,
    public.sales_return_audit FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.sales_return_documents,public.sales_return_lines,
    public.sales_return_refunds,public.sales_return_fifo_restorations,
    public.sales_return_audit TO authenticated;
GRANT ALL ON public.sales_return_documents,public.sales_return_lines,
    public.sales_return_refunds,public.sales_return_fifo_restorations,
    public.sales_return_audit TO service_role;

REVOKE ALL ON FUNCTION public.list_returnable_sales(TEXT,INTEGER),
    public.save_sales_return_draft(UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB,JSONB),
    public.post_sales_return(UUID,BIGINT,UUID),
    public.cancel_sales_return_draft(UUID,BIGINT,TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.list_returnable_sales(TEXT,INTEGER),
    public.save_sales_return_draft(UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB,JSONB),
    public.post_sales_return(UUID,BIGINT,UUID),
    public.cancel_sales_return_draft(UUID,BIGINT,TEXT)
TO authenticated,service_role;
REVOKE ALL ON FUNCTION private.trg_g4_sales_return_history_guard()
FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.trg_g4_sales_return_audit_immutable()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g4_sales_return_history_guard(),
    private.trg_g4_sales_return_audit_immutable(),
    private.calculate_cashier_session_expected_cash(UUID,UUID)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260803010000','g4_phase26_sales_return_foundation',
    'Canonical source-bound Sales Return draft/post/cancel, refund snapshots, original FIFO restoration, audit, idempotency, and Finance HOLD event'
);

COMMIT;
