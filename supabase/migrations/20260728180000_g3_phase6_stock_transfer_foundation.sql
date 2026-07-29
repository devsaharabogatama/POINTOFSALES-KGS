-- KGS POS G3 phase 6: canonical Stock Transfer document and posting.
-- Dependency: canonical Stock Movement through 20260728150000.
--
-- SCOPE:
-- - Draft/Posted/Canceled Transfer document;
-- - atomic Base-UOM balance and FIFO-layer relocation;
-- - paired immutable TRANSFER_OUT/TRANSFER_IN movement;
-- - optimistic version, idempotency, audit, and guarded roles;
-- - legacy unsafe transfer RPC is retained but fully revoked.
--
-- OUT OF SCOPE:
-- - Adjustment, Opname, notification, Purchasing, and Finance journal posting.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260728150000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: canonical Stock Movement missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260728180000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260728180000';
    END IF;
    IF to_regclass('public.stock_transfer_documents') IS NOT NULL
       OR to_regclass('public.stock_transfer_lines') IS NOT NULL
       OR to_regclass('public.stock_transfer_audit') IS NOT NULL
       OR to_regclass('public.stock_transfer_fifo_allocations') IS NOT NULL THEN
        RAISE EXCEPTION
            'G3_PHASE6_STATE_CHANGED: canonical Transfer table exists';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.stock_movements
        WHERE movement_type IN (
            'TRANSFER_IN'::public.stock_movement_type,
            'TRANSFER_OUT'::public.stock_movement_type
        )
    ) THEN
        RAISE EXCEPTION
            'G3_PHASE6_STATE_CHANGED: Transfer history requires backfill';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.product_stocks ps
        FULL JOIN (
            SELECT company_id,product_id,warehouse_id,sum(qty_change) AS qty
            FROM public.stock_movements
            GROUP BY company_id,product_id,warehouse_id
        ) mt
          ON mt.company_id = ps.company_id
         AND mt.product_id = ps.product_id
         AND mt.warehouse_id = ps.warehouse_id
        WHERE ps.product_id IS NULL
           OR mt.product_id IS NULL
           OR ps.stock_qty IS DISTINCT FROM mt.qty
    ) THEN
        RAISE EXCEPTION
            'G3_PHASE6_STATE_CHANGED: stock balance and movement mismatch';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.product_stocks ps
        LEFT JOIN (
            SELECT
                company_id,product_id,warehouse_id,
                sum(qty_remaining) AS qty
            FROM public.product_batches
            GROUP BY company_id,product_id,warehouse_id
        ) b
          ON b.company_id = ps.company_id
         AND b.product_id = ps.product_id
         AND b.warehouse_id = ps.warehouse_id
        WHERE ps.stock_qty > 0
          AND ps.stock_qty IS DISTINCT FROM COALESCE(b.qty,0)
    ) THEN
        RAISE EXCEPTION
            'G3_PHASE6_STATE_CHANGED: FIFO remaining and balance mismatch';
    END IF;
END
$migration_guard$;

CREATE SEQUENCE private.stock_transfer_document_no_seq;
REVOKE ALL ON SEQUENCE private.stock_transfer_document_no_seq
FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.stock_transfer_document_no_seq
TO service_role;

