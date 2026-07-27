-- KGS POS G2 phase 4: atomic canonical STOCK Product + Product-UOM CRUD.
-- Requirements: MST-001, MST-002
-- Dependency: 20260721180000_g2_phase1_master_data_foundation.sql
--
-- Compatibility:
-- - legacy Product columns remain synchronized for existing readers;
-- - direct browser writes and the legacy import RPC are closed;
-- - Bundle composition remains deferred to G3 and cannot be created here.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260721180000'
       ) THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: G2 phase 1 not recorded';
    END IF;

    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260721210000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260721210000';
    END IF;
END
$migration_guard$;

DO $data_preflight$
DECLARE
    v_violations BIGINT;
BEGIN
    SELECT count(*) INTO v_violations
    FROM public.products p
    WHERE p.category_id IS NULL
       OR p.uom_id IS NULL
       OR p.weight_reference_uom_id IS NULL
       OR p.weight_per_uom_kg <= 0
       OR NOT EXISTS (
           SELECT 1 FROM public.product_uoms pu
           WHERE pu.company_id = p.company_id
             AND pu.product_id = p.id
             AND pu.uom_id = p.uom_id
             AND pu.factor_to_base = 1
       );

    IF v_violations > 0 THEN
        RAISE EXCEPTION
            'G2_PHASE4_DATA_PRECONDITION_FAILED: % Product row(s) require backfill',
            v_violations;
    END IF;
END
$data_preflight$;

CREATE UNIQUE INDEX uq_products_company_normalized_sku
    ON public.products (
        company_id,
        upper(regexp_replace(btrim(sku), '\s+', ' ', 'g'))
    );

ALTER TABLE public.product_uoms
    ADD CONSTRAINT product_uoms_factor_not_below_base
    CHECK (factor_to_base >= 1) NOT VALID;
ALTER TABLE public.product_uoms
    VALIDATE CONSTRAINT product_uoms_factor_not_below_base;

CREATE TABLE public.product_master_audit (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    product_id UUID NOT NULL
        REFERENCES public.products(id) ON DELETE RESTRICT,
    action TEXT NOT NULL CHECK (action IN ('CREATE','UPDATE')),
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_snapshot JSONB,
    after_snapshot JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT product_master_audit_company_id_id_unique
        UNIQUE (company_id, id),
    CONSTRAINT fk_product_master_audit_company_product
        FOREIGN KEY (company_id, product_id)
        REFERENCES public.products(company_id, id) ON DELETE RESTRICT
);

CREATE INDEX idx_product_master_audit_company_product_created
    ON public.product_master_audit(company_id, product_id, created_at DESC);

ALTER TABLE public.product_master_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Product master audit readable by catalog managers"
ON public.product_master_audit FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY[
            'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'
        ]::TEXT[]
    )
);

