-- KGS POS G3 phase 10: canonical non-blocking Stock Opname foundation.
-- Dependency: canonical Stock Adjustment through 20260728210000.
--
-- Cashiers count through blind-safe RPCs. Stock remains operational while a
-- session is open. Posting applies the variance-at-count to current stock via
-- one canonical Stock Adjustment transaction.

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260728210000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: canonical Stock Adjustment missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260728230000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260728230000';
    END IF;
    IF EXISTS (SELECT 1 FROM public.stock_opnames)
       OR EXISTS (SELECT 1 FROM public.stock_opname_details) THEN
        RAISE EXCEPTION
            'G3_PHASE10_STATE_CHANGED: legacy Opname requires explicit backfill';
    END IF;
    IF to_regclass('public.stock_opname_count_attempts') IS NOT NULL
       OR to_regclass('public.stock_opname_audit') IS NOT NULL THEN
        RAISE EXCEPTION
            'G3_PHASE10_STATE_CHANGED: canonical Opname table exists';
    END IF;
END
$migration_guard$;

-- PostgreSQL requires a newly added enum label to be committed before it can
-- be used. These additive labels are the only non-rollbackable part; rerunning
-- remains safe because every statement uses IF NOT EXISTS.
ALTER TYPE public.opname_status ADD VALUE IF NOT EXISTS 'COUNTING';
ALTER TYPE public.opname_status ADD VALUE IF NOT EXISTS 'COMPLETED';
ALTER TYPE public.opname_status ADD VALUE IF NOT EXISTS 'POSTED';
ALTER TYPE public.opname_status ADD VALUE IF NOT EXISTS 'CANCELED';

COMMIT;
BEGIN;

DO $transaction_guard$
BEGIN
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260728230000'
    ) OR EXISTS (SELECT 1 FROM public.stock_opnames)
       OR EXISTS (SELECT 1 FROM public.stock_opname_details)
       OR to_regclass('public.stock_opname_count_attempts') IS NOT NULL
       OR to_regclass('public.stock_opname_audit') IS NOT NULL THEN
        RAISE EXCEPTION
            'G3_PHASE10_STATE_CHANGED: rerun preflight before retry';
    END IF;
END
$transaction_guard$;

CREATE SEQUENCE private.stock_opname_no_seq;
REVOKE ALL ON SEQUENCE private.stock_opname_no_seq
FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.stock_opname_no_seq TO service_role;

