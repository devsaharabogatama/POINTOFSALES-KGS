-- KGS POS G3 phase 1: canonical Opening Stock document and atomic posting.
-- Requirements: INV-001, MST-005
-- Dependency: G2 phase 46 through 20260728090000.
--
-- Posting creates, in one transaction:
-- - immutable OPENING_BALANCE stock movement;
-- - Product-Warehouse materialized balance;
-- - FIFO opening layer with source-line trace;
-- - HOLD financial event with resolved account snapshots;
-- - document/audit state.
--
-- Finance journals remain disabled. HOLD prevents the legacy queue worker from
-- consuming this canonical event before the G6 resolver/poster exists.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260728090000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G2 phase 46 is required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260728120000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260728120000';
    END IF;
    IF to_regclass('public.opening_stock_documents') IS NOT NULL
       OR to_regclass('public.opening_stock_lines') IS NOT NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Opening Stock schema already exists';
    END IF;
    IF (
        SELECT count(*)
        FROM public.account_functions
        WHERE function_key IN (
            'INVENTORY_ASSET','OPENING_BALANCE_CLEARING'
        )
          AND is_active
    ) <> 2 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Opening Stock account functions missing';
    END IF;
END
$migration_guard$;

ALTER TYPE public.stock_movement_type
    ADD VALUE IF NOT EXISTS 'OPENING_BALANCE';
ALTER TYPE public.event_type
    ADD VALUE IF NOT EXISTS 'STOCK_OPENING';
ALTER TYPE public.event_status
    ADD VALUE IF NOT EXISTS 'HOLD';

CREATE SEQUENCE private.opening_stock_document_no_seq;
REVOKE ALL ON SEQUENCE private.opening_stock_document_no_seq
FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.opening_stock_document_no_seq
TO service_role;