CREATE FUNCTION public.save_product_with_uoms(
    p_product_id UUID,
    p_master_version BIGINT,
    p_sku TEXT,
    p_name TEXT,
    p_category_id UUID,
    p_base_uom_id UUID,
    p_weight_reference_uom_id UUID,
    p_weight_per_reference_uom_kg NUMERIC,
    p_is_bundle BOOLEAN,
    p_image_url TEXT,
    p_is_active BOOLEAN,
    p_uoms JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company_id UUID := public.private_active_company_id();
    v_product_id UUID := p_product_id;
    v_existing public.products%ROWTYPE;
    v_category_name TEXT;
    v_base_uom_code TEXT;
    v_item JSONB;
    v_uom_id UUID;
    v_factor NUMERIC(24,6);
    v_purchase_allowed BOOLEAN;
    v_sales_allowed BOOLEAN;
    v_purchase_price NUMERIC(20,4);
    v_sale_price NUMERIC(20,4);
    v_barcode TEXT;
    v_row_active BOOLEAN;
    v_base_count INTEGER := 0;
    v_weight_count INTEGER := 0;
    v_sales_count INTEGER := 0;
    v_purchase_count INTEGER := 0;
    v_max_factor NUMERIC(24,6) := 1;
    v_weight_factor NUMERIC(24,6);
    v_base_purchase_price NUMERIC(20,4);
    v_base_sale_price NUMERIC(20,4);
    v_submitted_uom_ids UUID[] := ARRAY[]::UUID[];
    v_before JSONB;
    v_after JSONB;
    v_result_version BIGINT;
    v_has_movement BOOLEAN := FALSE;
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'AUTHENTICATION_REQUIRED';
    END IF;
    IF v_company_id IS NULL THEN
        RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND';
    END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company_id,
        ARRAY[
            'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'
        ]::TEXT[]
    ) THEN
        RAISE EXCEPTION 'CATALOG_MANAGER_REQUIRED';
    END IF;

    IF btrim(COALESCE(p_sku, '')) = ''
       OR char_length(btrim(p_sku)) > 100 THEN
        RAISE EXCEPTION 'INVALID_PRODUCT_SKU';
    END IF;
    IF btrim(COALESCE(p_name, '')) = ''
       OR char_length(btrim(p_name)) > 200 THEN
        RAISE EXCEPTION 'INVALID_PRODUCT_NAME';
    END IF;
    IF p_weight_per_reference_uom_kg IS NULL
       OR p_weight_per_reference_uom_kg <= 0 THEN
        RAISE EXCEPTION 'POSITIVE_REFERENCE_WEIGHT_REQUIRED';
    END IF;
    IF p_image_url IS NOT NULL
       AND btrim(p_image_url) <> ''
       AND btrim(p_image_url) !~* '^https://' THEN
        RAISE EXCEPTION 'PRODUCT_IMAGE_HTTPS_REQUIRED';
    END IF;
    IF COALESCE(p_is_bundle, FALSE) THEN
        RAISE EXCEPTION 'BUNDLE_COMPONENTS_REQUIRED_G3';
    END IF;
    IF jsonb_typeof(p_uoms) IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_uoms) = 0
       OR jsonb_array_length(p_uoms) > 20 THEN
        RAISE EXCEPTION 'PRODUCT_UOMS_ARRAY_REQUIRED';
    END IF;

    SELECT pc.category_name INTO v_category_name
    FROM public.product_categories pc
    WHERE pc.company_id = v_company_id
      AND pc.id = p_category_id
      AND pc.is_active;
    IF v_category_name IS NULL THEN
        RAISE EXCEPTION 'ACTIVE_PRODUCT_CATEGORY_NOT_FOUND';
    END IF;

    SELECT u.code INTO v_base_uom_code
    FROM public.uoms u
    WHERE u.company_id = v_company_id
      AND u.id = p_base_uom_id
      AND u.is_active;
    IF v_base_uom_code IS NULL THEN
        RAISE EXCEPTION 'ACTIVE_BASE_UOM_NOT_FOUND';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.uoms u
        WHERE u.company_id = v_company_id
          AND u.id = p_weight_reference_uom_id
          AND u.is_active
    ) THEN
        RAISE EXCEPTION 'ACTIVE_WEIGHT_REFERENCE_UOM_NOT_FOUND';
    END IF;

    FOR v_item IN SELECT value FROM jsonb_array_elements(p_uoms)
    LOOP
        BEGIN
            v_uom_id := (v_item->>'uomId')::UUID;
            v_factor := (v_item->>'factorToBase')::NUMERIC;
            v_purchase_allowed := COALESCE(
                (v_item->>'purchaseAllowed')::BOOLEAN, FALSE
            );
            v_sales_allowed := COALESCE(
                (v_item->>'salesAllowed')::BOOLEAN, FALSE
            );
            v_purchase_price := NULLIF(v_item->>'purchasePrice', '')::NUMERIC;
            v_sale_price := NULLIF(v_item->>'salePrice', '')::NUMERIC;
            v_barcode := NULLIF(btrim(COALESCE(v_item->>'barcode', '')), '');
            v_row_active := COALESCE((v_item->>'isActive')::BOOLEAN, TRUE);
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'INVALID_PRODUCT_UOM_ROW';
        END;

        IF v_uom_id = ANY(v_submitted_uom_ids) THEN
            RAISE EXCEPTION 'DUPLICATE_PRODUCT_UOM';
        END IF;
        v_submitted_uom_ids := array_append(v_submitted_uom_ids, v_uom_id);

        IF NOT EXISTS (
            SELECT 1 FROM public.uoms u
            WHERE u.company_id = v_company_id
              AND u.id = v_uom_id
              AND u.is_active
        ) THEN
            RAISE EXCEPTION 'ACTIVE_PRODUCT_UOM_NOT_FOUND';
        END IF;
        IF v_factor IS NULL OR v_factor < 1 THEN
            RAISE EXCEPTION 'PRODUCT_UOM_FACTOR_BELOW_BASE';
        END IF;
        IF v_purchase_price IS NOT NULL AND v_purchase_price < 0
           OR v_sale_price IS NOT NULL AND v_sale_price < 0 THEN
            RAISE EXCEPTION 'PRODUCT_UOM_PRICE_NEGATIVE';
        END IF;
        IF v_purchase_allowed AND v_purchase_price IS NULL THEN
            RAISE EXCEPTION 'PURCHASE_PRICE_REQUIRED';
        END IF;
        IF v_sales_allowed AND v_sale_price IS NULL THEN
            RAISE EXCEPTION 'SALE_PRICE_REQUIRED';
        END IF;
        IF NOT v_row_active AND (v_purchase_allowed OR v_sales_allowed) THEN
            RAISE EXCEPTION 'INACTIVE_PRODUCT_UOM_CANNOT_BE_USED';
        END IF;

        IF v_uom_id = p_base_uom_id THEN
            v_base_count := v_base_count + 1;
            IF v_factor <> 1 THEN
                RAISE EXCEPTION 'BASE_UOM_FACTOR_MUST_EQUAL_ONE';
            END IF;
            v_base_purchase_price := v_purchase_price;
            v_base_sale_price := v_sale_price;
        ELSIF v_factor = 1 THEN
            RAISE EXCEPTION 'NON_BASE_UOM_FACTOR_MUST_EXCEED_ONE';
        END IF;

        IF v_uom_id = p_weight_reference_uom_id THEN
            v_weight_count := v_weight_count + 1;
            v_weight_factor := v_factor;
        END IF;
        IF v_row_active AND v_sales_allowed THEN
            v_sales_count := v_sales_count + 1;
        END IF;
        IF v_row_active AND v_purchase_allowed THEN
            v_purchase_count := v_purchase_count + 1;
        END IF;
        IF v_row_active THEN
            v_max_factor := GREATEST(v_max_factor, v_factor);
        END IF;
    END LOOP;

    IF v_base_count <> 1 THEN
        RAISE EXCEPTION 'EXACTLY_ONE_BASE_UOM_REQUIRED';
    END IF;
    IF v_weight_count <> 1 OR v_weight_factor <> v_max_factor THEN
        RAISE EXCEPTION 'WEIGHT_REFERENCE_MUST_BE_LARGEST_UOM';
    END IF;
    IF v_sales_count = 0 THEN
        RAISE EXCEPTION 'ACTIVE_SALES_UOM_REQUIRED';
    END IF;
    IF v_purchase_count = 0 THEN
        RAISE EXCEPTION 'ACTIVE_PURCHASE_UOM_REQUIRED';
    END IF;

    IF p_product_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;

        INSERT INTO public.products(
            company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
            weight_reference_uom_id,weight_per_uom_kg,is_bundle,is_active,
            image_url,created_by,updated_by
        ) VALUES (
            v_company_id,upper(btrim(p_sku)),btrim(p_name),v_category_name,
            p_category_id,
            COALESCE(v_base_sale_price,0),COALESCE(v_base_purchase_price,0),
            upper(btrim(v_base_uom_code)),p_base_uom_id,
            p_weight_reference_uom_id,p_weight_per_reference_uom_kg,
            FALSE,COALESCE(p_is_active,TRUE),NULLIF(btrim(p_image_url),''),
            v_actor,v_actor
        )
        RETURNING id,master_version INTO v_product_id,v_result_version;
    ELSE
        SELECT p.* INTO v_existing
        FROM public.products p
        WHERE p.company_id = v_company_id
          AND p.id = p_product_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'PRODUCT_NOT_FOUND';
        END IF;
        IF p_master_version IS NULL
           OR p_master_version <> v_existing.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;

        SELECT EXISTS (
            SELECT 1 FROM public.stock_movements sm
            WHERE sm.company_id = v_company_id
              AND sm.product_id = p_product_id
        ) INTO v_has_movement;

        IF v_has_movement
           AND upper(btrim(p_sku)) <> upper(btrim(v_existing.sku)) THEN
            RAISE EXCEPTION 'PRODUCT_SKU_LOCKED_BY_MOVEMENT';
        END IF;
        IF v_has_movement AND v_existing.is_bundle IS DISTINCT FROM FALSE THEN
            RAISE EXCEPTION 'PRODUCT_TYPE_LOCKED_BY_MOVEMENT';
        END IF;

        SELECT jsonb_build_object(
            'product',to_jsonb(p),
            'uoms',COALESCE((
                SELECT jsonb_agg(to_jsonb(pu) ORDER BY pu.id)
                FROM public.product_uoms pu
                WHERE pu.company_id = p.company_id
                  AND pu.product_id = p.id
            ),'[]'::jsonb)
        ) INTO v_before
        FROM public.products p
        WHERE p.company_id = v_company_id AND p.id = p_product_id;

        UPDATE public.products
        SET sku = upper(btrim(p_sku)),
            name = btrim(p_name),
            category = v_category_name,
            category_id = p_category_id,
            price = COALESCE(v_base_sale_price,0),
            cogs = COALESCE(v_base_purchase_price,0),
            uom = upper(btrim(v_base_uom_code)),
            uom_id = p_base_uom_id,
            weight_reference_uom_id = p_weight_reference_uom_id,
            weight_per_uom_kg = p_weight_per_reference_uom_kg,
            is_bundle = FALSE,
            is_active = COALESCE(p_is_active,TRUE),
            image_url = NULLIF(btrim(p_image_url),''),
            updated_by = v_actor
        WHERE company_id = v_company_id AND id = p_product_id
        RETURNING master_version INTO v_result_version;
    END IF;

    UPDATE public.product_uoms pu
    SET is_active = FALSE,
        purchase_allowed = FALSE,
        sales_allowed = FALSE,
        updated_by = v_actor
    WHERE pu.company_id = v_company_id
      AND pu.product_id = v_product_id
      AND NOT (pu.uom_id = ANY(v_submitted_uom_ids));

    FOR v_item IN SELECT value FROM jsonb_array_elements(p_uoms)
    LOOP
        v_uom_id := (v_item->>'uomId')::UUID;
        v_factor := (v_item->>'factorToBase')::NUMERIC;
        v_purchase_allowed := COALESCE(
            (v_item->>'purchaseAllowed')::BOOLEAN, FALSE
        );
        v_sales_allowed := COALESCE(
            (v_item->>'salesAllowed')::BOOLEAN, FALSE
        );
        v_purchase_price := NULLIF(v_item->>'purchasePrice', '')::NUMERIC;
        v_sale_price := NULLIF(v_item->>'salePrice', '')::NUMERIC;
        v_barcode := NULLIF(btrim(COALESCE(v_item->>'barcode', '')), '');
        v_row_active := COALESCE((v_item->>'isActive')::BOOLEAN, TRUE);

        INSERT INTO public.product_uoms(
            company_id,product_id,uom_id,factor_to_base,
            purchase_allowed,sales_allowed,purchase_price,sale_price,
            barcode,is_active,created_by,updated_by
        ) VALUES (
            v_company_id,v_product_id,v_uom_id,v_factor,
            v_purchase_allowed,v_sales_allowed,v_purchase_price,v_sale_price,
            v_barcode,v_row_active,v_actor,v_actor
        )
        ON CONFLICT ON CONSTRAINT product_uoms_company_product_uom_unique
        DO UPDATE SET
            factor_to_base = EXCLUDED.factor_to_base,
            purchase_allowed = EXCLUDED.purchase_allowed,
            sales_allowed = EXCLUDED.sales_allowed,
            purchase_price = EXCLUDED.purchase_price,
            sale_price = EXCLUDED.sale_price,
            barcode = EXCLUDED.barcode,
            is_active = EXCLUDED.is_active,
            effective_from = CASE
                WHEN public.product_uoms.factor_to_base
                     IS DISTINCT FROM EXCLUDED.factor_to_base
                THEN clock_timestamp()
                ELSE public.product_uoms.effective_from
            END,
            updated_by = v_actor;
    END LOOP;

    SELECT jsonb_build_object(
        'product',to_jsonb(p),
        'uoms',COALESCE((
            SELECT jsonb_agg(to_jsonb(pu) ORDER BY pu.factor_to_base,pu.id)
            FROM public.product_uoms pu
            WHERE pu.company_id = p.company_id
              AND pu.product_id = p.id
        ),'[]'::jsonb)
    ) INTO v_after
    FROM public.products p
    WHERE p.company_id = v_company_id AND p.id = v_product_id;

    INSERT INTO public.product_master_audit(
        company_id,product_id,action,actor_id,before_snapshot,after_snapshot
    ) VALUES (
        v_company_id,v_product_id,
        CASE WHEN p_product_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
        v_actor,v_before,v_after
    );

    RETURN jsonb_build_object(
        'productId',v_product_id,
        'masterVersion',v_result_version,
        'action',CASE WHEN p_product_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END
    );
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'DUPLICATE_PRODUCT_OR_BARCODE';
END;
$$;

REVOKE INSERT, UPDATE, DELETE ON public.products
FROM PUBLIC, anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.product_uoms
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON public.product_master_audit
FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.product_master_audit TO authenticated;
GRANT ALL ON public.product_master_audit TO service_role;

REVOKE ALL ON FUNCTION public.save_product_with_uoms(
    UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,NUMERIC,BOOLEAN,TEXT,BOOLEAN,JSONB
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_product_with_uoms(
    UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,NUMERIC,BOOLEAN,TEXT,BOOLEAN,JSONB
) TO authenticated, service_role;

-- The legacy importer creates Product without canonical Product-UOM rows.
-- Keep it for controlled forward migration only, not for browser callers.
REVOKE EXECUTE ON FUNCTION public.import_products_for_company(UUID,JSONB)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.import_products_for_company(UUID,JSONB)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260721210000',
    'g2_phase4_atomic_product_crud',
    'MST-001/MST-002 atomic STOCK Product plus Product-UOM RPC, audit, optimistic concurrency, normalized SKU, and legacy import closure'
);

COMMIT;