ALTER TABLE public.stock_opnames
    ALTER COLUMN created_by SET NOT NULL,
    ADD COLUMN scope_type TEXT NOT NULL DEFAULT 'ALL',
    ADD COLUMN category_id UUID,
    ADD COLUMN count_started_at TIMESTAMPTZ,
    ADD COLUMN movement_watermark_at TIMESTAMPTZ,
    ADD COLUMN completed_by UUID REFERENCES public.profiles(id),
    ADD COLUMN completed_at TIMESTAMPTZ,
    ADD COLUMN reviewed_by UUID REFERENCES public.profiles(id),
    ADD COLUMN reviewed_at TIMESTAMPTZ,
    ADD COLUMN adjustment_document_id UUID,
    ADD COLUMN posting_idempotency_key UUID,
    ADD COLUMN posted_by UUID REFERENCES public.profiles(id),
    ADD COLUMN posted_at TIMESTAMPTZ,
    ADD COLUMN canceled_by UUID REFERENCES public.profiles(id),
    ADD COLUMN canceled_at TIMESTAMPTZ,
    ADD COLUMN master_version BIGINT NOT NULL DEFAULT 1,
    ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    ADD CONSTRAINT stock_opnames_scope_check
        CHECK(scope_type IN ('ALL','CATEGORY','SELECTED')),
    ADD CONSTRAINT stock_opnames_scope_category_check CHECK(
        (scope_type = 'CATEGORY' AND category_id IS NOT NULL)
        OR (scope_type <> 'CATEGORY' AND category_id IS NULL)
    ),
    ADD CONSTRAINT stock_opnames_version_positive CHECK(master_version > 0),
    ADD CONSTRAINT stock_opnames_company_post_key_unique
        UNIQUE(company_id,posting_idempotency_key),
    ADD CONSTRAINT fk_stock_opnames_company_category
        FOREIGN KEY(company_id,category_id)
        REFERENCES public.product_categories(company_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT fk_stock_opnames_company_adjustment
        FOREIGN KEY(company_id,adjustment_document_id)
        REFERENCES public.stock_adjustment_documents(company_id,id)
        ON DELETE RESTRICT;

CREATE INDEX idx_stock_opnames_company_status_created
    ON public.stock_opnames(company_id,status,created_at DESC);

ALTER TABLE public.stock_opname_details
    ADD COLUMN line_status TEXT NOT NULL DEFAULT 'PENDING',
    ADD COLUMN base_uom_id UUID NOT NULL,
    ADD COLUMN system_qty_at_start NUMERIC(24,6) NOT NULL DEFAULT 0,
    ADD COLUMN expected_qty_at_count NUMERIC(24,6),
    ADD COLUMN variance_at_count NUMERIC(24,6),
    ADD COLUMN count_started_at TIMESTAMPTZ,
    ADD COLUMN counted_at TIMESTAMPTZ,
    ADD COLUMN counter_id UUID REFERENCES public.profiles(id),
    ADD COLUMN movement_watermark_at TIMESTAMPTZ,
    ADD COLUMN superseded_by_line_id UUID,
    ADD COLUMN recount_requested_by UUID REFERENCES public.profiles(id),
    ADD COLUMN recount_requested_at TIMESTAMPTZ,
    ADD COLUMN adjustment_line_id UUID,
    ADD COLUMN product_sku_snapshot TEXT NOT NULL,
    ADD COLUMN product_name_snapshot TEXT NOT NULL,
    ADD COLUMN base_uom_name_snapshot TEXT NOT NULL,
    ADD CONSTRAINT stock_opname_details_session_product_unique
        UNIQUE(company_id,opname_id,product_id),
    ADD CONSTRAINT stock_opname_details_line_status_check CHECK(
        line_status IN (
            'PENDING','COUNTED','RECOUNT_REQUIRED','SUPERSEDED','POSTED'
        )
    ),
    ADD CONSTRAINT stock_opname_details_quantity_nonnegative CHECK(
        system_qty_at_start >= 0
        AND system_qty >= 0
        AND physical_qty >= 0
        AND (expected_qty_at_count IS NULL OR expected_qty_at_count >= 0)
    ),
    ADD CONSTRAINT stock_opname_details_variance_exact CHECK(
        variance_at_count IS NULL
        OR (
            expected_qty_at_count IS NOT NULL
            AND variance_at_count = physical_qty - expected_qty_at_count
            AND difference = variance_at_count
        )
    ),
    ADD CONSTRAINT stock_opname_details_count_shape CHECK(
        (
            line_status = 'PENDING'
            AND counted_at IS NULL
            AND expected_qty_at_count IS NULL
            AND variance_at_count IS NULL
        ) OR (
            line_status IN ('COUNTED','RECOUNT_REQUIRED','POSTED')
            AND counted_at IS NOT NULL
            AND counter_id IS NOT NULL
            AND expected_qty_at_count IS NOT NULL
            AND variance_at_count IS NOT NULL
        ) OR line_status = 'SUPERSEDED'
    ),
    ADD CONSTRAINT fk_opname_details_company_base_uom
        FOREIGN KEY(company_id,base_uom_id)
        REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_opname_details_company_superseded_by
        FOREIGN KEY(company_id,superseded_by_line_id)
        REFERENCES public.stock_opname_details(company_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT fk_opname_details_company_adjustment_line
        FOREIGN KEY(company_id,adjustment_line_id)
        REFERENCES public.stock_adjustment_lines(company_id,id)
        ON DELETE RESTRICT;

CREATE INDEX idx_opname_details_company_status_product
    ON public.stock_opname_details(company_id,line_status,product_id);
CREATE UNIQUE INDEX uq_opname_details_active_adjustment_line
    ON public.stock_opname_details(company_id,adjustment_line_id)
    WHERE adjustment_line_id IS NOT NULL;

CREATE TABLE public.stock_opname_count_attempts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    opname_id UUID NOT NULL,
    opname_detail_id UUID NOT NULL,
    attempt_no INTEGER NOT NULL,
    physical_qty NUMERIC(24,6) NOT NULL,
    count_started_at TIMESTAMPTZ NOT NULL,
    counted_at TIMESTAMPTZ NOT NULL,
    counter_id UUID NOT NULL REFERENCES public.profiles(id),
    movement_count_in_window BIGINT NOT NULL,
    result_status TEXT NOT NULL,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT stock_opname_attempts_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT stock_opname_attempts_line_attempt_unique
        UNIQUE(company_id,opname_detail_id,attempt_no),
    CONSTRAINT stock_opname_attempts_positive
        CHECK(attempt_no > 0 AND physical_qty >= 0
              AND movement_count_in_window >= 0),
    CONSTRAINT stock_opname_attempts_status_check
        CHECK(result_status IN ('COUNTED','RECOUNT_REQUIRED')),
    CONSTRAINT fk_stock_opname_attempts_company_opname
        FOREIGN KEY(company_id,opname_id)
        REFERENCES public.stock_opnames(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_stock_opname_attempts_company_detail
        FOREIGN KEY(company_id,opname_detail_id)
        REFERENCES public.stock_opname_details(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_stock_opname_attempts_detail_created
    ON public.stock_opname_count_attempts(
        company_id,opname_detail_id,created_at DESC
    );

CREATE TABLE public.stock_opname_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    opname_id UUID NOT NULL,
    opname_detail_id UUID,
    action TEXT NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT stock_opname_audit_action_check CHECK(
        action IN (
            'CREATE','UPDATE','START','COUNT','COMPLETE',
            'REQUEST_RECOUNT','SUPERSEDE','POST','CANCEL'
        )
    ),
    CONSTRAINT fk_stock_opname_audit_company_opname
        FOREIGN KEY(company_id,opname_id)
        REFERENCES public.stock_opnames(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_stock_opname_audit_company_detail
        FOREIGN KEY(company_id,opname_detail_id)
        REFERENCES public.stock_opname_details(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_stock_opname_audit_opname_created
    ON public.stock_opname_audit(company_id,opname_id,created_at DESC);

CREATE FUNCTION public.private_stock_opname_counter_allowed(
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
                         w.store_id,
                         ARRAY['CASHIER','STORE_MANAGER']::TEXT[]
                     )
                 )
             )
       );
$$;

CREATE FUNCTION public.save_stock_opname_session(
    p_opname_id UUID,
    p_master_version BIGINT,
    p_warehouse_id UUID,
    p_scope_type TEXT,
    p_category_id UUID,
    p_product_ids JSONB,
    p_notes TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_id UUID;
    v_no TEXT;
    v_scope TEXT := upper(btrim(COALESCE(p_scope_type,'')));
    v_existing public.stock_opnames%ROWTYPE;
    v_before JSONB;
    v_after JSONB;
    v_version BIGINT;
    v_line_count INTEGER;
    v_selected_count INTEGER;
    v_selected_distinct_count INTEGER;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_stock_opname_counter_allowed(
        v_company,p_warehouse_id
    ) THEN RAISE EXCEPTION 'STOCK_OPNAME_COUNTER_REQUIRED'; END IF;
    IF v_scope NOT IN ('ALL','CATEGORY','SELECTED') THEN
        RAISE EXCEPTION 'STOCK_OPNAME_SCOPE_INVALID';
    END IF;
    IF (v_scope = 'CATEGORY') IS DISTINCT FROM (p_category_id IS NOT NULL) THEN
        RAISE EXCEPTION 'STOCK_OPNAME_CATEGORY_SCOPE_INVALID';
    END IF;
    IF v_scope = 'CATEGORY' AND NOT EXISTS (
        SELECT 1 FROM public.product_categories c
        WHERE c.company_id = v_company AND c.id = p_category_id
          AND c.is_active
    ) THEN RAISE EXCEPTION 'ACTIVE_PRODUCT_CATEGORY_NOT_FOUND'; END IF;
    IF v_scope = 'SELECTED'
       AND (
           p_product_ids IS NULL
           OR jsonb_typeof(p_product_ids) <> 'array'
           OR jsonb_array_length(p_product_ids) = 0
       ) THEN RAISE EXCEPTION 'STOCK_OPNAME_SELECTED_PRODUCTS_REQUIRED'; END IF;
    IF v_scope = 'SELECTED' THEN
        v_selected_count := jsonb_array_length(p_product_ids);
        SELECT count(DISTINCT value::UUID)
        INTO v_selected_distinct_count
        FROM jsonb_array_elements_text(p_product_ids);
        IF v_selected_count <> v_selected_distinct_count THEN
            RAISE EXCEPTION 'STOCK_OPNAME_DUPLICATE_SELECTED_PRODUCT';
        END IF;
    END IF;

    IF p_opname_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        v_no := 'OPN-' || lpad(
            nextval('private.stock_opname_no_seq')::TEXT,10,'0'
        );
        INSERT INTO public.stock_opnames(
            opname_no,warehouse_id,status,notes,created_by,company_id,
            scope_type,category_id
        ) VALUES (
            v_no,p_warehouse_id,'DRAFT'::public.opname_status,
            NULLIF(btrim(p_notes),''),v_actor,v_company,v_scope,p_category_id
        ) RETURNING id,master_version INTO v_id,v_version;
    ELSE
        SELECT * INTO v_existing
        FROM public.stock_opnames o
        WHERE o.company_id = v_company AND o.id = p_opname_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
        IF v_existing.created_by <> v_actor
           AND NOT public.private_stock_adjustment_operator_allowed(
               v_company,v_existing.warehouse_id
           ) THEN RAISE EXCEPTION 'STOCK_OPNAME_OWNER_OR_REVIEWER_REQUIRED';
        END IF;
        IF v_existing.status <> 'DRAFT'::public.opname_status THEN
            RAISE EXCEPTION 'STOCK_OPNAME_DRAFT_REQUIRED';
        END IF;
        IF p_master_version IS NULL
           OR p_master_version <> v_existing.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        v_before := to_jsonb(v_existing);
        v_id := p_opname_id;
        DELETE FROM public.stock_opname_details
        WHERE company_id = v_company AND opname_id = v_id;
        UPDATE public.stock_opnames SET
            warehouse_id = p_warehouse_id,scope_type = v_scope,
            category_id = p_category_id,notes = NULLIF(btrim(p_notes),''),
            updated_at = clock_timestamp(),
            master_version = master_version + 1
        WHERE company_id = v_company AND id = v_id
        RETURNING master_version INTO v_version;
    END IF;

    INSERT INTO public.stock_opname_details(
        opname_id,product_id,system_qty,physical_qty,difference,notes,
        company_id,line_status,base_uom_id,system_qty_at_start,
        product_sku_snapshot,product_name_snapshot,base_uom_name_snapshot
    )
    SELECT
        v_id,p.id,COALESCE(ps.stock_qty,0),0,0,NULL,v_company,'PENDING',
        p.uom_id,COALESCE(ps.stock_qty,0),p.sku,p.name,u.name
    FROM public.products p
    JOIN public.product_uoms pu
      ON pu.company_id = p.company_id AND pu.product_id = p.id
     AND pu.uom_id = p.uom_id AND pu.factor_to_base = 1 AND pu.is_active
    JOIN public.uoms u
      ON u.company_id = p.company_id AND u.id = p.uom_id AND u.is_active
    LEFT JOIN public.product_stocks ps
      ON ps.company_id = p.company_id AND ps.product_id = p.id
     AND ps.warehouse_id = p_warehouse_id
    WHERE p.company_id = v_company AND p.is_active AND NOT p.is_bundle
      AND (v_scope <> 'CATEGORY' OR p.category_id = p_category_id)
      AND (
          v_scope <> 'SELECTED'
          OR p.id IN (
              SELECT value::UUID
              FROM jsonb_array_elements_text(p_product_ids)
          )
      );
    GET DIAGNOSTICS v_line_count = ROW_COUNT;
    IF v_line_count = 0 THEN
        RAISE EXCEPTION 'STOCK_OPNAME_SCOPE_HAS_NO_ELIGIBLE_PRODUCT';
    END IF;
    IF v_scope = 'SELECTED' AND v_line_count <> v_selected_count THEN
        RAISE EXCEPTION 'STOCK_OPNAME_SELECTED_PRODUCT_NOT_ELIGIBLE';
    END IF;
    IF v_line_count > 2000 THEN
        RAISE EXCEPTION 'STOCK_OPNAME_LINE_LIMIT_EXCEEDED';
    END IF;

    SELECT to_jsonb(o) INTO v_after FROM public.stock_opnames o
    WHERE o.company_id = v_company AND o.id = v_id;
    INSERT INTO public.stock_opname_audit(
        company_id,opname_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_id,
        CASE WHEN p_opname_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
        v_actor,v_before,v_after
    );
    RETURN jsonb_build_object(
        'opnameId',v_id,'opnameNo',v_after->>'opname_no',
        'status',v_after->>'status','masterVersion',v_version,
        'lineCount',v_line_count
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'STOCK_OPNAME_DUPLICATE_SCOPE_PRODUCT';
END;
$$;

CREATE FUNCTION public.start_stock_opname(
    p_opname_id UUID,
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
    v_opname public.stock_opnames%ROWTYPE;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    SELECT * INTO v_opname FROM public.stock_opnames o
    WHERE o.company_id = v_company AND o.id = p_opname_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
    IF v_opname.created_by <> v_actor
       OR NOT public.private_stock_opname_counter_allowed(
           v_company,v_opname.warehouse_id
       ) THEN RAISE EXCEPTION 'STOCK_OPNAME_OWNER_COUNTER_REQUIRED'; END IF;
    IF v_opname.status <> 'DRAFT'::public.opname_status THEN
        RAISE EXCEPTION 'STOCK_OPNAME_DRAFT_REQUIRED';
    END IF;
    IF p_master_version IS DISTINCT FROM v_opname.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;

    UPDATE public.stock_opname_details d SET
        system_qty = COALESCE(ps.stock_qty,0),
        system_qty_at_start = COALESCE(ps.stock_qty,0),
        physical_qty = 0,difference = 0,line_status = 'PENDING',
        expected_qty_at_count = NULL,variance_at_count = NULL,
        count_started_at = v_now,counted_at = NULL,counter_id = NULL,
        movement_watermark_at = v_now
    FROM public.products p
    LEFT JOIN public.product_stocks ps
      ON ps.company_id = p.company_id AND ps.product_id = p.id
     AND ps.warehouse_id = v_opname.warehouse_id
    WHERE d.company_id = v_company AND d.opname_id = v_opname.id
      AND p.company_id = d.company_id AND p.id = d.product_id;

    UPDATE public.stock_opnames SET
        status = 'COUNTING'::public.opname_status,
        count_started_at = v_now,movement_watermark_at = v_now,
        updated_at = v_now,master_version = master_version + 1
    WHERE company_id = v_company AND id = v_opname.id
    RETURNING master_version INTO v_version;
    INSERT INTO public.stock_opname_audit(
        company_id,opname_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_opname.id,'START',v_actor,to_jsonb(v_opname),
        jsonb_build_object('status','COUNTING','startedAt',v_now)
    );
    RETURN jsonb_build_object(
        'opnameId',v_opname.id,'status','COUNTING',
        'masterVersion',v_version
    );
END;
$$;

CREATE FUNCTION public.record_stock_opname_count(
    p_opname_id UUID,
    p_master_version BIGINT,
    p_product_id UUID,
    p_physical_qty NUMERIC,
    p_notes TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_opname public.stock_opnames%ROWTYPE;
    v_line public.stock_opname_details%ROWTYPE;
    v_uom RECORD;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_expected NUMERIC(24,6);
    v_variance NUMERIC(24,6);
    v_movement_count BIGINT;
    v_attempt INTEGER;
    v_line_status TEXT;
    v_version BIGINT;
    v_old RECORD;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    SELECT * INTO v_opname FROM public.stock_opnames o
    WHERE o.company_id = v_company AND o.id = p_opname_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
    IF v_opname.created_by <> v_actor
       OR NOT public.private_stock_opname_counter_allowed(
           v_company,v_opname.warehouse_id
       ) THEN RAISE EXCEPTION 'STOCK_OPNAME_OWNER_COUNTER_REQUIRED'; END IF;
    IF v_opname.status <> 'COUNTING'::public.opname_status THEN
        RAISE EXCEPTION 'STOCK_OPNAME_COUNTING_REQUIRED';
    END IF;
    IF p_master_version IS DISTINCT FROM v_opname.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF p_physical_qty IS NULL OR p_physical_qty < 0 THEN
        RAISE EXCEPTION 'STOCK_OPNAME_PHYSICAL_QUANTITY_INVALID';
    END IF;

    SELECT * INTO v_line FROM public.stock_opname_details d
    WHERE d.company_id = v_company AND d.opname_id = v_opname.id
      AND d.product_id = p_product_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_OPNAME_PRODUCT_NOT_FOUND'; END IF;
    IF v_line.line_status NOT IN ('PENDING','COUNTED','RECOUNT_REQUIRED') THEN
        RAISE EXCEPTION 'STOCK_OPNAME_LINE_NOT_COUNTABLE';
    END IF;
    SELECT u.allow_decimal,u.decimal_precision INTO v_uom
    FROM public.uoms u
    WHERE u.company_id = v_company AND u.id = v_line.base_uom_id
      AND u.is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_BASE_UOM_NOT_FOUND'; END IF;
    IF NOT v_uom.allow_decimal AND p_physical_qty <> trunc(p_physical_qty) THEN
        RAISE EXCEPTION 'STOCK_OPNAME_BASE_UOM_REQUIRES_INTEGER';
    END IF;
    IF v_uom.allow_decimal
       AND p_physical_qty <> round(p_physical_qty,v_uom.decimal_precision) THEN
        RAISE EXCEPTION 'STOCK_OPNAME_BASE_UOM_PRECISION_EXCEEDED';
    END IF;

    SELECT count(*),COALESCE(sum(qty_change),0)
    INTO v_movement_count,v_expected
    FROM public.stock_movements sm
    WHERE sm.company_id = v_company
      AND sm.product_id = p_product_id
      AND sm.warehouse_id = v_opname.warehouse_id
      AND sm.movement_status = 'POSTED'
      AND sm.posted_at > v_line.count_started_at
      AND sm.posted_at <= v_now;
    v_expected := v_line.system_qty_at_start + v_expected;
    v_variance := p_physical_qty - v_expected;
    v_line_status := CASE WHEN v_movement_count > 0
        THEN 'RECOUNT_REQUIRED' ELSE 'COUNTED' END;
    SELECT COALESCE(max(attempt_no),0) + 1 INTO v_attempt
    FROM public.stock_opname_count_attempts
    WHERE company_id = v_company AND opname_detail_id = v_line.id;

    UPDATE public.stock_opname_details SET
        physical_qty = p_physical_qty,system_qty = v_expected,
        expected_qty_at_count = v_expected,variance_at_count = v_variance,
        difference = v_variance,line_status = v_line_status,
        counted_at = v_now,counter_id = v_actor,
        movement_watermark_at = v_now,notes = NULLIF(btrim(p_notes),'')
    WHERE company_id = v_company AND id = v_line.id;
    INSERT INTO public.stock_opname_count_attempts(
        company_id,opname_id,opname_detail_id,attempt_no,physical_qty,
        count_started_at,counted_at,counter_id,movement_count_in_window,
        result_status,notes
    ) VALUES (
        v_company,v_opname.id,v_line.id,v_attempt,p_physical_qty,
        v_line.count_started_at,v_now,v_actor,v_movement_count,
        v_line_status,NULLIF(btrim(p_notes),'')
    );

    IF v_line_status = 'COUNTED' THEN
        FOR v_old IN
            SELECT d.id,d.opname_id,to_jsonb(d) AS before_state
            FROM public.stock_opname_details d
            JOIN public.stock_opnames o
              ON o.company_id = d.company_id AND o.id = d.opname_id
            WHERE d.company_id = v_company
              AND o.warehouse_id = v_opname.warehouse_id
              AND d.product_id = p_product_id
              AND d.id <> v_line.id
              AND d.line_status NOT IN ('SUPERSEDED','POSTED')
              AND o.status IN (
                  'DRAFT'::public.opname_status,
                  'COUNTING'::public.opname_status,
                  'COMPLETED'::public.opname_status
              )
              AND (d.counted_at IS NULL OR d.counted_at < v_now)
            FOR UPDATE OF d
        LOOP
            UPDATE public.stock_opname_details SET
                line_status = 'SUPERSEDED',superseded_by_line_id = v_line.id
            WHERE company_id = v_company AND id = v_old.id;
            INSERT INTO public.stock_opname_audit(
                company_id,opname_id,opname_detail_id,action,actor_id,
                before_state,after_state
            ) VALUES (
                v_company,v_old.opname_id,v_old.id,'SUPERSEDE',v_actor,
                v_old.before_state,
                jsonb_build_object('lineStatus','SUPERSEDED',
                                   'supersededByLineId',v_line.id)
            );
        END LOOP;
    END IF;

    UPDATE public.stock_opnames SET
        updated_at = v_now,master_version = master_version + 1
    WHERE company_id = v_company AND id = v_opname.id
    RETURNING master_version INTO v_version;
    INSERT INTO public.stock_opname_audit(
        company_id,opname_id,opname_detail_id,action,actor_id,
        before_state,after_state
    ) VALUES (
        v_company,v_opname.id,v_line.id,'COUNT',v_actor,to_jsonb(v_line),
        jsonb_build_object(
            'lineStatus',v_line_status,'physicalQuantity',p_physical_qty,
            'countedAt',v_now,'movementCountInWindow',v_movement_count
        )
    );
    RETURN jsonb_build_object(
        'opnameId',v_opname.id,'productId',p_product_id,
        'lineStatus',v_line_status,'masterVersion',v_version
    );
END;
$$;

CREATE FUNCTION public.complete_stock_opname(
    p_opname_id UUID,
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
    v_opname public.stock_opnames%ROWTYPE;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_version BIGINT;
BEGIN
    SELECT * INTO v_opname FROM public.stock_opnames o
    WHERE o.company_id = v_company AND o.id = p_opname_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
    IF v_opname.created_by <> v_actor
       OR NOT public.private_stock_opname_counter_allowed(
           v_company,v_opname.warehouse_id
       ) THEN RAISE EXCEPTION 'STOCK_OPNAME_OWNER_COUNTER_REQUIRED'; END IF;
    IF v_opname.status <> 'COUNTING'::public.opname_status THEN
        RAISE EXCEPTION 'STOCK_OPNAME_COUNTING_REQUIRED';
    END IF;
    IF p_master_version IS DISTINCT FROM v_opname.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.stock_opname_details d
        WHERE d.company_id = v_company AND d.opname_id = v_opname.id
          AND d.line_status IN ('PENDING','RECOUNT_REQUIRED')
    ) THEN RAISE EXCEPTION 'STOCK_OPNAME_UNRESOLVED_LINE'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.stock_opname_details d
        WHERE d.company_id = v_company AND d.opname_id = v_opname.id
          AND d.line_status = 'COUNTED'
    ) THEN RAISE EXCEPTION 'STOCK_OPNAME_NO_ACTIVE_COUNTED_LINE'; END IF;
    UPDATE public.stock_opnames SET
        status = 'COMPLETED'::public.opname_status,
        completed_by = v_actor,completed_at = v_now,updated_at = v_now,
        master_version = master_version + 1
    WHERE company_id = v_company AND id = v_opname.id
    RETURNING master_version INTO v_version;
    INSERT INTO public.stock_opname_audit(
        company_id,opname_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_opname.id,'COMPLETE',v_actor,to_jsonb(v_opname),
        jsonb_build_object('status','COMPLETED','completedAt',v_now)
    );
    RETURN jsonb_build_object(
        'opnameId',v_opname.id,'status','COMPLETED',
        'masterVersion',v_version
    );
END;
$$;

CREATE FUNCTION public.request_stock_opname_recount(
    p_opname_id UUID,
    p_master_version BIGINT,
    p_opname_detail_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_opname public.stock_opnames%ROWTYPE;
    v_line public.stock_opname_details%ROWTYPE;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_stock NUMERIC(24,6);
    v_version BIGINT;
BEGIN
    SELECT * INTO v_opname FROM public.stock_opnames o
    WHERE o.company_id = v_company AND o.id = p_opname_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
    IF p_master_version IS DISTINCT FROM v_opname.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    SELECT * INTO v_line FROM public.stock_opname_details d
    WHERE d.company_id = v_company AND d.opname_id = v_opname.id
      AND d.id = p_opname_detail_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_OPNAME_LINE_NOT_FOUND'; END IF;
    IF v_opname.status = 'COUNTING'::public.opname_status
       AND v_line.line_status = 'RECOUNT_REQUIRED' THEN
        IF v_opname.created_by <> v_actor
           OR NOT public.private_stock_opname_counter_allowed(
               v_company,v_opname.warehouse_id
           ) THEN RAISE EXCEPTION 'STOCK_OPNAME_OWNER_COUNTER_REQUIRED'; END IF;
    ELSIF v_opname.status = 'COMPLETED'::public.opname_status
       AND v_line.line_status = 'COUNTED' THEN
        IF NOT public.private_stock_adjustment_operator_allowed(
            v_company,v_opname.warehouse_id
        ) THEN RAISE EXCEPTION 'STOCK_OPNAME_REVIEWER_REQUIRED'; END IF;
    ELSE
        RAISE EXCEPTION 'STOCK_OPNAME_RECOUNT_NOT_ALLOWED';
    END IF;
    SELECT COALESCE(stock_qty,0) INTO v_stock
    FROM public.product_stocks
    WHERE company_id = v_company AND product_id = v_line.product_id
      AND warehouse_id = v_opname.warehouse_id;
    v_stock := COALESCE(v_stock,0);
    UPDATE public.stock_opname_details SET
        line_status = 'PENDING',system_qty_at_start = v_stock,
        system_qty = v_stock,physical_qty = 0,difference = 0,
        expected_qty_at_count = NULL,variance_at_count = NULL,
        count_started_at = v_now,counted_at = NULL,counter_id = NULL,
        movement_watermark_at = v_now,recount_requested_by = v_actor,
        recount_requested_at = v_now
    WHERE company_id = v_company AND id = v_line.id;
    UPDATE public.stock_opnames SET
        status = 'COUNTING'::public.opname_status,
        completed_by = NULL,completed_at = NULL,reviewed_by = v_actor,
        reviewed_at = v_now,updated_at = v_now,
        master_version = master_version + 1
    WHERE company_id = v_company AND id = v_opname.id
    RETURNING master_version INTO v_version;
    INSERT INTO public.stock_opname_audit(
        company_id,opname_id,opname_detail_id,action,actor_id,
        before_state,after_state
    ) VALUES (
        v_company,v_opname.id,v_line.id,'REQUEST_RECOUNT',v_actor,
        to_jsonb(v_line),
        jsonb_build_object('lineStatus','PENDING','countStartedAt',v_now)
    );
    RETURN jsonb_build_object(
        'opnameId',v_opname.id,'lineStatus','PENDING',
        'status','COUNTING','masterVersion',v_version
    );
END;
$$;

CREATE FUNCTION public.post_stock_opname(
    p_opname_id UUID,
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
    v_opname public.stock_opnames%ROWTYPE;
    v_reason_id UUID;
    v_lines JSONB;
    v_adjustment JSONB;
    v_adjustment_id UUID;
    v_adjustment_version BIGINT;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_version BIGINT;
    v_nonzero INTEGER;
BEGIN
    IF p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'STOCK_OPNAME_IDEMPOTENCY_KEY_REQUIRED';
    END IF;
    SELECT * INTO v_opname FROM public.stock_opnames o
    WHERE o.company_id = v_company AND o.id = p_opname_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
    IF v_opname.status = 'POSTED'::public.opname_status THEN
        IF v_opname.posting_idempotency_key = p_idempotency_key THEN
            RETURN jsonb_build_object(
                'opnameId',v_opname.id,'opnameNo',v_opname.opname_no,
                'status','POSTED','masterVersion',v_opname.master_version,
                'adjustmentDocumentId',v_opname.adjustment_document_id,
                'idempotentReplay',TRUE
            );
        END IF;
        RAISE EXCEPTION 'STOCK_OPNAME_IDEMPOTENCY_CONFLICT';
    END IF;
    IF NOT public.private_stock_adjustment_operator_allowed(
        v_company,v_opname.warehouse_id
    ) THEN RAISE EXCEPTION 'STOCK_OPNAME_REVIEWER_REQUIRED'; END IF;
    IF v_opname.status <> 'COMPLETED'::public.opname_status THEN
        RAISE EXCEPTION 'STOCK_OPNAME_COMPLETED_REQUIRED';
    END IF;
    IF p_master_version IS DISTINCT FROM v_opname.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.stock_opname_details d
        WHERE d.company_id = v_company AND d.opname_id = v_opname.id
          AND d.line_status NOT IN ('COUNTED','SUPERSEDED')
    ) THEN RAISE EXCEPTION 'STOCK_OPNAME_UNRESOLVED_LINE'; END IF;

    SELECT id INTO v_reason_id
    FROM public.stock_adjustment_reasons
    WHERE company_id = v_company AND is_active
      AND direction_allowed = 'BOTH'
      AND lower(regexp_replace(btrim(reason_name),'\s+',' ','g'))
          = 'selisih stok'
    ORDER BY is_system_default DESC,id LIMIT 1;
    IF v_reason_id IS NULL THEN
        RAISE EXCEPTION 'STOCK_OPNAME_ADJUSTMENT_REASON_NOT_FOUND';
    END IF;

    SELECT count(*),jsonb_agg(
        jsonb_build_object(
            'productId',d.product_id,'reasonId',v_reason_id,
            'finalPhysicalQuantity',
                COALESCE(ps.stock_qty,0) + d.variance_at_count,
            'notes','Generated from Stock Opname ' || v_opname.opname_no
        ) ORDER BY d.product_id
    )
    INTO v_nonzero,v_lines
    FROM public.stock_opname_details d
    LEFT JOIN public.product_stocks ps
      ON ps.company_id = d.company_id AND ps.product_id = d.product_id
     AND ps.warehouse_id = v_opname.warehouse_id
    WHERE d.company_id = v_company AND d.opname_id = v_opname.id
      AND d.line_status = 'COUNTED' AND d.variance_at_count <> 0;
    IF EXISTS (
        SELECT 1
        FROM public.stock_opname_details d
        LEFT JOIN public.product_stocks ps
          ON ps.company_id = d.company_id AND ps.product_id = d.product_id
         AND ps.warehouse_id = v_opname.warehouse_id
        WHERE d.company_id = v_company AND d.opname_id = v_opname.id
          AND d.line_status = 'COUNTED'
          AND COALESCE(ps.stock_qty,0) + d.variance_at_count < 0
    ) THEN RAISE EXCEPTION 'STOCK_OPNAME_FINAL_STOCK_NEGATIVE'; END IF;

    IF v_nonzero > 0 THEN
        v_adjustment := public.save_stock_adjustment_document(
            NULL,NULL,v_opname.warehouse_id,CURRENT_DATE,
            'Generated from Stock Opname ' || v_opname.opname_no,v_lines
        );
        v_adjustment_id := (v_adjustment->>'documentId')::UUID;
        v_adjustment_version := (v_adjustment->>'masterVersion')::BIGINT;
        UPDATE public.stock_adjustment_lines a SET
            opname_detail_id = d.id
        FROM public.stock_opname_details d
        WHERE a.company_id = v_company
          AND a.document_id = v_adjustment_id
          AND d.company_id = a.company_id
          AND d.opname_id = v_opname.id
          AND d.product_id = a.product_id;
        PERFORM public.post_stock_adjustment(
            v_adjustment_id,v_adjustment_version,p_idempotency_key
        );
        UPDATE public.stock_opname_details d SET
            line_status = CASE WHEN d.line_status = 'COUNTED'
                THEN 'POSTED' ELSE d.line_status END,
            adjustment_line_id = a.id
        FROM public.stock_adjustment_lines a
        WHERE d.company_id = v_company AND d.opname_id = v_opname.id
          AND a.company_id = d.company_id
          AND a.document_id = v_adjustment_id
          AND a.product_id = d.product_id;
    END IF;
    UPDATE public.stock_opname_details SET line_status = 'POSTED'
    WHERE company_id = v_company AND opname_id = v_opname.id
      AND line_status = 'COUNTED';
    UPDATE public.stock_opnames SET
        status = 'POSTED'::public.opname_status,
        adjustment_document_id = v_adjustment_id,
        posting_idempotency_key = p_idempotency_key,
        reviewed_by = COALESCE(reviewed_by,v_actor),
        reviewed_at = COALESCE(reviewed_at,v_now),
        posted_by = v_actor,posted_at = v_now,updated_at = v_now,
        master_version = master_version + 1
    WHERE company_id = v_company AND id = v_opname.id
    RETURNING master_version INTO v_version;
    INSERT INTO public.stock_opname_audit(
        company_id,opname_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_opname.id,'POST',v_actor,to_jsonb(v_opname),
        jsonb_build_object(
            'status','POSTED','postedAt',v_now,
            'adjustmentDocumentId',v_adjustment_id
        )
    );
    RETURN jsonb_build_object(
        'opnameId',v_opname.id,'opnameNo',v_opname.opname_no,
        'status','POSTED','masterVersion',v_version,
        'adjustmentDocumentId',v_adjustment_id,
        'idempotentReplay',FALSE
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'STOCK_OPNAME_IDEMPOTENCY_CONFLICT';
END;
$$;

CREATE FUNCTION public.cancel_stock_opname(
    p_opname_id UUID,
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
    v_opname public.stock_opnames%ROWTYPE;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_version BIGINT;
BEGIN
    SELECT * INTO v_opname FROM public.stock_opnames o
    WHERE o.company_id = v_company AND o.id = p_opname_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
    IF v_opname.created_by <> v_actor
       AND NOT public.private_stock_adjustment_operator_allowed(
           v_company,v_opname.warehouse_id
       ) THEN RAISE EXCEPTION 'STOCK_OPNAME_OWNER_OR_REVIEWER_REQUIRED';
    END IF;
    IF v_opname.status NOT IN (
        'DRAFT'::public.opname_status,
        'COUNTING'::public.opname_status,
        'COMPLETED'::public.opname_status
    ) THEN RAISE EXCEPTION 'FINAL_STOCK_OPNAME_IMMUTABLE'; END IF;
    IF p_master_version IS DISTINCT FROM v_opname.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    UPDATE public.stock_opnames SET
        status = 'CANCELED'::public.opname_status,canceled_by = v_actor,
        canceled_at = v_now,updated_at = v_now,
        master_version = master_version + 1
    WHERE company_id = v_company AND id = v_opname.id
    RETURNING master_version INTO v_version;
    INSERT INTO public.stock_opname_audit(
        company_id,opname_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_opname.id,'CANCEL',v_actor,to_jsonb(v_opname),
        jsonb_build_object('status','CANCELED','canceledAt',v_now)
    );
    RETURN jsonb_build_object(
        'opnameId',v_opname.id,'status','CANCELED',
        'masterVersion',v_version
    );
END;
$$;

CREATE FUNCTION public.get_stock_opname_blind_session(p_opname_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_opname public.stock_opnames%ROWTYPE;
    v_lines JSONB;
BEGIN
    SELECT * INTO v_opname FROM public.stock_opnames o
    WHERE o.company_id = v_company AND o.id = p_opname_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
    IF v_opname.created_by <> v_actor
       OR NOT public.private_stock_opname_counter_allowed(
           v_company,v_opname.warehouse_id
       ) THEN RAISE EXCEPTION 'STOCK_OPNAME_OWNER_COUNTER_REQUIRED'; END IF;
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'detailId',d.id,'productId',d.product_id,
            'sku',d.product_sku_snapshot,'productName',d.product_name_snapshot,
            'uomName',d.base_uom_name_snapshot,'lineStatus',d.line_status,
            'notes',d.notes
        ) ORDER BY d.product_name_snapshot,d.id
    ),'[]'::jsonb) INTO v_lines
    FROM public.stock_opname_details d
    WHERE d.company_id = v_company AND d.opname_id = v_opname.id
      AND d.line_status <> 'SUPERSEDED';
    RETURN jsonb_build_object(
        'opnameId',v_opname.id,'opnameNo',v_opname.opname_no,
        'warehouseId',v_opname.warehouse_id,'status',v_opname.status,
        'masterVersion',v_opname.master_version,'lines',v_lines
    );
END;
$$;

REVOKE ALL ON FUNCTION public.private_stock_opname_counter_allowed(UUID,UUID)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.save_stock_opname_session(
    UUID,BIGINT,UUID,TEXT,UUID,JSONB,TEXT
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.start_stock_opname(UUID,BIGINT)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.record_stock_opname_count(
    UUID,BIGINT,UUID,NUMERIC,TEXT
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.complete_stock_opname(UUID,BIGINT)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.request_stock_opname_recount(
    UUID,BIGINT,UUID
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.post_stock_opname(UUID,BIGINT,UUID)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.cancel_stock_opname(UUID,BIGINT)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_stock_opname_blind_session(UUID)
FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.private_stock_opname_counter_allowed(
    UUID,UUID
), public.save_stock_opname_session(
    UUID,BIGINT,UUID,TEXT,UUID,JSONB,TEXT
), public.start_stock_opname(UUID,BIGINT),
    public.record_stock_opname_count(UUID,BIGINT,UUID,NUMERIC,TEXT),
    public.complete_stock_opname(UUID,BIGINT),
    public.request_stock_opname_recount(UUID,BIGINT,UUID),
    public.post_stock_opname(UUID,BIGINT,UUID),
    public.cancel_stock_opname(UUID,BIGINT),
    public.get_stock_opname_blind_session(UUID)
TO authenticated,service_role;

ALTER TABLE public.stock_opname_count_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_opname_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Opname attempts readable by inventory reviewers"
ON public.stock_opname_count_attempts FOR SELECT TO authenticated
USING (public.private_inventory_reviewer_visible(company_id));
CREATE POLICY "Opname audit readable by inventory reviewers"
ON public.stock_opname_audit FOR SELECT TO authenticated
USING (public.private_inventory_reviewer_visible(company_id));

REVOKE ALL ON public.stock_opnames,public.stock_opname_details,
    public.stock_opname_count_attempts,public.stock_opname_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.stock_opnames,public.stock_opname_details,
    public.stock_opname_count_attempts,public.stock_opname_audit
TO authenticated;
GRANT ALL ON public.stock_opnames,public.stock_opname_details,
    public.stock_opname_count_attempts,public.stock_opname_audit
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260728230000',
    'g3_phase10_stock_opname_foundation',
    'Canonical blind-count Stock Opname with non-blocking movement reconciliation, recount, per-line supersede, atomic Adjustment posting, idempotency, audit, and blind-safe cashier RPC'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