CREATE TABLE public.opening_stock_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    document_no TEXT NOT NULL,
    warehouse_id UUID NOT NULL,
    effective_date DATE NOT NULL,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    source_import_job_id UUID,
    notes TEXT,
    line_count INTEGER NOT NULL DEFAULT 0,
    total_quantity_base NUMERIC(24,6) NOT NULL DEFAULT 0,
    total_cost NUMERIC(24,4) NOT NULL DEFAULT 0,
    posting_idempotency_key UUID,
    financial_event_id UUID,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    updated_by UUID NOT NULL REFERENCES public.profiles(id),
    posted_by UUID REFERENCES public.profiles(id),
    posted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT opening_stock_documents_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT opening_stock_documents_company_number_unique
        UNIQUE(company_id,document_no),
    CONSTRAINT opening_stock_documents_company_posting_key_unique
        UNIQUE(company_id,posting_idempotency_key),
    CONSTRAINT opening_stock_documents_number_not_blank
        CHECK(btrim(document_no) <> ''),
    CONSTRAINT opening_stock_documents_status_check
        CHECK(status IN ('DRAFT','POSTED')),
    CONSTRAINT opening_stock_documents_totals_nonnegative CHECK(
        line_count >= 0
        AND total_quantity_base >= 0
        AND total_cost >= 0
    ),
    CONSTRAINT opening_stock_documents_version_positive
        CHECK(master_version > 0),
    CONSTRAINT opening_stock_documents_posting_state_check CHECK(
        (
            status = 'DRAFT'
            AND posting_idempotency_key IS NULL
            AND financial_event_id IS NULL
            AND posted_by IS NULL
            AND posted_at IS NULL
        )
        OR
        (
            status = 'POSTED'
            AND posting_idempotency_key IS NOT NULL
            AND financial_event_id IS NOT NULL
            AND posted_by IS NOT NULL
            AND posted_at IS NOT NULL
        )
    ),
    CONSTRAINT fk_opening_stock_documents_company_warehouse
        FOREIGN KEY(company_id,warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_opening_stock_documents_company_import_job
        FOREIGN KEY(company_id,source_import_job_id)
        REFERENCES public.master_import_jobs(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_opening_stock_documents_company_financial_event
        FOREIGN KEY(company_id,financial_event_id)
        REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_opening_stock_documents_company_status_date
    ON public.opening_stock_documents(
        company_id,status,effective_date DESC,created_at DESC
    );
CREATE INDEX idx_opening_stock_documents_company_warehouse
    ON public.opening_stock_documents(company_id,warehouse_id,effective_date);

CREATE TABLE public.opening_stock_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    line_no INTEGER NOT NULL,
    product_id UUID NOT NULL,
    base_uom_id UUID NOT NULL,
    quantity_base NUMERIC(24,6) NOT NULL,
    unit_cost_base NUMERIC(24,6) NOT NULL,
    total_cost NUMERIC(24,4) NOT NULL,
    product_sku_snapshot TEXT NOT NULL,
    product_name_snapshot TEXT NOT NULL,
    base_uom_code_snapshot TEXT NOT NULL,
    base_uom_name_snapshot TEXT NOT NULL,
    zero_cost_reason TEXT,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT opening_stock_lines_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT opening_stock_lines_document_line_unique
        UNIQUE(company_id,document_id,line_no),
    CONSTRAINT opening_stock_lines_document_product_unique
        UNIQUE(company_id,document_id,product_id),
    CONSTRAINT opening_stock_lines_line_positive CHECK(line_no > 0),
    CONSTRAINT opening_stock_lines_quantity_positive CHECK(quantity_base > 0),
    CONSTRAINT opening_stock_lines_cost_nonnegative CHECK(unit_cost_base >= 0),
    CONSTRAINT opening_stock_lines_total_check CHECK(
        total_cost = round(quantity_base * unit_cost_base,4)
    ),
    CONSTRAINT opening_stock_lines_zero_cost_reason_check CHECK(
        unit_cost_base > 0
        OR NULLIF(btrim(zero_cost_reason),'') IS NOT NULL
    ),
    CONSTRAINT opening_stock_lines_snapshot_not_blank CHECK(
        btrim(product_sku_snapshot) <> ''
        AND btrim(product_name_snapshot) <> ''
        AND btrim(base_uom_code_snapshot) <> ''
        AND btrim(base_uom_name_snapshot) <> ''
    ),
    CONSTRAINT fk_opening_stock_lines_company_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.opening_stock_documents(company_id,id)
        ON DELETE CASCADE,
    CONSTRAINT fk_opening_stock_lines_company_product
        FOREIGN KEY(company_id,product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_opening_stock_lines_company_base_uom
        FOREIGN KEY(company_id,base_uom_id)
        REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_opening_stock_lines_company_product
    ON public.opening_stock_lines(company_id,product_id);

ALTER TABLE public.product_batches
    ADD COLUMN opening_stock_line_id UUID,
    ADD CONSTRAINT fk_product_batches_company_opening_stock_line
        FOREIGN KEY(company_id,opening_stock_line_id)
        REFERENCES public.opening_stock_lines(company_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT product_batches_opening_stock_line_unique
        UNIQUE(opening_stock_line_id);

CREATE UNIQUE INDEX uq_stock_movements_source_product_warehouse_type
    ON public.stock_movements(
        company_id,reference_table,reference_id,
        product_id,warehouse_id,movement_type
    );

CREATE TABLE public.opening_stock_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    action TEXT NOT NULL CHECK(action IN ('CREATE','UPDATE','POST')),
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fk_opening_stock_audit_company_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.opening_stock_documents(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_opening_stock_audit_document_created
    ON public.opening_stock_audit(company_id,document_id,created_at DESC);

CREATE FUNCTION public.private_opening_stock_prepare_allowed(
    p_company_id UUID,
    p_warehouse_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT public.private_request_company_matches(p_company_id)
       AND (
           public.private_user_has_any_company_role(
               p_company_id,
               ARRAY[
                   'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER',
                   'FINANCE','ACCOUNTING'
               ]::TEXT[]
           )
           OR EXISTS (
               SELECT 1
               FROM public.warehouses w
               WHERE w.company_id = p_company_id
                 AND w.id = p_warehouse_id
                 AND w.store_id IS NOT NULL
                 AND public.private_user_has_any_store_role(
                     w.store_id,ARRAY['STORE_MANAGER']::TEXT[]
                 )
           )
       );
$$;

CREATE FUNCTION private.resolve_opening_stock_account(
    p_company_id UUID,
    p_transaction_category_id UUID,
    p_account_function_key TEXT,
    p_effective_at TIMESTAMPTZ
)
RETURNS UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_account_id UUID;
BEGIN
    SELECT r.account_id INTO v_account_id
    FROM public.transaction_account_rules r
    JOIN public.chart_of_accounts coa
      ON coa.company_id = r.company_id
     AND coa.id = r.account_id
     AND coa.is_active
     AND coa.is_postable
    WHERE r.company_id = p_company_id
      AND r.transaction_category_id = p_transaction_category_id
      AND r.account_function_key = p_account_function_key
      AND r.status = 'ACTIVE'
      AND r.effective_from <= p_effective_at
      AND (r.effective_to IS NULL OR r.effective_to > p_effective_at)
    ORDER BY r.effective_from DESC,r.rule_version DESC
    LIMIT 1;

    IF v_account_id IS NULL THEN
        SELECT f.account_id INTO v_account_id
        FROM public.company_account_function_fallbacks f
        JOIN public.chart_of_accounts coa
          ON coa.company_id = f.company_id
         AND coa.id = f.account_id
         AND coa.is_active
         AND coa.is_postable
        WHERE f.company_id = p_company_id
          AND f.account_function_key = p_account_function_key
          AND f.status = 'ACTIVE'
          AND f.effective_from <= p_effective_at
          AND (f.effective_to IS NULL OR f.effective_to > p_effective_at)
        ORDER BY f.effective_from DESC,f.fallback_version DESC
        LIMIT 1;
    END IF;

    IF v_account_id IS NULL THEN
        SELECT coa.id INTO v_account_id
        FROM public.chart_of_accounts coa
        WHERE coa.company_id = p_company_id
          AND coa.system_function_key = p_account_function_key
          AND coa.is_active
          AND coa.is_postable
        ORDER BY coa.id
        LIMIT 1;
    END IF;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'OPENING_STOCK_ACCOUNT_NOT_RESOLVED:%',
            p_account_function_key;
    END IF;

    RETURN v_account_id;
END;
$$;

CREATE FUNCTION public.save_opening_stock_document(
    p_document_id UUID,
    p_master_version BIGINT,
    p_warehouse_id UUID,
    p_effective_date DATE,
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
    v_document_id UUID;
    v_document_no TEXT;
    v_result_version BIGINT;
    v_existing public.opening_stock_documents%ROWTYPE;
    v_before JSONB;
    v_after JSONB;
    v_line RECORD;
    v_line_no INTEGER := 0;
    v_line_count INTEGER;
    v_total_quantity NUMERIC(24,6);
    v_total_cost NUMERIC(24,4);
    v_product RECORD;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_warehouse_id IS NULL THEN RAISE EXCEPTION 'WAREHOUSE_REQUIRED'; END IF;
    IF NOT public.private_opening_stock_prepare_allowed(
        v_company,p_warehouse_id
    ) THEN
        RAISE EXCEPTION 'OPENING_STOCK_PREPARER_REQUIRED';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.warehouses w
        WHERE w.company_id = v_company
          AND w.id = p_warehouse_id
          AND w.is_active
    ) THEN
        RAISE EXCEPTION 'ACTIVE_WAREHOUSE_NOT_FOUND';
    END IF;
    IF p_effective_date IS NULL THEN
        RAISE EXCEPTION 'EFFECTIVE_DATE_REQUIRED';
    END IF;
    IF p_effective_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'OPENING_STOCK_FUTURE_DATE_NOT_ALLOWED';
    END IF;
    IF p_lines IS NULL
       OR jsonb_typeof(p_lines) <> 'array'
       OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'OPENING_STOCK_LINES_REQUIRED';
    END IF;
    IF jsonb_array_length(p_lines) > 1000 THEN
        RAISE EXCEPTION 'OPENING_STOCK_LINE_LIMIT_EXCEEDED';
    END IF;

    IF p_document_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        v_document_no := 'OS-' || lpad(
            nextval('private.opening_stock_document_no_seq')::TEXT,10,'0'
        );
        INSERT INTO public.opening_stock_documents(
            company_id,document_no,warehouse_id,effective_date,notes,
            created_by,updated_by
        ) VALUES (
            v_company,v_document_no,p_warehouse_id,p_effective_date,
            NULLIF(btrim(p_notes),''),v_actor,v_actor
        )
        RETURNING id,master_version
        INTO v_document_id,v_result_version;
    ELSE
        SELECT * INTO v_existing
        FROM public.opening_stock_documents d
        WHERE d.company_id = v_company AND d.id = p_document_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'OPENING_STOCK_NOT_FOUND'; END IF;
        IF v_existing.status <> 'DRAFT' THEN
            RAISE EXCEPTION 'POSTED_OPENING_STOCK_IMMUTABLE';
        END IF;
        IF p_master_version IS NULL
           OR p_master_version <> v_existing.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        v_before := to_jsonb(v_existing);
        v_document_id := p_document_id;

        DELETE FROM public.opening_stock_lines
        WHERE company_id = v_company AND document_id = v_document_id;
    END IF;

    FOR v_line IN
        SELECT *
        FROM jsonb_to_recordset(p_lines) AS x(
            "productId" UUID,
            "quantityBase" NUMERIC,
            "unitCostBase" NUMERIC,
            "zeroCostReason" TEXT,
            "notes" TEXT
        )
    LOOP
        v_line_no := v_line_no + 1;
        IF v_line."productId" IS NULL THEN
            RAISE EXCEPTION 'OPENING_STOCK_PRODUCT_REQUIRED';
        END IF;
        IF v_line."quantityBase" IS NULL
           OR v_line."quantityBase" <= 0 THEN
            RAISE EXCEPTION 'OPENING_STOCK_QUANTITY_MUST_BE_POSITIVE';
        END IF;
        IF v_line."quantityBase" >= 1000000000000000::NUMERIC THEN
            RAISE EXCEPTION 'OPENING_STOCK_QUANTITY_TOO_LARGE';
        END IF;
        IF v_line."unitCostBase" IS NULL
           OR v_line."unitCostBase" < 0 THEN
            RAISE EXCEPTION 'OPENING_STOCK_UNIT_COST_INVALID';
        END IF;
        IF v_line."unitCostBase" >= 1000000000000000000::NUMERIC THEN
            RAISE EXCEPTION 'OPENING_STOCK_UNIT_COST_TOO_LARGE';
        END IF;
        IF round(
            v_line."quantityBase" * v_line."unitCostBase",4
        ) >= 100000000000000000::NUMERIC THEN
            RAISE EXCEPTION 'OPENING_STOCK_LINE_TOTAL_TOO_LARGE';
        END IF;
        IF v_line."unitCostBase" = 0
           AND NULLIF(btrim(v_line."zeroCostReason"),'') IS NULL THEN
            RAISE EXCEPTION 'OPENING_STOCK_ZERO_COST_REASON_REQUIRED';
        END IF;

        SELECT
            p.id,p.sku,p.name,p.uom_id,
            u.code AS uom_code,u.name AS uom_name,
            u.allow_decimal,u.decimal_precision
        INTO v_product
        FROM public.products p
        JOIN public.product_uoms pu
          ON pu.company_id = p.company_id
         AND pu.product_id = p.id
         AND pu.uom_id = p.uom_id
         AND pu.factor_to_base = 1
         AND pu.is_active
        JOIN public.uoms u
          ON u.company_id = pu.company_id
         AND u.id = pu.uom_id
         AND u.is_active
        WHERE p.company_id = v_company
          AND p.id = v_line."productId"
          AND p.is_active
          AND NOT p.is_bundle;
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND';
        END IF;
        IF NOT v_product.allow_decimal
           AND v_line."quantityBase" <> trunc(v_line."quantityBase") THEN
            RAISE EXCEPTION 'OPENING_STOCK_BASE_UOM_REQUIRES_INTEGER';
        END IF;
        IF v_product.allow_decimal
           AND v_line."quantityBase" <> round(
               v_line."quantityBase",v_product.decimal_precision
           ) THEN
            RAISE EXCEPTION 'OPENING_STOCK_BASE_UOM_PRECISION_EXCEEDED';
        END IF;
        IF EXISTS (
            SELECT 1 FROM public.stock_movements sm
            WHERE sm.company_id = v_company
              AND sm.product_id = v_product.id
              AND sm.warehouse_id = p_warehouse_id
        ) THEN
            RAISE EXCEPTION 'OPENING_STOCK_MOVEMENT_ALREADY_EXISTS';
        END IF;

        INSERT INTO public.opening_stock_lines(
            company_id,document_id,line_no,product_id,base_uom_id,
            quantity_base,unit_cost_base,total_cost,
            product_sku_snapshot,product_name_snapshot,
            base_uom_code_snapshot,base_uom_name_snapshot,
            zero_cost_reason,notes
        ) VALUES (
            v_company,v_document_id,v_line_no,v_product.id,v_product.uom_id,
            v_line."quantityBase",v_line."unitCostBase",
            round(v_line."quantityBase" * v_line."unitCostBase",4),
            v_product.sku,v_product.name,v_product.uom_code,v_product.uom_name,
            NULLIF(btrim(v_line."zeroCostReason"),''),
            NULLIF(btrim(v_line."notes"),'')
        );
    END LOOP;

    SELECT count(*),sum(quantity_base),sum(total_cost)
    INTO v_line_count,v_total_quantity,v_total_cost
    FROM public.opening_stock_lines
    WHERE company_id = v_company AND document_id = v_document_id;

    UPDATE public.opening_stock_documents SET
        warehouse_id = p_warehouse_id,
        effective_date = p_effective_date,
        notes = NULLIF(btrim(p_notes),''),
        line_count = v_line_count,
        total_quantity_base = v_total_quantity,
        total_cost = v_total_cost,
        updated_by = v_actor,
        updated_at = clock_timestamp(),
        master_version = CASE
            WHEN p_document_id IS NULL THEN master_version
            ELSE master_version + 1
        END
    WHERE company_id = v_company AND id = v_document_id
    RETURNING master_version INTO v_result_version;

    SELECT to_jsonb(d) INTO v_after
    FROM public.opening_stock_documents d
    WHERE d.company_id = v_company AND d.id = v_document_id;
    INSERT INTO public.opening_stock_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_document_id,
        CASE WHEN p_document_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
        v_actor,v_before,v_after
    );

    RETURN jsonb_build_object(
        'documentId',v_document_id,
        'documentNo',v_after->>'document_no',
        'status','DRAFT',
        'masterVersion',v_result_version,
        'lineCount',v_line_count,
        'totalQuantityBase',v_total_quantity,
        'totalCost',v_total_cost
    );
END;
$$;

CREATE FUNCTION public.post_opening_stock(
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
    v_document public.opening_stock_documents%ROWTYPE;
    v_line public.opening_stock_lines%ROWTYPE;
    v_before JSONB;
    v_after JSONB;
    v_category_id UUID;
    v_inventory_account_id UUID;
    v_opening_account_id UUID;
    v_inventory_account RECORD;
    v_opening_account RECORD;
    v_event_id UUID;
    v_store_id UUID;
    v_result_version BIGINT;
    v_effective_at TIMESTAMPTZ;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED';
    END IF;
    IF NOT public.private_user_has_any_company_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    ) THEN
        RAISE EXCEPTION 'OPENING_STOCK_POSTER_REQUIRED';
    END IF;

    SELECT * INTO v_document
    FROM public.opening_stock_documents d
    WHERE d.company_id = v_company AND d.id = p_document_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'OPENING_STOCK_NOT_FOUND'; END IF;

    IF v_document.status = 'POSTED' THEN
        IF v_document.posting_idempotency_key = p_idempotency_key THEN
            RETURN jsonb_build_object(
                'documentId',v_document.id,
                'documentNo',v_document.document_no,
                'status',v_document.status,
                'masterVersion',v_document.master_version,
                'financialEventId',v_document.financial_event_id,
                'lineCount',v_document.line_count,
                'totalQuantityBase',v_document.total_quantity_base,
                'totalCost',v_document.total_cost,
                'idempotentReplay',TRUE
            );
        END IF;
        RAISE EXCEPTION 'OPENING_STOCK_ALREADY_POSTED';
    END IF;
    IF p_master_version IS NULL
       OR p_master_version <> v_document.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_document.line_count <= 0
       OR v_document.total_quantity_base <= 0 THEN
        RAISE EXCEPTION 'OPENING_STOCK_LINES_REQUIRED';
    END IF;

    v_before := to_jsonb(v_document);
    v_effective_at := v_document.effective_date::TIMESTAMPTZ;

    SELECT tc.id INTO v_category_id
    FROM public.transaction_categories tc
    WHERE tc.company_id = v_company
      AND tc.system_key = 'STOCK_OPENING'
      AND tc.is_active
    ORDER BY tc.id
    LIMIT 1;
    IF v_category_id IS NULL THEN
        RAISE EXCEPTION 'OPENING_STOCK_TRANSACTION_CATEGORY_NOT_FOUND';
    END IF;

    v_inventory_account_id := private.resolve_opening_stock_account(
        v_company,v_category_id,'INVENTORY_ASSET',v_effective_at
    );
    v_opening_account_id := private.resolve_opening_stock_account(
        v_company,v_category_id,'OPENING_BALANCE_CLEARING',v_effective_at
    );
    SELECT id,account_code,account_name
    INTO v_inventory_account
    FROM public.chart_of_accounts
    WHERE company_id = v_company AND id = v_inventory_account_id;
    SELECT id,account_code,account_name
    INTO v_opening_account
    FROM public.chart_of_accounts
    WHERE company_id = v_company AND id = v_opening_account_id;

    SELECT w.store_id INTO v_store_id
    FROM public.warehouses w
    WHERE w.company_id = v_company
      AND w.id = v_document.warehouse_id
      AND w.is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_WAREHOUSE_NOT_FOUND'; END IF;

    FOR v_line IN
        SELECT *
        FROM public.opening_stock_lines l
        WHERE l.company_id = v_company
          AND l.document_id = v_document.id
        ORDER BY l.product_id
    LOOP
        PERFORM pg_advisory_xact_lock(hashtextextended(
            v_company::TEXT || ':STOCK:' || v_line.product_id::TEXT ||
            ':' || v_document.warehouse_id::TEXT,0
        ));

        PERFORM 1
        FROM public.product_stocks ps
        WHERE ps.company_id = v_company
          AND ps.product_id = v_line.product_id
          AND ps.warehouse_id = v_document.warehouse_id
        FOR UPDATE;

        IF EXISTS (
            SELECT 1 FROM public.stock_movements sm
            WHERE sm.company_id = v_company
              AND sm.product_id = v_line.product_id
              AND sm.warehouse_id = v_document.warehouse_id
        ) THEN
            RAISE EXCEPTION 'OPENING_STOCK_MOVEMENT_ALREADY_EXISTS';
        END IF;

        INSERT INTO public.stock_movements(
            product_id,warehouse_id,qty_change,movement_type,
            reference_table,reference_id,company_id
        ) VALUES (
            v_line.product_id,v_document.warehouse_id,v_line.quantity_base,
            'OPENING_BALANCE'::public.stock_movement_type,
            'opening_stock_documents',v_document.id,v_company
        );

        INSERT INTO public.product_stocks(
            product_id,warehouse_id,stock_qty,company_id
        ) VALUES (
            v_line.product_id,v_document.warehouse_id,
            v_line.quantity_base,v_company
        )
        ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
            stock_qty = public.product_stocks.stock_qty + EXCLUDED.stock_qty,
            updated_at = clock_timestamp();

        INSERT INTO public.product_batches(
            product_id,warehouse_id,purchase_detail_id,
            qty_purchased,qty_remaining,cogs_unit,company_id,
            opening_stock_line_id
        ) VALUES (
            v_line.product_id,v_document.warehouse_id,NULL,
            v_line.quantity_base,v_line.quantity_base,
            v_line.unit_cost_base,v_company,v_line.id
        );
    END LOOP;

    INSERT INTO public.financial_events(
        event_code,event_type,source_table,source_id,root_sales_id,
        event_date,event_version,idempotency_key,amounts,status,
        error_message,created_by,company_id,store_id,
        system_event_key,transaction_category_id
    ) VALUES (
        'STOCK-OPEN-' || replace(v_document.id::TEXT,'-',''),
        'STOCK_OPENING'::public.event_type,
        'opening_stock_documents',v_document.id,NULL,
        v_effective_at,1,
        'OPENING_STOCK|' || v_company::TEXT || '|' || p_idempotency_key::TEXT,
        jsonb_build_object(
            'inventoryDebit',v_document.total_cost,
            'openingBalanceCredit',v_document.total_cost,
            'lineCount',v_document.line_count,
            'totalQuantityBase',v_document.total_quantity_base,
            'warehouseId',v_document.warehouse_id,
            'inventoryAccountId',v_inventory_account.id,
            'inventoryAccountCode',v_inventory_account.account_code,
            'inventoryAccountName',v_inventory_account.account_name,
            'openingBalanceAccountId',v_opening_account.id,
            'openingBalanceAccountCode',v_opening_account.account_code,
            'openingBalanceAccountName',v_opening_account.account_name,
            'financePostingState','HOLD_UNTIL_G6'
        ),
        'HOLD'::public.event_status,
        'CANONICAL_FINANCE_POSTING_NOT_ENABLED',
        v_actor,v_company,v_store_id,'STOCK_OPENING',v_category_id
    )
    RETURNING id INTO v_event_id;

    UPDATE public.opening_stock_documents SET
        status = 'POSTED',
        posting_idempotency_key = p_idempotency_key,
        financial_event_id = v_event_id,
        posted_by = v_actor,
        posted_at = clock_timestamp(),
        updated_by = v_actor,
        updated_at = clock_timestamp(),
        master_version = master_version + 1
    WHERE company_id = v_company AND id = v_document.id
    RETURNING master_version INTO v_result_version;

    SELECT to_jsonb(d) INTO v_after
    FROM public.opening_stock_documents d
    WHERE d.company_id = v_company AND d.id = v_document.id;
    INSERT INTO public.opening_stock_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_document.id,'POST',v_actor,v_before,v_after
    );

    RETURN jsonb_build_object(
        'documentId',v_document.id,
        'documentNo',v_document.document_no,
        'status','POSTED',
        'masterVersion',v_result_version,
        'financialEventId',v_event_id,
        'lineCount',v_document.line_count,
        'totalQuantityBase',v_document.total_quantity_base,
        'totalCost',v_document.total_cost,
        'idempotentReplay',FALSE
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'OPENING_STOCK_IDEMPOTENCY_CONFLICT';
END;
$$;

REVOKE ALL ON FUNCTION public.private_opening_stock_prepare_allowed(UUID,UUID)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION private.resolve_opening_stock_account(
    UUID,UUID,TEXT,TIMESTAMPTZ
) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.save_opening_stock_document(
    UUID,BIGINT,UUID,DATE,TEXT,JSONB
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.post_opening_stock(UUID,BIGINT,UUID)
FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.private_opening_stock_prepare_allowed(
    UUID,UUID
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION private.resolve_opening_stock_account(
    UUID,UUID,TEXT,TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION public.save_opening_stock_document(
    UUID,BIGINT,UUID,DATE,TEXT,JSONB
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.post_opening_stock(UUID,BIGINT,UUID)
TO authenticated,service_role;

ALTER TABLE public.opening_stock_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.opening_stock_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.opening_stock_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Opening Stock documents readable by preparers"
ON public.opening_stock_documents FOR SELECT TO authenticated
USING (
    public.private_opening_stock_prepare_allowed(company_id,warehouse_id)
);

CREATE POLICY "Opening Stock lines readable by document preparers"
ON public.opening_stock_lines FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.opening_stock_documents d
        WHERE d.company_id = opening_stock_lines.company_id
          AND d.id = opening_stock_lines.document_id
          AND public.private_opening_stock_prepare_allowed(
              d.company_id,d.warehouse_id
          )
    )
);

CREATE POLICY "Opening Stock audit readable by document preparers"
ON public.opening_stock_audit FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.opening_stock_documents d
        WHERE d.company_id = opening_stock_audit.company_id
          AND d.id = opening_stock_audit.document_id
          AND public.private_opening_stock_prepare_allowed(
              d.company_id,d.warehouse_id
          )
    )
);

REVOKE ALL ON public.opening_stock_documents,public.opening_stock_lines,
    public.opening_stock_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.opening_stock_documents,public.opening_stock_lines,
    public.opening_stock_audit
TO authenticated;
GRANT ALL ON public.opening_stock_documents,public.opening_stock_lines,
    public.opening_stock_audit
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260728120000',
    'g3_phase1_opening_stock_foundation',
    'Draft/posted Opening Stock with guarded atomic movement, balance, FIFO opening layer, HOLD Finance event, audit, idempotency, and no-prior-movement guard'
);

COMMIT;
