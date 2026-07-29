-- KGS POS G4 phase 4: server-authoritative Sale Draft/Post runtime.
-- Requirements: POS-002, POS-003, STK-005, STK-006, FIN-001 boundary.
-- Dependency: Cashier Session foundation through 20260729040000.
--
-- This migration opens canonical online Sale Draft/Post only. Offline
-- allowance/queue, Return, Expense, Deposit, Ketul, and Purchase stay closed.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260729040000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 Cashier Session missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260729070000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260729070000';
    END IF;
END
$migration_guard$;

-- The approved preflight reported no Sale history. Historical Sale rows would
-- require explicit snapshot and source allocation backfill.
DO $empty_sale_surface_guard$
BEGIN
    IF EXISTS (SELECT 1 FROM public.sales_headers)
       OR EXISTS (SELECT 1 FROM public.sales_details)
       OR EXISTS (SELECT 1 FROM public.sales_payments) THEN
        RAISE EXCEPTION
            'G4_PHASE4_STATE_CHANGED: Sale history appeared; rerun preflight and design explicit backfill';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.product_stocks ps
        FULL JOIN (
            SELECT company_id,product_id,warehouse_id,sum(qty_change) AS qty
            FROM public.stock_movements
            WHERE movement_status = 'POSTED'
            GROUP BY company_id,product_id,warehouse_id
        ) mt
          ON mt.company_id = ps.company_id
         AND mt.product_id = ps.product_id
         AND mt.warehouse_id = ps.warehouse_id
        FULL JOIN (
            SELECT company_id,product_id,warehouse_id,sum(qty_remaining) AS qty
            FROM public.product_batches
            GROUP BY company_id,product_id,warehouse_id
        ) bt
          ON bt.company_id = COALESCE(ps.company_id,mt.company_id)
         AND bt.product_id = COALESCE(ps.product_id,mt.product_id)
         AND bt.warehouse_id = COALESCE(ps.warehouse_id,mt.warehouse_id)
        WHERE ps.product_id IS NULL
           OR mt.product_id IS NULL
           OR ps.stock_qty IS DISTINCT FROM mt.qty
           OR (ps.stock_qty > 0 AND ps.stock_qty IS DISTINCT FROM COALESCE(bt.qty,0))
    ) THEN
        RAISE EXCEPTION
            'G4_PHASE4_STATE_CHANGED: Stock, Movement, and FIFO mismatch';
    END IF;
END
$empty_sale_surface_guard$;

