-- KGS POS G5 phase 11: Supplier Invoice three-way matching foundation.
-- Supplier Order -> Goods Receipt/AP provisional -> Supplier Invoice/AP final.
-- Finance journal posting and Supplier Payment remain closed until G6.
BEGIN;

DO $guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260806070000'
    ) OR NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260806080000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G5 Purchase Return chain missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260806100000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260806100000';
    END IF;
    IF to_regclass('public.supplier_invoice_documents') IS NOT NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Supplier Invoice objects exist';
    END IF;
END
$guard$;

ALTER TYPE public.event_type
    ADD VALUE IF NOT EXISTS 'SUPPLIER_INVOICE_VALIDATED';

CREATE SEQUENCE private.supplier_invoice_no_seq AS BIGINT START 1;
REVOKE ALL ON SEQUENCE private.supplier_invoice_no_seq
    FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.supplier_invoice_no_seq TO service_role;

CREATE TABLE public.supplier_invoice_tolerance_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    supplier_id UUID,
    quantity_tolerance_percent NUMERIC(9,6) NOT NULL DEFAULT 0,
    quantity_tolerance_base_qty NUMERIC(24,6),
    value_tolerance_percent NUMERIC(9,6) NOT NULL DEFAULT 0,
    value_tolerance_amount NUMERIC(20,4),
    effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT supplier_invoice_tolerance_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT fk_supplier_invoice_tolerance_company
        FOREIGN KEY(company_id) REFERENCES public.companies(id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_invoice_tolerance_supplier
        FOREIGN KEY(company_id,supplier_id)
        REFERENCES public.suppliers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT supplier_invoice_tolerance_quantity_percent_check
        CHECK(quantity_tolerance_percent BETWEEN 0 AND 100),
    CONSTRAINT supplier_invoice_tolerance_quantity_amount_check
        CHECK(quantity_tolerance_base_qty IS NULL
              OR quantity_tolerance_base_qty >= 0),
    CONSTRAINT supplier_invoice_tolerance_value_percent_check
        CHECK(value_tolerance_percent BETWEEN 0 AND 100),
    CONSTRAINT supplier_invoice_tolerance_value_amount_check
        CHECK(value_tolerance_amount IS NULL OR value_tolerance_amount >= 0),
    CONSTRAINT supplier_invoice_tolerance_version_check
        CHECK(master_version > 0)
);

CREATE UNIQUE INDEX uq_supplier_invoice_tolerance_company_default
    ON public.supplier_invoice_tolerance_policies(company_id)
    WHERE supplier_id IS NULL AND is_active;
CREATE UNIQUE INDEX uq_supplier_invoice_tolerance_supplier_active
    ON public.supplier_invoice_tolerance_policies(company_id,supplier_id)
    WHERE supplier_id IS NOT NULL AND is_active;

