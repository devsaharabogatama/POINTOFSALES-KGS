-- KGS POS G3 phase 8: canonical Stock Adjustment foundation.
-- Dependency: canonical Stock Transfer through 20260728180000.
--
-- The operator enters FINAL physical Base-UOM quantity. The server snapshots
-- current stock and derives the signed difference. Drafts never affect stock.
-- Posting atomically updates balance, FIFO, immutable Movement, HOLD Finance
-- events, document state, and audit.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260728180000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: canonical Stock Transfer missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260728210000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260728210000';
    END IF;
    IF to_regclass('public.stock_adjustment_documents') IS NOT NULL
       OR to_regclass('public.stock_adjustment_lines') IS NOT NULL
       OR to_regclass('public.stock_adjustment_reasons') IS NOT NULL THEN
        RAISE EXCEPTION
            'G3_PHASE8_STATE_CHANGED: canonical Adjustment table exists';
    END IF;
    IF EXISTS (SELECT 1 FROM public.stock_adjustments)
       OR EXISTS (
           SELECT 1 FROM public.stock_movements
           WHERE movement_type = 'ADJUSTMENT'::public.stock_movement_type
       ) THEN
        RAISE EXCEPTION
            'G3_PHASE8_STATE_CHANGED: legacy Adjustment requires backfill';
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
        WHERE ps.product_id IS NULL OR mt.product_id IS NULL
           OR ps.stock_qty IS DISTINCT FROM mt.qty
    ) THEN
        RAISE EXCEPTION
            'G3_PHASE8_STATE_CHANGED: stock balance and Movement mismatch';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.product_stocks ps
        LEFT JOIN (
            SELECT company_id,product_id,warehouse_id,
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
            'G3_PHASE8_STATE_CHANGED: FIFO remaining and balance mismatch';
    END IF;
END
$migration_guard$;

ALTER TYPE public.event_type ADD VALUE IF NOT EXISTS 'STOCK_GAIN';
ALTER TYPE public.event_type ADD VALUE IF NOT EXISTS 'STOCK_LOSS';

CREATE SEQUENCE private.stock_adjustment_document_no_seq;
CREATE SEQUENCE private.stock_adjustment_reason_code_seq;
REVOKE ALL ON SEQUENCE private.stock_adjustment_document_no_seq,
    private.stock_adjustment_reason_code_seq
FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.stock_adjustment_document_no_seq,
    private.stock_adjustment_reason_code_seq
TO service_role;

CREATE TABLE public.stock_adjustment_reasons (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    reason_code TEXT NOT NULL DEFAULT (
        'ADJ-RSN-' || lpad(
            nextval('private.stock_adjustment_reason_code_seq')::TEXT,8,'0'
        )
    ),
    reason_name TEXT NOT NULL,
    direction_allowed TEXT NOT NULL,
    finance_treatment TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    is_system_default BOOLEAN NOT NULL DEFAULT FALSE,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT stock_adjustment_reasons_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT stock_adjustment_reasons_company_code_unique
        UNIQUE(company_id,reason_code),
    CONSTRAINT stock_adjustment_reasons_name_not_blank
        CHECK(btrim(reason_name) <> ''),
    CONSTRAINT stock_adjustment_reasons_direction_check
        CHECK(direction_allowed IN ('INCREASE','DECREASE','BOTH')),
    CONSTRAINT stock_adjustment_reasons_finance_check
        CHECK(finance_treatment IN ('STOCK_GAIN','STOCK_LOSS','OTHER')),
    CONSTRAINT stock_adjustment_reasons_version_positive
        CHECK(master_version > 0)
);
CREATE UNIQUE INDEX uq_stock_adjustment_reasons_company_name
    ON public.stock_adjustment_reasons(
        company_id,lower(regexp_replace(btrim(reason_name),'\s+',' ','g'))
    );

CREATE TABLE public.stock_adjustment_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    document_no TEXT NOT NULL,
    warehouse_id UUID NOT NULL,
    adjustment_date DATE NOT NULL,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    notes TEXT,
    correction_of_document_id UUID,
    line_count INTEGER NOT NULL DEFAULT 0,
    total_gain_quantity_base NUMERIC(24,6) NOT NULL DEFAULT 0,
    total_loss_quantity_base NUMERIC(24,6) NOT NULL DEFAULT 0,
    total_gain_value NUMERIC(24,4) NOT NULL DEFAULT 0,
    total_loss_value NUMERIC(24,4) NOT NULL DEFAULT 0,
    posting_idempotency_key UUID,
    gain_transaction_category_id UUID,
    loss_transaction_category_id UUID,
    gain_financial_event_id UUID,
    loss_financial_event_id UUID,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    updated_by UUID NOT NULL REFERENCES public.profiles(id),
    posted_by UUID REFERENCES public.profiles(id),
    posted_at TIMESTAMPTZ,
    canceled_by UUID REFERENCES public.profiles(id),
    canceled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT stock_adjustment_documents_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT stock_adjustment_documents_company_number_unique
        UNIQUE(company_id,document_no),
    CONSTRAINT stock_adjustment_documents_company_post_key_unique
        UNIQUE(company_id,posting_idempotency_key),
    CONSTRAINT stock_adjustment_documents_status_check
        CHECK(status IN ('DRAFT','POSTED','CANCELED')),
    CONSTRAINT stock_adjustment_documents_totals_nonnegative CHECK(
        line_count >= 0
        AND total_gain_quantity_base >= 0
        AND total_loss_quantity_base >= 0
        AND total_gain_value >= 0
        AND total_loss_value >= 0
    ),
    CONSTRAINT stock_adjustment_documents_version_positive
        CHECK(master_version > 0),
    CONSTRAINT stock_adjustment_documents_correction_not_self
        CHECK(correction_of_document_id IS NULL
              OR correction_of_document_id <> id),
    CONSTRAINT stock_adjustment_documents_final_state_check CHECK(
        (
            status = 'DRAFT'
            AND posting_idempotency_key IS NULL
            AND posted_by IS NULL AND posted_at IS NULL
            AND canceled_by IS NULL AND canceled_at IS NULL
            AND gain_transaction_category_id IS NULL
            AND loss_transaction_category_id IS NULL
            AND gain_financial_event_id IS NULL
            AND loss_financial_event_id IS NULL
        ) OR (
            status = 'POSTED'
            AND posting_idempotency_key IS NOT NULL
            AND posted_by IS NOT NULL AND posted_at IS NOT NULL
            AND canceled_by IS NULL AND canceled_at IS NULL
            AND (
                (
                    total_gain_quantity_base = 0
                    AND gain_transaction_category_id IS NULL
                    AND gain_financial_event_id IS NULL
                ) OR (
                    total_gain_quantity_base > 0
                    AND gain_transaction_category_id IS NOT NULL
                    AND gain_financial_event_id IS NOT NULL
                )
            )
            AND (
                (
                    total_loss_quantity_base = 0
                    AND loss_transaction_category_id IS NULL
                    AND loss_financial_event_id IS NULL
                ) OR (
                    total_loss_quantity_base > 0
                    AND loss_transaction_category_id IS NOT NULL
                    AND loss_financial_event_id IS NOT NULL
                )
            )
        ) OR (
            status = 'CANCELED'
            AND posting_idempotency_key IS NULL
            AND posted_by IS NULL AND posted_at IS NULL
            AND canceled_by IS NOT NULL AND canceled_at IS NOT NULL
            AND gain_transaction_category_id IS NULL
            AND loss_transaction_category_id IS NULL
            AND gain_financial_event_id IS NULL
            AND loss_financial_event_id IS NULL
        )
    ),
    CONSTRAINT fk_stock_adjustment_documents_company_warehouse
        FOREIGN KEY(company_id,warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_stock_adjustment_documents_company_correction
        FOREIGN KEY(company_id,correction_of_document_id)
        REFERENCES public.stock_adjustment_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_stock_adjustment_documents_company_gain_category
        FOREIGN KEY(company_id,gain_transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_stock_adjustment_documents_company_loss_category
        FOREIGN KEY(company_id,loss_transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_stock_adjustment_documents_company_gain_event
        FOREIGN KEY(company_id,gain_financial_event_id)
        REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_stock_adjustment_documents_company_loss_event
        FOREIGN KEY(company_id,loss_financial_event_id)
        REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_stock_adjustment_documents_company_status_date
    ON public.stock_adjustment_documents(
        company_id,status,adjustment_date DESC,created_at DESC
    );
CREATE INDEX idx_stock_adjustment_documents_company_warehouse
    ON public.stock_adjustment_documents(
        company_id,warehouse_id,adjustment_date DESC
    );

CREATE TABLE public.stock_adjustment_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    line_no INTEGER NOT NULL,
    product_id UUID NOT NULL,
    base_uom_id UUID NOT NULL,
    reason_id UUID NOT NULL,
    opname_detail_id UUID,
    system_quantity_snapshot NUMERIC(24,6) NOT NULL,
    final_physical_quantity NUMERIC(24,6) NOT NULL,
    calculated_difference NUMERIC(24,6) NOT NULL,
    unit_cost_base NUMERIC(24,6) NOT NULL DEFAULT 0,
    total_value NUMERIC(24,4) NOT NULL DEFAULT 0,
    cost_override_reason TEXT,
    fifo_layer_count INTEGER NOT NULL DEFAULT 0,
    product_sku_snapshot TEXT NOT NULL,
    product_name_snapshot TEXT NOT NULL,
    base_uom_name_snapshot TEXT NOT NULL,
    reason_name_snapshot TEXT NOT NULL,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT stock_adjustment_lines_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT stock_adjustment_lines_document_line_unique
        UNIQUE(company_id,document_id,line_no),
    CONSTRAINT stock_adjustment_lines_document_product_unique
        UNIQUE(company_id,document_id,product_id),
    CONSTRAINT stock_adjustment_lines_line_positive CHECK(line_no > 0),
    CONSTRAINT stock_adjustment_lines_final_nonnegative
        CHECK(final_physical_quantity >= 0),
    CONSTRAINT stock_adjustment_lines_difference_nonzero
        CHECK(calculated_difference <> 0),
    CONSTRAINT stock_adjustment_lines_difference_exact CHECK(
        calculated_difference =
            final_physical_quantity - system_quantity_snapshot
    ),
    CONSTRAINT stock_adjustment_lines_cost_nonnegative CHECK(
        unit_cost_base >= 0 AND total_value >= 0 AND fifo_layer_count >= 0
    ),
    -- Loss may span FIFO layers, so its weighted unit-cost snapshot is rounded
    -- while total_value retains the exact sum of layer allocations.
    CONSTRAINT stock_adjustment_lines_snapshot_not_blank CHECK(
        btrim(product_sku_snapshot) <> ''
        AND btrim(product_name_snapshot) <> ''
        AND btrim(base_uom_name_snapshot) <> ''
        AND btrim(reason_name_snapshot) <> ''
    ),
    CONSTRAINT fk_stock_adjustment_lines_company_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.stock_adjustment_documents(company_id,id)
        ON DELETE CASCADE,
    CONSTRAINT fk_stock_adjustment_lines_company_product
        FOREIGN KEY(company_id,product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_stock_adjustment_lines_company_uom
        FOREIGN KEY(company_id,base_uom_id)
        REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_stock_adjustment_lines_company_reason
        FOREIGN KEY(company_id,reason_id)
        REFERENCES public.stock_adjustment_reasons(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_stock_adjustment_lines_company_opname_detail
        FOREIGN KEY(company_id,opname_detail_id)
        REFERENCES public.stock_opname_details(company_id,id)
        ON DELETE RESTRICT
);
CREATE INDEX idx_stock_adjustment_lines_company_product
    ON public.stock_adjustment_lines(company_id,product_id);

ALTER TABLE public.product_batches
    ADD COLUMN stock_adjustment_line_id UUID,
    ADD CONSTRAINT fk_product_batches_company_adjustment_line
        FOREIGN KEY(company_id,stock_adjustment_line_id)
        REFERENCES public.stock_adjustment_lines(company_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT product_batches_adjustment_lineage_check CHECK(
        stock_adjustment_line_id IS NULL
        OR (
            purchase_detail_id IS NULL
            AND opening_stock_line_id IS NULL
            AND stock_transfer_line_id IS NULL
            AND source_batch_id IS NULL
        )
    );
CREATE INDEX idx_product_batches_company_adjustment_line
    ON public.product_batches(company_id,stock_adjustment_line_id)
    WHERE stock_adjustment_line_id IS NOT NULL;

ALTER TABLE public.stock_movements
    ADD CONSTRAINT stock_movements_adjustment_snapshot_complete CHECK(
        movement_type IS DISTINCT FROM
            'ADJUSTMENT'::public.stock_movement_type
        OR (
            reference_table = 'stock_adjustment_documents'
            AND base_uom_id IS NOT NULL
            AND base_uom_name_snapshot IS NOT NULL
            AND balance_after_base_qty IS NOT NULL
            AND actor_id IS NOT NULL
            AND posted_at IS NOT NULL
            AND movement_status = 'POSTED'
            AND source_line_id IS NOT NULL
        )
    );

CREATE TABLE public.stock_adjustment_fifo_allocations (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    line_id UUID NOT NULL,
    direction TEXT NOT NULL CHECK(direction IN ('GAIN','LOSS')),
    source_batch_id UUID,
    gain_batch_id UUID,
    quantity_base NUMERIC(24,6) NOT NULL,
    unit_cost_base NUMERIC(24,6) NOT NULL,
    total_value NUMERIC(24,4) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT stock_adjustment_fifo_source_unique
        UNIQUE(company_id,line_id,source_batch_id),
    CONSTRAINT stock_adjustment_fifo_gain_unique
        UNIQUE(company_id,gain_batch_id),
    CONSTRAINT stock_adjustment_fifo_shape_check CHECK(
        (direction = 'LOSS' AND source_batch_id IS NOT NULL
            AND gain_batch_id IS NULL)
        OR
        (direction = 'GAIN' AND source_batch_id IS NULL
            AND gain_batch_id IS NOT NULL)
    ),
    CONSTRAINT stock_adjustment_fifo_quantity_positive
        CHECK(quantity_base > 0),
    CONSTRAINT stock_adjustment_fifo_cost_nonnegative
        CHECK(unit_cost_base >= 0),
    CONSTRAINT stock_adjustment_fifo_value_exact CHECK(
        total_value = round(quantity_base * unit_cost_base,4)
    ),
    CONSTRAINT fk_stock_adjustment_fifo_company_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.stock_adjustment_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_stock_adjustment_fifo_company_line
        FOREIGN KEY(company_id,line_id)
        REFERENCES public.stock_adjustment_lines(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_stock_adjustment_fifo_company_source_batch
        FOREIGN KEY(company_id,source_batch_id)
        REFERENCES public.product_batches(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_stock_adjustment_fifo_company_gain_batch
        FOREIGN KEY(company_id,gain_batch_id)
        REFERENCES public.product_batches(company_id,id)
        ON DELETE RESTRICT
);

CREATE TABLE public.stock_adjustment_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    document_id UUID,
    reason_id UUID,
    action TEXT NOT NULL CHECK(action IN (
        'CREATE','UPDATE','POST','CANCEL','REASON_CREATE','REASON_UPDATE'
    )),
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT stock_adjustment_audit_target_check CHECK(
        (document_id IS NOT NULL AND reason_id IS NULL)
        OR (document_id IS NULL AND reason_id IS NOT NULL)
    ),
    CONSTRAINT fk_stock_adjustment_audit_company_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.stock_adjustment_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_stock_adjustment_audit_company_reason
        FOREIGN KEY(company_id,reason_id)
        REFERENCES public.stock_adjustment_reasons(company_id,id)
        ON DELETE RESTRICT
);

CREATE FUNCTION private.provision_stock_adjustment_reasons(p_company_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO public.stock_adjustment_reasons(
        company_id,reason_name,direction_allowed,finance_treatment,
        is_system_default
    ) VALUES
        (p_company_id,'Barang Rusak','DECREASE','STOCK_LOSS',TRUE),
        (p_company_id,'Barang Hilang','DECREASE','STOCK_LOSS',TRUE),
        (p_company_id,'Salah Input','BOTH','OTHER',TRUE),
        (p_company_id,'Selisih Stok','BOTH','OTHER',TRUE),
        (p_company_id,'Kedaluwarsa','DECREASE','STOCK_LOSS',TRUE),
        (p_company_id,'Koreksi Migrasi','BOTH','OTHER',TRUE)
    ON CONFLICT DO NOTHING;
END;
$$;

CREATE FUNCTION private.trg_provision_stock_adjustment_reasons()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM private.provision_stock_adjustment_reasons(NEW.id);
    RETURN NEW;
END;
$$;

SELECT private.provision_stock_adjustment_reasons(id)
FROM public.companies;

CREATE TRIGGER provision_stock_adjustment_reasons_after_company
AFTER INSERT ON public.companies
FOR EACH ROW EXECUTE FUNCTION
    private.trg_provision_stock_adjustment_reasons();

CREATE FUNCTION public.private_stock_adjustment_operator_allowed(
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
       AND EXISTS (
           SELECT 1
           FROM public.warehouses w
           WHERE w.company_id = p_company_id
             AND w.id = p_warehouse_id
             AND w.is_active
             AND (
                 public.private_user_has_any_company_role(
                     p_company_id,
                     ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
                 )
                 OR (
                     w.store_id IS NOT NULL
                     AND public.private_user_has_any_store_role(
                         w.store_id,ARRAY['STORE_MANAGER']::TEXT[]
                     )
                 )
             )
       );
$$;

CREATE FUNCTION private.resolve_stock_adjustment_account(
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
      ON coa.company_id = r.company_id AND coa.id = r.account_id
     AND coa.is_active AND coa.is_postable
    WHERE r.company_id = p_company_id
      AND r.transaction_category_id = p_transaction_category_id
      AND r.account_function_key = p_account_function_key
      AND r.status = 'ACTIVE'
      AND r.effective_from <= p_effective_at
      AND (r.effective_to IS NULL OR r.effective_to > p_effective_at)
    ORDER BY r.effective_from DESC,r.rule_version DESC LIMIT 1;

    IF v_account_id IS NULL THEN
        SELECT f.account_id INTO v_account_id
        FROM public.company_account_function_fallbacks f
        JOIN public.chart_of_accounts coa
          ON coa.company_id = f.company_id AND coa.id = f.account_id
         AND coa.is_active AND coa.is_postable
        WHERE f.company_id = p_company_id
          AND f.account_function_key = p_account_function_key
          AND f.status = 'ACTIVE'
          AND f.effective_from <= p_effective_at
          AND (f.effective_to IS NULL OR f.effective_to > p_effective_at)
        ORDER BY f.effective_from DESC,f.fallback_version DESC LIMIT 1;
    END IF;

    IF v_account_id IS NULL THEN
        SELECT coa.id INTO v_account_id
        FROM public.chart_of_accounts coa
        WHERE coa.company_id = p_company_id
          AND coa.system_function_key = p_account_function_key
          AND coa.is_active AND coa.is_postable
        ORDER BY coa.id LIMIT 1;
    END IF;
    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'STOCK_ADJUSTMENT_ACCOUNT_NOT_RESOLVED:%',
            p_account_function_key;
    END IF;
    RETURN v_account_id;
END;
$$;

CREATE FUNCTION public.save_stock_adjustment_reason(
    p_reason_id UUID,
    p_master_version BIGINT,
    p_reason_name TEXT,
    p_direction_allowed TEXT,
    p_finance_treatment TEXT,
    p_is_active BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_existing public.stock_adjustment_reasons%ROWTYPE;
    v_id UUID;
    v_version BIGINT;
    v_before JSONB;
    v_after JSONB;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    ) THEN
        RAISE EXCEPTION 'COMPANY_ADMIN_REQUIRED';
    END IF;
    IF NULLIF(btrim(p_reason_name),'') IS NULL THEN
        RAISE EXCEPTION 'STOCK_ADJUSTMENT_REASON_NAME_REQUIRED';
    END IF;
    IF upper(COALESCE(p_direction_allowed,'')) NOT IN (
        'INCREASE','DECREASE','BOTH'
    ) THEN RAISE EXCEPTION 'STOCK_ADJUSTMENT_REASON_DIRECTION_INVALID'; END IF;
    IF upper(COALESCE(p_finance_treatment,'')) NOT IN (
        'STOCK_GAIN','STOCK_LOSS','OTHER'
    ) THEN RAISE EXCEPTION 'STOCK_ADJUSTMENT_REASON_FINANCE_INVALID'; END IF;

    IF p_reason_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        INSERT INTO public.stock_adjustment_reasons(
            company_id,reason_name,direction_allowed,finance_treatment,
            is_active,created_by,updated_by
        ) VALUES (
            v_company,btrim(p_reason_name),upper(p_direction_allowed),
            upper(p_finance_treatment),COALESCE(p_is_active,TRUE),
            v_actor,v_actor
        ) RETURNING id,master_version INTO v_id,v_version;
    ELSE
        SELECT * INTO v_existing
        FROM public.stock_adjustment_reasons r
        WHERE r.company_id = v_company AND r.id = p_reason_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_ADJUSTMENT_REASON_NOT_FOUND'; END IF;
        IF p_master_version IS NULL
           OR p_master_version <> v_existing.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        v_before := to_jsonb(v_existing);
        UPDATE public.stock_adjustment_reasons SET
            reason_name = btrim(p_reason_name),
            direction_allowed = upper(p_direction_allowed),
            finance_treatment = upper(p_finance_treatment),
            is_active = COALESCE(p_is_active,TRUE),
            updated_by = v_actor,
            updated_at = clock_timestamp(),
            master_version = master_version + 1
        WHERE company_id = v_company AND id = p_reason_id
        RETURNING id,master_version INTO v_id,v_version;
    END IF;

    SELECT to_jsonb(r) INTO v_after
    FROM public.stock_adjustment_reasons r
    WHERE r.company_id = v_company AND r.id = v_id;
    INSERT INTO public.stock_adjustment_audit(
        company_id,reason_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_id,
        CASE WHEN p_reason_id IS NULL
            THEN 'REASON_CREATE' ELSE 'REASON_UPDATE' END,
        v_actor,v_before,v_after
    );
    RETURN jsonb_build_object(
        'reasonId',v_id,'reasonName',v_after->>'reason_name',
        'reasonCode',v_after->>'reason_code','masterVersion',v_version
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'STOCK_ADJUSTMENT_REASON_NAME_ALREADY_EXISTS';
END;
$$;

CREATE FUNCTION public.save_stock_adjustment_document(
    p_document_id UUID,
    p_master_version BIGINT,
    p_warehouse_id UUID,
    p_adjustment_date DATE,
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
    v_existing public.stock_adjustment_documents%ROWTYPE;
    v_before JSONB;
    v_after JSONB;
    v_line RECORD;
    v_product RECORD;
    v_reason RECORD;
    v_line_no INTEGER := 0;
    v_line_count INTEGER;
    v_stock NUMERIC(24,6);
    v_difference NUMERIC(24,6);
    v_suggested_cost NUMERIC(24,6);
    v_unit_cost NUMERIC(24,6);
    v_gain_qty NUMERIC(24,6);
    v_loss_qty NUMERIC(24,6);
    v_gain_value NUMERIC(24,4);
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_warehouse_id IS NULL THEN
        RAISE EXCEPTION 'STOCK_ADJUSTMENT_WAREHOUSE_REQUIRED';
    END IF;
    IF NOT public.private_stock_adjustment_operator_allowed(
        v_company,p_warehouse_id
    ) THEN RAISE EXCEPTION 'STOCK_ADJUSTMENT_OPERATOR_REQUIRED'; END IF;
    IF p_adjustment_date IS NULL THEN
        RAISE EXCEPTION 'STOCK_ADJUSTMENT_DATE_REQUIRED';
    END IF;
    IF p_adjustment_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'STOCK_ADJUSTMENT_FUTURE_DATE_NOT_ALLOWED';
    END IF;
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array'
       OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'STOCK_ADJUSTMENT_LINES_REQUIRED';
    END IF;
    IF jsonb_array_length(p_lines) > 1000 THEN
        RAISE EXCEPTION 'STOCK_ADJUSTMENT_LINE_LIMIT_EXCEEDED';
    END IF;

    IF p_document_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        v_document_no := 'ADJ-' || lpad(
            nextval('private.stock_adjustment_document_no_seq')::TEXT,10,'0'
        );
        INSERT INTO public.stock_adjustment_documents(
            company_id,document_no,warehouse_id,adjustment_date,notes,
            created_by,updated_by
        ) VALUES (
            v_company,v_document_no,p_warehouse_id,p_adjustment_date,
            NULLIF(btrim(p_notes),''),v_actor,v_actor
        ) RETURNING id,master_version
          INTO v_document_id,v_result_version;
    ELSE
        SELECT * INTO v_existing
        FROM public.stock_adjustment_documents d
        WHERE d.company_id = v_company AND d.id = p_document_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_ADJUSTMENT_NOT_FOUND'; END IF;
        IF v_existing.status <> 'DRAFT' THEN
            RAISE EXCEPTION 'FINAL_STOCK_ADJUSTMENT_IMMUTABLE';
        END IF;
        IF p_master_version IS NULL
           OR p_master_version <> v_existing.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        v_before := to_jsonb(v_existing);
        v_document_id := p_document_id;
        DELETE FROM public.stock_adjustment_lines
        WHERE company_id = v_company AND document_id = v_document_id;
    END IF;

    FOR v_line IN
        SELECT * FROM jsonb_to_recordset(p_lines) AS x(
            "productId" UUID,
            "reasonId" UUID,
            "finalPhysicalQuantity" NUMERIC,
            "unitCostBase" NUMERIC,
            "costOverrideReason" TEXT,
            "notes" TEXT
        )
    LOOP
        v_line_no := v_line_no + 1;
        IF v_line."productId" IS NULL THEN
            RAISE EXCEPTION 'STOCK_ADJUSTMENT_PRODUCT_REQUIRED';
        END IF;
        IF v_line."reasonId" IS NULL THEN
            RAISE EXCEPTION 'STOCK_ADJUSTMENT_REASON_REQUIRED';
        END IF;
        IF v_line."finalPhysicalQuantity" IS NULL
           OR v_line."finalPhysicalQuantity" < 0 THEN
            RAISE EXCEPTION
                'STOCK_ADJUSTMENT_FINAL_QUANTITY_MUST_BE_NONNEGATIVE';
        END IF;
        IF v_line."finalPhysicalQuantity" >=
            1000000000000000::NUMERIC THEN
            RAISE EXCEPTION 'STOCK_ADJUSTMENT_QUANTITY_TOO_LARGE';
        END IF;

        SELECT p.id,p.sku,p.name,p.uom_id,p.cogs,
               u.name AS uom_name,u.allow_decimal,u.decimal_precision
        INTO v_product
        FROM public.products p
        JOIN public.product_uoms pu
          ON pu.company_id = p.company_id AND pu.product_id = p.id
         AND pu.uom_id = p.uom_id AND pu.factor_to_base = 1
         AND pu.is_active
        JOIN public.uoms u
          ON u.company_id = pu.company_id AND u.id = pu.uom_id
         AND u.is_active
        WHERE p.company_id = v_company
          AND p.id = v_line."productId"
          AND p.is_active AND NOT p.is_bundle;
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND';
        END IF;
        IF NOT v_product.allow_decimal
           AND v_line."finalPhysicalQuantity" <>
               trunc(v_line."finalPhysicalQuantity") THEN
            RAISE EXCEPTION 'STOCK_ADJUSTMENT_BASE_UOM_REQUIRES_INTEGER';
        END IF;
        IF v_product.allow_decimal
           AND v_line."finalPhysicalQuantity" <> round(
               v_line."finalPhysicalQuantity",v_product.decimal_precision
           ) THEN
            RAISE EXCEPTION 'STOCK_ADJUSTMENT_BASE_UOM_PRECISION_EXCEEDED';
        END IF;

        SELECT r.id,r.reason_name,r.direction_allowed
        INTO v_reason
        FROM public.stock_adjustment_reasons r
        WHERE r.company_id = v_company
          AND r.id = v_line."reasonId" AND r.is_active;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'ACTIVE_STOCK_ADJUSTMENT_REASON_NOT_FOUND';
        END IF;

        SELECT COALESCE(ps.stock_qty,0) INTO v_stock
        FROM public.product_stocks ps
        WHERE ps.company_id = v_company
          AND ps.product_id = v_product.id
          AND ps.warehouse_id = p_warehouse_id;
        v_stock := COALESCE(v_stock,0);
        v_difference := v_line."finalPhysicalQuantity" - v_stock;
        IF v_difference = 0 THEN
            RAISE EXCEPTION 'STOCK_ADJUSTMENT_NO_DIFFERENCE';
        END IF;
        IF v_difference > 0
           AND v_reason.direction_allowed = 'DECREASE' THEN
            RAISE EXCEPTION 'STOCK_ADJUSTMENT_REASON_DIRECTION_MISMATCH';
        END IF;
        IF v_difference < 0
           AND v_reason.direction_allowed = 'INCREASE' THEN
            RAISE EXCEPTION 'STOCK_ADJUSTMENT_REASON_DIRECTION_MISMATCH';
        END IF;

        IF v_difference > 0 THEN
            SELECT b.cogs_unit INTO v_suggested_cost
            FROM public.product_batches b
            WHERE b.company_id = v_company
              AND b.product_id = v_product.id
              AND b.cogs_unit >= 0
            ORDER BY b.created_at DESC,b.id DESC LIMIT 1;
            v_suggested_cost := COALESCE(v_suggested_cost,v_product.cogs,0);
            v_unit_cost := COALESCE(
                v_line."unitCostBase",v_suggested_cost
            );
            IF v_unit_cost < 0 THEN
                RAISE EXCEPTION 'STOCK_ADJUSTMENT_UNIT_COST_INVALID';
            END IF;
            IF v_unit_cost IS DISTINCT FROM v_suggested_cost
               AND NULLIF(btrim(v_line."costOverrideReason"),'') IS NULL THEN
                RAISE EXCEPTION
                    'STOCK_ADJUSTMENT_COST_OVERRIDE_REASON_REQUIRED';
            END IF;
        ELSE
            v_unit_cost := 0;
        END IF;

        INSERT INTO public.stock_adjustment_lines(
            company_id,document_id,line_no,product_id,base_uom_id,
            reason_id,system_quantity_snapshot,final_physical_quantity,
            calculated_difference,unit_cost_base,total_value,
            cost_override_reason,product_sku_snapshot,
            product_name_snapshot,base_uom_name_snapshot,
            reason_name_snapshot,notes
        ) VALUES (
            v_company,v_document_id,v_line_no,v_product.id,
            v_product.uom_id,v_reason.id,v_stock,
            v_line."finalPhysicalQuantity",v_difference,v_unit_cost,
            round(abs(v_difference) * v_unit_cost,4),
            NULLIF(btrim(v_line."costOverrideReason"),''),
            v_product.sku,v_product.name,v_product.uom_name,
            v_reason.reason_name,NULLIF(btrim(v_line."notes"),'')
        );
    END LOOP;

    SELECT count(*),
           COALESCE(sum(calculated_difference)
               FILTER(WHERE calculated_difference > 0),0),
           COALESCE(sum(abs(calculated_difference))
               FILTER(WHERE calculated_difference < 0),0),
           COALESCE(sum(total_value)
               FILTER(WHERE calculated_difference > 0),0)
    INTO v_line_count,v_gain_qty,v_loss_qty,v_gain_value
    FROM public.stock_adjustment_lines
    WHERE company_id = v_company AND document_id = v_document_id;

    UPDATE public.stock_adjustment_documents SET
        warehouse_id = p_warehouse_id,
        adjustment_date = p_adjustment_date,
        notes = NULLIF(btrim(p_notes),''),
        line_count = v_line_count,
        total_gain_quantity_base = v_gain_qty,
        total_loss_quantity_base = v_loss_qty,
        total_gain_value = v_gain_value,
        total_loss_value = 0,
        updated_by = v_actor,
        updated_at = clock_timestamp(),
        master_version = CASE WHEN p_document_id IS NULL
            THEN master_version ELSE master_version + 1 END
    WHERE company_id = v_company AND id = v_document_id
    RETURNING master_version INTO v_result_version;

    SELECT to_jsonb(d) INTO v_after
    FROM public.stock_adjustment_documents d
    WHERE d.company_id = v_company AND d.id = v_document_id;
    INSERT INTO public.stock_adjustment_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_document_id,
        CASE WHEN p_document_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
        v_actor,v_before,v_after
    );
    RETURN jsonb_build_object(
        'documentId',v_document_id,'documentNo',v_after->>'document_no',
        'status','DRAFT','masterVersion',v_result_version,
        'lineCount',v_line_count,'totalGainQuantityBase',v_gain_qty,
        'totalLossQuantityBase',v_loss_qty
    );
END;
$$;

CREATE FUNCTION public.post_stock_adjustment(
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
    v_document public.stock_adjustment_documents%ROWTYPE;
    v_line public.stock_adjustment_lines%ROWTYPE;
    v_batch RECORD;
    v_before JSONB;
    v_after JSONB;
    v_current_stock NUMERIC(24,6);
    v_remaining NUMERIC(24,6);
    v_take NUMERIC(24,6);
    v_line_value NUMERIC(24,4);
    v_total_gain NUMERIC(24,4) := 0;
    v_total_loss NUMERIC(24,4) := 0;
    v_layer_count INTEGER;
    v_gain_batch_id UUID;
    v_gain_category_id UUID;
    v_loss_category_id UUID;
    v_inventory_account_id UUID;
    v_counter_account_id UUID;
    v_inventory_account RECORD;
    v_counter_account RECORD;
    v_gain_event_id UUID;
    v_loss_event_id UUID;
    v_store_id UUID;
    v_result_version BIGINT;
    v_posted_at TIMESTAMPTZ := clock_timestamp();
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED';
    END IF;

    SELECT * INTO v_document
    FROM public.stock_adjustment_documents d
    WHERE d.company_id = v_company AND d.id = p_document_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_ADJUSTMENT_NOT_FOUND'; END IF;
    IF NOT public.private_stock_adjustment_operator_allowed(
        v_company,v_document.warehouse_id
    ) THEN RAISE EXCEPTION 'STOCK_ADJUSTMENT_OPERATOR_REQUIRED'; END IF;

    IF v_document.status = 'POSTED' THEN
        IF v_document.posting_idempotency_key = p_idempotency_key THEN
            RETURN jsonb_build_object(
                'documentId',v_document.id,
                'documentNo',v_document.document_no,
                'status','POSTED','masterVersion',v_document.master_version,
                'gainFinancialEventId',v_document.gain_financial_event_id,
                'lossFinancialEventId',v_document.loss_financial_event_id,
                'idempotentReplay',TRUE
            );
        END IF;
        RAISE EXCEPTION 'STOCK_ADJUSTMENT_ALREADY_POSTED';
    END IF;
    IF v_document.status = 'CANCELED' THEN
        RAISE EXCEPTION 'CANCELED_STOCK_ADJUSTMENT_IMMUTABLE';
    END IF;
    IF p_master_version IS NULL
       OR p_master_version <> v_document.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_document.line_count <= 0 THEN
        RAISE EXCEPTION 'STOCK_ADJUSTMENT_LINES_REQUIRED';
    END IF;

    SELECT w.store_id INTO v_store_id
    FROM public.warehouses w
    WHERE w.company_id = v_company
      AND w.id = v_document.warehouse_id AND w.is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_WAREHOUSE_NOT_FOUND'; END IF;
    v_before := to_jsonb(v_document);

    IF v_document.total_gain_quantity_base > 0 THEN
        SELECT tc.id INTO v_gain_category_id
        FROM public.transaction_categories tc
        WHERE tc.company_id = v_company
          AND tc.system_key = 'STOCK_GAIN'
          AND tc.is_active AND tc.is_system_default
        ORDER BY tc.id LIMIT 1;
        IF v_gain_category_id IS NULL THEN
            RAISE EXCEPTION
                'STOCK_GAIN_TRANSACTION_CATEGORY_NOT_FOUND';
        END IF;
    END IF;
    IF v_document.total_loss_quantity_base > 0 THEN
        SELECT tc.id INTO v_loss_category_id
        FROM public.transaction_categories tc
        WHERE tc.company_id = v_company
          AND tc.system_key = 'STOCK_LOSS'
          AND tc.is_active AND tc.is_system_default
        ORDER BY tc.id LIMIT 1;
        IF v_loss_category_id IS NULL THEN
            RAISE EXCEPTION
                'STOCK_LOSS_TRANSACTION_CATEGORY_NOT_FOUND';
        END IF;
    END IF;

    FOR v_line IN
        SELECT *
        FROM public.stock_adjustment_lines l
        WHERE l.company_id = v_company
          AND l.document_id = v_document.id
        ORDER BY l.product_id
    LOOP
        PERFORM pg_advisory_xact_lock(hashtextextended(
            v_company::TEXT || ':STOCK:' || v_line.product_id::TEXT ||
            ':' || v_document.warehouse_id::TEXT,0
        ));

        SELECT ps.stock_qty INTO v_current_stock
        FROM public.product_stocks ps
        WHERE ps.company_id = v_company
          AND ps.product_id = v_line.product_id
          AND ps.warehouse_id = v_document.warehouse_id
        FOR UPDATE;
        v_current_stock := COALESCE(v_current_stock,0);
        IF v_current_stock IS DISTINCT FROM
            v_line.system_quantity_snapshot THEN
            RAISE EXCEPTION 'STOCK_ADJUSTMENT_STOCK_CHANGED';
        END IF;

        v_line_value := 0;
        v_layer_count := 0;
        IF v_line.calculated_difference < 0 THEN
            v_remaining := abs(v_line.calculated_difference);
            IF v_current_stock < v_remaining THEN
                RAISE EXCEPTION 'INSUFFICIENT_STOCK';
            END IF;
            FOR v_batch IN
                SELECT b.*
                FROM public.product_batches b
                WHERE b.company_id = v_company
                  AND b.product_id = v_line.product_id
                  AND b.warehouse_id = v_document.warehouse_id
                  AND b.qty_remaining > 0
                ORDER BY b.created_at,b.id
                FOR UPDATE
            LOOP
                EXIT WHEN v_remaining <= 0;
                v_take := LEAST(v_remaining,v_batch.qty_remaining);
                UPDATE public.product_batches SET
                    qty_remaining = qty_remaining - v_take
                WHERE company_id = v_company AND id = v_batch.id;
                INSERT INTO public.stock_adjustment_fifo_allocations(
                    company_id,document_id,line_id,direction,
                    source_batch_id,quantity_base,unit_cost_base,total_value
                ) VALUES (
                    v_company,v_document.id,v_line.id,'LOSS',v_batch.id,
                    v_take,v_batch.cogs_unit,
                    round(v_take * v_batch.cogs_unit,4)
                );
                v_line_value := v_line_value +
                    round(v_take * v_batch.cogs_unit,4);
                v_layer_count := v_layer_count + 1;
                v_remaining := v_remaining - v_take;
            END LOOP;
            IF v_remaining <> 0 THEN
                RAISE EXCEPTION 'INSUFFICIENT_FIFO_STOCK';
            END IF;
            v_total_loss := v_total_loss + v_line_value;
        ELSE
            INSERT INTO public.product_batches(
                product_id,warehouse_id,purchase_detail_id,
                qty_purchased,qty_remaining,cogs_unit,company_id,
                stock_adjustment_line_id
            ) VALUES (
                v_line.product_id,v_document.warehouse_id,NULL,
                v_line.calculated_difference,v_line.calculated_difference,
                v_line.unit_cost_base,v_company,v_line.id
            ) RETURNING id INTO v_gain_batch_id;
            v_line_value := round(
                v_line.calculated_difference * v_line.unit_cost_base,4
            );
            v_layer_count := 1;
            INSERT INTO public.stock_adjustment_fifo_allocations(
                company_id,document_id,line_id,direction,gain_batch_id,
                quantity_base,unit_cost_base,total_value
            ) VALUES (
                v_company,v_document.id,v_line.id,'GAIN',v_gain_batch_id,
                v_line.calculated_difference,v_line.unit_cost_base,
                v_line_value
            );
            v_total_gain := v_total_gain + v_line_value;
        END IF;

        INSERT INTO public.product_stocks(
            product_id,warehouse_id,stock_qty,company_id
        ) VALUES (
            v_line.product_id,v_document.warehouse_id,
            v_line.final_physical_quantity,v_company
        )
        ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
            stock_qty = EXCLUDED.stock_qty,
            updated_at = clock_timestamp();

        INSERT INTO public.stock_movements(
            product_id,warehouse_id,qty_change,movement_type,
            reference_table,reference_id,company_id,
            base_uom_id,base_uom_name_snapshot,balance_after_base_qty,
            actor_id,posted_at,movement_status,source_line_id,notes
        ) VALUES (
            v_line.product_id,v_document.warehouse_id,
            v_line.calculated_difference,
            'ADJUSTMENT'::public.stock_movement_type,
            'stock_adjustment_documents',v_document.id,v_company,
            v_line.base_uom_id,v_line.base_uom_name_snapshot,
            v_line.final_physical_quantity,v_actor,v_posted_at,
            'POSTED',v_line.id,COALESCE(v_line.notes,v_document.notes)
        );

        UPDATE public.stock_adjustment_lines SET
            unit_cost_base = CASE
                WHEN calculated_difference < 0
                    THEN CASE WHEN calculated_difference = 0 THEN 0
                        ELSE round(
                            v_line_value / abs(calculated_difference),6
                        ) END
                ELSE unit_cost_base
            END,
            total_value = v_line_value,
            fifo_layer_count = v_layer_count
        WHERE company_id = v_company AND id = v_line.id;
    END LOOP;

    IF v_total_gain > 0 THEN
        v_inventory_account_id := private.resolve_stock_adjustment_account(
            v_company,v_gain_category_id,'INVENTORY_ASSET',v_posted_at
        );
        v_counter_account_id := private.resolve_stock_adjustment_account(
            v_company,v_gain_category_id,'STOCK_GAIN_INCOME',v_posted_at
        );
        SELECT id,account_code,account_name INTO v_inventory_account
        FROM public.chart_of_accounts
        WHERE company_id = v_company AND id = v_inventory_account_id;
        SELECT id,account_code,account_name INTO v_counter_account
        FROM public.chart_of_accounts
        WHERE company_id = v_company AND id = v_counter_account_id;

        INSERT INTO public.financial_events(
            event_code,event_type,source_table,source_id,root_sales_id,
            event_date,event_version,idempotency_key,amounts,status,
            error_message,created_by,company_id,store_id,
            system_event_key,transaction_category_id
        ) VALUES (
            'STOCK-GAIN-' || replace(v_document.id::TEXT,'-',''),
            'STOCK_GAIN'::public.event_type,
            'stock_adjustment_documents',v_document.id,NULL,
            v_posted_at,1,
            'STOCK_ADJUSTMENT_GAIN|' || v_company::TEXT || '|' ||
                p_idempotency_key::TEXT,
            jsonb_build_object(
                'inventoryDebit',v_total_gain,
                'stockGainCredit',v_total_gain,
                'warehouseId',v_document.warehouse_id,
                'inventoryAccountId',v_inventory_account.id,
                'inventoryAccountCode',v_inventory_account.account_code,
                'inventoryAccountName',v_inventory_account.account_name,
                'counterAccountId',v_counter_account.id,
                'counterAccountCode',v_counter_account.account_code,
                'counterAccountName',v_counter_account.account_name,
                'financePostingState','HOLD_UNTIL_G6'
            ),
            'HOLD'::public.event_status,
            'CANONICAL_FINANCE_POSTING_NOT_ENABLED',
            v_actor,v_company,v_store_id,'STOCK_GAIN',v_gain_category_id
        ) RETURNING id INTO v_gain_event_id;
    END IF;

    IF v_total_loss > 0 THEN
        v_inventory_account_id := private.resolve_stock_adjustment_account(
            v_company,v_loss_category_id,'INVENTORY_ASSET',v_posted_at
        );
        v_counter_account_id := private.resolve_stock_adjustment_account(
            v_company,v_loss_category_id,'STOCK_LOSS_EXPENSE',v_posted_at
        );
        SELECT id,account_code,account_name INTO v_inventory_account
        FROM public.chart_of_accounts
        WHERE company_id = v_company AND id = v_inventory_account_id;
        SELECT id,account_code,account_name INTO v_counter_account
        FROM public.chart_of_accounts
        WHERE company_id = v_company AND id = v_counter_account_id;

        INSERT INTO public.financial_events(
            event_code,event_type,source_table,source_id,root_sales_id,
            event_date,event_version,idempotency_key,amounts,status,
            error_message,created_by,company_id,store_id,
            system_event_key,transaction_category_id
        ) VALUES (
            'STOCK-LOSS-' || replace(v_document.id::TEXT,'-',''),
            'STOCK_LOSS'::public.event_type,
            'stock_adjustment_documents',v_document.id,NULL,
            v_posted_at,1,
            'STOCK_ADJUSTMENT_LOSS|' || v_company::TEXT || '|' ||
                p_idempotency_key::TEXT,
            jsonb_build_object(
                'stockLossDebit',v_total_loss,
                'inventoryCredit',v_total_loss,
                'warehouseId',v_document.warehouse_id,
                'inventoryAccountId',v_inventory_account.id,
                'inventoryAccountCode',v_inventory_account.account_code,
                'inventoryAccountName',v_inventory_account.account_name,
                'counterAccountId',v_counter_account.id,
                'counterAccountCode',v_counter_account.account_code,
                'counterAccountName',v_counter_account.account_name,
                'financePostingState','HOLD_UNTIL_G6'
            ),
            'HOLD'::public.event_status,
            'CANONICAL_FINANCE_POSTING_NOT_ENABLED',
            v_actor,v_company,v_store_id,'STOCK_LOSS',v_loss_category_id
        ) RETURNING id INTO v_loss_event_id;
    END IF;

    UPDATE public.stock_adjustment_documents SET
        status = 'POSTED',
        posting_idempotency_key = p_idempotency_key,
        gain_transaction_category_id = v_gain_category_id,
        loss_transaction_category_id = v_loss_category_id,
        gain_financial_event_id = v_gain_event_id,
        loss_financial_event_id = v_loss_event_id,
        total_gain_value = v_total_gain,
        total_loss_value = v_total_loss,
        posted_by = v_actor,posted_at = v_posted_at,
        updated_by = v_actor,updated_at = v_posted_at,
        master_version = master_version + 1
    WHERE company_id = v_company AND id = v_document.id
    RETURNING master_version INTO v_result_version;

    SELECT to_jsonb(d) INTO v_after
    FROM public.stock_adjustment_documents d
    WHERE d.company_id = v_company AND d.id = v_document.id;
    INSERT INTO public.stock_adjustment_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_document.id,'POST',v_actor,v_before,v_after
    );
    RETURN jsonb_build_object(
        'documentId',v_document.id,'documentNo',v_document.document_no,
        'status','POSTED','masterVersion',v_result_version,
        'totalGainValue',v_total_gain,'totalLossValue',v_total_loss,
        'gainFinancialEventId',v_gain_event_id,
        'lossFinancialEventId',v_loss_event_id,
        'idempotentReplay',FALSE
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'STOCK_ADJUSTMENT_IDEMPOTENCY_CONFLICT';
END;
$$;

CREATE FUNCTION public.cancel_stock_adjustment(
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
    v_document public.stock_adjustment_documents%ROWTYPE;
    v_before JSONB;
    v_after JSONB;
    v_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    SELECT * INTO v_document
    FROM public.stock_adjustment_documents d
    WHERE d.company_id = v_company AND d.id = p_document_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_ADJUSTMENT_NOT_FOUND'; END IF;
    IF NOT public.private_stock_adjustment_operator_allowed(
        v_company,v_document.warehouse_id
    ) THEN RAISE EXCEPTION 'STOCK_ADJUSTMENT_OPERATOR_REQUIRED'; END IF;
    IF v_document.status <> 'DRAFT' THEN
        RAISE EXCEPTION 'FINAL_STOCK_ADJUSTMENT_IMMUTABLE';
    END IF;
    IF p_master_version IS NULL
       OR p_master_version <> v_document.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before := to_jsonb(v_document);
    UPDATE public.stock_adjustment_documents SET
        status = 'CANCELED',canceled_by = v_actor,
        canceled_at = clock_timestamp(),updated_by = v_actor,
        updated_at = clock_timestamp(),master_version = master_version + 1
    WHERE company_id = v_company AND id = v_document.id
    RETURNING master_version INTO v_version;
    SELECT to_jsonb(d) INTO v_after
    FROM public.stock_adjustment_documents d
    WHERE d.company_id = v_company AND d.id = v_document.id;
    INSERT INTO public.stock_adjustment_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_document.id,'CANCEL',v_actor,v_before,v_after
    );
    RETURN jsonb_build_object(
        'documentId',v_document.id,'documentNo',v_document.document_no,
        'status','CANCELED','masterVersion',v_version
    );
END;
$$;

REVOKE ALL ON FUNCTION private.provision_stock_adjustment_reasons(UUID)
FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.trg_provision_stock_adjustment_reasons()
FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.resolve_stock_adjustment_account(
    UUID,UUID,TEXT,TIMESTAMPTZ
) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.private_stock_adjustment_operator_allowed(
    UUID,UUID
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.save_stock_adjustment_reason(
    UUID,BIGINT,TEXT,TEXT,TEXT,BOOLEAN
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.save_stock_adjustment_document(
    UUID,BIGINT,UUID,DATE,TEXT,JSONB
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.post_stock_adjustment(UUID,BIGINT,UUID)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.cancel_stock_adjustment(UUID,BIGINT)
FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION private.provision_stock_adjustment_reasons(UUID),
    private.trg_provision_stock_adjustment_reasons(),
    private.resolve_stock_adjustment_account(UUID,UUID,TEXT,TIMESTAMPTZ)
TO service_role;
GRANT EXECUTE ON FUNCTION public.private_stock_adjustment_operator_allowed(
    UUID,UUID
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.save_stock_adjustment_reason(
    UUID,BIGINT,TEXT,TEXT,TEXT,BOOLEAN
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.save_stock_adjustment_document(
    UUID,BIGINT,UUID,DATE,TEXT,JSONB
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.post_stock_adjustment(UUID,BIGINT,UUID),
    public.cancel_stock_adjustment(UUID,BIGINT)
TO authenticated,service_role;

ALTER TABLE public.stock_adjustment_reasons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_adjustment_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_adjustment_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_adjustment_fifo_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_adjustment_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Adjustment reasons readable by inventory reviewers"
ON public.stock_adjustment_reasons FOR SELECT TO authenticated
USING (public.private_inventory_reviewer_visible(company_id));
CREATE POLICY "Adjustment documents readable by inventory reviewers"
ON public.stock_adjustment_documents FOR SELECT TO authenticated
USING (public.private_inventory_reviewer_visible(company_id));
CREATE POLICY "Adjustment lines readable by inventory reviewers"
ON public.stock_adjustment_lines FOR SELECT TO authenticated
USING (public.private_inventory_reviewer_visible(company_id));
CREATE POLICY "Adjustment FIFO readable by inventory reviewers"
ON public.stock_adjustment_fifo_allocations FOR SELECT TO authenticated
USING (public.private_inventory_reviewer_visible(company_id));
CREATE POLICY "Adjustment audit readable by inventory reviewers"
ON public.stock_adjustment_audit FOR SELECT TO authenticated
USING (public.private_inventory_reviewer_visible(company_id));

REVOKE ALL ON public.stock_adjustment_reasons,
    public.stock_adjustment_documents,public.stock_adjustment_lines,
    public.stock_adjustment_fifo_allocations,public.stock_adjustment_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.stock_adjustment_reasons,
    public.stock_adjustment_documents,public.stock_adjustment_lines,
    public.stock_adjustment_fifo_allocations,public.stock_adjustment_audit
TO authenticated;
GRANT ALL ON public.stock_adjustment_reasons,
    public.stock_adjustment_documents,public.stock_adjustment_lines,
    public.stock_adjustment_fifo_allocations,public.stock_adjustment_audit
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260728210000',
    'g3_phase8_stock_adjustment_foundation',
    'Canonical final-physical-quantity Adjustment with reusable reason master, Draft/Posted/Canceled workflow, FIFO gain/loss, immutable Movement, HOLD Finance events, role guard, idempotency, and audit'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