ALTER TABLE public.sales_headers
    ADD COLUMN document_status TEXT NOT NULL DEFAULT 'DRAFT',
    ADD COLUMN client_transaction_id UUID NOT NULL DEFAULT gen_random_uuid(),
    ADD COLUMN posting_idempotency_key UUID,
    ADD COLUMN sales_warehouse_id UUID,
    ADD COLUMN posted_session_id UUID,
    ADD COLUMN draft_reason TEXT,
    ADD COLUMN blocker_snapshot JSONB,
    ADD COLUMN grand_total_before_rounding NUMERIC(20,4) NOT NULL DEFAULT 0,
    ADD COLUMN rounding_direction TEXT NOT NULL DEFAULT 'NONE',
    ADD COLUMN rounding_increment NUMERIC(20,4) NOT NULL DEFAULT 100,
    ADD COLUMN rounding_adjustment NUMERIC(20,4) NOT NULL DEFAULT 0,
    ADD COLUMN grand_total_after_rounding NUMERIC(20,4) NOT NULL DEFAULT 0,
    ADD COLUMN receipt_snapshot JSONB,
    ADD COLUMN master_version BIGINT NOT NULL DEFAULT 1,
    ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    ADD COLUMN posted_at TIMESTAMPTZ,
    ADD COLUMN posted_by UUID REFERENCES public.profiles(id),
    ADD CONSTRAINT sales_headers_document_status_check CHECK (
        document_status IN ('DRAFT','POSTED','CANCELED')
    ),
    ADD CONSTRAINT sales_headers_rounding_direction_check CHECK (
        rounding_direction IN ('NONE','DOWN','UP')
    ),
    ADD CONSTRAINT sales_headers_rounding_increment_positive CHECK (
        rounding_increment > 0
    ),
    ADD CONSTRAINT sales_headers_runtime_amounts_nonnegative CHECK (
        grand_total_before_rounding >= 0
        AND grand_total_after_rounding >= 0
    ),
    ADD CONSTRAINT sales_headers_master_version_positive CHECK (
        master_version > 0
    ),
    ADD CONSTRAINT sales_headers_posted_contract CHECK (
        document_status <> 'POSTED'
        OR (
            posting_idempotency_key IS NOT NULL
            AND sales_warehouse_id IS NOT NULL
            AND posted_session_id IS NOT NULL
            AND posted_at IS NOT NULL
            AND posted_by IS NOT NULL
            AND receipt_snapshot IS NOT NULL
            AND invoice_status = 'GENERATED'::public.invoice_status
        )
    ),
    ADD CONSTRAINT fk_sales_headers_company_sales_warehouse
        FOREIGN KEY(company_id,sales_warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_sales_headers_company_posted_session
        FOREIGN KEY(company_id,posted_session_id)
        REFERENCES public.cashier_sessions(company_id,id) ON DELETE RESTRICT;

CREATE UNIQUE INDEX uq_sales_headers_company_client_transaction
    ON public.sales_headers(company_id,client_transaction_id);
CREATE UNIQUE INDEX uq_sales_headers_company_posting_idempotency
    ON public.sales_headers(company_id,posting_idempotency_key)
    WHERE posting_idempotency_key IS NOT NULL;
CREATE INDEX idx_sales_headers_company_document_status_updated
    ON public.sales_headers(company_id,document_status,updated_at DESC);

ALTER TABLE public.sales_details
    ADD COLUMN client_line_key TEXT,
    ADD COLUMN product_uom_id UUID,
    ADD COLUMN sale_uom_id UUID,
    ADD COLUMN sale_uom_name_snapshot TEXT,
    ADD COLUMN uom_factor_to_base_snapshot NUMERIC(24,6),
    ADD COLUMN quantity_base NUMERIC(24,6),
    ADD COLUMN product_sku_snapshot TEXT,
    ADD COLUMN product_name_snapshot TEXT,
    ADD COLUMN allocated_document_rounding NUMERIC(20,4) NOT NULL DEFAULT 0,
    ADD COLUMN fifo_cost_total NUMERIC(20,4) NOT NULL DEFAULT 0,
    ADD CONSTRAINT sales_details_client_line_unique
        UNIQUE(company_id,sales_id,client_line_key),
    ADD CONSTRAINT sales_details_runtime_quantity_positive CHECK (
        client_line_key IS NULL
        OR (
            qty > 0
            AND quantity_base > 0
            AND uom_factor_to_base_snapshot > 0
        )
    ),
    ADD CONSTRAINT sales_details_runtime_snapshot_not_blank CHECK (
        client_line_key IS NULL
        OR (
            btrim(client_line_key) <> ''
            AND product_uom_id IS NOT NULL
            AND sale_uom_id IS NOT NULL
            AND btrim(sale_uom_name_snapshot) <> ''
            AND btrim(product_sku_snapshot) <> ''
            AND btrim(product_name_snapshot) <> ''
        )
    ),
    ADD CONSTRAINT sales_details_fifo_cost_nonnegative CHECK (
        fifo_cost_total >= 0
    ),
    ADD CONSTRAINT fk_sales_details_company_product_uom
        FOREIGN KEY(company_id,product_uom_id,product_id)
        REFERENCES public.product_uoms(company_id,id,product_id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT fk_sales_details_company_sale_uom
        FOREIGN KEY(company_id,sale_uom_id)
        REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT;

ALTER TABLE public.sales_payments
    ADD COLUMN tendered_amount NUMERIC(20,4),
    ADD COLUMN change_amount NUMERIC(20,4) NOT NULL DEFAULT 0,
    ADD COLUMN proof_url TEXT,
    ADD CONSTRAINT sales_payments_tender_contract CHECK (
        amount > 0
        AND change_amount >= 0
        AND (
            tendered_amount IS NULL
            OR tendered_amount >= amount
        )
    ),
    ADD CONSTRAINT sales_payments_proof_https_check CHECK (
        proof_url IS NULL OR proof_url ~* '^https://'
    );

CREATE TABLE public.sale_stock_requirements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    sales_id UUID NOT NULL,
    sales_detail_id UUID NOT NULL,
    commercial_product_id UUID NOT NULL,
    stock_product_id UUID NOT NULL,
    stock_uom_id UUID NOT NULL,
    stock_uom_name_snapshot TEXT NOT NULL,
    quantity_uom NUMERIC(24,6) NOT NULL,
    factor_to_base NUMERIC(24,6) NOT NULL,
    quantity_base NUMERIC(24,6) NOT NULL,
    bundle_component_line_no SMALLINT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT sale_stock_requirements_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT sale_stock_requirement_identity_unique
        UNIQUE(company_id,sales_detail_id,stock_product_id,stock_uom_id),
    CONSTRAINT sale_stock_requirement_quantity_positive CHECK (
        quantity_uom > 0 AND factor_to_base > 0 AND quantity_base > 0
    ),
    CONSTRAINT sale_stock_requirement_uom_not_blank CHECK (
        btrim(stock_uom_name_snapshot) <> ''
    ),
    CONSTRAINT fk_sale_stock_requirement_sale
        FOREIGN KEY(company_id,sales_id)
        REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sale_stock_requirement_detail
        FOREIGN KEY(company_id,sales_detail_id)
        REFERENCES public.sales_details(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sale_stock_requirement_commercial_product
        FOREIGN KEY(company_id,commercial_product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sale_stock_requirement_stock_product
        FOREIGN KEY(company_id,stock_product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sale_stock_requirement_uom
        FOREIGN KEY(company_id,stock_uom_id)
        REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_sale_stock_requirements_sale_product
    ON public.sale_stock_requirements(
        company_id,sales_id,stock_product_id,id
    );

CREATE TABLE public.bundle_sale_allocations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    sales_id UUID NOT NULL,
    sales_detail_id UUID NOT NULL,
    stock_requirement_id UUID NOT NULL,
    bundle_product_id UUID NOT NULL,
    component_product_id UUID NOT NULL,
    component_uom_id UUID NOT NULL,
    component_product_sku_snapshot TEXT NOT NULL,
    component_product_name_snapshot TEXT NOT NULL,
    component_uom_name_snapshot TEXT NOT NULL,
    component_qty_per_bundle NUMERIC(24,6) NOT NULL,
    bundle_quantity NUMERIC(24,6) NOT NULL,
    component_quantity_uom NUMERIC(24,6) NOT NULL,
    component_quantity_base NUMERIC(24,6) NOT NULL,
    standalone_unit_price_snapshot NUMERIC(20,4) NOT NULL,
    allocation_weight NUMERIC(24,6) NOT NULL,
    allocated_gross NUMERIC(20,4) NOT NULL DEFAULT 0,
    allocated_discount NUMERIC(20,4) NOT NULL DEFAULT 0,
    allocated_tax NUMERIC(20,4) NOT NULL DEFAULT 0,
    allocated_rounding NUMERIC(20,4) NOT NULL DEFAULT 0,
    allocated_net NUMERIC(20,4) NOT NULL DEFAULT 0,
    fifo_cost_total NUMERIC(20,4) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT bundle_sale_allocations_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT bundle_sale_allocation_requirement_unique
        UNIQUE(company_id,stock_requirement_id),
    CONSTRAINT bundle_sale_allocation_quantity_positive CHECK (
        component_qty_per_bundle > 0
        AND bundle_quantity > 0
        AND component_quantity_uom > 0
        AND component_quantity_base > 0
    ),
    CONSTRAINT bundle_sale_allocation_amounts_nonnegative CHECK (
        standalone_unit_price_snapshot >= 0
        AND allocation_weight >= 0
        AND allocated_gross >= 0
        AND allocated_discount >= 0
        AND allocated_tax >= 0
        AND allocated_net >= 0
        AND fifo_cost_total >= 0
    ),
    CONSTRAINT fk_bundle_sale_allocation_sale
        FOREIGN KEY(company_id,sales_id)
        REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_bundle_sale_allocation_detail
        FOREIGN KEY(company_id,sales_detail_id)
        REFERENCES public.sales_details(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_bundle_sale_allocation_requirement
        FOREIGN KEY(company_id,stock_requirement_id)
        REFERENCES public.sale_stock_requirements(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_bundle_sale_allocation_bundle
        FOREIGN KEY(company_id,bundle_product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_bundle_sale_allocation_component
        FOREIGN KEY(company_id,component_product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_bundle_sale_allocation_uom
        FOREIGN KEY(company_id,component_uom_id)
        REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.sale_fifo_allocations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    sales_id UUID NOT NULL,
    sales_detail_id UUID NOT NULL,
    stock_requirement_id UUID NOT NULL,
    bundle_sale_allocation_id UUID,
    stock_product_id UUID NOT NULL,
    product_batch_id UUID NOT NULL,
    quantity_base NUMERIC(24,6) NOT NULL,
    fifo_unit_cost NUMERIC(20,4) NOT NULL,
    fifo_cost_total NUMERIC(20,4) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT sale_fifo_allocation_batch_unique
        UNIQUE(company_id,stock_requirement_id,product_batch_id),
    CONSTRAINT sale_fifo_allocation_quantity_positive CHECK (
        quantity_base > 0
    ),
    CONSTRAINT sale_fifo_allocation_cost_nonnegative CHECK (
        fifo_unit_cost >= 0 AND fifo_cost_total >= 0
    ),
    CONSTRAINT fk_sale_fifo_allocation_sale
        FOREIGN KEY(company_id,sales_id)
        REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sale_fifo_allocation_detail
        FOREIGN KEY(company_id,sales_detail_id)
        REFERENCES public.sales_details(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sale_fifo_allocation_requirement
        FOREIGN KEY(company_id,stock_requirement_id)
        REFERENCES public.sale_stock_requirements(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_sale_fifo_allocation_bundle
        FOREIGN KEY(company_id,bundle_sale_allocation_id)
        REFERENCES public.bundle_sale_allocations(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_sale_fifo_allocation_product
        FOREIGN KEY(company_id,stock_product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sale_fifo_allocation_batch
        FOREIGN KEY(company_id,product_batch_id)
        REFERENCES public.product_batches(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_sale_fifo_allocations_sale_detail
    ON public.sale_fifo_allocations(company_id,sales_id,sales_detail_id);

CREATE TABLE public.sale_master_audit (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    sales_id UUID NOT NULL,
    action TEXT NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT sale_master_audit_action_check CHECK (
        action IN ('CREATE_DRAFT','UPDATE_DRAFT','STOCK_SHORTAGE','POST')
    ),
    CONSTRAINT fk_sale_master_audit_sale
        FOREIGN KEY(company_id,sales_id)
        REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_sale_master_audit_sale_created
    ON public.sale_master_audit(company_id,sales_id,created_at DESC);

CREATE SEQUENCE private.pos_invoice_number_seq AS BIGINT START WITH 1;
CREATE SEQUENCE private.pos_payment_number_seq AS BIGINT START WITH 1;
REVOKE ALL ON SEQUENCE private.pos_invoice_number_seq,
    private.pos_payment_number_seq
FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.pos_invoice_number_seq,
    private.pos_payment_number_seq
TO service_role;

-- Customer Pricelist wins when it has an eligible tier. Otherwise the
-- eligible Global Pricelist tier wins, then Product-UOM sale price.
CREATE FUNCTION private.resolve_pos_sale_price(
    p_company_id UUID,
    p_store_id UUID,
    p_customer_id UUID,
    p_product_uom_id UUID,
    p_quantity NUMERIC,
    p_resolved_at TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_product_id UUID;
    v_factor NUMERIC(24,6);
    v_base_price NUMERIC(20,4);
    v_product_name TEXT;
    v_uom_name TEXT;
    v_rule RECORD;
    v_resolved NUMERIC(20,4);
BEGIN
    IF p_company_id IS NULL OR p_store_id IS NULL
       OR p_product_uom_id IS NULL OR p_resolved_at IS NULL THEN
        RAISE EXCEPTION 'PRICE_RESOLVER_CONTEXT_REQUIRED';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'SALE_QUANTITY_INVALID';
    END IF;

    SELECT
        pu.product_id,pu.factor_to_base,pu.sale_price,p.name,u.name
    INTO
        v_product_id,v_factor,v_base_price,v_product_name,v_uom_name
    FROM public.product_uoms pu
    JOIN public.products p
      ON p.company_id = pu.company_id
     AND p.id = pu.product_id
     AND p.is_active
    JOIN public.uoms u
      ON u.company_id = pu.company_id
     AND u.id = pu.uom_id
     AND u.is_active
    WHERE pu.company_id = p_company_id
      AND pu.id = p_product_uom_id
      AND pu.is_active
      AND pu.sales_allowed
      AND pu.sale_price IS NOT NULL
      AND pu.sale_price >= 0;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_SALES_PRODUCT_UOM_NOT_FOUND';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.stores s
        WHERE s.company_id = p_company_id
          AND s.id = p_store_id
          AND s.status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND';
    END IF;
    IF p_customer_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.customers c
        WHERE c.company_id = p_company_id
          AND c.id = p_customer_id
          AND c.is_active
    ) THEN
        RAISE EXCEPTION 'ACTIVE_CUSTOMER_NOT_FOUND';
    END IF;

    SELECT
        ranked.pricelist_id,
        ranked.pricelist_rule_id,
        ranked.pricelist_name,
        ranked.pricing_method,
        ranked.fixed_unit_price,
        ranked.discount_amount_per_unit,
        ranked.discount_percent,
        ranked.rule_version
    INTO v_rule
    FROM (
        SELECT
            pl.id AS pricelist_id,
            pr.id AS pricelist_rule_id,
            pl.name AS pricelist_name,
            pr.pricing_method,
            pr.fixed_unit_price,
            pr.discount_amount_per_unit,
            pr.discount_percent,
            pr.rule_version,
            CASE WHEN pl.scope = 'CUSTOMER' THEN 1 ELSE 2 END AS source_rank,
            pl.priority,
            pr.min_qty
        FROM public.pricelists pl
        JOIN public.pricelist_rules pr
          ON pr.company_id = pl.company_id
         AND pr.pricelist_id = pl.id
         AND pr.product_id = v_product_id
         AND pr.product_uom_id = p_product_uom_id
         AND pr.is_active
         AND (pr.valid_from IS NULL OR pr.valid_from <= p_resolved_at)
         AND (pr.valid_until IS NULL OR pr.valid_until >= p_resolved_at)
         AND pr.min_qty <= CASE
             WHEN pr.tier_qty_basis = 'BASE_UOM_EQUIVALENT'
                 THEN p_quantity * v_factor
             ELSE p_quantity
         END
        LEFT JOIN public.customers c
          ON c.company_id = pl.company_id
         AND c.id = p_customer_id
        WHERE pl.company_id = p_company_id
          AND pl.is_active
          AND (pl.valid_from IS NULL OR pl.valid_from <= p_resolved_at)
          AND (pl.valid_until IS NULL OR pl.valid_until >= p_resolved_at)
          AND (
              (pl.scope = 'CUSTOMER'
               AND c.default_pricelist_id = pl.id)
              OR (pl.scope = 'GLOBAL' AND pl.is_default)
          )
          AND (
              pl.applies_all_stores
              OR EXISTS (
                  SELECT 1
                  FROM public.pricelist_store_assignments psa
                  WHERE psa.company_id = pl.company_id
                    AND psa.pricelist_id = pl.id
                    AND psa.store_id = p_store_id
              )
          )
        ORDER BY
            source_rank,
            priority DESC,
            min_qty DESC,
            pr.id
        LIMIT 1
    ) ranked;

    IF v_rule.pricelist_rule_id IS NULL THEN
        v_resolved := v_base_price;
    ELSIF v_rule.pricing_method = 'FIXED_PRICE' THEN
        v_resolved := v_rule.fixed_unit_price;
    ELSIF v_rule.pricing_method = 'DISCOUNT_AMOUNT' THEN
        v_resolved := greatest(
            v_base_price - v_rule.discount_amount_per_unit,0
        );
    ELSE
        v_resolved := round(
            v_base_price * (100 - v_rule.discount_percent) / 100,4
        );
    END IF;

    RETURN jsonb_build_object(
        'productId',v_product_id,
        'productName',v_product_name,
        'productUomId',p_product_uom_id,
        'uomName',v_uom_name,
        'factorToBase',v_factor,
        'baseUnitPrice',v_base_price,
        'resolvedUnitPrice',v_resolved,
        'pricelistId',v_rule.pricelist_id,
        'pricelistRuleId',v_rule.pricelist_rule_id,
        'pricelistName',v_rule.pricelist_name,
        'ruleVersion',v_rule.rule_version,
        'resolvedAt',p_resolved_at
    );
END;
$$;

-- Internal deterministic repricing. Draft rows and requirements are snapshots
-- only; this routine never writes stock, FIFO, Payment, or Finance.
CREATE FUNCTION private.reprice_pos_sale_draft(
    p_company_id UUID,
    p_sales_id UUID,
    p_actor_id UUID,
    p_payload JSONB,
    p_resolved_at TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_sale public.sales_headers%ROWTYPE;
    v_lines JSONB := p_payload->'lines';
    v_line JSONB;
    v_line_key TEXT;
    v_product_uom_id UUID;
    v_quantity NUMERIC(24,6);
    v_discount_type TEXT;
    v_discount_input NUMERIC(20,6);
    v_price JSONB;
    v_tax JSONB;
    v_detail_id UUID;
    v_product_id UUID;
    v_product_sku TEXT;
    v_product_name TEXT;
    v_uom_id UUID;
    v_uom_name TEXT;
    v_factor NUMERIC(24,6);
    v_base_price NUMERIC(20,4);
    v_resolved_price NUMERIC(20,4);
    v_line_gross NUMERIC(20,4);
    v_line_discount NUMERIC(20,4);
    v_line_net NUMERIC(20,4);
    v_global_discount NUMERIC(20,4) :=
        COALESCE((p_payload->>'globalDiscount')::NUMERIC,0);
    v_pre_global_total NUMERIC(20,4);
    v_residual NUMERIC(20,4);
    v_rounding_direction TEXT :=
        upper(btrim(COALESCE(p_payload->>'roundingDirection','NONE')));
    v_rounding_increment NUMERIC(20,4) :=
        COALESCE((p_payload->>'roundingIncrement')::NUMERIC,100);
    v_before_rounding NUMERIC(20,4);
    v_after_rounding NUMERIC(20,4);
    v_tax_group RECORD;
    v_tax_input JSONB;
    v_tax_result JSONB;
    v_tax_line JSONB;
    v_bundle_component RECORD;
    v_subtotal NUMERIC(20,4);
    v_item_discount NUMERIC(20,4);
BEGIN
    SELECT * INTO v_sale
    FROM public.sales_headers sh
    WHERE sh.company_id = p_company_id
      AND sh.id = p_sales_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND'; END IF;
    IF v_sale.document_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'SALE_DRAFT_REQUIRED';
    END IF;
    IF jsonb_typeof(v_lines) IS DISTINCT FROM 'array'
       OR jsonb_array_length(v_lines) = 0
       OR jsonb_array_length(v_lines) > 200 THEN
        RAISE EXCEPTION 'SALE_LINES_ARRAY_REQUIRED';
    END IF;
    IF v_global_discount < 0 THEN
        RAISE EXCEPTION 'GLOBAL_DISCOUNT_INVALID';
    END IF;
    IF v_rounding_direction NOT IN ('NONE','DOWN','UP')
       OR v_rounding_increment <= 0 THEN
        RAISE EXCEPTION 'ROUNDING_CONTRACT_INVALID';
    END IF;

    DELETE FROM public.sale_stock_requirements
    WHERE company_id = p_company_id AND sales_id = p_sales_id;
    DELETE FROM public.sales_details
    WHERE company_id = p_company_id AND sales_id = p_sales_id;

    FOR v_line IN SELECT value FROM jsonb_array_elements(v_lines)
    LOOP
        BEGIN
            v_line_key := btrim(v_line->>'lineKey');
            v_product_uom_id := (v_line->>'productUomId')::UUID;
            v_quantity := (v_line->>'quantity')::NUMERIC;
            v_discount_type := upper(NULLIF(
                btrim(v_line->>'lineDiscountType'),''
            ));
            v_discount_input := COALESCE(
                (v_line->>'lineDiscountInput')::NUMERIC,0
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'INVALID_SALE_LINE';
        END;
        IF v_line_key IS NULL OR v_line_key = ''
           OR char_length(v_line_key) > 100 THEN
            RAISE EXCEPTION 'SALE_LINE_KEY_REQUIRED';
        END IF;
        IF v_quantity IS NULL OR v_quantity <= 0 THEN
            RAISE EXCEPTION 'SALE_QUANTITY_INVALID';
        END IF;
        IF v_discount_type IS NOT NULL
           AND v_discount_type NOT IN ('AMOUNT','PERCENT') THEN
            RAISE EXCEPTION 'LINE_DISCOUNT_TYPE_INVALID';
        END IF;
        IF v_discount_input < 0
           OR (v_discount_type = 'PERCENT' AND v_discount_input > 100) THEN
            RAISE EXCEPTION 'LINE_DISCOUNT_INVALID';
        END IF;

        v_price := private.resolve_pos_sale_price(
            p_company_id,v_sale.store_id,v_sale.customer_id,
            v_product_uom_id,v_quantity,p_resolved_at
        );
        v_product_id := (v_price->>'productId')::UUID;
        v_factor := (v_price->>'factorToBase')::NUMERIC;
        v_base_price := (v_price->>'baseUnitPrice')::NUMERIC;
        v_resolved_price := (v_price->>'resolvedUnitPrice')::NUMERIC;

        SELECT p.sku,p.name,pu.uom_id,u.name
        INTO v_product_sku,v_product_name,v_uom_id,v_uom_name
        FROM public.products p
        JOIN public.product_uoms pu
          ON pu.company_id = p.company_id
         AND pu.product_id = p.id
         AND pu.id = v_product_uom_id
        JOIN public.uoms u
          ON u.company_id = pu.company_id AND u.id = pu.uom_id
        WHERE p.company_id = p_company_id AND p.id = v_product_id;

        v_line_gross := round(v_resolved_price * v_quantity,4);
        v_line_discount := CASE v_discount_type
            WHEN 'AMOUNT' THEN round(v_discount_input,4)
            WHEN 'PERCENT' THEN round(
                v_line_gross * v_discount_input / 100,4
            )
            ELSE 0
        END;
        IF v_line_discount > v_line_gross THEN
            RAISE EXCEPTION 'LINE_DISCOUNT_EXCEEDS_LINE_TOTAL';
        END IF;
        v_line_net := v_line_gross - v_line_discount;
        v_detail_id := gen_random_uuid();
        v_tax := private.resolve_product_tax_rule(
            p_company_id,v_product_id,'SALES',p_resolved_at
        );

        INSERT INTO public.sales_details(
            id,sales_id,product_id,warehouse_id,qty,price,discount_amount,
            subtotal,cogs_unit,cogs_total,company_id,
            base_unit_price,pricelist_id,pricelist_rule_id,
            resolved_unit_price,line_discount_type,line_discount_input,
            line_discount_amount,allocated_order_discount_amount,
            unit_price_after_discount,line_total,pricing_resolved_at,
            tax_rule_id,tax_rule_version,tax_code_snapshot,tax_name_snapshot,
            tax_scope_snapshot,tax_rate_percent_snapshot,
            tax_price_mode_snapshot,tax_calculation_scope_snapshot,
            tax_base,tax_amount,tax_rounding,tax_account_id,
            tax_account_code_snapshot,tax_account_name_snapshot,
            client_line_key,product_uom_id,sale_uom_id,
            sale_uom_name_snapshot,uom_factor_to_base_snapshot,quantity_base,
            product_sku_snapshot,product_name_snapshot,
            allocated_document_rounding,fifo_cost_total
        ) VALUES (
            v_detail_id,p_sales_id,v_product_id,v_sale.sales_warehouse_id,
            v_quantity,v_resolved_price,v_line_discount,v_line_net,0,0,
            p_company_id,v_base_price,
            NULLIF(v_price->>'pricelistId','')::UUID,
            NULLIF(v_price->>'pricelistRuleId','')::UUID,
            v_resolved_price,v_discount_type,
            CASE WHEN v_discount_type IS NULL THEN NULL
                 ELSE v_discount_input END,
            v_line_discount,0,
            CASE WHEN v_quantity > 0
                 THEN round(v_line_net / v_quantity,4) ELSE 0 END,
            v_line_net,p_resolved_at,
            CASE WHEN COALESCE((v_tax->>'taxApplied')::BOOLEAN,FALSE)
                 THEN (v_tax->>'taxRuleId')::UUID ELSE NULL END,
            CASE WHEN COALESCE((v_tax->>'taxApplied')::BOOLEAN,FALSE)
                 THEN (v_tax->>'ruleVersion')::BIGINT ELSE NULL END,
            CASE WHEN COALESCE((v_tax->>'taxApplied')::BOOLEAN,FALSE)
                 THEN v_tax->>'taxCode' ELSE NULL END,
            CASE WHEN COALESCE((v_tax->>'taxApplied')::BOOLEAN,FALSE)
                 THEN v_tax->>'taxName' ELSE NULL END,
            CASE WHEN COALESCE((v_tax->>'taxApplied')::BOOLEAN,FALSE)
                 THEN 'SALES' ELSE NULL END,
            CASE WHEN COALESCE((v_tax->>'taxApplied')::BOOLEAN,FALSE)
                 THEN (v_tax->>'ratePercent')::NUMERIC ELSE NULL END,
            CASE WHEN COALESCE((v_tax->>'taxApplied')::BOOLEAN,FALSE)
                 THEN v_tax->>'priceMode' ELSE NULL END,
            CASE WHEN COALESCE((v_tax->>'taxApplied')::BOOLEAN,FALSE)
                 THEN v_tax->>'calculationScope' ELSE NULL END,
            NULL,0,0,
            CASE WHEN COALESCE((v_tax->>'taxApplied')::BOOLEAN,FALSE)
                 THEN (v_tax->>'taxAccountId')::UUID ELSE NULL END,
            CASE WHEN COALESCE((v_tax->>'taxApplied')::BOOLEAN,FALSE)
                 THEN v_tax->>'taxAccountCode' ELSE NULL END,
            CASE WHEN COALESCE((v_tax->>'taxApplied')::BOOLEAN,FALSE)
                 THEN v_tax->>'taxAccountName' ELSE NULL END,
            v_line_key,v_product_uom_id,v_uom_id,v_uom_name,
            v_factor,v_quantity * v_factor,v_product_sku,v_product_name,0,0
        );

        IF EXISTS (
            SELECT 1 FROM public.products p
            WHERE p.company_id = p_company_id
              AND p.id = v_product_id
              AND p.is_bundle
        ) THEN
            FOR v_bundle_component IN
                SELECT *
                FROM private.resolve_bundle_components(
                    p_company_id,v_product_id,v_quantity
                )
            LOOP
                INSERT INTO public.sale_stock_requirements(
                    company_id,sales_id,sales_detail_id,
                    commercial_product_id,stock_product_id,stock_uom_id,
                    stock_uom_name_snapshot,quantity_uom,factor_to_base,
                    quantity_base,bundle_component_line_no
                )
                SELECT
                    p_company_id,p_sales_id,v_detail_id,
                    v_product_id,v_bundle_component.component_product_id,
                    v_bundle_component.component_uom_id,u.name,
                    v_bundle_component.total_component_qty,
                    v_bundle_component.factor_to_base,
                    v_bundle_component.total_base_qty,
                    v_bundle_component.line_no
                FROM public.uoms u
                WHERE u.company_id = p_company_id
                  AND u.id = v_bundle_component.component_uom_id;
            END LOOP;
        ELSE
            INSERT INTO public.sale_stock_requirements(
                company_id,sales_id,sales_detail_id,
                commercial_product_id,stock_product_id,stock_uom_id,
                stock_uom_name_snapshot,quantity_uom,factor_to_base,
                quantity_base
            ) VALUES (
                p_company_id,p_sales_id,v_detail_id,
                v_product_id,v_product_id,v_uom_id,v_uom_name,
                v_quantity,v_factor,v_quantity * v_factor
            );
        END IF;
    END LOOP;

    SELECT sum(line_total) INTO v_pre_global_total
    FROM public.sales_details
    WHERE company_id = p_company_id AND sales_id = p_sales_id;
    IF v_global_discount > v_pre_global_total THEN
        RAISE EXCEPTION 'GLOBAL_DISCOUNT_EXCEEDS_SALE_TOTAL';
    END IF;

    IF v_global_discount > 0 AND v_pre_global_total > 0 THEN
        UPDATE public.sales_details
        SET allocated_order_discount_amount = round(
                v_global_discount * line_total / v_pre_global_total,4
            )
        WHERE company_id = p_company_id AND sales_id = p_sales_id;

        SELECT v_global_discount
               - COALESCE(sum(allocated_order_discount_amount),0)
        INTO v_residual
        FROM public.sales_details
        WHERE company_id = p_company_id AND sales_id = p_sales_id;

        UPDATE public.sales_details
        SET allocated_order_discount_amount =
                allocated_order_discount_amount + v_residual
        WHERE id = (
            SELECT id FROM public.sales_details
            WHERE company_id = p_company_id AND sales_id = p_sales_id
            ORDER BY line_total DESC,id
            LIMIT 1
        );
    END IF;

    UPDATE public.sales_details
    SET
        line_total = line_total - allocated_order_discount_amount,
        subtotal = line_total - allocated_order_discount_amount,
        unit_price_after_discount = round(
            (line_total - allocated_order_discount_amount) / qty,4
        )
    WHERE company_id = p_company_id AND sales_id = p_sales_id;

    UPDATE public.sales_details
    SET tax_base = line_total,tax_amount = 0,tax_rounding = 0
    WHERE company_id = p_company_id
      AND sales_id = p_sales_id
      AND tax_rule_id IS NULL;

    FOR v_tax_group IN
        SELECT
            tax_rule_id,tax_rule_version,tax_rate_percent_snapshot,
            tax_price_mode_snapshot,tax_calculation_scope_snapshot
        FROM public.sales_details
        WHERE company_id = p_company_id
          AND sales_id = p_sales_id
          AND tax_rule_id IS NOT NULL
        GROUP BY
            tax_rule_id,tax_rule_version,tax_rate_percent_snapshot,
            tax_price_mode_snapshot,tax_calculation_scope_snapshot
    LOOP
        SELECT jsonb_agg(
            jsonb_build_object('lineKey',id::TEXT,'amount',line_total)
            ORDER BY id
        ) INTO v_tax_input
        FROM public.sales_details
        WHERE company_id = p_company_id
          AND sales_id = p_sales_id
          AND tax_rule_id = v_tax_group.tax_rule_id
          AND tax_rule_version = v_tax_group.tax_rule_version;

        v_tax_result := private.calculate_tax_group(
            v_tax_input,v_tax_group.tax_rate_percent_snapshot,
            'SALES',v_tax_group.tax_price_mode_snapshot,
            v_tax_group.tax_calculation_scope_snapshot
        );
        FOR v_tax_line IN
            SELECT value FROM jsonb_array_elements(v_tax_result->'lines')
        LOOP
            UPDATE public.sales_details
            SET tax_base = (v_tax_line->>'taxBase')::NUMERIC,
                tax_amount = (v_tax_line->>'taxAmount')::NUMERIC,
                tax_rounding = (v_tax_line->>'taxRounding')::NUMERIC
            WHERE id = (v_tax_line->>'lineKey')::UUID;
        END LOOP;
    END LOOP;

    SELECT
        COALESCE(sum(resolved_unit_price * qty),0),
        COALESCE(sum(line_discount_amount),0),
        COALESCE(sum(line_total),0)
    INTO v_subtotal,v_item_discount,v_before_rounding
    FROM public.sales_details
    WHERE company_id = p_company_id AND sales_id = p_sales_id;

    v_after_rounding := CASE v_rounding_direction
        WHEN 'DOWN' THEN floor(v_before_rounding / v_rounding_increment)
                         * v_rounding_increment
        WHEN 'UP' THEN ceil(v_before_rounding / v_rounding_increment)
                       * v_rounding_increment
        ELSE v_before_rounding
    END;
    v_after_rounding := round(v_after_rounding,4);

    IF v_before_rounding > 0
       AND v_after_rounding IS DISTINCT FROM v_before_rounding THEN
        UPDATE public.sales_details
        SET allocated_document_rounding = round(
            (v_after_rounding - v_before_rounding)
            * line_total / v_before_rounding,4
        )
        WHERE company_id = p_company_id AND sales_id = p_sales_id;
        SELECT (v_after_rounding - v_before_rounding)
               - COALESCE(sum(allocated_document_rounding),0)
        INTO v_residual
        FROM public.sales_details
        WHERE company_id = p_company_id AND sales_id = p_sales_id;
        UPDATE public.sales_details
        SET allocated_document_rounding =
                allocated_document_rounding + v_residual
        WHERE id = (
            SELECT id FROM public.sales_details
            WHERE company_id = p_company_id AND sales_id = p_sales_id
            ORDER BY line_total DESC,id
            LIMIT 1
        );
    END IF;

    UPDATE public.sales_headers
    SET
        subtotal = v_subtotal,
        item_discount = v_item_discount,
        global_discount = v_global_discount,
        grand_total = v_after_rounding,
        grand_total_before_rounding = v_before_rounding,
        rounding_direction = v_rounding_direction,
        rounding_increment = v_rounding_increment,
        rounding_adjustment = v_after_rounding - v_before_rounding,
        grand_total_after_rounding = v_after_rounding,
        payload_snapshot = p_payload || jsonb_build_object(
            'serverResolvedAt',p_resolved_at
        ),
        blocker_snapshot = NULL,
        draft_reason = NULL,
        updated_at = clock_timestamp()
    WHERE company_id = p_company_id AND id = p_sales_id;

    RETURN jsonb_build_object(
        'salesId',p_sales_id,
        'grandTotalBeforeRounding',v_before_rounding,
        'roundingAdjustment',v_after_rounding - v_before_rounding,
        'grandTotalAfterRounding',v_after_rounding,
        'resolvedAt',p_resolved_at
    );
END;
$$;

CREATE FUNCTION public.save_pos_sale_draft(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_session public.cashier_sessions%ROWTYPE;
    v_sale public.sales_headers%ROWTYPE;
    v_sale_id UUID;
    v_client_transaction_id UUID;
    v_customer_id UUID;
    v_existing_by_client UUID;
    v_before JSONB;
    v_result JSONB;
    v_new_version BIGINT;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'SALE_PAYLOAD_OBJECT_REQUIRED';
    END IF;
    BEGIN
        v_client_transaction_id :=
            (p_payload->>'clientTransactionId')::UUID;
        v_sale_id := NULLIF(p_payload->>'saleId','')::UUID;
        v_customer_id := NULLIF(p_payload->>'customerId','')::UUID;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'INVALID_SALE_IDENTITY';
    END;
    IF v_client_transaction_id IS NULL THEN
        RAISE EXCEPTION 'CLIENT_TRANSACTION_ID_REQUIRED';
    END IF;

    SELECT * INTO v_session
    FROM public.cashier_sessions cs
    WHERE cs.company_id = v_company
      AND cs.id = (p_payload->>'cashierSessionId')::UUID
      AND cs.cashier_id = v_actor
      AND cs.status = 'OPEN'::public.session_status
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;

    IF v_customer_id IS NULL THEN
        SELECT c.id INTO v_customer_id
        FROM public.customers c
        WHERE c.company_id = v_company
          AND c.is_active
          AND c.is_system_customer
          AND upper(btrim(c.code)) = 'WALK-IN';
    END IF;
    IF v_customer_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.customers c
        WHERE c.company_id = v_company
          AND c.id = v_customer_id
          AND c.is_active
    ) THEN
        RAISE EXCEPTION 'ACTIVE_CUSTOMER_REQUIRED';
    END IF;

    SELECT sh.id INTO v_existing_by_client
    FROM public.sales_headers sh
    WHERE sh.company_id = v_company
      AND sh.client_transaction_id = v_client_transaction_id;
    IF v_sale_id IS NULL THEN v_sale_id := v_existing_by_client; END IF;
    IF v_existing_by_client IS NOT NULL
       AND v_existing_by_client IS DISTINCT FROM v_sale_id THEN
        RAISE EXCEPTION 'CLIENT_TRANSACTION_ID_CONFLICT';
    END IF;

    IF v_sale_id IS NULL THEN
        v_sale_id := gen_random_uuid();
        INSERT INTO public.sales_headers(
            id,invoice_no,session_id,customer_id,transaction_date,
            is_tempo,due_date,sj_required,sj_status,so_confirm_status,
            invoice_status,subtotal,item_discount,global_discount,grand_total,
            paid_amount,sisa_piutang,payment_status,financial_status,
            recon_status,created_by,payload_snapshot,company_id,store_id,pos_id,
            document_status,client_transaction_id,sales_warehouse_id,
            grand_total_before_rounding,rounding_direction,rounding_increment,
            rounding_adjustment,grand_total_after_rounding,master_version,
            updated_at
        ) VALUES (
            v_sale_id,'DRAFT-' || replace(v_sale_id::TEXT,'-',''),
            v_session.id,v_customer_id,v_now,
            COALESCE((p_payload->>'isTempo')::BOOLEAN,FALSE),
            NULLIF(p_payload->>'dueDate','')::TIMESTAMPTZ,
            FALSE,'NONE'::public.sj_status,'DRAFT'::public.so_confirm_status,
            'DRAFT'::public.invoice_status,0,0,0,0,0,0,
            'DRAFT'::public.payment_status,'PENDING'::public.financial_status,
            'UNRECONCILED'::public.recon_status,v_actor,p_payload,
            v_company,v_session.store_id,v_session.pos_id,'DRAFT',
            v_client_transaction_id,v_session.sales_warehouse_id,
            0,'NONE',100,0,0,1,v_now
        );
        v_before := NULL;
        v_new_version := 1;
    ELSE
        SELECT * INTO v_sale
        FROM public.sales_headers sh
        WHERE sh.company_id = v_company AND sh.id = v_sale_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND'; END IF;
        IF v_sale.document_status <> 'DRAFT' THEN
            IF v_sale.client_transaction_id = v_client_transaction_id
               AND v_sale.document_status = 'POSTED' THEN
                RETURN jsonb_build_object(
                    'salesId',v_sale.id,'documentStatus','POSTED',
                    'masterVersion',v_sale.master_version,
                    'idempotentReplay',TRUE
                );
            END IF;
            RAISE EXCEPTION 'SALE_DRAFT_REQUIRED';
        END IF;
        IF (p_payload->>'masterVersion')::BIGINT
           IS DISTINCT FROM v_sale.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        IF v_sale.store_id IS DISTINCT FROM v_session.store_id THEN
            RAISE EXCEPTION 'DRAFT_STORE_IMMUTABLE';
        END IF;
        v_before := to_jsonb(v_sale);
        v_new_version := v_sale.master_version + 1;
        UPDATE public.sales_headers
        SET session_id = v_session.id,
            pos_id = v_session.pos_id,
            sales_warehouse_id = v_session.sales_warehouse_id,
            customer_id = v_customer_id,
            is_tempo = COALESCE((p_payload->>'isTempo')::BOOLEAN,FALSE),
            due_date = NULLIF(p_payload->>'dueDate','')::TIMESTAMPTZ,
            master_version = v_new_version,
            updated_at = v_now
        WHERE company_id = v_company AND id = v_sale_id;
    END IF;

    v_result := private.reprice_pos_sale_draft(
        v_company,v_sale_id,v_actor,p_payload,v_now
    );
    UPDATE public.sales_headers
    SET master_version = v_new_version
    WHERE company_id = v_company AND id = v_sale_id;

    INSERT INTO public.sale_master_audit(
        company_id,sales_id,action,actor_id,before_state,after_state
    )
    SELECT
        v_company,v_sale_id,
        CASE WHEN v_before IS NULL THEN 'CREATE_DRAFT' ELSE 'UPDATE_DRAFT' END,
        v_actor,v_before,
        jsonb_build_object(
            'documentStatus','DRAFT','masterVersion',v_new_version,
            'pricing',v_result
        );

    RETURN v_result || jsonb_build_object(
        'documentStatus','DRAFT',
        'masterVersion',v_new_version,
        'idempotentReplay',FALSE
    );
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'SALE_DRAFT_IDENTITY_CONFLICT';
END;
$$;

CREATE FUNCTION public.post_pos_sale(
    p_sales_id UUID,
    p_master_version BIGINT,
    p_posting_idempotency_key UUID
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
    v_now TIMESTAMPTZ := clock_timestamp();
    v_requirement RECORD;
    v_stock NUMERIC(24,6);
    v_fifo NUMERIC(24,6);
    v_shortages JSONB := '[]'::JSONB;
    v_remaining NUMERIC(24,6);
    v_take NUMERIC(24,6);
    v_batch RECORD;
    v_requirement_cost NUMERIC(20,4);
    v_bundle_allocation_id UUID;
    v_stock_after NUMERIC(24,6);
    v_price JSONB;
    v_category_id UUID;
    v_event_id UUID;
    v_invoice_no TEXT;
    v_payment JSONB;
    v_payment_method RECORD;
    v_payment_base NUMERIC(20,4);
    v_tendered NUMERIC(20,4);
    v_fee NUMERIC(20,4);
    v_surcharge NUMERIC(20,4);
    v_payment_base_total NUMERIC(20,4) := 0;
    v_payment_actual_total NUMERIC(20,4) := 0;
    v_surcharge_total NUMERIC(20,4) := 0;
    v_payment_count INTEGER := 0;
    v_is_tempo BOOLEAN;
    v_receipt JSONB;
    v_result JSONB;
    v_new_version BIGINT;
    v_legacy_method public.payment_method;
    v_alloc RECORD;
    v_weight_total NUMERIC;
    v_count BIGINT;
    v_residual NUMERIC;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_posting_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'POSTING_IDEMPOTENCY_KEY_REQUIRED';
    END IF;

    SELECT * INTO v_sale
    FROM public.sales_headers sh
    WHERE sh.company_id = v_company AND sh.id = p_sales_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND'; END IF;
    IF v_sale.document_status = 'POSTED' THEN
        IF v_sale.posting_idempotency_key = p_posting_idempotency_key THEN
            RETURN jsonb_build_object(
                'salesId',v_sale.id,'invoiceNo',v_sale.invoice_no,
                'documentStatus','POSTED',
                'masterVersion',v_sale.master_version,
                'idempotentReplay',TRUE
            );
        END IF;
        RAISE EXCEPTION 'SALE_ALREADY_POSTED';
    END IF;
    IF v_sale.document_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'SALE_DRAFT_REQUIRED';
    END IF;
    IF p_master_version IS DISTINCT FROM v_sale.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;

    SELECT * INTO v_session
    FROM public.cashier_sessions cs
    WHERE cs.company_id = v_company
      AND cs.id = v_sale.session_id
      AND cs.cashier_id = v_actor
      AND cs.status = 'OPEN'::public.session_status
      AND cs.store_id = v_sale.store_id
      AND cs.pos_id = v_sale.pos_id
      AND cs.sales_warehouse_id = v_sale.sales_warehouse_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;

    -- Draft price/tax snapshots are always refreshed at posting time.
    v_result := private.reprice_pos_sale_draft(
        v_company,v_sale.id,v_actor,v_sale.payload_snapshot,v_now
    );
    SELECT * INTO v_sale
    FROM public.sales_headers
    WHERE company_id = v_company AND id = p_sales_id;

    FOR v_requirement IN
        SELECT
            r.stock_product_id,
            sum(r.quantity_base) AS quantity_base,
            p.sku,p.name,u.id AS base_uom_id,u.name AS base_uom_name
        FROM public.sale_stock_requirements r
        JOIN public.products p
          ON p.company_id = r.company_id
         AND p.id = r.stock_product_id
         AND p.is_active
         AND NOT p.is_bundle
        JOIN public.uoms u
          ON u.company_id = p.company_id AND u.id = p.uom_id
        WHERE r.company_id = v_company AND r.sales_id = v_sale.id
        GROUP BY r.stock_product_id,p.sku,p.name,u.id,u.name
        ORDER BY r.stock_product_id
    LOOP
        SELECT ps.stock_qty INTO v_stock
        FROM public.product_stocks ps
        WHERE ps.company_id = v_company
          AND ps.product_id = v_requirement.stock_product_id
          AND ps.warehouse_id = v_sale.sales_warehouse_id
        FOR UPDATE;
        v_stock := COALESCE(v_stock,0);
        SELECT COALESCE(sum(pb.qty_remaining),0) INTO v_fifo
        FROM public.product_batches pb
        WHERE pb.company_id = v_company
          AND pb.product_id = v_requirement.stock_product_id
          AND pb.warehouse_id = v_sale.sales_warehouse_id
          AND pb.qty_remaining > 0;
        IF v_stock < v_requirement.quantity_base
           OR v_fifo < v_requirement.quantity_base THEN
            v_shortages := v_shortages || jsonb_build_array(
                jsonb_build_object(
                    'productId',v_requirement.stock_product_id,
                    'sku',v_requirement.sku,
                    'productName',v_requirement.name,
                    'baseUomName',v_requirement.base_uom_name,
                    'requestedBaseQty',v_requirement.quantity_base,
                    'availableBaseQty',least(v_stock,v_fifo),
                    'shortageBaseQty',greatest(
                        v_requirement.quantity_base - least(v_stock,v_fifo),0
                    )
                )
            );
        END IF;
    END LOOP;

    IF jsonb_array_length(v_shortages) > 0 THEN
        v_new_version := v_sale.master_version + 1;
        UPDATE public.sales_headers
        SET draft_reason = 'STOCK_SHORTAGE',
            blocker_snapshot = jsonb_build_object(
                'type','STOCK_SHORTAGE','items',v_shortages,'checkedAt',v_now
            ),
            master_version = v_new_version,
            updated_at = v_now
        WHERE company_id = v_company AND id = v_sale.id;
        INSERT INTO public.sale_master_audit(
            company_id,sales_id,action,actor_id,after_state
        ) VALUES (
            v_company,v_sale.id,'STOCK_SHORTAGE',v_actor,
            jsonb_build_object(
                'masterVersion',v_new_version,'shortages',v_shortages
            )
        );
        RETURN jsonb_build_object(
            'salesId',v_sale.id,'documentStatus','DRAFT',
            'draftReason','STOCK_SHORTAGE','shortages',v_shortages,
            'masterVersion',v_new_version,'idempotentReplay',FALSE
        );
    END IF;

    SELECT tc.id INTO v_category_id
    FROM public.transaction_categories tc
    WHERE tc.company_id = v_company
      AND tc.system_key = 'SALE_POSTED'
      AND tc.is_active;
    IF v_category_id IS NULL THEN
        RAISE EXCEPTION 'SALE_POSTED_TRANSACTION_CATEGORY_REQUIRED';
    END IF;

    DELETE FROM public.sale_fifo_allocations
    WHERE company_id = v_company AND sales_id = v_sale.id;
    DELETE FROM public.bundle_sale_allocations
    WHERE company_id = v_company AND sales_id = v_sale.id;

    FOR v_requirement IN
        SELECT
            r.*,commercial.is_bundle,stock.sku AS stock_sku,
            stock.name AS stock_name,stock.uom_id AS base_uom_id,
            base_uom.name AS base_uom_name,
            commercial_qty.qty AS commercial_quantity
        FROM public.sale_stock_requirements r
        JOIN public.products commercial
          ON commercial.company_id = r.company_id
         AND commercial.id = r.commercial_product_id
        JOIN public.products stock
          ON stock.company_id = r.company_id
         AND stock.id = r.stock_product_id
        JOIN public.uoms base_uom
          ON base_uom.company_id = stock.company_id
         AND base_uom.id = stock.uom_id
        JOIN public.sales_details commercial_qty
          ON commercial_qty.company_id = r.company_id
         AND commercial_qty.id = r.sales_detail_id
        WHERE r.company_id = v_company AND r.sales_id = v_sale.id
        ORDER BY r.stock_product_id,r.id
    LOOP
        v_bundle_allocation_id := NULL;
        v_requirement_cost := 0;
        IF v_requirement.is_bundle THEN
            SELECT CASE
                WHEN selected.sales_allowed
                     AND selected.sale_price IS NOT NULL
                THEN private.resolve_pos_sale_price(
                    v_company,v_sale.store_id,v_sale.customer_id,
                    selected.id,v_requirement.quantity_uom,v_now
                )
                ELSE jsonb_build_object(
                    'resolvedUnitPrice',
                    COALESCE(
                        selected.sale_price,
                        base.sale_price * selected.factor_to_base,
                        stock.price * selected.factor_to_base,
                        0
                    )
                )
            END
            INTO v_price
            FROM public.product_uoms selected
            JOIN public.products stock
              ON stock.company_id = selected.company_id
             AND stock.id = selected.product_id
            LEFT JOIN public.product_uoms base
              ON base.company_id = stock.company_id
             AND base.product_id = stock.id
             AND base.uom_id = stock.uom_id
             AND base.is_active
            WHERE selected.company_id = v_company
              AND selected.product_id = v_requirement.stock_product_id
              AND selected.uom_id = v_requirement.stock_uom_id
              AND selected.is_active;
            IF v_price IS NULL THEN
                RAISE EXCEPTION 'BUNDLE_COMPONENT_PRICE_REFERENCE_INVALID';
            END IF;
            v_bundle_allocation_id := gen_random_uuid();
            INSERT INTO public.bundle_sale_allocations(
                id,company_id,sales_id,sales_detail_id,stock_requirement_id,
                bundle_product_id,component_product_id,component_uom_id,
                component_product_sku_snapshot,
                component_product_name_snapshot,component_uom_name_snapshot,
                component_qty_per_bundle,bundle_quantity,
                component_quantity_uom,component_quantity_base,
                standalone_unit_price_snapshot,allocation_weight
            ) VALUES (
                v_bundle_allocation_id,v_company,v_sale.id,
                v_requirement.sales_detail_id,v_requirement.id,
                v_requirement.commercial_product_id,
                v_requirement.stock_product_id,v_requirement.stock_uom_id,
                v_requirement.stock_sku,v_requirement.stock_name,
                v_requirement.stock_uom_name_snapshot,
                v_requirement.quantity_uom / v_requirement.commercial_quantity,
                v_requirement.commercial_quantity,
                v_requirement.quantity_uom,v_requirement.quantity_base,
                (v_price->>'resolvedUnitPrice')::NUMERIC,
                (v_price->>'resolvedUnitPrice')::NUMERIC
                    * v_requirement.quantity_uom
            );
        END IF;

        v_remaining := v_requirement.quantity_base;
        FOR v_batch IN
            SELECT pb.*
            FROM public.product_batches pb
            WHERE pb.company_id = v_company
              AND pb.product_id = v_requirement.stock_product_id
              AND pb.warehouse_id = v_sale.sales_warehouse_id
              AND pb.qty_remaining > 0
            ORDER BY pb.created_at,pb.id
            FOR UPDATE
        LOOP
            EXIT WHEN v_remaining <= 0;
            v_take := least(v_remaining,v_batch.qty_remaining);
            UPDATE public.product_batches
            SET qty_remaining = qty_remaining - v_take
            WHERE id = v_batch.id;
            INSERT INTO public.sale_fifo_allocations(
                company_id,sales_id,sales_detail_id,stock_requirement_id,
                bundle_sale_allocation_id,stock_product_id,product_batch_id,
                quantity_base,fifo_unit_cost,fifo_cost_total
            ) VALUES (
                v_company,v_sale.id,v_requirement.sales_detail_id,
                v_requirement.id,v_bundle_allocation_id,
                v_requirement.stock_product_id,v_batch.id,
                v_take,v_batch.cogs_unit,round(v_take * v_batch.cogs_unit,4)
            );
            v_requirement_cost := v_requirement_cost
                + round(v_take * v_batch.cogs_unit,4);
            v_remaining := v_remaining - v_take;
        END LOOP;
        IF v_remaining > 0 THEN RAISE EXCEPTION 'FIFO_STOCK_CHANGED'; END IF;

        UPDATE public.product_stocks
        SET stock_qty = stock_qty - v_requirement.quantity_base,
            updated_at = clock_timestamp()
        WHERE company_id = v_company
          AND product_id = v_requirement.stock_product_id
          AND warehouse_id = v_sale.sales_warehouse_id
          AND stock_qty >= v_requirement.quantity_base
        RETURNING stock_qty INTO v_stock_after;
        IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_CHANGED_DURING_POST'; END IF;

        UPDATE public.sales_details
        SET fifo_cost_total = fifo_cost_total + v_requirement_cost,
            cogs_total = cogs_total + v_requirement_cost
        WHERE company_id = v_company AND id = v_requirement.sales_detail_id;
        IF v_bundle_allocation_id IS NOT NULL THEN
            UPDATE public.bundle_sale_allocations
            SET fifo_cost_total = v_requirement_cost
            WHERE id = v_bundle_allocation_id;
        END IF;
    END LOOP;

    -- Legacy source uniqueness permits one Movement per Product/Warehouse/Sale.
    -- Multiple commercial lines and Bundle requirements are therefore
    -- aggregated while FIFO allocations remain traceable per requirement.
    INSERT INTO public.stock_movements(
        product_id,warehouse_id,qty_change,movement_type,
        reference_table,reference_id,company_id,
        base_uom_id,base_uom_name_snapshot,balance_after_base_qty,
        actor_id,posted_at,movement_status,source_line_id,notes
    )
    SELECT
        grouped.stock_product_id,v_sale.sales_warehouse_id,
        -grouped.quantity_base,'SALE'::public.stock_movement_type,
        'sales_headers',v_sale.id,v_company,
        p.uom_id,u.name,ps.stock_qty,
        v_actor,v_now,'POSTED',grouped.source_line_id,
        'Aggregated canonical Sale stock deduction'
    FROM (
        SELECT
            r.stock_product_id,
            sum(r.quantity_base) AS quantity_base,
            min(r.id::TEXT)::UUID AS source_line_id
        FROM public.sale_stock_requirements r
        WHERE r.company_id = v_company AND r.sales_id = v_sale.id
        GROUP BY r.stock_product_id
    ) grouped
    JOIN public.products p
      ON p.company_id = v_company AND p.id = grouped.stock_product_id
    JOIN public.uoms u
      ON u.company_id = p.company_id AND u.id = p.uom_id
    JOIN public.product_stocks ps
      ON ps.company_id = v_company
     AND ps.product_id = grouped.stock_product_id
     AND ps.warehouse_id = v_sale.sales_warehouse_id;

    UPDATE public.sales_details
    SET cogs_unit = CASE WHEN qty > 0
        THEN round(cogs_total / qty,4) ELSE 0 END
    WHERE company_id = v_company AND sales_id = v_sale.id;

    -- Component analytics use deterministic standalone-price weights. Residual
    -- from four-decimal allocation is attached to the largest weight.
    FOR v_alloc IN
        SELECT sd.id,sd.resolved_unit_price * sd.qty AS gross,
               sd.line_discount_amount
                    + sd.allocated_order_discount_amount AS discount,
               sd.tax_amount,sd.allocated_document_rounding,
               sd.line_total + sd.allocated_document_rounding AS net
        FROM public.sales_details sd
        JOIN public.products p
          ON p.company_id = sd.company_id
         AND p.id = sd.product_id
         AND p.is_bundle
        WHERE sd.company_id = v_company AND sd.sales_id = v_sale.id
    LOOP
        SELECT sum(allocation_weight),count(*)
        INTO v_weight_total,v_count
        FROM public.bundle_sale_allocations
        WHERE company_id = v_company
          AND sales_detail_id = v_alloc.id;
        UPDATE public.bundle_sale_allocations
        SET
            allocated_gross = round(v_alloc.gross * CASE
                WHEN v_weight_total > 0
                    THEN allocation_weight / v_weight_total
                ELSE 1::NUMERIC / v_count END,4),
            allocated_discount = round(v_alloc.discount * CASE
                WHEN v_weight_total > 0
                    THEN allocation_weight / v_weight_total
                ELSE 1::NUMERIC / v_count END,4),
            allocated_tax = round(v_alloc.tax_amount * CASE
                WHEN v_weight_total > 0
                    THEN allocation_weight / v_weight_total
                ELSE 1::NUMERIC / v_count END,4),
            allocated_rounding = round(v_alloc.allocated_document_rounding
                * CASE WHEN v_weight_total > 0
                    THEN allocation_weight / v_weight_total
                ELSE 1::NUMERIC / v_count END,4),
            allocated_net = round(v_alloc.net * CASE
                WHEN v_weight_total > 0
                    THEN allocation_weight / v_weight_total
                ELSE 1::NUMERIC / v_count END,4)
        WHERE company_id = v_company AND sales_detail_id = v_alloc.id;

        SELECT v_alloc.gross - sum(allocated_gross)
        INTO v_residual FROM public.bundle_sale_allocations
        WHERE company_id = v_company AND sales_detail_id = v_alloc.id;
        UPDATE public.bundle_sale_allocations
        SET allocated_gross = allocated_gross + v_residual
        WHERE id = (
            SELECT id FROM public.bundle_sale_allocations
            WHERE company_id = v_company AND sales_detail_id = v_alloc.id
            ORDER BY allocation_weight DESC,id LIMIT 1
        );
        SELECT v_alloc.discount - sum(allocated_discount)
        INTO v_residual FROM public.bundle_sale_allocations
        WHERE company_id = v_company AND sales_detail_id = v_alloc.id;
        UPDATE public.bundle_sale_allocations
        SET allocated_discount = allocated_discount + v_residual
        WHERE id = (
            SELECT id FROM public.bundle_sale_allocations
            WHERE company_id = v_company AND sales_detail_id = v_alloc.id
            ORDER BY allocation_weight DESC,id LIMIT 1
        );
        SELECT v_alloc.tax_amount - sum(allocated_tax)
        INTO v_residual FROM public.bundle_sale_allocations
        WHERE company_id = v_company AND sales_detail_id = v_alloc.id;
        UPDATE public.bundle_sale_allocations
        SET allocated_tax = allocated_tax + v_residual
        WHERE id = (
            SELECT id FROM public.bundle_sale_allocations
            WHERE company_id = v_company AND sales_detail_id = v_alloc.id
            ORDER BY allocation_weight DESC,id LIMIT 1
        );
        SELECT v_alloc.allocated_document_rounding - sum(allocated_rounding)
        INTO v_residual FROM public.bundle_sale_allocations
        WHERE company_id = v_company AND sales_detail_id = v_alloc.id;
        UPDATE public.bundle_sale_allocations
        SET allocated_rounding = allocated_rounding + v_residual
        WHERE id = (
            SELECT id FROM public.bundle_sale_allocations
            WHERE company_id = v_company AND sales_detail_id = v_alloc.id
            ORDER BY allocation_weight DESC,id LIMIT 1
        );
        SELECT v_alloc.net - sum(allocated_net)
        INTO v_residual FROM public.bundle_sale_allocations
        WHERE company_id = v_company AND sales_detail_id = v_alloc.id;
        UPDATE public.bundle_sale_allocations
        SET allocated_net = allocated_net + v_residual
        WHERE id = (
            SELECT id FROM public.bundle_sale_allocations
            WHERE company_id = v_company AND sales_detail_id = v_alloc.id
            ORDER BY allocation_weight DESC,id LIMIT 1
        );
    END LOOP;

    v_is_tempo := v_sale.is_tempo;
    IF jsonb_typeof(v_sale.payload_snapshot->'payments') = 'array' THEN
        FOR v_payment IN
            SELECT value
            FROM jsonb_array_elements(v_sale.payload_snapshot->'payments')
        LOOP
            BEGIN
                v_payment_base := (v_payment->>'amount')::NUMERIC;
                v_tendered := COALESCE(
                    (v_payment->>'tenderedAmount')::NUMERIC,v_payment_base
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE EXCEPTION 'INVALID_PAYMENT_INTENT';
            END;
            IF v_payment_base <= 0 OR v_tendered < v_payment_base THEN
                RAISE EXCEPTION 'INVALID_PAYMENT_AMOUNT';
            END IF;
            SELECT pm.* INTO v_payment_method
            FROM public.payment_methods pm
            WHERE pm.company_id = v_company
              AND pm.id = (v_payment->>'paymentMethodId')::UUID
              AND pm.is_active
              AND pm.effective_from <= v_now
              AND (pm.effective_to IS NULL OR pm.effective_to >= v_now)
              AND (
                  pm.available_all_stores
                  OR EXISTS (
                      SELECT 1
                      FROM public.payment_method_store_assignments pmsa
                      WHERE pmsa.company_id = pm.company_id
                        AND pmsa.payment_method_id = pm.id
                        AND pmsa.store_id = v_sale.store_id
                  )
              );
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ELIGIBLE_PAYMENT_METHOD_REQUIRED';
            END IF;
            IF v_payment_method.method_type IN (
                'CUSTOMER_BALANCE','KETUL_OFFSET'
            ) THEN
                RAISE EXCEPTION 'DEFERRED_PAYMENT_METHOD_NOT_ENABLED';
            END IF;
            IF v_payment_method.method_type = 'TEMPO' THEN
                RAISE EXCEPTION 'TEMPO_IS_DOCUMENT_MODE_NOT_PAYMENT_LEG';
            END IF;
            IF v_payment_method.proof_mode = 'REQUIRED'
               AND NULLIF(btrim(v_payment->>'proofUrl'),'') IS NULL THEN
                RAISE EXCEPTION 'PAYMENT_PROOF_REQUIRED';
            END IF;
            IF NULLIF(btrim(v_payment->>'proofUrl'),'') IS NOT NULL
               AND btrim(v_payment->>'proofUrl') !~* '^https://' THEN
                RAISE EXCEPTION 'PAYMENT_PROOF_HTTPS_REQUIRED';
            END IF;

            v_fee := CASE
                WHEN NOT v_payment_method.fee_enabled THEN 0
                WHEN v_payment_method.fee_type = 'PERCENT'
                    THEN round(
                        v_payment_base * v_payment_method.fee_percent / 100,4
                    )
                WHEN v_payment_method.fee_type = 'FIXED'
                    THEN v_payment_method.fee_fixed_amount
                ELSE round(
                    v_payment_base * v_payment_method.fee_percent / 100
                    + v_payment_method.fee_fixed_amount,4
                )
            END;
            v_surcharge := CASE
                WHEN v_payment_method.fee_bearer = 'CUSTOMER' THEN v_fee
                ELSE 0
            END;
            v_payment_base_total := v_payment_base_total + v_payment_base;
            v_payment_actual_total :=
                v_payment_actual_total + v_payment_base + v_surcharge;
            v_surcharge_total := v_surcharge_total + v_surcharge;
            v_payment_count := v_payment_count + 1;

            v_legacy_method := CASE
                WHEN v_payment_method.method_type = 'CASH'
                    THEN 'Cash'::public.payment_method
                WHEN v_payment_method.method_type = 'TRANSFER'
                    THEN 'Transfer'::public.payment_method
                WHEN v_payment_method.method_type = 'CUSTOMER_BALANCE'
                    THEN 'Customer_Balance'::public.payment_method
                ELSE 'QRIS'::public.payment_method
            END;
            INSERT INTO public.sales_payments(
                payment_no,sales_id,payment_date,session_id,payment_method,
                amount,balance_before,balance_after,is_reversal,company_id,
                payment_method_id,payment_method_code_snapshot,
                payment_method_name_snapshot,payment_method_type_snapshot,
                settlement_route_snapshot,fee_bearer_snapshot,
                fee_type_snapshot,fee_percent_snapshot,
                fee_fixed_amount_snapshot,configured_fee_amount,
                customer_surcharge_amount,tendered_amount,change_amount,
                proof_url
            ) VALUES (
                'PAY-' || to_char(v_now,'YYYYMMDD') || '-'
                    || lpad(
                        nextval('private.pos_payment_number_seq')::TEXT,10,'0'
                    ),
                v_sale.id,v_now,v_session.id,v_legacy_method,
                v_payment_base + v_surcharge,0,0,FALSE,v_company,
                v_payment_method.id,v_payment_method.payment_method_code,
                v_payment_method.payment_method_name,
                v_payment_method.method_type,
                v_payment_method.settlement_route,
                v_payment_method.fee_bearer,v_payment_method.fee_type,
                v_payment_method.fee_percent,
                v_payment_method.fee_fixed_amount,v_fee,v_surcharge,
                v_tendered + v_surcharge,
                v_tendered - v_payment_base,
                NULLIF(btrim(v_payment->>'proofUrl'),'')
            );
        END LOOP;
    END IF;

    IF NOT v_is_tempo
       AND (
           v_payment_count = 0
           OR v_payment_base_total <> v_sale.grand_total_after_rounding
       ) THEN
        RAISE EXCEPTION 'PAYMENT_TOTAL_MISMATCH';
    END IF;
    IF v_is_tempo THEN
        IF v_sale.customer_id IS NULL
           OR EXISTS (
               SELECT 1 FROM public.customers c
               WHERE c.company_id = v_company
                 AND c.id = v_sale.customer_id
                 AND c.is_system_customer
           )
           OR v_sale.due_date IS NULL
           OR v_payment_base_total > v_sale.grand_total_after_rounding THEN
            RAISE EXCEPTION 'TEMPO_SALE_CONTRACT_INVALID';
        END IF;
    END IF;

    v_invoice_no := 'INV-' || to_char(v_now,'YYYYMMDD') || '-'
        || lpad(nextval('private.pos_invoice_number_seq')::TEXT,10,'0');
    v_receipt := jsonb_build_object(
        'invoiceNo',v_invoice_no,
        'saleId',v_sale.id,
        'companyId',v_company,
        'storeId',v_sale.store_id,
        'posTerminalId',v_sale.pos_id,
        'cashierSessionId',v_session.id,
        'customerId',v_sale.customer_id,
        'postedAt',v_now,
        'subtotal',v_sale.subtotal,
        'itemDiscount',v_sale.item_discount,
        'globalDiscount',v_sale.global_discount,
        'totalBeforeRounding',v_sale.grand_total_before_rounding,
        'roundingDirection',v_sale.rounding_direction,
        'roundingAdjustment',v_sale.rounding_adjustment,
        'grandTotal',v_sale.grand_total_after_rounding,
        'customerSurcharge',v_surcharge_total,
        'amountPaid',v_payment_actual_total,
        'lines',(
            SELECT jsonb_agg(jsonb_build_object(
                'lineKey',sd.client_line_key,
                'productId',sd.product_id,
                'sku',sd.product_sku_snapshot,
                'productName',sd.product_name_snapshot,
                'uomName',sd.sale_uom_name_snapshot,
                'quantity',sd.qty,
                'unitPrice',sd.resolved_unit_price,
                'discount',sd.line_discount_amount
                    + sd.allocated_order_discount_amount,
                'taxAmount',sd.tax_amount,
                'lineTotal',sd.line_total,
                'fifoCostTotal',sd.fifo_cost_total
            ) ORDER BY sd.id)
            FROM public.sales_details sd
            WHERE sd.company_id = v_company AND sd.sales_id = v_sale.id
        ),
        'payments',(
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'paymentMethodName',sp.payment_method_name_snapshot,
                'paymentMethodType',sp.payment_method_type_snapshot,
                'amount',sp.amount,
                'configuredFee',sp.configured_fee_amount,
                'customerSurcharge',sp.customer_surcharge_amount,
                'tenderedAmount',sp.tendered_amount,
                'changeAmount',sp.change_amount,
                'proofUrl',sp.proof_url
            ) ORDER BY sp.id),'[]'::JSONB)
            FROM public.sales_payments sp
            WHERE sp.company_id = v_company AND sp.sales_id = v_sale.id
        )
    );

    INSERT INTO public.financial_events(
        event_code,event_type,source_table,source_id,root_sales_id,
        event_date,event_version,idempotency_key,payment_method,amounts,
        status,error_message,created_by,company_id,store_id,
        system_event_key,transaction_category_id
    ) VALUES (
        'SALE-' || replace(v_sale.id::TEXT,'-',''),
        'SALE_POSTED'::public.event_type,'sales_headers',v_sale.id,v_sale.id,
        v_now,1,
        'SALE_POSTED|' || v_company::TEXT || '|'
            || p_posting_idempotency_key::TEXT,
        CASE WHEN v_payment_count = 0 THEN 'TEMPO'
             WHEN v_payment_count = 1 THEN (
            SELECT payment_method_name_snapshot
            FROM public.sales_payments
            WHERE company_id = v_company AND sales_id = v_sale.id
            LIMIT 1
        ) ELSE 'SPLIT' END,
        jsonb_build_object(
            'grossSales',v_sale.subtotal,
            'itemDiscount',v_sale.item_discount,
            'orderDiscount',v_sale.global_discount,
            'netSalesInclusiveTax',v_sale.grand_total_before_rounding,
            'roundingAdjustment',v_sale.rounding_adjustment,
            'grandTotal',v_sale.grand_total_after_rounding,
            'customerSurcharge',v_surcharge_total,
            'paymentTotal',v_payment_actual_total,
            'receivable',greatest(
                v_sale.grand_total_after_rounding - v_payment_base_total,0
            ),
            'taxAmount',(
                SELECT COALESCE(sum(tax_amount),0)
                FROM public.sales_details
                WHERE company_id = v_company AND sales_id = v_sale.id
            ),
            'fifoCostTotal',(
                SELECT COALESCE(sum(fifo_cost_total),0)
                FROM public.sales_details
                WHERE company_id = v_company AND sales_id = v_sale.id
            ),
            'financePostingState','HOLD_UNTIL_G6'
        ),
        'HOLD'::public.event_status,
        'CANONICAL_FINANCE_POSTING_NOT_ENABLED',
        v_actor,v_company,v_sale.store_id,'SALE_POSTED',v_category_id
    )
    RETURNING id INTO v_event_id;

    v_new_version := v_sale.master_version + 1;
    UPDATE public.sales_headers
    SET invoice_no = v_invoice_no,
        document_status = 'POSTED',
        posting_idempotency_key = p_posting_idempotency_key,
        posted_session_id = v_session.id,
        invoice_status = 'GENERATED'::public.invoice_status,
        so_confirm_status = 'CONFIRMED'::public.so_confirm_status,
        paid_amount = v_payment_actual_total,
        sisa_piutang = greatest(
            grand_total_after_rounding - v_payment_base_total,0
        ),
        payment_status = CASE
            WHEN v_payment_base_total = 0
                THEN 'UNPAID'::public.payment_status
            WHEN v_payment_base_total < grand_total_after_rounding
                THEN 'PARTIAL'::public.payment_status
            ELSE 'PAID'::public.payment_status
        END,
        financial_status = 'PENDING'::public.financial_status,
        receipt_snapshot = v_receipt,
        blocker_snapshot = NULL,
        draft_reason = NULL,
        master_version = v_new_version,
        updated_at = v_now,
        posted_at = v_now,
        posted_by = v_actor
    WHERE company_id = v_company AND id = v_sale.id;

    INSERT INTO public.sale_master_audit(
        company_id,sales_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_sale.id,'POST',v_actor,
        jsonb_build_object(
            'documentStatus','DRAFT','masterVersion',v_sale.master_version
        ),
        jsonb_build_object(
            'documentStatus','POSTED','masterVersion',v_new_version,
            'invoiceNo',v_invoice_no,'financialEventId',v_event_id,
            'postingIdempotencyKey',p_posting_idempotency_key
        )
    );

    RETURN jsonb_build_object(
        'salesId',v_sale.id,'invoiceNo',v_invoice_no,
        'documentStatus','POSTED','masterVersion',v_new_version,
        'financialEventId',v_event_id,
        'grandTotal',v_sale.grand_total_after_rounding,
        'customerSurcharge',v_surcharge_total,
        'amountPaid',v_payment_actual_total,
        'idempotentReplay',FALSE
    );
EXCEPTION
    WHEN unique_violation THEN
        IF EXISTS (
            SELECT 1 FROM public.sales_headers sh
            WHERE sh.company_id = v_company
              AND sh.id = p_sales_id
              AND sh.posting_idempotency_key = p_posting_idempotency_key
              AND sh.document_status = 'POSTED'
        ) THEN
            SELECT * INTO v_sale
            FROM public.sales_headers
            WHERE company_id = v_company AND id = p_sales_id;
            RETURN jsonb_build_object(
                'salesId',v_sale.id,'invoiceNo',v_sale.invoice_no,
                'documentStatus','POSTED',
                'masterVersion',v_sale.master_version,
                'idempotentReplay',TRUE
            );
        END IF;
        RAISE EXCEPTION 'SALE_POST_IDEMPOTENCY_CONFLICT';
END;
$$;

ALTER TABLE public.stock_movements
    ADD CONSTRAINT stock_movements_sale_snapshot_complete CHECK (
        movement_type IS DISTINCT FROM 'SALE'::public.stock_movement_type
        OR (
            reference_table = 'sales_headers'
            AND qty_change < 0
            AND base_uom_id IS NOT NULL
            AND base_uom_name_snapshot IS NOT NULL
            AND balance_after_base_qty IS NOT NULL
            AND actor_id IS NOT NULL
            AND posted_at IS NOT NULL
            AND movement_status = 'POSTED'
            AND source_line_id IS NOT NULL
        )
    );

CREATE FUNCTION public.private_sale_visible(p_sales_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.sales_headers sh
        WHERE sh.id = p_sales_id
          AND public.private_sales_document_visible(sh.id)
    );
$$;

ALTER TABLE public.sale_stock_requirements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bundle_sale_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_fifo_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_master_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Sale requirements readable by parent Sale"
ON public.sale_stock_requirements FOR SELECT TO authenticated
USING (public.private_sale_visible(sales_id));
CREATE POLICY "Bundle Sale allocations readable by parent Sale"
ON public.bundle_sale_allocations FOR SELECT TO authenticated
USING (public.private_sale_visible(sales_id));
CREATE POLICY "Sale FIFO allocations readable by parent Sale"
ON public.sale_fifo_allocations FOR SELECT TO authenticated
USING (public.private_sale_visible(sales_id));
CREATE POLICY "Sale audit readable by parent Sale"
ON public.sale_master_audit FOR SELECT TO authenticated
USING (public.private_sale_visible(sales_id));

REVOKE ALL ON public.sale_stock_requirements,
    public.bundle_sale_allocations,public.sale_fifo_allocations,
    public.sale_master_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.sale_stock_requirements,
    public.bundle_sale_allocations,public.sale_fifo_allocations,
    public.sale_master_audit
TO authenticated;
GRANT ALL ON public.sale_stock_requirements,
    public.bundle_sale_allocations,public.sale_fifo_allocations,
    public.sale_master_audit
TO service_role;

REVOKE ALL ON FUNCTION private.resolve_pos_sale_price(
    UUID,UUID,UUID,UUID,NUMERIC,TIMESTAMPTZ
) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.reprice_pos_sale_draft(
    UUID,UUID,UUID,JSONB,TIMESTAMPTZ
) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.save_pos_sale_draft(JSONB)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.post_pos_sale(UUID,BIGINT,UUID)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.private_sale_visible(UUID)
FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION private.resolve_pos_sale_price(
    UUID,UUID,UUID,UUID,NUMERIC,TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION private.reprice_pos_sale_draft(
    UUID,UUID,UUID,JSONB,TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION public.save_pos_sale_draft(JSONB)
TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.post_pos_sale(UUID,BIGINT,UUID)
TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.private_sale_visible(UUID)
TO authenticated,service_role;

-- Canonical browser mutation replaces the unsafe client-authoritative wrapper.
REVOKE ALL ON FUNCTION public.create_sales_transaction(
    TEXT,UUID,UUID,BOOLEAN,TIMESTAMPTZ,BOOLEAN,TEXT,
    NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,
    public.payment_status,UUID,JSONB,JSONB,JSONB
) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.private_create_sales_transaction_g1_legacy(
    TEXT,UUID,UUID,BOOLEAN,TIMESTAMPTZ,BOOLEAN,TEXT,
    NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,
    public.payment_status,UUID,JSONB,JSONB,JSONB
) FROM PUBLIC,anon,authenticated;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260729070000',
    'g4_phase4_atomic_sale_runtime',
    'POS-002/003 and STK-005/006 server-authoritative Draft/Post, price/tax/payment recomputation, shortage-safe Draft, atomic FIFO/Bundle stock posting, immutable snapshots, idempotency, Finance HOLD, and legacy checkout retirement'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