CREATE TABLE public.supplier_invoice_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    invoice_no TEXT NOT NULL,
    supplier_invoice_no TEXT NOT NULL,
    supplier_id UUID NOT NULL,
    invoice_date DATE NOT NULL,
    due_date DATE,
    price_mode TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    matching_status TEXT NOT NULL DEFAULT 'UNMATCHED',
    line_count INTEGER NOT NULL DEFAULT 0,
    invoice_total_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
    allocated_total_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
    subtotal_before_tax NUMERIC(20,4) NOT NULL DEFAULT 0,
    tax_total NUMERIC(20,4) NOT NULL DEFAULT 0,
    grand_total NUMERIC(20,4) NOT NULL DEFAULT 0,
    provisional_value_allocated NUMERIC(20,4) NOT NULL DEFAULT 0,
    actual_value_allocated NUMERIC(20,4) NOT NULL DEFAULT 0,
    purchase_price_variance NUMERIC(20,4) NOT NULL DEFAULT 0,
    tolerance_policy_id UUID,
    tolerance_policy_version BIGINT,
    notes TEXT,
    evidence_url TEXT,
    validation_idempotency_key UUID,
    financial_event_id UUID REFERENCES public.financial_events(id)
        ON DELETE RESTRICT,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    validated_by UUID REFERENCES public.profiles(id),
    validated_at TIMESTAMPTZ,
    canceled_by UUID REFERENCES public.profiles(id),
    canceled_at TIMESTAMPTZ,
    cancel_reason TEXT,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT supplier_invoice_documents_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT supplier_invoice_documents_company_no_unique
        UNIQUE(company_id,invoice_no),
    CONSTRAINT supplier_invoice_documents_validation_key_unique
        UNIQUE(company_id,validation_idempotency_key),
    CONSTRAINT fk_supplier_invoice_document_company
        FOREIGN KEY(company_id) REFERENCES public.companies(id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_invoice_document_supplier
        FOREIGN KEY(company_id,supplier_id)
        REFERENCES public.suppliers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_invoice_document_tolerance
        FOREIGN KEY(company_id,tolerance_policy_id)
        REFERENCES public.supplier_invoice_tolerance_policies(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT supplier_invoice_document_no_not_blank
        CHECK(btrim(invoice_no) <> '' AND btrim(supplier_invoice_no) <> ''),
    CONSTRAINT supplier_invoice_document_date_check
        CHECK(due_date IS NULL OR due_date >= invoice_date),
    CONSTRAINT supplier_invoice_document_price_mode_check
        CHECK(price_mode IN ('INCLUSIVE','EXCLUSIVE')),
    CONSTRAINT supplier_invoice_document_status_check
        CHECK(status IN ('DRAFT','HOLD','VALIDATED','CANCELED')),
    CONSTRAINT supplier_invoice_document_matching_status_check
        CHECK(matching_status IN (
            'UNMATCHED','PARTIALLY_MATCHED','MATCHED',
            'WITHIN_TOLERANCE','EXCEPTION','HOLD','CLOSED'
        )),
    CONSTRAINT supplier_invoice_document_totals_check CHECK(
        line_count >= 0
        AND invoice_total_base_qty >= 0
        AND allocated_total_base_qty >= 0
        AND allocated_total_base_qty <= invoice_total_base_qty
        AND subtotal_before_tax >= 0
        AND tax_total >= 0
        AND grand_total >= 0
        AND provisional_value_allocated >= 0
        AND actual_value_allocated >= 0
    ),
    CONSTRAINT supplier_invoice_document_evidence_https_check
        CHECK(evidence_url IS NULL OR evidence_url ~* '^https://'),
    CONSTRAINT supplier_invoice_document_version_check
        CHECK(master_version > 0),
    CONSTRAINT supplier_invoice_document_lifecycle_check CHECK(
        (status IN ('DRAFT','HOLD')
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

CREATE UNIQUE INDEX uq_supplier_invoice_external_no
    ON public.supplier_invoice_documents(
        company_id,supplier_id,
        upper(regexp_replace(btrim(supplier_invoice_no),'\s+',' ','g'))
    ) WHERE status <> 'CANCELED';
CREATE INDEX idx_supplier_invoice_supplier_status
    ON public.supplier_invoice_documents(
        company_id,supplier_id,status,invoice_date DESC
    );

CREATE TABLE public.supplier_invoice_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    line_no INTEGER NOT NULL,
    client_line_key UUID NOT NULL,
    product_id UUID NOT NULL,
    invoice_uom_id UUID NOT NULL,
    invoice_qty NUMERIC(24,6) NOT NULL,
    factor_to_base_snapshot NUMERIC(24,6) NOT NULL,
    invoice_base_qty NUMERIC(24,6) NOT NULL,
    unit_price_input NUMERIC(20,4) NOT NULL,
    price_mode_snapshot TEXT NOT NULL,
    net_unit_price NUMERIC(20,6) NOT NULL,
    subtotal_before_tax NUMERIC(20,4) NOT NULL,
    tax_rule_id UUID,
    tax_rule_version_id UUID,
    tax_code_snapshot TEXT,
    tax_name_snapshot TEXT,
    tax_rate_percent_snapshot NUMERIC(9,6) NOT NULL DEFAULT 0,
    tax_calculation_scope_snapshot TEXT,
    tax_is_recoverable_snapshot BOOLEAN,
    tax_account_id_snapshot UUID,
    tax_amount NUMERIC(20,4) NOT NULL DEFAULT 0,
    line_total NUMERIC(20,4) NOT NULL,
    allocated_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
    product_sku_snapshot TEXT NOT NULL,
    product_name_snapshot TEXT NOT NULL,
    invoice_uom_name_snapshot TEXT NOT NULL,
    base_uom_id UUID NOT NULL,
    base_uom_name_snapshot TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT supplier_invoice_lines_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT supplier_invoice_lines_line_unique
        UNIQUE(company_id,document_id,line_no),
    CONSTRAINT supplier_invoice_lines_client_key_unique
        UNIQUE(company_id,document_id,client_line_key),
    CONSTRAINT fk_supplier_invoice_line_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.supplier_invoice_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_invoice_line_product
        FOREIGN KEY(company_id,product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_invoice_line_uom
        FOREIGN KEY(company_id,product_id,invoice_uom_id)
        REFERENCES public.product_uoms(company_id,product_id,uom_id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_invoice_line_base_uom
        FOREIGN KEY(company_id,base_uom_id)
        REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_invoice_line_tax_rule
        FOREIGN KEY(company_id,tax_rule_id)
        REFERENCES public.tax_rules(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_invoice_line_tax_version
        FOREIGN KEY(company_id,tax_rule_version_id)
        REFERENCES public.tax_rule_versions(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_invoice_line_tax_account
        FOREIGN KEY(company_id,tax_account_id_snapshot)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT supplier_invoice_line_quantity_check CHECK(
        line_no > 0 AND invoice_qty > 0 AND factor_to_base_snapshot > 0
        AND invoice_base_qty > 0
        AND allocated_base_qty >= 0
        AND allocated_base_qty <= invoice_base_qty
    ),
    CONSTRAINT supplier_invoice_line_value_check CHECK(
        unit_price_input >= 0 AND net_unit_price >= 0
        AND subtotal_before_tax >= 0 AND tax_amount >= 0
        AND line_total >= 0
    ),
    CONSTRAINT supplier_invoice_line_price_mode_check
        CHECK(price_mode_snapshot IN ('INCLUSIVE','EXCLUSIVE')),
    CONSTRAINT supplier_invoice_line_tax_shape_check CHECK(
        (tax_rule_id IS NULL AND tax_rule_version_id IS NULL
         AND tax_code_snapshot IS NULL AND tax_name_snapshot IS NULL
         AND tax_rate_percent_snapshot = 0 AND tax_amount = 0
         AND tax_calculation_scope_snapshot IS NULL
         AND tax_is_recoverable_snapshot IS NULL
         AND tax_account_id_snapshot IS NULL)
        OR (tax_rule_id IS NOT NULL AND tax_rule_version_id IS NOT NULL
            AND btrim(COALESCE(tax_code_snapshot,'')) <> ''
            AND btrim(COALESCE(tax_name_snapshot,'')) <> ''
            AND tax_rate_percent_snapshot BETWEEN 0 AND 100
            AND tax_calculation_scope_snapshot IN ('PER_LINE','PER_DOCUMENT')
            AND tax_is_recoverable_snapshot IS NOT NULL
            AND tax_account_id_snapshot IS NOT NULL)
    ),
    CONSTRAINT supplier_invoice_line_snapshots_not_blank CHECK(
        btrim(product_sku_snapshot) <> ''
        AND btrim(product_name_snapshot) <> ''
        AND btrim(invoice_uom_name_snapshot) <> ''
        AND btrim(base_uom_name_snapshot) <> ''
    )
);

CREATE INDEX idx_supplier_invoice_lines_product
    ON public.supplier_invoice_lines(company_id,product_id,document_id);

CREATE TABLE public.supplier_invoice_allocations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    invoice_line_id UUID NOT NULL,
    client_allocation_key UUID NOT NULL,
    source_ap_provisional_id UUID NOT NULL,
    supplier_order_line_id UUID NOT NULL,
    receipt_line_id UUID NOT NULL,
    allocated_base_qty NUMERIC(24,6) NOT NULL,
    provisional_unit_cost_snapshot NUMERIC(20,6) NOT NULL,
    provisional_value NUMERIC(20,4) NOT NULL,
    actual_unit_cost NUMERIC(20,6) NOT NULL,
    actual_value NUMERIC(20,4) NOT NULL,
    price_variance NUMERIC(20,4) NOT NULL,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT supplier_invoice_allocations_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT supplier_invoice_allocations_source_unique
        UNIQUE(company_id,document_id,invoice_line_id,source_ap_provisional_id),
    CONSTRAINT supplier_invoice_allocations_client_key_unique
        UNIQUE(company_id,document_id,client_allocation_key),
    CONSTRAINT fk_supplier_invoice_allocation_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.supplier_invoice_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_invoice_allocation_line
        FOREIGN KEY(company_id,invoice_line_id)
        REFERENCES public.supplier_invoice_lines(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_invoice_allocation_provisional
        FOREIGN KEY(company_id,source_ap_provisional_id)
        REFERENCES public.goods_receipt_ap_provisionals(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_invoice_allocation_order_line
        FOREIGN KEY(company_id,supplier_order_line_id)
        REFERENCES public.supplier_order_lines(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_invoice_allocation_receipt_line
        FOREIGN KEY(company_id,receipt_line_id)
        REFERENCES public.goods_receipt_lines(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT supplier_invoice_allocation_quantity_check
        CHECK(allocated_base_qty > 0),
    CONSTRAINT supplier_invoice_allocation_value_check CHECK(
        provisional_unit_cost_snapshot >= 0
        AND provisional_value >= 0
        AND actual_unit_cost >= 0
        AND actual_value >= 0
        AND price_variance = actual_value - provisional_value
    )
);

CREATE INDEX idx_supplier_invoice_allocation_provisional
    ON public.supplier_invoice_allocations(
        company_id,source_ap_provisional_id,document_id
    );

CREATE TABLE public.supplier_invoice_tolerance_results (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    tolerance_policy_id UUID,
    tolerance_policy_version BIGINT,
    invoice_base_qty NUMERIC(24,6) NOT NULL,
    allocated_base_qty NUMERIC(24,6) NOT NULL,
    quantity_variance_base_qty NUMERIC(24,6) NOT NULL,
    quantity_tolerance_percent_snapshot NUMERIC(9,6) NOT NULL,
    quantity_tolerance_base_qty_snapshot NUMERIC(24,6),
    provisional_value NUMERIC(20,4) NOT NULL,
    actual_value NUMERIC(20,4) NOT NULL,
    value_variance NUMERIC(20,4) NOT NULL,
    value_tolerance_percent_snapshot NUMERIC(9,6) NOT NULL,
    value_tolerance_amount_snapshot NUMERIC(20,4),
    result_status TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT supplier_invoice_tolerance_results_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT supplier_invoice_tolerance_results_document_unique
        UNIQUE(company_id,document_id),
    CONSTRAINT fk_supplier_invoice_tolerance_result_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.supplier_invoice_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_supplier_invoice_tolerance_result_policy
        FOREIGN KEY(company_id,tolerance_policy_id)
        REFERENCES public.supplier_invoice_tolerance_policies(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT supplier_invoice_tolerance_result_shape_check CHECK(
        invoice_base_qty >= 0 AND allocated_base_qty >= 0
        AND provisional_value >= 0 AND actual_value >= 0
        AND quantity_variance_base_qty = invoice_base_qty - allocated_base_qty
        AND value_variance = actual_value - provisional_value
        AND quantity_tolerance_percent_snapshot BETWEEN 0 AND 100
        AND (quantity_tolerance_base_qty_snapshot IS NULL
             OR quantity_tolerance_base_qty_snapshot >= 0)
        AND value_tolerance_percent_snapshot BETWEEN 0 AND 100
        AND (value_tolerance_amount_snapshot IS NULL
             OR value_tolerance_amount_snapshot >= 0)
    ),
    CONSTRAINT supplier_invoice_tolerance_result_status_check
        CHECK(result_status IN (
            'MATCHED','WITHIN_TOLERANCE','EXCEPTION','HOLD'
        ))
);

CREATE TABLE public.supplier_invoice_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    action TEXT NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fk_supplier_invoice_audit_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.supplier_invoice_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT supplier_invoice_audit_action_check
        CHECK(action IN ('CREATE','UPDATE','HOLD','VALIDATE','CANCEL'))
);

CREATE INDEX idx_supplier_invoice_audit_document
    ON public.supplier_invoice_audit(company_id,document_id,created_at DESC);

-- Zero tolerance is the safe server default. Supplier-specific policies can
-- later override it without changing historical document snapshots.
INSERT INTO public.supplier_invoice_tolerance_policies(
    company_id,supplier_id,created_by,updated_by
)
SELECT company.id,NULL,NULL,NULL
FROM public.companies company
ON CONFLICT DO NOTHING;

CREATE FUNCTION public.private_supplier_invoice_finance_allowed(
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

CREATE FUNCTION private.trg_g5_guard_ap_provisional_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_receipt_status TEXT;
BEGIN
    SELECT document.status INTO v_receipt_status
    FROM public.goods_receipt_documents document
    WHERE document.company_id = COALESCE(NEW.company_id,OLD.company_id)
      AND document.id = COALESCE(NEW.receipt_id,OLD.receipt_id);
    IF NOT FOUND THEN RAISE EXCEPTION 'GOODS_RECEIPT_NOT_FOUND'; END IF;
    IF TG_OP = 'INSERT' THEN
        IF v_receipt_status <> 'DRAFT' THEN
            RAISE EXCEPTION 'FINAL_GOODS_RECEIPT_IMMUTABLE';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'DELETE' THEN
        IF v_receipt_status <> 'DRAFT' THEN
            RAISE EXCEPTION 'FINAL_GOODS_RECEIPT_IMMUTABLE';
        END IF;
        RETURN OLD;
    END IF;
    IF v_receipt_status <> 'POSTED'
       OR NEW.company_id IS DISTINCT FROM OLD.company_id
       OR NEW.receipt_id IS DISTINCT FROM OLD.receipt_id
       OR NEW.receipt_line_id IS DISTINCT FROM OLD.receipt_line_id
       OR NEW.supplier_id IS DISTINCT FROM OLD.supplier_id
       OR NEW.amount IS DISTINCT FROM OLD.amount
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NOT (
           NEW.status = OLD.status
           OR (OLD.status = 'OPEN' AND NEW.status IN ('MATCHED','REVERSED'))
       ) THEN
        RAISE EXCEPTION 'AP_PROVISIONAL_HISTORY_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER g5_guard_goods_receipt_ap
ON public.goods_receipt_ap_provisionals;
CREATE TRIGGER g5_guard_goods_receipt_ap
BEFORE INSERT OR UPDATE OR DELETE ON public.goods_receipt_ap_provisionals
FOR EACH ROW EXECUTE FUNCTION private.trg_g5_guard_ap_provisional_lifecycle();

CREATE FUNCTION private.trg_g5_supplier_invoice_document_guard()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_OP <> 'INSERT' AND OLD.status IN ('VALIDATED','CANCELED') THEN
        RAISE EXCEPTION 'FINAL_SUPPLIER_INVOICE_IMMUTABLE';
    END IF;
    RETURN COALESCE(NEW,OLD);
END;
$$;

CREATE FUNCTION private.trg_g5_supplier_invoice_child_guard()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_document_id UUID;
    v_status TEXT;
BEGIN
    v_document_id := COALESCE(NEW.document_id,OLD.document_id);
    SELECT document.status INTO v_status
    FROM public.supplier_invoice_documents document
    WHERE document.id = v_document_id;
    IF v_status NOT IN ('DRAFT','HOLD') THEN
        RAISE EXCEPTION 'FINAL_SUPPLIER_INVOICE_IMMUTABLE';
    END IF;
    RETURN COALESCE(NEW,OLD);
END;
$$;

CREATE TRIGGER g5_guard_supplier_invoice_documents
BEFORE UPDATE OR DELETE ON public.supplier_invoice_documents
FOR EACH ROW EXECUTE FUNCTION private.trg_g5_supplier_invoice_document_guard();
CREATE TRIGGER g5_guard_supplier_invoice_lines
BEFORE INSERT OR UPDATE OR DELETE ON public.supplier_invoice_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_g5_supplier_invoice_child_guard();
CREATE TRIGGER g5_guard_supplier_invoice_allocations
BEFORE INSERT OR UPDATE OR DELETE ON public.supplier_invoice_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_g5_supplier_invoice_child_guard();
CREATE TRIGGER g5_guard_supplier_invoice_tolerance_results
BEFORE INSERT OR UPDATE OR DELETE ON public.supplier_invoice_tolerance_results
FOR EACH ROW EXECUTE FUNCTION private.trg_g5_supplier_invoice_child_guard();

CREATE TRIGGER g5_touch_supplier_invoice_tolerance_policy
BEFORE INSERT OR UPDATE ON public.supplier_invoice_tolerance_policies
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();

CREATE FUNCTION private.refresh_supplier_invoice_totals(
    p_company_id UUID,p_document_id UUID
) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_document public.supplier_invoice_documents%ROWTYPE;
    v_policy public.supplier_invoice_tolerance_policies%ROWTYPE;
    v_line_count INTEGER;
    v_invoice_qty NUMERIC(24,6);
    v_allocated_qty NUMERIC(24,6);
    v_subtotal NUMERIC(20,4);
    v_tax NUMERIC(20,4);
    v_grand NUMERIC(20,4);
    v_provisional NUMERIC(20,4);
    v_actual NUMERIC(20,4);
    v_variance NUMERIC(20,4);
    v_value_tolerance NUMERIC(20,4);
    v_matching_status TEXT;
BEGIN
    SELECT * INTO v_document
    FROM public.supplier_invoice_documents document
    WHERE document.company_id = p_company_id
      AND document.id = p_document_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_INVOICE_NOT_FOUND'; END IF;

    UPDATE public.supplier_invoice_lines line SET
        allocated_base_qty = COALESCE((
            SELECT sum(allocation.allocated_base_qty)
            FROM public.supplier_invoice_allocations allocation
            WHERE allocation.company_id = line.company_id
              AND allocation.invoice_line_id = line.id
        ),0)
    WHERE line.company_id = p_company_id
      AND line.document_id = p_document_id;

    SELECT count(*),COALESCE(sum(line.invoice_base_qty),0),
           COALESCE(sum(line.allocated_base_qty),0),
           COALESCE(sum(line.subtotal_before_tax),0),
           COALESCE(sum(line.tax_amount),0),
           COALESCE(sum(line.line_total),0)
      INTO v_line_count,v_invoice_qty,v_allocated_qty,
           v_subtotal,v_tax,v_grand
    FROM public.supplier_invoice_lines line
    WHERE line.company_id = p_company_id
      AND line.document_id = p_document_id;

    SELECT COALESCE(sum(allocation.provisional_value),0),
           COALESCE(sum(allocation.actual_value),0)
      INTO v_provisional,v_actual
    FROM public.supplier_invoice_allocations allocation
    WHERE allocation.company_id = p_company_id
      AND allocation.document_id = p_document_id;
    v_variance := round(v_actual-v_provisional,4);

    SELECT policy.* INTO v_policy
    FROM public.supplier_invoice_tolerance_policies policy
    WHERE policy.company_id = p_company_id
      AND policy.is_active
      AND policy.effective_from <= v_document.invoice_date
      AND (policy.supplier_id = v_document.supplier_id
           OR policy.supplier_id IS NULL)
    ORDER BY (policy.supplier_id IS NOT NULL) DESC,
             policy.effective_from DESC,policy.id
    LIMIT 1;
    IF NOT FOUND THEN
        v_policy.quantity_tolerance_percent := 0;
        v_policy.value_tolerance_percent := 0;
    END IF;
    v_value_tolerance := GREATEST(
        COALESCE(v_policy.value_tolerance_amount,0),
        round(v_provisional*v_policy.value_tolerance_percent/100,4)
    );

    IF v_allocated_qty = 0 THEN
        v_matching_status := 'UNMATCHED';
    ELSIF v_allocated_qty < v_invoice_qty THEN
        v_matching_status := 'PARTIALLY_MATCHED';
    ELSIF abs(v_variance) = 0 THEN
        v_matching_status := 'MATCHED';
    ELSIF abs(v_variance) <= v_value_tolerance THEN
        v_matching_status := 'WITHIN_TOLERANCE';
    ELSE
        v_matching_status := 'EXCEPTION';
    END IF;

    DELETE FROM public.supplier_invoice_tolerance_results result
    WHERE result.company_id = p_company_id
      AND result.document_id = p_document_id;
    INSERT INTO public.supplier_invoice_tolerance_results(
        company_id,document_id,tolerance_policy_id,tolerance_policy_version,
        invoice_base_qty,allocated_base_qty,quantity_variance_base_qty,
        quantity_tolerance_percent_snapshot,
        quantity_tolerance_base_qty_snapshot,
        provisional_value,actual_value,value_variance,
        value_tolerance_percent_snapshot,value_tolerance_amount_snapshot,
        result_status
    ) VALUES (
        p_company_id,p_document_id,v_policy.id,v_policy.master_version,
        v_invoice_qty,v_allocated_qty,v_invoice_qty-v_allocated_qty,
        COALESCE(v_policy.quantity_tolerance_percent,0),
        v_policy.quantity_tolerance_base_qty,
        v_provisional,v_actual,v_variance,
        COALESCE(v_policy.value_tolerance_percent,0),
        v_policy.value_tolerance_amount,
        CASE
            WHEN v_matching_status = 'MATCHED' THEN 'MATCHED'
            WHEN v_matching_status = 'WITHIN_TOLERANCE'
                THEN 'WITHIN_TOLERANCE'
            WHEN v_matching_status = 'EXCEPTION' THEN 'EXCEPTION'
            ELSE 'HOLD'
        END
    );

    UPDATE public.supplier_invoice_documents SET
        matching_status = v_matching_status,
        line_count = v_line_count,
        invoice_total_base_qty = v_invoice_qty,
        allocated_total_base_qty = v_allocated_qty,
        subtotal_before_tax = v_subtotal,
        tax_total = v_tax,
        grand_total = v_grand,
        provisional_value_allocated = v_provisional,
        actual_value_allocated = v_actual,
        purchase_price_variance = v_variance,
        tolerance_policy_id = v_policy.id,
        tolerance_policy_version = v_policy.master_version,
        updated_at = clock_timestamp()
    WHERE company_id = p_company_id AND id = p_document_id;
    RETURN v_matching_status;
END;
$$;

CREATE FUNCTION public.save_supplier_invoice_tolerance_policy(
    p_policy_id UUID,p_master_version BIGINT,p_supplier_id UUID,
    p_quantity_tolerance_percent NUMERIC,
    p_quantity_tolerance_base_qty NUMERIC,
    p_value_tolerance_percent NUMERIC,p_value_tolerance_amount NUMERIC,
    p_effective_from DATE,p_is_active BOOLEAN
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_id UUID;
    v_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF NOT public.private_supplier_invoice_finance_allowed(v_company) THEN
        RAISE EXCEPTION 'SUPPLIER_INVOICE_FINANCE_ACCESS_DENIED';
    END IF;
    IF p_supplier_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.suppliers supplier
        WHERE supplier.company_id = v_company
          AND supplier.id = p_supplier_id AND supplier.is_active
    ) THEN RAISE EXCEPTION 'ACTIVE_SUPPLIER_NOT_FOUND'; END IF;
    IF p_quantity_tolerance_percent IS NULL
       OR p_quantity_tolerance_percent < 0
       OR p_quantity_tolerance_percent > 100
       OR p_value_tolerance_percent IS NULL
       OR p_value_tolerance_percent < 0
       OR p_value_tolerance_percent > 100
       OR p_quantity_tolerance_base_qty < 0
       OR p_value_tolerance_amount < 0 THEN
        RAISE EXCEPTION 'SUPPLIER_INVOICE_TOLERANCE_INVALID';
    END IF;
    IF p_policy_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        INSERT INTO public.supplier_invoice_tolerance_policies(
            company_id,supplier_id,quantity_tolerance_percent,
            quantity_tolerance_base_qty,value_tolerance_percent,
            value_tolerance_amount,effective_from,is_active,
            created_by,updated_by
        ) VALUES (
            v_company,p_supplier_id,p_quantity_tolerance_percent,
            p_quantity_tolerance_base_qty,p_value_tolerance_percent,
            p_value_tolerance_amount,COALESCE(p_effective_from,CURRENT_DATE),
            COALESCE(p_is_active,TRUE),v_actor,v_actor
        ) RETURNING id,master_version INTO v_id,v_version;
    ELSE
        UPDATE public.supplier_invoice_tolerance_policies SET
            supplier_id = p_supplier_id,
            quantity_tolerance_percent = p_quantity_tolerance_percent,
            quantity_tolerance_base_qty = p_quantity_tolerance_base_qty,
            value_tolerance_percent = p_value_tolerance_percent,
            value_tolerance_amount = p_value_tolerance_amount,
            effective_from = COALESCE(p_effective_from,CURRENT_DATE),
            is_active = COALESCE(p_is_active,TRUE),updated_by = v_actor
        WHERE company_id = v_company AND id = p_policy_id
          AND master_version = p_master_version
        RETURNING id,master_version INTO v_id,v_version;
        IF NOT FOUND THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    END IF;
    RETURN jsonb_build_object('policyId',v_id,'masterVersion',v_version);
END;
$$;

CREATE FUNCTION public.save_supplier_invoice_draft(
    p_document_id UUID,p_master_version BIGINT,p_supplier_id UUID,
    p_supplier_invoice_no TEXT,p_invoice_date DATE,p_due_date DATE,
    p_price_mode TEXT,p_notes TEXT,p_evidence_url TEXT,p_lines JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_document_id UUID;
    v_invoice_no TEXT;
    v_existing public.supplier_invoice_documents%ROWTYPE;
    v_invoice_line public.supplier_invoice_lines%ROWTYPE;
    v_line RECORD;
    v_product RECORD;
    v_tax RECORD;
    v_tax_group RECORD;
    v_tax_line RECORD;
    v_tax_result JSONB;
    v_allocation RECORD;
    v_source RECORD;
    v_line_id UUID;
    v_line_no INTEGER := 0;
    v_raw_amount NUMERIC(20,4);
    v_tax_base NUMERIC(20,4);
    v_tax_amount NUMERIC(20,4);
    v_line_total NUMERIC(20,4);
    v_net_unit NUMERIC(20,6);
    v_returned_base NUMERIC(24,6);
    v_validated_base NUMERIC(24,6);
    v_current_base NUMERIC(24,6);
    v_line_current_base NUMERIC(24,6);
    v_actual_base_cost NUMERIC(20,6);
    v_provisional_value NUMERIC(20,4);
    v_actual_value NUMERIC(20,4);
    v_matching_status TEXT;
    v_version BIGINT;
    v_before JSONB;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF NOT public.private_supplier_invoice_finance_allowed(v_company) THEN
        RAISE EXCEPTION 'SUPPLIER_INVOICE_FINANCE_ACCESS_DENIED';
    END IF;
    IF p_supplier_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.suppliers supplier
        WHERE supplier.company_id = v_company
          AND supplier.id = p_supplier_id AND supplier.is_active
    ) THEN RAISE EXCEPTION 'ACTIVE_SUPPLIER_NOT_FOUND'; END IF;
    IF btrim(COALESCE(p_supplier_invoice_no,'')) = '' THEN
        RAISE EXCEPTION 'SUPPLIER_INVOICE_NUMBER_REQUIRED';
    END IF;
    IF p_invoice_date IS NULL THEN RAISE EXCEPTION 'INVOICE_DATE_REQUIRED'; END IF;
    IF p_due_date IS NOT NULL AND p_due_date < p_invoice_date THEN
        RAISE EXCEPTION 'SUPPLIER_INVOICE_DUE_DATE_INVALID';
    END IF;
    IF upper(btrim(COALESCE(p_price_mode,'')))
       NOT IN ('INCLUSIVE','EXCLUSIVE') THEN
        RAISE EXCEPTION 'SUPPLIER_INVOICE_PRICE_MODE_INVALID';
    END IF;
    IF p_evidence_url IS NOT NULL
       AND p_evidence_url !~* '^https://' THEN
        RAISE EXCEPTION 'SUPPLIER_INVOICE_EVIDENCE_MUST_USE_HTTPS';
    END IF;
    IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'SUPPLIER_INVOICE_LINES_REQUIRED';
    END IF;

    IF p_document_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        v_document_id := gen_random_uuid();
        v_invoice_no := 'SINV-' || to_char(clock_timestamp(),'YYYYMMDD')
            || '-' || lpad(nextval(
                'private.supplier_invoice_no_seq'::regclass
            )::TEXT,6,'0');
        INSERT INTO public.supplier_invoice_documents(
            id,company_id,invoice_no,supplier_invoice_no,supplier_id,
            invoice_date,due_date,price_mode,notes,evidence_url,created_by
        ) VALUES (
            v_document_id,v_company,v_invoice_no,btrim(p_supplier_invoice_no),
            p_supplier_id,p_invoice_date,p_due_date,
            upper(btrim(p_price_mode)),NULLIF(btrim(p_notes),''),
            NULLIF(btrim(p_evidence_url),''),v_actor
        );
    ELSE
        SELECT * INTO v_existing
        FROM public.supplier_invoice_documents document
        WHERE document.company_id = v_company AND document.id = p_document_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_INVOICE_NOT_FOUND'; END IF;
        IF v_existing.status NOT IN ('DRAFT','HOLD') THEN
            RAISE EXCEPTION 'FINAL_SUPPLIER_INVOICE_IMMUTABLE';
        END IF;
        IF p_master_version IS DISTINCT FROM v_existing.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        v_document_id := v_existing.id;
        v_invoice_no := v_existing.invoice_no;
        v_before := to_jsonb(v_existing);
        DELETE FROM public.supplier_invoice_tolerance_results result
        WHERE result.company_id = v_company
          AND result.document_id = v_document_id;
        DELETE FROM public.supplier_invoice_allocations allocation
        WHERE allocation.company_id = v_company
          AND allocation.document_id = v_document_id;
        DELETE FROM public.supplier_invoice_lines line
        WHERE line.company_id = v_company
          AND line.document_id = v_document_id;
        UPDATE public.supplier_invoice_documents SET
            supplier_invoice_no = btrim(p_supplier_invoice_no),
            supplier_id = p_supplier_id,invoice_date = p_invoice_date,
            due_date = p_due_date,price_mode = upper(btrim(p_price_mode)),
            status = 'DRAFT',matching_status = 'UNMATCHED',
            notes = NULLIF(btrim(p_notes),''),
            evidence_url = NULLIF(btrim(p_evidence_url),''),
            master_version = master_version + 1,
            updated_at = clock_timestamp()
        WHERE company_id = v_company AND id = v_document_id;
    END IF;

    -- Pass 1: authoritative Product/UOM and Tax snapshots.
    FOR v_line IN
        SELECT * FROM jsonb_to_recordset(p_lines) AS payload(
            "clientLineKey" UUID,"productId" UUID,"invoiceUomId" UUID,
            "invoiceQty" NUMERIC,"unitPrice" NUMERIC,"taxRuleId" UUID,
            "allocations" JSONB
        )
    LOOP
        v_line_no := v_line_no + 1;
        IF v_line."clientLineKey" IS NULL THEN
            RAISE EXCEPTION 'SUPPLIER_INVOICE_CLIENT_LINE_KEY_REQUIRED';
        END IF;
        SELECT product.sku,product.name,product.uom_id AS base_uom_id,
               base_uom.name AS base_uom_name,
               product_uom.factor_to_base,uom.name AS invoice_uom_name,
               uom.allow_decimal,uom.decimal_precision
          INTO v_product
        FROM public.products product
        JOIN public.product_uoms product_uom
          ON product_uom.company_id = product.company_id
         AND product_uom.product_id = product.id
         AND product_uom.uom_id = v_line."invoiceUomId"
         AND product_uom.is_active
        JOIN public.uoms uom
          ON uom.company_id = product_uom.company_id
         AND uom.id = product_uom.uom_id AND uom.is_active
        JOIN public.uoms base_uom
          ON base_uom.company_id = product.company_id
         AND base_uom.id = product.uom_id AND base_uom.is_active
        WHERE product.company_id = v_company
          AND product.id = v_line."productId"
          AND product.is_active AND NOT product.is_bundle;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'ACTIVE_SUPPLIER_INVOICE_PRODUCT_UOM_NOT_FOUND';
        END IF;
        IF v_line."invoiceQty" IS NULL OR v_line."invoiceQty" <= 0
           OR v_line."unitPrice" IS NULL OR v_line."unitPrice" < 0 THEN
            RAISE EXCEPTION 'SUPPLIER_INVOICE_LINE_VALUE_INVALID';
        END IF;
        IF NOT v_product.allow_decimal
           AND v_line."invoiceQty" <> trunc(v_line."invoiceQty") THEN
            RAISE EXCEPTION 'SUPPLIER_INVOICE_UOM_REQUIRES_INTEGER';
        END IF;
        IF v_product.allow_decimal
           AND scale(v_line."invoiceQty") > v_product.decimal_precision THEN
            RAISE EXCEPTION 'SUPPLIER_INVOICE_UOM_PRECISION_EXCEEDED';
        END IF;
        v_raw_amount := round(
            v_line."invoiceQty"*v_line."unitPrice",4
        );
        SELECT NULL::UUID AS rule_id,NULL::TEXT AS tax_code,
               NULL::TEXT AS tax_name,NULL::UUID AS version_id,
               NULL::NUMERIC AS rate_percent,
               NULL::TEXT AS calculation_scope,
               NULL::UUID AS account_id,NULL::BOOLEAN AS is_recoverable
          INTO v_tax;
        IF v_line."taxRuleId" IS NOT NULL THEN
            SELECT rule.id AS rule_id,rule.tax_code,rule.tax_name,
                   version.id AS version_id,version.rate_percent,
                   version.calculation_scope,version.account_id,
                   version.is_recoverable
              INTO v_tax
            FROM public.tax_rules rule
            JOIN public.tax_rule_versions version
              ON version.company_id = rule.company_id
             AND version.tax_rule_id = rule.id
             AND version.status = 'ACTIVE'
             AND version.effective_from <= p_invoice_date::TIMESTAMPTZ
             AND (version.effective_to IS NULL
                  OR version.effective_to > p_invoice_date::TIMESTAMPTZ)
            WHERE rule.company_id = v_company
              AND rule.id = v_line."taxRuleId"
              AND rule.tax_scope = 'PURCHASE' AND rule.is_active
            ORDER BY version.effective_from DESC,version.rule_version DESC
            LIMIT 1;
            IF NOT FOUND OR v_tax.is_recoverable IS NULL THEN
                RAISE EXCEPTION 'ACTIVE_PURCHASE_TAX_RULE_NOT_FOUND';
            END IF;
            IF upper(btrim(p_price_mode)) = 'INCLUSIVE' THEN
                v_tax_base := round(
                    v_raw_amount/(1+v_tax.rate_percent/100),4
                );
                v_tax_amount := v_raw_amount-v_tax_base;
                v_line_total := v_raw_amount;
            ELSE
                v_tax_base := v_raw_amount;
                v_tax_amount := round(
                    v_tax_base*v_tax.rate_percent/100,4
                );
                v_line_total := v_tax_base+v_tax_amount;
            END IF;
        ELSE
            v_tax_base := v_raw_amount;
            v_tax_amount := 0;
            v_line_total := v_raw_amount;
        END IF;
        v_net_unit := round(v_tax_base/v_line."invoiceQty",6);
        INSERT INTO public.supplier_invoice_lines(
            company_id,document_id,line_no,client_line_key,product_id,
            invoice_uom_id,invoice_qty,factor_to_base_snapshot,
            invoice_base_qty,unit_price_input,price_mode_snapshot,
            net_unit_price,subtotal_before_tax,tax_rule_id,
            tax_rule_version_id,tax_code_snapshot,tax_name_snapshot,
            tax_rate_percent_snapshot,tax_calculation_scope_snapshot,
            tax_is_recoverable_snapshot,tax_account_id_snapshot,
            tax_amount,line_total,product_sku_snapshot,
            product_name_snapshot,invoice_uom_name_snapshot,
            base_uom_id,base_uom_name_snapshot
        ) VALUES (
            v_company,v_document_id,v_line_no,v_line."clientLineKey",
            v_line."productId",v_line."invoiceUomId",v_line."invoiceQty",
            v_product.factor_to_base,
            v_line."invoiceQty"*v_product.factor_to_base,
            v_line."unitPrice",upper(btrim(p_price_mode)),v_net_unit,
            v_tax_base,v_tax.rule_id,v_tax.version_id,v_tax.tax_code,
            v_tax.tax_name,COALESCE(v_tax.rate_percent,0),
            v_tax.calculation_scope,v_tax.is_recoverable,v_tax.account_id,
            v_tax_amount,v_line_total,v_product.sku,v_product.name,
            v_product.invoice_uom_name,v_product.base_uom_id,
            v_product.base_uom_name
        ) RETURNING id INTO v_line_id;
    END LOOP;

    -- Apply the canonical Tax calculator by rule group so PER_DOCUMENT
    -- residual rounding is allocated exactly once.
    FOR v_tax_group IN
        SELECT line.tax_rule_version_id,line.tax_rate_percent_snapshot,
               line.tax_calculation_scope_snapshot,
               jsonb_agg(jsonb_build_object(
                   'lineKey',line.client_line_key::TEXT,
                   'amount',round(line.invoice_qty*line.unit_price_input,4)
               ) ORDER BY line.line_no) AS tax_lines
        FROM public.supplier_invoice_lines line
        WHERE line.company_id = v_company
          AND line.document_id = v_document_id
          AND line.tax_rule_version_id IS NOT NULL
        GROUP BY line.tax_rule_version_id,line.tax_rate_percent_snapshot,
                 line.tax_calculation_scope_snapshot
    LOOP
        v_tax_result := private.calculate_tax_group(
            v_tax_group.tax_lines,v_tax_group.tax_rate_percent_snapshot,
            'PURCHASE',upper(btrim(p_price_mode)),
            v_tax_group.tax_calculation_scope_snapshot
        );
        FOR v_tax_line IN
            SELECT * FROM jsonb_to_recordset(v_tax_result->'lines') AS result(
                "lineKey" TEXT,"taxBase" NUMERIC,"taxAmount" NUMERIC,
                "grossAmount" NUMERIC
            )
        LOOP
            UPDATE public.supplier_invoice_lines SET
                subtotal_before_tax = v_tax_line."taxBase",
                tax_amount = v_tax_line."taxAmount",
                line_total = v_tax_line."grossAmount",
                net_unit_price = round(
                    v_tax_line."taxBase"/invoice_qty,6
                )
            WHERE company_id = v_company
              AND document_id = v_document_id
              AND client_line_key = v_tax_line."lineKey"::UUID;
        END LOOP;
    END LOOP;

    -- Pass 2: immutable-ID allocations to eligible Receipt/AP sources.
    FOR v_line IN
        SELECT * FROM jsonb_to_recordset(p_lines) AS payload(
            "clientLineKey" UUID,"productId" UUID,"invoiceUomId" UUID,
            "invoiceQty" NUMERIC,"unitPrice" NUMERIC,"taxRuleId" UUID,
            "allocations" JSONB
        )
    LOOP
        SELECT * INTO v_invoice_line
        FROM public.supplier_invoice_lines line
        WHERE line.company_id = v_company
          AND line.document_id = v_document_id
          AND line.client_line_key = v_line."clientLineKey";
        IF v_line."allocations" IS NULL THEN CONTINUE; END IF;
        IF jsonb_typeof(v_line."allocations") IS DISTINCT FROM 'array' THEN
            RAISE EXCEPTION 'SUPPLIER_INVOICE_ALLOCATIONS_ARRAY_REQUIRED';
        END IF;
        FOR v_allocation IN
            SELECT * FROM jsonb_to_recordset(v_line."allocations") AS item(
                "clientAllocationKey" UUID,"sourceApProvisionalId" UUID,
                "quantityBase" NUMERIC
            )
        LOOP
            IF v_allocation."clientAllocationKey" IS NULL THEN
                RAISE EXCEPTION
                    'SUPPLIER_INVOICE_CLIENT_ALLOCATION_KEY_REQUIRED';
            END IF;
            IF v_allocation."quantityBase" IS NULL
               OR v_allocation."quantityBase" <= 0 THEN
                RAISE EXCEPTION 'SUPPLIER_INVOICE_ALLOCATION_QUANTITY_INVALID';
            END IF;
            SELECT provisional.id,provisional.status,provisional.amount,
                   provisional.supplier_id,receipt_line.id AS receipt_line_id,
                   receipt_line.supplier_order_line_id,
                   receipt_line.product_id,
                   receipt_line.accepted_good_base_qty
                       + receipt_line.damaged_base_qty AS accepted_base_qty,
                   receipt_line.estimated_base_unit_cost
              INTO v_source
            FROM public.goods_receipt_ap_provisionals provisional
            JOIN public.goods_receipt_documents receipt
              ON receipt.company_id = provisional.company_id
             AND receipt.id = provisional.receipt_id
             AND receipt.status = 'POSTED'
            JOIN public.goods_receipt_lines receipt_line
              ON receipt_line.company_id = provisional.company_id
             AND receipt_line.id = provisional.receipt_line_id
             AND receipt_line.document_id = provisional.receipt_id
            WHERE provisional.company_id = v_company
              AND provisional.id = v_allocation."sourceApProvisionalId"
            FOR UPDATE OF provisional;
            IF NOT FOUND OR v_source.status <> 'OPEN' THEN
                RAISE EXCEPTION 'OPEN_AP_PROVISIONAL_NOT_FOUND';
            END IF;
            IF v_source.supplier_id <> p_supplier_id THEN
                RAISE EXCEPTION 'SUPPLIER_INVOICE_ALLOCATION_SUPPLIER_MISMATCH';
            END IF;
            IF v_source.product_id <> v_invoice_line.product_id THEN
                RAISE EXCEPTION 'SUPPLIER_INVOICE_ALLOCATION_PRODUCT_MISMATCH';
            END IF;
            SELECT COALESCE(sum(return_line.return_base_qty),0)
              INTO v_returned_base
            FROM public.purchase_return_lines return_line
            JOIN public.purchase_return_documents return_document
              ON return_document.company_id = return_line.company_id
             AND return_document.id = return_line.document_id
             AND return_document.status = 'POSTED'
            WHERE return_line.company_id = v_company
              AND return_line.source_receipt_line_id = v_source.receipt_line_id;
            SELECT COALESCE(sum(allocation.allocated_base_qty),0)
              INTO v_validated_base
            FROM public.supplier_invoice_allocations allocation
            JOIN public.supplier_invoice_documents document
              ON document.company_id = allocation.company_id
             AND document.id = allocation.document_id
             AND document.status = 'VALIDATED'
            WHERE allocation.company_id = v_company
              AND allocation.source_ap_provisional_id = v_source.id;
            SELECT COALESCE(sum(allocation.allocated_base_qty),0)
              INTO v_current_base
            FROM public.supplier_invoice_allocations allocation
            WHERE allocation.company_id = v_company
              AND allocation.document_id = v_document_id
              AND allocation.source_ap_provisional_id = v_source.id;
            IF v_validated_base+v_current_base
               +v_allocation."quantityBase"
               > v_source.accepted_base_qty-v_returned_base THEN
                RAISE EXCEPTION
                    'SUPPLIER_INVOICE_ALLOCATION_EXCEEDS_RECEIPT';
            END IF;
            SELECT COALESCE(sum(allocation.allocated_base_qty),0)
              INTO v_line_current_base
            FROM public.supplier_invoice_allocations allocation
            WHERE allocation.company_id = v_company
              AND allocation.invoice_line_id = v_invoice_line.id;
            IF v_line_current_base+v_allocation."quantityBase"
               > v_invoice_line.invoice_base_qty THEN
                RAISE EXCEPTION
                    'SUPPLIER_INVOICE_ALLOCATION_EXCEEDS_INVOICE_LINE';
            END IF;
            v_actual_base_cost := round(
                v_invoice_line.net_unit_price
                    /v_invoice_line.factor_to_base_snapshot,6
            );
            v_provisional_value := round(
                v_allocation."quantityBase"
                    *v_source.estimated_base_unit_cost,4
            );
            v_actual_value := round(
                v_allocation."quantityBase"*v_actual_base_cost,4
            );
            INSERT INTO public.supplier_invoice_allocations(
                company_id,document_id,invoice_line_id,
                client_allocation_key,source_ap_provisional_id,
                supplier_order_line_id,receipt_line_id,allocated_base_qty,
                provisional_unit_cost_snapshot,provisional_value,
                actual_unit_cost,actual_value,price_variance,created_by
            ) VALUES (
                v_company,v_document_id,v_invoice_line.id,
                v_allocation."clientAllocationKey",v_source.id,
                v_source.supplier_order_line_id,v_source.receipt_line_id,
                v_allocation."quantityBase",v_source.estimated_base_unit_cost,
                v_provisional_value,v_actual_base_cost,v_actual_value,
                v_actual_value-v_provisional_value,v_actor
            );
        END LOOP;
    END LOOP;

    -- Keep the allocated actual value equal to the canonical line tax base.
    -- Any 4-decimal split residual is assigned to the final allocation.
    FOR v_invoice_line IN
        SELECT * FROM public.supplier_invoice_lines line
        WHERE line.company_id = v_company
          AND line.document_id = v_document_id
    LOOP
        SELECT COALESCE(sum(allocation.allocated_base_qty),0),
               COALESCE(sum(allocation.actual_value),0)
          INTO v_line_current_base,v_actual_value
        FROM public.supplier_invoice_allocations allocation
        WHERE allocation.company_id = v_company
          AND allocation.invoice_line_id = v_invoice_line.id;
        IF v_line_current_base = v_invoice_line.invoice_base_qty
           AND v_actual_value <> v_invoice_line.subtotal_before_tax THEN
            UPDATE public.supplier_invoice_allocations allocation SET
                actual_value = allocation.actual_value
                    +(v_invoice_line.subtotal_before_tax-v_actual_value),
                price_variance = allocation.actual_value
                    +(v_invoice_line.subtotal_before_tax-v_actual_value)
                    -allocation.provisional_value
            WHERE allocation.id = (
                SELECT selected.id
                FROM public.supplier_invoice_allocations selected
                WHERE selected.company_id = v_company
                  AND selected.invoice_line_id = v_invoice_line.id
                ORDER BY selected.created_at DESC,selected.id DESC
                LIMIT 1
            );
        END IF;
    END LOOP;

    v_matching_status := private.refresh_supplier_invoice_totals(
        v_company,v_document_id
    );
    SELECT document.master_version INTO v_version
    FROM public.supplier_invoice_documents document
    WHERE document.company_id = v_company AND document.id = v_document_id;
    INSERT INTO public.supplier_invoice_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) SELECT v_company,v_document_id,
             CASE WHEN p_document_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
             v_actor,v_before,to_jsonb(document)
      FROM public.supplier_invoice_documents document
      WHERE document.company_id = v_company AND document.id = v_document_id;
    RETURN jsonb_build_object(
        'documentId',v_document_id,'invoiceNo',v_invoice_no,
        'status','DRAFT','matchingStatus',v_matching_status,
        'masterVersion',v_version
    );
END;
$$;

CREATE FUNCTION public.validate_supplier_invoice(
    p_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_document public.supplier_invoice_documents%ROWTYPE;
    v_source RECORD;
    v_line RECORD;
    v_relation RECORD;
    v_before JSONB;
    v_before_relation JSONB;
    v_after_relation JSONB;
    v_eligible_base NUMERIC(24,6);
    v_existing_base NUMERIC(24,6);
    v_current_base NUMERIC(24,6);
    v_return_value NUMERIC(20,4);
    v_existing_provisional_value NUMERIC(20,4);
    v_current_provisional_value NUMERIC(20,4);
    v_category UUID;
    v_ap_provisional_account UUID;
    v_ap_final_account UUID;
    v_variance_account UUID;
    v_input_tax_account UUID;
    v_recoverable_tax NUMERIC(20,4);
    v_nonrecoverable_tax NUMERIC(20,4);
    v_event UUID;
    v_version BIGINT;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
    IF NOT public.private_supplier_invoice_finance_allowed(v_company) THEN
        RAISE EXCEPTION 'SUPPLIER_INVOICE_FINANCE_ACCESS_DENIED';
    END IF;
    SELECT * INTO v_document
    FROM public.supplier_invoice_documents document
    WHERE document.company_id = v_company AND document.id = p_document_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_INVOICE_NOT_FOUND'; END IF;
    IF v_document.status = 'VALIDATED' THEN
        IF v_document.validation_idempotency_key = p_idempotency_key THEN
            RETURN jsonb_build_object(
                'documentId',v_document.id,'invoiceNo',v_document.invoice_no,
                'status','VALIDATED','matchingStatus',v_document.matching_status,
                'masterVersion',v_document.master_version,
                'financialEventId',v_document.financial_event_id,
                'idempotentReplay',TRUE
            );
        END IF;
        RAISE EXCEPTION 'SUPPLIER_INVOICE_ALREADY_VALIDATED';
    END IF;
    IF v_document.status NOT IN ('DRAFT','HOLD') THEN
        RAISE EXCEPTION 'SUPPLIER_INVOICE_NOT_VALIDATABLE';
    END IF;
    IF p_master_version IS DISTINCT FROM v_document.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_document.line_count <= 0 THEN
        RAISE EXCEPTION 'SUPPLIER_INVOICE_LINES_REQUIRED';
    END IF;
    IF v_document.matching_status NOT IN ('MATCHED','WITHIN_TOLERANCE') THEN
        v_before := to_jsonb(v_document);
        UPDATE public.supplier_invoice_documents SET
            status = 'HOLD',master_version = master_version+1,
            updated_at = v_now
        WHERE company_id = v_company AND id = v_document.id
        RETURNING master_version INTO v_version;
        INSERT INTO public.supplier_invoice_audit(
            company_id,document_id,action,actor_id,before_state,after_state
        ) SELECT v_company,v_document.id,'HOLD',v_actor,v_before,to_jsonb(document)
          FROM public.supplier_invoice_documents document
          WHERE document.company_id = v_company AND document.id = v_document.id;
        RETURN jsonb_build_object(
            'documentId',v_document.id,'invoiceNo',v_document.invoice_no,
            'status','HOLD','matchingStatus',v_document.matching_status,
            'masterVersion',v_version,'idempotentReplay',FALSE
        );
    END IF;

    -- Serialize each provisional before final allocation to prevent two
    -- Finance users from consuming the same Receipt residual.
    FOR v_source IN
        SELECT DISTINCT allocation.source_ap_provisional_id
        FROM public.supplier_invoice_allocations allocation
        WHERE allocation.company_id = v_company
          AND allocation.document_id = v_document.id
        ORDER BY allocation.source_ap_provisional_id
    LOOP
        PERFORM 1
        FROM public.goods_receipt_ap_provisionals provisional
        WHERE provisional.company_id = v_company
          AND provisional.id = v_source.source_ap_provisional_id
        FOR UPDATE;
        SELECT
            receipt_line.accepted_good_base_qty
                + receipt_line.damaged_base_qty
                - COALESCE((
                    SELECT sum(return_line.return_base_qty)
                    FROM public.purchase_return_lines return_line
                    JOIN public.purchase_return_documents return_document
                      ON return_document.company_id = return_line.company_id
                     AND return_document.id = return_line.document_id
                     AND return_document.status = 'POSTED'
                    WHERE return_line.company_id = provisional.company_id
                      AND return_line.source_receipt_line_id = receipt_line.id
                ),0),
            provisional.amount-COALESCE((
                SELECT sum(adjustment.amount)
                FROM public.purchase_return_ap_adjustments adjustment
                JOIN public.purchase_return_documents return_document
                  ON return_document.company_id = adjustment.company_id
                 AND return_document.id = adjustment.document_id
                 AND return_document.status = 'POSTED'
                WHERE adjustment.company_id = provisional.company_id
                  AND adjustment.source_ap_provisional_id = provisional.id
            ),0)
          INTO v_eligible_base,v_return_value
        FROM public.goods_receipt_ap_provisionals provisional
        JOIN public.goods_receipt_lines receipt_line
          ON receipt_line.company_id = provisional.company_id
         AND receipt_line.id = provisional.receipt_line_id
        WHERE provisional.company_id = v_company
          AND provisional.id = v_source.source_ap_provisional_id;
        SELECT COALESCE(sum(allocation.allocated_base_qty),0),
               COALESCE(sum(allocation.provisional_value),0)
          INTO v_existing_base,v_existing_provisional_value
        FROM public.supplier_invoice_allocations allocation
        JOIN public.supplier_invoice_documents document
          ON document.company_id = allocation.company_id
         AND document.id = allocation.document_id
         AND document.status = 'VALIDATED'
        WHERE allocation.company_id = v_company
          AND allocation.source_ap_provisional_id
              = v_source.source_ap_provisional_id;
        SELECT COALESCE(sum(allocation.allocated_base_qty),0),
               COALESCE(sum(allocation.provisional_value),0)
          INTO v_current_base,v_current_provisional_value
        FROM public.supplier_invoice_allocations allocation
        WHERE allocation.company_id = v_company
          AND allocation.document_id = v_document.id
          AND allocation.source_ap_provisional_id
              = v_source.source_ap_provisional_id;
        IF v_existing_base+v_current_base > v_eligible_base
           OR v_existing_provisional_value+v_current_provisional_value
              > v_return_value+0.01 THEN
            RAISE EXCEPTION
                'SUPPLIER_INVOICE_SOURCE_CHANGED_DURING_VALIDATION';
        END IF;
    END LOOP;

    SELECT category.id INTO v_category
    FROM public.transaction_categories category
    WHERE category.company_id = v_company
      AND category.system_key = 'SUPPLIER_INVOICE'
      AND category.is_active
    ORDER BY category.id LIMIT 1;
    IF v_category IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_INVOICE_TRANSACTION_CATEGORY_NOT_FOUND';
    END IF;
    v_ap_provisional_account := private.resolve_opening_stock_account(
        v_company,v_category,'SUPPLIER_AP_PROVISIONAL',v_now
    );
    v_ap_final_account := private.resolve_opening_stock_account(
        v_company,v_category,'SUPPLIER_AP_FINAL',v_now
    );
    v_variance_account := private.resolve_opening_stock_account(
        v_company,v_category,'PURCHASE_PRICE_VARIANCE',v_now
    );
    SELECT COALESCE(sum(line.tax_amount)
               FILTER(WHERE line.tax_is_recoverable_snapshot),0),
           COALESCE(sum(line.tax_amount)
               FILTER(WHERE line.tax_is_recoverable_snapshot = FALSE),0)
      INTO v_recoverable_tax,v_nonrecoverable_tax
    FROM public.supplier_invoice_lines line
    WHERE line.company_id = v_company
      AND line.document_id = v_document.id;
    IF v_recoverable_tax > 0 THEN
        v_input_tax_account := private.resolve_opening_stock_account(
            v_company,v_category,'INPUT_TAX',v_now
        );
    END IF;
    v_before := to_jsonb(v_document);

    INSERT INTO public.financial_events(
        event_code,event_type,source_table,source_id,root_sales_id,event_date,
        event_version,idempotency_key,amounts,status,error_message,created_by,
        company_id,store_id,system_event_key,transaction_category_id
    ) VALUES (
        'SINV-' || replace(v_document.id::TEXT,'-',''),
        'SUPPLIER_INVOICE_VALIDATED'::public.event_type,
        'supplier_invoice_documents',v_document.id,NULL,v_now,1,
        'SUPPLIER_INVOICE|' || v_company::TEXT || '|'
            || p_idempotency_key::TEXT,
        jsonb_build_object(
            'supplierId',v_document.supplier_id,
            'supplierInvoiceNo',v_document.supplier_invoice_no,
            'apProvisionalDebit',v_document.provisional_value_allocated,
            'apFinalCredit',v_document.grand_total,
            'purchasePriceVariance',v_document.purchase_price_variance,
            'recoverableInputTaxDebit',v_recoverable_tax,
            'nonrecoverablePurchaseTax',v_nonrecoverable_tax,
            'apProvisionalAccountId',v_ap_provisional_account,
            'apFinalAccountId',v_ap_final_account,
            'purchasePriceVarianceAccountId',v_variance_account,
            'inputTaxAccountId',v_input_tax_account,
            'matchingStatus',v_document.matching_status,
            'financePostingState','HOLD_UNTIL_G6'
        ),'HOLD'::public.event_status,
        'CANONICAL_FINANCE_POSTING_NOT_ENABLED',v_actor,v_company,NULL,
        'SUPPLIER_INVOICE',v_category
    ) RETURNING id INTO v_event;

    UPDATE public.supplier_invoice_documents SET
        status = 'VALIDATED',validation_idempotency_key = p_idempotency_key,
        financial_event_id = v_event,validated_by = v_actor,
        validated_at = v_now,master_version = master_version+1,
        updated_at = v_now
    WHERE company_id = v_company AND id = v_document.id
    RETURNING master_version INTO v_version;

    -- The relation stores the latest validated invoice price in its configured
    -- purchase UOM. Historical Product and Invoice snapshots are untouched.
    FOR v_line IN
        SELECT DISTINCT ON (line.product_id)
               line.product_id,line.net_unit_price,
               line.factor_to_base_snapshot,line.line_no
        FROM public.supplier_invoice_lines line
        WHERE line.company_id = v_company
          AND line.document_id = v_document.id
        ORDER BY line.product_id,line.line_no DESC
    LOOP
        FOR v_relation IN
            SELECT relation.id,relation.master_version,
                   purchase_uom.factor_to_base
            FROM public.product_suppliers relation
            JOIN public.product_uoms purchase_uom
              ON purchase_uom.company_id = relation.company_id
             AND purchase_uom.product_id = relation.product_id
             AND purchase_uom.uom_id = relation.purchase_uom_id
            WHERE relation.company_id = v_company
              AND relation.product_id = v_line.product_id
              AND relation.supplier_id = v_document.supplier_id
              AND relation.is_active
            FOR UPDATE OF relation
        LOOP
            SELECT to_jsonb(relation) INTO v_before_relation
            FROM public.product_suppliers relation
            WHERE relation.company_id = v_company
              AND relation.id = v_relation.id;
            UPDATE public.product_suppliers SET
                last_purchase_price = round(
                    (v_line.net_unit_price/v_line.factor_to_base_snapshot)
                        *v_relation.factor_to_base,4
                ),
                last_price_updated_at = v_now,
                last_price_source_document_id = v_document.id,
                updated_by = v_actor
            WHERE company_id = v_company AND id = v_relation.id;
            SELECT to_jsonb(relation) INTO v_after_relation
            FROM public.product_suppliers relation
            WHERE relation.company_id = v_company
              AND relation.id = v_relation.id;
            INSERT INTO public.product_supplier_audit(
                company_id,product_supplier_id,action,actor_id,
                before_state,after_state
            ) VALUES (
                v_company,v_relation.id,'UPDATE',v_actor,
                v_before_relation,v_after_relation
            );
        END LOOP;
    END LOOP;

    UPDATE public.goods_receipt_ap_provisionals provisional SET
        status = CASE WHEN
            COALESCE((
                SELECT sum(allocation.allocated_base_qty)
                FROM public.supplier_invoice_allocations allocation
                JOIN public.supplier_invoice_documents document
                  ON document.company_id = allocation.company_id
                 AND document.id = allocation.document_id
                 AND document.status = 'VALIDATED'
                WHERE allocation.company_id = provisional.company_id
                  AND allocation.source_ap_provisional_id = provisional.id
            ),0)
            + COALESCE((
                SELECT sum(return_line.return_base_qty)
                FROM public.purchase_return_lines return_line
                JOIN public.purchase_return_documents return_document
                  ON return_document.company_id = return_line.company_id
                 AND return_document.id = return_line.document_id
                 AND return_document.status = 'POSTED'
                WHERE return_line.company_id = provisional.company_id
                  AND return_line.source_receipt_line_id
                      = provisional.receipt_line_id
            ),0) >= (
                SELECT receipt_line.accepted_good_base_qty
                    +receipt_line.damaged_base_qty
                FROM public.goods_receipt_lines receipt_line
                WHERE receipt_line.company_id = provisional.company_id
                  AND receipt_line.id = provisional.receipt_line_id
            )
            THEN 'MATCHED' ELSE 'OPEN' END
    WHERE provisional.company_id = v_company
      AND EXISTS (
          SELECT 1 FROM public.supplier_invoice_allocations allocation
          WHERE allocation.company_id = v_company
            AND allocation.document_id = v_document.id
            AND allocation.source_ap_provisional_id = provisional.id
      );

    INSERT INTO public.supplier_invoice_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) SELECT v_company,v_document.id,'VALIDATE',v_actor,v_before,to_jsonb(document)
      FROM public.supplier_invoice_documents document
      WHERE document.company_id = v_company AND document.id = v_document.id;
    RETURN jsonb_build_object(
        'documentId',v_document.id,'invoiceNo',v_document.invoice_no,
        'status','VALIDATED','matchingStatus',v_document.matching_status,
        'masterVersion',v_version,'financialEventId',v_event,
        'idempotentReplay',FALSE
    );
END;
$$;

-- Until Debit/Credit Note allocation is opened, a Return against a partially
-- invoiced Receipt line is blocked rather than misclassifying the whole value
-- as provisional AP or Supplier Credit. Uninvoiced and fully invoiced sources
-- retain the Phase-8 routes.
CREATE FUNCTION private.trg_g5_guard_partial_invoice_purchase_return()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM public.supplier_invoice_allocations allocation
        JOIN public.supplier_invoice_documents document
          ON document.company_id = allocation.company_id
         AND document.id = allocation.document_id
         AND document.status = 'VALIDATED'
        JOIN public.goods_receipt_ap_provisionals provisional
          ON provisional.company_id = allocation.company_id
         AND provisional.id = allocation.source_ap_provisional_id
         AND provisional.status = 'OPEN'
        WHERE allocation.company_id = NEW.company_id
          AND allocation.source_ap_provisional_id
              = NEW.source_ap_provisional_id
    ) THEN
        RAISE EXCEPTION
            'PURCHASE_RETURN_AFTER_PARTIAL_INVOICE_REQUIRES_FINANCE_SPLIT';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER g5_guard_partial_invoice_purchase_return
BEFORE INSERT ON public.purchase_return_ap_adjustments
FOR EACH ROW
EXECUTE FUNCTION private.trg_g5_guard_partial_invoice_purchase_return();

CREATE FUNCTION public.cancel_supplier_invoice(
    p_document_id UUID,p_master_version BIGINT,p_reason TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_document public.supplier_invoice_documents%ROWTYPE;
    v_before JSONB;
    v_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF NOT public.private_supplier_invoice_finance_allowed(v_company) THEN
        RAISE EXCEPTION 'SUPPLIER_INVOICE_FINANCE_ACCESS_DENIED';
    END IF;
    IF btrim(COALESCE(p_reason,'')) = '' THEN
        RAISE EXCEPTION 'SUPPLIER_INVOICE_CANCEL_REASON_REQUIRED';
    END IF;
    SELECT * INTO v_document
    FROM public.supplier_invoice_documents document
    WHERE document.company_id = v_company AND document.id = p_document_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_INVOICE_NOT_FOUND'; END IF;
    IF v_document.status NOT IN ('DRAFT','HOLD') THEN
        RAISE EXCEPTION 'FINAL_SUPPLIER_INVOICE_IMMUTABLE';
    END IF;
    IF p_master_version IS DISTINCT FROM v_document.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before := to_jsonb(v_document);
    UPDATE public.supplier_invoice_documents SET
        status = 'CANCELED',canceled_by = v_actor,
        canceled_at = clock_timestamp(),cancel_reason = btrim(p_reason),
        master_version = master_version+1,updated_at = clock_timestamp()
    WHERE company_id = v_company AND id = v_document.id
    RETURNING master_version INTO v_version;
    INSERT INTO public.supplier_invoice_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) SELECT v_company,v_document.id,'CANCEL',v_actor,v_before,to_jsonb(document)
      FROM public.supplier_invoice_documents document
      WHERE document.company_id = v_company AND document.id = v_document.id;
    RETURN jsonb_build_object(
        'documentId',v_document.id,'status','CANCELED',
        'masterVersion',v_version
    );
END;
$$;

ALTER TABLE public.supplier_invoice_tolerance_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_invoice_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_invoice_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_invoice_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_invoice_tolerance_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_invoice_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY supplier_invoice_tolerance_read ON public.supplier_invoice_tolerance_policies
FOR SELECT TO authenticated USING(
    public.private_request_company_matches(company_id)
    AND (public.private_is_super_admin(auth.uid())
         OR public.private_user_has_any_company_role(
             company_id,ARRAY[
                 'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'
             ]::TEXT[]
         ))
);
CREATE POLICY supplier_invoice_document_read ON public.supplier_invoice_documents
FOR SELECT TO authenticated USING(
    public.private_request_company_matches(company_id)
    AND (public.private_is_super_admin(auth.uid())
         OR public.private_user_has_any_company_role(
             company_id,ARRAY[
                 'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'
             ]::TEXT[]
         ))
);
CREATE POLICY supplier_invoice_line_read ON public.supplier_invoice_lines
FOR SELECT TO authenticated USING(
    EXISTS(
        SELECT 1 FROM public.supplier_invoice_documents document
        WHERE document.company_id = supplier_invoice_lines.company_id
          AND document.id = supplier_invoice_lines.document_id
    )
);
CREATE POLICY supplier_invoice_allocation_read ON public.supplier_invoice_allocations
FOR SELECT TO authenticated USING(
    EXISTS(
        SELECT 1 FROM public.supplier_invoice_documents document
        WHERE document.company_id = supplier_invoice_allocations.company_id
          AND document.id = supplier_invoice_allocations.document_id
    )
);
CREATE POLICY supplier_invoice_tolerance_result_read ON public.supplier_invoice_tolerance_results
FOR SELECT TO authenticated USING(
    EXISTS(
        SELECT 1 FROM public.supplier_invoice_documents document
        WHERE document.company_id = supplier_invoice_tolerance_results.company_id
          AND document.id = supplier_invoice_tolerance_results.document_id
    )
);
CREATE POLICY supplier_invoice_audit_read ON public.supplier_invoice_audit
FOR SELECT TO authenticated USING(
    EXISTS(
        SELECT 1 FROM public.supplier_invoice_documents document
        WHERE document.company_id = supplier_invoice_audit.company_id
          AND document.id = supplier_invoice_audit.document_id
    )
);

REVOKE ALL ON public.supplier_invoice_tolerance_policies,
    public.supplier_invoice_documents,public.supplier_invoice_lines,
    public.supplier_invoice_allocations,
    public.supplier_invoice_tolerance_results,public.supplier_invoice_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.supplier_invoice_tolerance_policies,
    public.supplier_invoice_documents,public.supplier_invoice_lines,
    public.supplier_invoice_allocations,
    public.supplier_invoice_tolerance_results,public.supplier_invoice_audit
TO authenticated;
GRANT ALL ON public.supplier_invoice_tolerance_policies,
    public.supplier_invoice_documents,public.supplier_invoice_lines,
    public.supplier_invoice_allocations,
    public.supplier_invoice_tolerance_results,public.supplier_invoice_audit
TO service_role;

REVOKE ALL ON FUNCTION public.private_supplier_invoice_finance_allowed(UUID),
    private.trg_g5_guard_ap_provisional_lifecycle(),
    private.trg_g5_supplier_invoice_document_guard(),
    private.trg_g5_supplier_invoice_child_guard(),
    private.trg_g5_guard_partial_invoice_purchase_return(),
    private.refresh_supplier_invoice_totals(UUID,UUID),
    public.save_supplier_invoice_tolerance_policy(
        UUID,BIGINT,UUID,NUMERIC,NUMERIC,NUMERIC,NUMERIC,DATE,BOOLEAN
    ),
    public.save_supplier_invoice_draft(
        UUID,BIGINT,UUID,TEXT,DATE,DATE,TEXT,TEXT,TEXT,JSONB
    ),
    public.validate_supplier_invoice(UUID,BIGINT,UUID),
    public.cancel_supplier_invoice(UUID,BIGINT,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    public.private_supplier_invoice_finance_allowed(UUID),
    public.save_supplier_invoice_tolerance_policy(
        UUID,BIGINT,UUID,NUMERIC,NUMERIC,NUMERIC,NUMERIC,DATE,BOOLEAN
    ),
    public.save_supplier_invoice_draft(
        UUID,BIGINT,UUID,TEXT,DATE,DATE,TEXT,TEXT,TEXT,JSONB
    ),
    public.validate_supplier_invoice(UUID,BIGINT,UUID),
    public.cancel_supplier_invoice(UUID,BIGINT,TEXT)
TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION
    private.trg_g5_supplier_invoice_document_guard(),
    private.trg_g5_supplier_invoice_child_guard(),
    private.trg_g5_guard_partial_invoice_purchase_return(),
    private.trg_g5_guard_ap_provisional_lifecycle(),
    private.refresh_supplier_invoice_totals(UUID,UUID)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260806100000','g5_phase11_supplier_invoice_matching_foundation',
    'Guarded Supplier Invoice Draft/HOLD/VALIDATED lifecycle, exact many-to-many Receipt/AP allocation, tolerance and Purchase Tax snapshots, AP residual reconciliation, last purchase price, immutable audit, and G6 Finance HOLD'
);

COMMIT;