CREATE TABLE public.stock_transfer_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    document_no TEXT NOT NULL,
    source_warehouse_id UUID NOT NULL,
    destination_warehouse_id UUID NOT NULL,
    transfer_date DATE NOT NULL,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    notes TEXT,
    line_count INTEGER NOT NULL DEFAULT 0,
    total_quantity_base NUMERIC(24,6) NOT NULL DEFAULT 0,
    total_cost NUMERIC(24,4) NOT NULL DEFAULT 0,
    posting_idempotency_key UUID,
    transaction_category_id UUID,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    updated_by UUID NOT NULL REFERENCES public.profiles(id),
    posted_by UUID REFERENCES public.profiles(id),
    posted_at TIMESTAMPTZ,
    canceled_by UUID REFERENCES public.profiles(id),
    canceled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT stock_transfer_documents_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT stock_transfer_documents_company_number_unique
        UNIQUE(company_id,document_no),
    CONSTRAINT stock_transfer_documents_company_posting_key_unique
        UNIQUE(company_id,posting_idempotency_key),
    CONSTRAINT stock_transfer_documents_number_not_blank
        CHECK(btrim(document_no) <> ''),
    CONSTRAINT stock_transfer_documents_distinct_warehouse
        CHECK(source_warehouse_id <> destination_warehouse_id),
    CONSTRAINT stock_transfer_documents_status_check
        CHECK(status IN ('DRAFT','POSTED','CANCELED')),
    CONSTRAINT stock_transfer_documents_totals_nonnegative CHECK(
        line_count >= 0
        AND total_quantity_base >= 0
        AND total_cost >= 0
    ),
    CONSTRAINT stock_transfer_documents_version_positive
        CHECK(master_version > 0),
    CONSTRAINT stock_transfer_documents_posting_state_check CHECK(
        (
            status = 'DRAFT'
            AND posting_idempotency_key IS NULL
            AND transaction_category_id IS NULL
            AND posted_by IS NULL
            AND posted_at IS NULL
            AND canceled_by IS NULL
            AND canceled_at IS NULL
        )
        OR
        (
            status = 'POSTED'
            AND posting_idempotency_key IS NOT NULL
            AND transaction_category_id IS NOT NULL
            AND posted_by IS NOT NULL
            AND posted_at IS NOT NULL
            AND canceled_by IS NULL
            AND canceled_at IS NULL
        )
        OR
        (
            status = 'CANCELED'
            AND posting_idempotency_key IS NULL
            AND transaction_category_id IS NULL
            AND posted_by IS NULL
            AND posted_at IS NULL
            AND canceled_by IS NOT NULL
            AND canceled_at IS NOT NULL
        )
    ),
    CONSTRAINT fk_stock_transfer_documents_company_source
        FOREIGN KEY(company_id,source_warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_stock_transfer_documents_company_destination
        FOREIGN KEY(company_id,destination_warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_stock_transfer_documents_company_category
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_stock_transfer_documents_company_status_date
    ON public.stock_transfer_documents(
        company_id,status,transfer_date DESC,created_at DESC
    );
CREATE INDEX idx_stock_transfer_documents_source
    ON public.stock_transfer_documents(
        company_id,source_warehouse_id,transfer_date DESC
    );
CREATE INDEX idx_stock_transfer_documents_destination
    ON public.stock_transfer_documents(
        company_id,destination_warehouse_id,transfer_date DESC
    );

CREATE TABLE public.stock_transfer_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    line_no INTEGER NOT NULL,
    product_id UUID NOT NULL,
    base_uom_id UUID NOT NULL,
    quantity_base NUMERIC(24,6) NOT NULL,
    transferred_cost NUMERIC(24,4) NOT NULL DEFAULT 0,
    fifo_layer_count INTEGER NOT NULL DEFAULT 0,
    product_sku_snapshot TEXT NOT NULL,
    product_name_snapshot TEXT NOT NULL,
    base_uom_name_snapshot TEXT NOT NULL,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT stock_transfer_lines_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT stock_transfer_lines_document_line_unique
        UNIQUE(company_id,document_id,line_no),
    CONSTRAINT stock_transfer_lines_document_product_unique
        UNIQUE(company_id,document_id,product_id),
    CONSTRAINT stock_transfer_lines_line_positive CHECK(line_no > 0),
    CONSTRAINT stock_transfer_lines_quantity_positive CHECK(quantity_base > 0),
    CONSTRAINT stock_transfer_lines_cost_nonnegative CHECK(transferred_cost >= 0),
    CONSTRAINT stock_transfer_lines_layer_nonnegative CHECK(fifo_layer_count >= 0),
    CONSTRAINT stock_transfer_lines_snapshot_not_blank CHECK(
        btrim(product_sku_snapshot) <> ''
        AND btrim(product_name_snapshot) <> ''
        AND btrim(base_uom_name_snapshot) <> ''
    ),
    CONSTRAINT fk_stock_transfer_lines_company_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.stock_transfer_documents(company_id,id)
        ON DELETE CASCADE,
    CONSTRAINT fk_stock_transfer_lines_company_product
        FOREIGN KEY(company_id,product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_stock_transfer_lines_company_base_uom
        FOREIGN KEY(company_id,base_uom_id)
        REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_stock_transfer_lines_company_product
    ON public.stock_transfer_lines(company_id,product_id);

ALTER TABLE public.product_batches
    ADD COLUMN stock_transfer_line_id UUID,
    ADD COLUMN source_batch_id UUID,
    ADD CONSTRAINT fk_product_batches_company_transfer_line
        FOREIGN KEY(company_id,stock_transfer_line_id)
        REFERENCES public.stock_transfer_lines(company_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT fk_product_batches_company_source_batch
        FOREIGN KEY(company_id,source_batch_id)
        REFERENCES public.product_batches(company_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT product_batches_transfer_lineage_check CHECK(
        (stock_transfer_line_id IS NULL AND source_batch_id IS NULL)
        OR
        (stock_transfer_line_id IS NOT NULL AND source_batch_id IS NOT NULL)
    );

CREATE INDEX idx_product_batches_company_transfer_line
    ON public.product_batches(company_id,stock_transfer_line_id)
    WHERE stock_transfer_line_id IS NOT NULL;
CREATE INDEX idx_product_batches_company_source_batch
    ON public.product_batches(company_id,source_batch_id)
    WHERE source_batch_id IS NOT NULL;

CREATE TABLE public.stock_transfer_fifo_allocations (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    line_id UUID NOT NULL,
    source_batch_id UUID NOT NULL,
    destination_batch_id UUID NOT NULL,
    quantity_base NUMERIC(24,6) NOT NULL,
    unit_cost_base NUMERIC(24,6) NOT NULL,
    total_cost NUMERIC(24,4) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT stock_transfer_fifo_allocations_source_unique
        UNIQUE(company_id,line_id,source_batch_id),
    CONSTRAINT stock_transfer_fifo_allocations_destination_unique
        UNIQUE(company_id,destination_batch_id),
    CONSTRAINT stock_transfer_fifo_allocations_quantity_positive
        CHECK(quantity_base > 0),
    CONSTRAINT stock_transfer_fifo_allocations_cost_nonnegative
        CHECK(unit_cost_base >= 0),
    CONSTRAINT stock_transfer_fifo_allocations_total_check
        CHECK(total_cost = round(quantity_base * unit_cost_base,4)),
    CONSTRAINT fk_stock_transfer_fifo_company_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.stock_transfer_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_stock_transfer_fifo_company_line
        FOREIGN KEY(company_id,line_id)
        REFERENCES public.stock_transfer_lines(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_stock_transfer_fifo_company_source_batch
        FOREIGN KEY(company_id,source_batch_id)
        REFERENCES public.product_batches(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_stock_transfer_fifo_company_destination_batch
        FOREIGN KEY(company_id,destination_batch_id)
        REFERENCES public.product_batches(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_stock_transfer_fifo_document
    ON public.stock_transfer_fifo_allocations(
        company_id,document_id,line_id
    );

CREATE TABLE public.stock_transfer_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    action TEXT NOT NULL CHECK(action IN ('CREATE','UPDATE','POST','CANCEL')),
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fk_stock_transfer_audit_company_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.stock_transfer_documents(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_stock_transfer_audit_document_created
    ON public.stock_transfer_audit(company_id,document_id,created_at DESC);

CREATE FUNCTION public.private_stock_transfer_operator_allowed(
    p_company_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT public.private_request_company_matches(p_company_id)
       AND public.private_user_has_any_company_role(
           p_company_id,
           ARRAY[
               'COMPANY_OWNER','COMPANY_ADMIN','WAREHOUSE_ADMIN'
           ]::TEXT[]
       );
$$;

CREATE FUNCTION public.save_stock_transfer_document(
    p_document_id UUID,
    p_master_version BIGINT,
    p_source_warehouse_id UUID,
    p_destination_warehouse_id UUID,
    p_transfer_date DATE,
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
    v_existing public.stock_transfer_documents%ROWTYPE;
    v_before JSONB;
    v_after JSONB;
    v_line RECORD;
    v_line_no INTEGER := 0;
    v_line_count INTEGER;
    v_total_quantity NUMERIC(24,6);
    v_product RECORD;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_stock_transfer_operator_allowed(v_company) THEN
        RAISE EXCEPTION 'STOCK_TRANSFER_OPERATOR_REQUIRED';
    END IF;
    IF p_source_warehouse_id IS NULL
       OR p_destination_warehouse_id IS NULL THEN
        RAISE EXCEPTION 'STOCK_TRANSFER_WAREHOUSE_REQUIRED';
    END IF;
    IF p_source_warehouse_id = p_destination_warehouse_id THEN
        RAISE EXCEPTION 'STOCK_TRANSFER_WAREHOUSES_MUST_DIFFER';
    END IF;
    IF (
        SELECT count(*)
        FROM public.warehouses w
        WHERE w.company_id = v_company
          AND w.id IN (
              p_source_warehouse_id,p_destination_warehouse_id
          )
          AND w.is_active
    ) <> 2 THEN
        RAISE EXCEPTION 'ACTIVE_TRANSFER_WAREHOUSE_NOT_FOUND';
    END IF;
    IF p_transfer_date IS NULL THEN
        RAISE EXCEPTION 'STOCK_TRANSFER_DATE_REQUIRED';
    END IF;
    IF p_transfer_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'STOCK_TRANSFER_FUTURE_DATE_NOT_ALLOWED';
    END IF;
    IF p_lines IS NULL
       OR jsonb_typeof(p_lines) <> 'array'
       OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'STOCK_TRANSFER_LINES_REQUIRED';
    END IF;
    IF jsonb_array_length(p_lines) > 1000 THEN
        RAISE EXCEPTION 'STOCK_TRANSFER_LINE_LIMIT_EXCEEDED';
    END IF;

    IF p_document_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        v_document_no := 'TRF-' || lpad(
            nextval('private.stock_transfer_document_no_seq')::TEXT,10,'0'
        );
        INSERT INTO public.stock_transfer_documents(
            company_id,document_no,source_warehouse_id,
            destination_warehouse_id,transfer_date,notes,
            created_by,updated_by
        ) VALUES (
            v_company,v_document_no,p_source_warehouse_id,
            p_destination_warehouse_id,p_transfer_date,
            NULLIF(btrim(p_notes),''),v_actor,v_actor
        )
        RETURNING id,master_version
        INTO v_document_id,v_result_version;
    ELSE
        SELECT * INTO v_existing
        FROM public.stock_transfer_documents d
        WHERE d.company_id = v_company AND d.id = p_document_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_TRANSFER_NOT_FOUND'; END IF;
        IF v_existing.status <> 'DRAFT' THEN
            RAISE EXCEPTION 'FINAL_STOCK_TRANSFER_IMMUTABLE';
        END IF;
        IF p_master_version IS NULL
           OR p_master_version <> v_existing.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        v_before := to_jsonb(v_existing);
        v_document_id := p_document_id;
        DELETE FROM public.stock_transfer_lines
        WHERE company_id = v_company AND document_id = v_document_id;
    END IF;

    FOR v_line IN
        SELECT *
        FROM jsonb_to_recordset(p_lines) AS x(
            "productId" UUID,
            "quantityBase" NUMERIC,
            "notes" TEXT
        )
    LOOP
        v_line_no := v_line_no + 1;
        IF v_line."productId" IS NULL THEN
            RAISE EXCEPTION 'STOCK_TRANSFER_PRODUCT_REQUIRED';
        END IF;
        IF v_line."quantityBase" IS NULL
           OR v_line."quantityBase" <= 0 THEN
            RAISE EXCEPTION 'STOCK_TRANSFER_QUANTITY_MUST_BE_POSITIVE';
        END IF;
        IF v_line."quantityBase" >= 1000000000000000::NUMERIC THEN
            RAISE EXCEPTION 'STOCK_TRANSFER_QUANTITY_TOO_LARGE';
        END IF;

        SELECT
            p.id,p.sku,p.name,p.uom_id,
            u.name AS uom_name,u.allow_decimal,u.decimal_precision
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
            RAISE EXCEPTION 'STOCK_TRANSFER_BASE_UOM_REQUIRES_INTEGER';
        END IF;
        IF v_product.allow_decimal
           AND v_line."quantityBase" <> round(
               v_line."quantityBase",v_product.decimal_precision
           ) THEN
            RAISE EXCEPTION 'STOCK_TRANSFER_BASE_UOM_PRECISION_EXCEEDED';
        END IF;

        INSERT INTO public.stock_transfer_lines(
            company_id,document_id,line_no,product_id,base_uom_id,
            quantity_base,product_sku_snapshot,product_name_snapshot,
            base_uom_name_snapshot,notes
        ) VALUES (
            v_company,v_document_id,v_line_no,v_product.id,v_product.uom_id,
            v_line."quantityBase",v_product.sku,v_product.name,
            v_product.uom_name,NULLIF(btrim(v_line."notes"),'')
        );
    END LOOP;

    SELECT count(*),sum(quantity_base)
    INTO v_line_count,v_total_quantity
    FROM public.stock_transfer_lines
    WHERE company_id = v_company AND document_id = v_document_id;

    UPDATE public.stock_transfer_documents SET
        source_warehouse_id = p_source_warehouse_id,
        destination_warehouse_id = p_destination_warehouse_id,
        transfer_date = p_transfer_date,
        notes = NULLIF(btrim(p_notes),''),
        line_count = v_line_count,
        total_quantity_base = v_total_quantity,
        total_cost = 0,
        updated_by = v_actor,
        updated_at = clock_timestamp(),
        master_version = CASE
            WHEN p_document_id IS NULL THEN master_version
            ELSE master_version + 1
        END
    WHERE company_id = v_company AND id = v_document_id
    RETURNING master_version INTO v_result_version;

    SELECT to_jsonb(d) INTO v_after
    FROM public.stock_transfer_documents d
    WHERE d.company_id = v_company AND d.id = v_document_id;
    INSERT INTO public.stock_transfer_audit(
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
        'totalQuantityBase',v_total_quantity
    );
END;
$$;

CREATE FUNCTION public.post_stock_transfer(
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
    v_document public.stock_transfer_documents%ROWTYPE;
    v_line public.stock_transfer_lines%ROWTYPE;
    v_batch RECORD;
    v_before JSONB;
    v_after JSONB;
    v_category_id UUID;
    v_result_version BIGINT;
    v_source_before NUMERIC(24,6);
    v_destination_before NUMERIC(24,6);
    v_remaining NUMERIC(24,6);
    v_take NUMERIC(24,6);
    v_line_cost NUMERIC(24,4);
    v_total_cost NUMERIC(24,4) := 0;
    v_layer_count INTEGER;
    v_destination_batch_id UUID;
    v_posted_at TIMESTAMPTZ := clock_timestamp();
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED';
    END IF;
    IF NOT public.private_stock_transfer_operator_allowed(v_company) THEN
        RAISE EXCEPTION 'STOCK_TRANSFER_OPERATOR_REQUIRED';
    END IF;

    SELECT * INTO v_document
    FROM public.stock_transfer_documents d
    WHERE d.company_id = v_company AND d.id = p_document_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_TRANSFER_NOT_FOUND'; END IF;

    IF v_document.status = 'POSTED' THEN
        IF v_document.posting_idempotency_key = p_idempotency_key THEN
            RETURN jsonb_build_object(
                'documentId',v_document.id,
                'documentNo',v_document.document_no,
                'status',v_document.status,
                'masterVersion',v_document.master_version,
                'lineCount',v_document.line_count,
                'totalQuantityBase',v_document.total_quantity_base,
                'totalCost',v_document.total_cost,
                'idempotentReplay',TRUE
            );
        END IF;
        RAISE EXCEPTION 'STOCK_TRANSFER_ALREADY_POSTED';
    END IF;
    IF v_document.status = 'CANCELED' THEN
        RAISE EXCEPTION 'CANCELED_STOCK_TRANSFER_IMMUTABLE';
    END IF;
    IF p_master_version IS NULL
       OR p_master_version <> v_document.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_document.line_count <= 0
       OR v_document.total_quantity_base <= 0 THEN
        RAISE EXCEPTION 'STOCK_TRANSFER_LINES_REQUIRED';
    END IF;

    IF (
        SELECT count(*)
        FROM public.warehouses w
        WHERE w.company_id = v_company
          AND w.id IN (
              v_document.source_warehouse_id,
              v_document.destination_warehouse_id
          )
          AND w.is_active
    ) <> 2 THEN
        RAISE EXCEPTION 'ACTIVE_TRANSFER_WAREHOUSE_NOT_FOUND';
    END IF;

    SELECT tc.id INTO v_category_id
    FROM public.transaction_categories tc
    WHERE tc.company_id = v_company
      AND tc.system_key = 'STOCK_TRANSFER'
      AND tc.is_active
      AND tc.is_system_default
    ORDER BY tc.id
    LIMIT 1;
    IF v_category_id IS NULL THEN
        RAISE EXCEPTION 'STOCK_TRANSFER_TRANSACTION_CATEGORY_NOT_FOUND';
    END IF;

    v_before := to_jsonb(v_document);

    FOR v_line IN
        SELECT *
        FROM public.stock_transfer_lines l
        WHERE l.company_id = v_company
          AND l.document_id = v_document.id
        ORDER BY l.product_id
    LOOP
        PERFORM pg_advisory_xact_lock(hashtextextended(
            v_company::TEXT || ':STOCK:' || v_line.product_id::TEXT ||
            ':' || LEAST(
                v_document.source_warehouse_id::TEXT,
                v_document.destination_warehouse_id::TEXT
            ),0
        ));
        PERFORM pg_advisory_xact_lock(hashtextextended(
            v_company::TEXT || ':STOCK:' || v_line.product_id::TEXT ||
            ':' || GREATEST(
                v_document.source_warehouse_id::TEXT,
                v_document.destination_warehouse_id::TEXT
            ),0
        ));

        SELECT ps.stock_qty INTO v_source_before
        FROM public.product_stocks ps
        WHERE ps.company_id = v_company
          AND ps.product_id = v_line.product_id
          AND ps.warehouse_id = v_document.source_warehouse_id
        FOR UPDATE;
        IF NOT FOUND OR v_source_before < v_line.quantity_base THEN
            RAISE EXCEPTION 'INSUFFICIENT_STOCK';
        END IF;

        SELECT COALESCE(ps.stock_qty,0) INTO v_destination_before
        FROM public.product_stocks ps
        WHERE ps.company_id = v_company
          AND ps.product_id = v_line.product_id
          AND ps.warehouse_id = v_document.destination_warehouse_id
        FOR UPDATE;
        v_destination_before := COALESCE(v_destination_before,0);

        v_remaining := v_line.quantity_base;
        v_line_cost := 0;
        v_layer_count := 0;
        FOR v_batch IN
            SELECT b.*
            FROM public.product_batches b
            WHERE b.company_id = v_company
              AND b.product_id = v_line.product_id
              AND b.warehouse_id = v_document.source_warehouse_id
              AND b.qty_remaining > 0
            ORDER BY b.created_at,b.id
            FOR UPDATE
        LOOP
            EXIT WHEN v_remaining <= 0;
            v_take := LEAST(v_remaining,v_batch.qty_remaining);

            UPDATE public.product_batches SET
                qty_remaining = qty_remaining - v_take
            WHERE company_id = v_company AND id = v_batch.id;

            INSERT INTO public.product_batches(
                product_id,warehouse_id,purchase_detail_id,
                qty_purchased,qty_remaining,cogs_unit,company_id,
                opening_stock_line_id,stock_transfer_line_id,source_batch_id
            ) VALUES (
                v_line.product_id,v_document.destination_warehouse_id,NULL,
                v_take,v_take,v_batch.cogs_unit,v_company,
                NULL,v_line.id,v_batch.id
            )
            RETURNING id INTO v_destination_batch_id;

            INSERT INTO public.stock_transfer_fifo_allocations(
                company_id,document_id,line_id,source_batch_id,
                destination_batch_id,quantity_base,unit_cost_base,total_cost
            ) VALUES (
                v_company,v_document.id,v_line.id,v_batch.id,
                v_destination_batch_id,v_take,v_batch.cogs_unit,
                round(v_take * v_batch.cogs_unit,4)
            );

            v_line_cost := v_line_cost +
                round(v_take * v_batch.cogs_unit,4);
            v_layer_count := v_layer_count + 1;
            v_remaining := v_remaining - v_take;
        END LOOP;

        IF v_remaining <> 0 THEN
            RAISE EXCEPTION 'INSUFFICIENT_FIFO_STOCK';
        END IF;

        UPDATE public.product_stocks SET
            stock_qty = stock_qty - v_line.quantity_base,
            updated_at = clock_timestamp()
        WHERE company_id = v_company
          AND product_id = v_line.product_id
          AND warehouse_id = v_document.source_warehouse_id
          AND stock_qty >= v_line.quantity_base;
        IF NOT FOUND THEN RAISE EXCEPTION 'INSUFFICIENT_STOCK'; END IF;

        INSERT INTO public.product_stocks(
            product_id,warehouse_id,stock_qty,company_id
        ) VALUES (
            v_line.product_id,v_document.destination_warehouse_id,
            v_line.quantity_base,v_company
        )
        ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
            stock_qty = public.product_stocks.stock_qty + EXCLUDED.stock_qty,
            updated_at = clock_timestamp();

        INSERT INTO public.stock_movements(
            product_id,warehouse_id,qty_change,movement_type,
            reference_table,reference_id,company_id,
            base_uom_id,base_uom_name_snapshot,balance_after_base_qty,
            actor_id,posted_at,movement_status,source_line_id,notes
        ) VALUES
        (
            v_line.product_id,v_document.source_warehouse_id,
            -v_line.quantity_base,
            'TRANSFER_OUT'::public.stock_movement_type,
            'stock_transfer_documents',v_document.id,v_company,
            v_line.base_uom_id,v_line.base_uom_name_snapshot,
            v_source_before - v_line.quantity_base,
            v_actor,v_posted_at,'POSTED',v_line.id,
            COALESCE(v_line.notes,v_document.notes)
        ),
        (
            v_line.product_id,v_document.destination_warehouse_id,
            v_line.quantity_base,
            'TRANSFER_IN'::public.stock_movement_type,
            'stock_transfer_documents',v_document.id,v_company,
            v_line.base_uom_id,v_line.base_uom_name_snapshot,
            v_destination_before + v_line.quantity_base,
            v_actor,v_posted_at,'POSTED',v_line.id,
            COALESCE(v_line.notes,v_document.notes)
        );

        UPDATE public.stock_transfer_lines SET
            transferred_cost = v_line_cost,
            fifo_layer_count = v_layer_count
        WHERE company_id = v_company AND id = v_line.id;
        v_total_cost := v_total_cost + v_line_cost;
    END LOOP;

    UPDATE public.stock_transfer_documents SET
        status = 'POSTED',
        posting_idempotency_key = p_idempotency_key,
        transaction_category_id = v_category_id,
        total_cost = v_total_cost,
        posted_by = v_actor,
        posted_at = v_posted_at,
        updated_by = v_actor,
        updated_at = v_posted_at,
        master_version = master_version + 1
    WHERE company_id = v_company AND id = v_document.id
    RETURNING master_version INTO v_result_version;

    SELECT to_jsonb(d) INTO v_after
    FROM public.stock_transfer_documents d
    WHERE d.company_id = v_company AND d.id = v_document.id;
    INSERT INTO public.stock_transfer_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_document.id,'POST',v_actor,v_before,v_after
    );

    RETURN jsonb_build_object(
        'documentId',v_document.id,
        'documentNo',v_document.document_no,
        'status','POSTED',
        'masterVersion',v_result_version,
        'lineCount',v_document.line_count,
        'totalQuantityBase',v_document.total_quantity_base,
        'totalCost',v_total_cost,
        'idempotentReplay',FALSE
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'STOCK_TRANSFER_IDEMPOTENCY_CONFLICT';
END;
$$;

CREATE FUNCTION public.cancel_stock_transfer(
    p_document_id UUID,
    p_master_version BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_document public.stock_transfer_documents%ROWTYPE;
    v_before JSONB;
    v_after JSONB;
    v_result_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_stock_transfer_operator_allowed(v_company) THEN
        RAISE EXCEPTION 'STOCK_TRANSFER_OPERATOR_REQUIRED';
    END IF;

    SELECT * INTO v_document
    FROM public.stock_transfer_documents d
    WHERE d.company_id = v_company AND d.id = p_document_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_TRANSFER_NOT_FOUND'; END IF;
    IF v_document.status <> 'DRAFT' THEN
        RAISE EXCEPTION 'FINAL_STOCK_TRANSFER_IMMUTABLE';
    END IF;
    IF p_master_version IS NULL
       OR p_master_version <> v_document.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;

    v_before := to_jsonb(v_document);
    UPDATE public.stock_transfer_documents SET
        status = 'CANCELED',
        canceled_by = v_actor,
        canceled_at = clock_timestamp(),
        updated_by = v_actor,
        updated_at = clock_timestamp(),
        master_version = master_version + 1
    WHERE company_id = v_company AND id = v_document.id
    RETURNING master_version INTO v_result_version;

    SELECT to_jsonb(d) INTO v_after
    FROM public.stock_transfer_documents d
    WHERE d.company_id = v_company AND d.id = v_document.id;
    INSERT INTO public.stock_transfer_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_document.id,'CANCEL',v_actor,v_before,v_after
    );

    RETURN jsonb_build_object(
        'documentId',v_document.id,
        'documentNo',v_document.document_no,
        'status','CANCELED',
        'masterVersion',v_result_version
    );
END;
$$;

REVOKE ALL ON FUNCTION public.private_stock_transfer_operator_allowed(UUID)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.save_stock_transfer_document(
    UUID,BIGINT,UUID,UUID,DATE,TEXT,JSONB
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.post_stock_transfer(UUID,BIGINT,UUID)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.cancel_stock_transfer(UUID,BIGINT)
FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.private_stock_transfer_operator_allowed(UUID)
TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.save_stock_transfer_document(
    UUID,BIGINT,UUID,UUID,DATE,TEXT,JSONB
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.post_stock_transfer(UUID,BIGINT,UUID)
TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.cancel_stock_transfer(UUID,BIGINT)
TO authenticated,service_role;

-- Keep the legacy signature for compatibility discovery, but make it
-- non-executable for every application role.
REVOKE ALL ON FUNCTION public.transfer_product_stock(
    UUID,UUID,UUID,NUMERIC
) FROM PUBLIC,anon,authenticated,service_role;

ALTER TABLE public.stock_transfer_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_transfer_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_transfer_fifo_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_transfer_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Stock Transfer documents readable by inventory reviewers"
ON public.stock_transfer_documents FOR SELECT TO authenticated
USING (public.private_inventory_reviewer_visible(company_id));

CREATE POLICY "Stock Transfer lines readable by inventory reviewers"
ON public.stock_transfer_lines FOR SELECT TO authenticated
USING (public.private_inventory_reviewer_visible(company_id));

CREATE POLICY "Stock Transfer FIFO readable by inventory reviewers"
ON public.stock_transfer_fifo_allocations FOR SELECT TO authenticated
USING (public.private_inventory_reviewer_visible(company_id));

CREATE POLICY "Stock Transfer audit readable by inventory reviewers"
ON public.stock_transfer_audit FOR SELECT TO authenticated
USING (public.private_inventory_reviewer_visible(company_id));

REVOKE ALL ON public.stock_transfer_documents,public.stock_transfer_lines,
    public.stock_transfer_fifo_allocations,public.stock_transfer_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.stock_transfer_documents,public.stock_transfer_lines,
    public.stock_transfer_fifo_allocations,public.stock_transfer_audit
TO authenticated;
GRANT ALL ON public.stock_transfer_documents,public.stock_transfer_lines,
    public.stock_transfer_fifo_allocations,public.stock_transfer_audit
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260728180000',
    'g3_phase6_stock_transfer_foundation',
    'Canonical Draft/Posted/Canceled Stock Transfer with atomic Base-UOM balance, FIFO relocation, paired immutable movement, role guard, idempotency, and audit; legacy unsafe RPC revoked'
);

COMMIT;
