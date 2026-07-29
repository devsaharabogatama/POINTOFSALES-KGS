-- KGS POS G3 phase 12: canonical Bundle master foundation.
-- Requirement: STK-006
-- Dependency: canonical Product/UOM and Stock Opname through 20260728230000.
--
-- BOUNDARY:
-- - adds atomic Bundle Product + composition save and availability resolver;
-- - Bundle remains virtual and never receives physical stock/FIFO;
-- - checkout, sale component snapshot/allocation, Return, and Import remain G4.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260721210000'
       )
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260728230000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Bundle dependencies incomplete';
    END IF;

    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260729010000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260729010000';
    END IF;
END
$migration_guard$;

-- Approved preflight reported zero Bundle and component rows. Refuse to infer
-- component UOM or composition semantics if that live state changed.
DO $empty_bundle_guard$
DECLARE
    v_bundles BIGINT;
    v_components BIGINT;
BEGIN
    SELECT count(*) INTO v_bundles
    FROM public.products WHERE is_bundle;
    SELECT count(*) INTO v_components
    FROM public.product_bundle_items;

    IF v_bundles <> 0 OR v_components <> 0 THEN
        RAISE EXCEPTION
            'G3_PHASE12_STATE_CHANGED: bundles %, components %; rerun preflight and design explicit backfill',
            v_bundles,v_components;
    END IF;
END
$empty_bundle_guard$;

-- -------------------------------------------------------------------------
-- 1. Canonical composition metadata
-- -------------------------------------------------------------------------

ALTER TABLE public.product_bundle_items
    ADD COLUMN component_uom_id UUID,
    ADD COLUMN component_qty NUMERIC(24,6),
    ADD COLUMN line_no SMALLINT,
    ADD COLUMN master_version BIGINT NOT NULL DEFAULT 1,
    ADD COLUMN created_by UUID REFERENCES public.profiles(id),
    ADD COLUMN updated_by UUID REFERENCES public.profiles(id),
    ADD COLUMN created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp();

-- Compatibility backfill is deterministic for any row admitted between
-- preflight and lock acquisition, though the state guard above normally keeps
-- this path empty.
WITH numbered AS (
    SELECT
        bi.id,
        p.uom_id,
        row_number() OVER (
            PARTITION BY bi.company_id,bi.bundle_id
            ORDER BY bi.id
        )::SMALLINT AS line_no
    FROM public.product_bundle_items bi
    JOIN public.products p
      ON p.company_id = bi.company_id
     AND p.id = bi.item_id
)
UPDATE public.product_bundle_items bi
SET component_uom_id = n.uom_id,
    component_qty = bi.qty,
    line_no = n.line_no
FROM numbered n
WHERE n.id = bi.id;

ALTER TABLE public.product_bundle_items
    ALTER COLUMN component_uom_id SET NOT NULL,
    ALTER COLUMN component_qty SET NOT NULL,
    ALTER COLUMN line_no SET NOT NULL,
    ADD CONSTRAINT product_bundle_items_component_qty_positive
        CHECK (component_qty > 0),
    ADD CONSTRAINT product_bundle_items_line_no_positive
        CHECK (line_no > 0),
    ADD CONSTRAINT product_bundle_items_version_positive
        CHECK (master_version > 0),
    ADD CONSTRAINT product_bundle_items_not_self
        CHECK (bundle_id <> item_id),
    ADD CONSTRAINT fk_bundle_items_company_item_uom
        FOREIGN KEY (company_id,item_id,component_uom_id)
        REFERENCES public.product_uoms(company_id,product_id,uom_id)
        ON DELETE RESTRICT;

CREATE UNIQUE INDEX uq_bundle_items_company_bundle_line
    ON public.product_bundle_items(company_id,bundle_id,line_no);
CREATE UNIQUE INDEX uq_bundle_items_company_bundle_item_uom
    ON public.product_bundle_items(
        company_id,bundle_id,item_id,component_uom_id
    );

CREATE TABLE public.product_bundle_master_audit (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    bundle_id UUID NOT NULL
        REFERENCES public.products(id) ON DELETE RESTRICT,
    action TEXT NOT NULL CHECK (action IN ('CREATE','UPDATE')),
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_snapshot JSONB,
    after_snapshot JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT product_bundle_master_audit_company_id_id_unique
        UNIQUE (company_id,id),
    CONSTRAINT fk_product_bundle_audit_company_bundle
        FOREIGN KEY (company_id,bundle_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_product_bundle_audit_company_bundle_created
    ON public.product_bundle_master_audit(
        company_id,bundle_id,created_at DESC
    );

-- -------------------------------------------------------------------------
-- 2. Structural guards and version touch
-- -------------------------------------------------------------------------

CREATE FUNCTION private.trg_g3_guard_product_type()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.is_bundle IS DISTINCT FROM OLD.is_bundle THEN
        RAISE EXCEPTION 'PRODUCT_TYPE_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g3_guard_bundle_component()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.bundle_id = NEW.item_id THEN
        RAISE EXCEPTION 'BUNDLE_SELF_COMPONENT_NOT_ALLOWED';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.products p
        WHERE p.company_id = NEW.company_id
          AND p.id = NEW.bundle_id
          AND p.is_bundle
    ) THEN
        RAISE EXCEPTION 'BUNDLE_PRODUCT_NOT_FOUND';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.products p
        WHERE p.company_id = NEW.company_id
          AND p.id = NEW.item_id
          AND p.is_active
          AND NOT p.is_bundle
    ) THEN
        RAISE EXCEPTION 'ACTIVE_STOCK_COMPONENT_NOT_FOUND';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.product_uoms pu
        WHERE pu.company_id = NEW.company_id
          AND pu.product_id = NEW.item_id
          AND pu.uom_id = NEW.component_uom_id
          AND pu.is_active
    ) THEN
        RAISE EXCEPTION 'ACTIVE_COMPONENT_UOM_NOT_FOUND';
    END IF;
    IF NEW.component_qty IS NULL OR NEW.component_qty <= 0 THEN
        RAISE EXCEPTION 'BUNDLE_COMPONENT_QUANTITY_INVALID';
    END IF;

    -- Keep the legacy quantity column synchronized during expand compatibility.
    NEW.qty := NEW.component_qty;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g3_reject_bundle_physical_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.products p
        WHERE p.company_id = NEW.company_id
          AND p.id = NEW.product_id
          AND p.is_bundle
    ) THEN
        RAISE EXCEPTION 'BUNDLE_PHYSICAL_STOCK_NOT_ALLOWED';
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g3_guard_product_type()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.trg_g3_guard_bundle_component()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.trg_g3_reject_bundle_physical_stock()
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g3_guard_product_type(),
    private.trg_g3_guard_bundle_component(),
    private.trg_g3_reject_bundle_physical_stock()
TO service_role;

CREATE TRIGGER g3_guard_product_type
BEFORE UPDATE OF is_bundle ON public.products
FOR EACH ROW EXECUTE FUNCTION private.trg_g3_guard_product_type();

CREATE TRIGGER g3_guard_bundle_component
BEFORE INSERT OR UPDATE ON public.product_bundle_items
FOR EACH ROW EXECUTE FUNCTION private.trg_g3_guard_bundle_component();

CREATE TRIGGER g3_touch_bundle_component
BEFORE INSERT OR UPDATE ON public.product_bundle_items
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();

CREATE TRIGGER g3_reject_bundle_product_stock
BEFORE INSERT OR UPDATE OF company_id,product_id ON public.product_stocks
FOR EACH ROW EXECUTE FUNCTION private.trg_g3_reject_bundle_physical_stock();

CREATE TRIGGER g3_reject_bundle_stock_movement
BEFORE INSERT OR UPDATE OF company_id,product_id ON public.stock_movements
FOR EACH ROW EXECUTE FUNCTION private.trg_g3_reject_bundle_physical_stock();

CREATE TRIGGER g3_reject_bundle_fifo_batch
BEFORE INSERT OR UPDATE OF company_id,product_id ON public.product_batches
FOR EACH ROW EXECUTE FUNCTION private.trg_g3_reject_bundle_physical_stock();

-- -------------------------------------------------------------------------
-- 3. Private expansion contract for future G4 checkout
-- -------------------------------------------------------------------------

CREATE FUNCTION private.resolve_bundle_components(
    p_company_id UUID,
    p_bundle_id UUID,
    p_bundle_qty NUMERIC
)
RETURNS TABLE (
    component_product_id UUID,
    component_uom_id UUID,
    component_qty_per_bundle NUMERIC,
    factor_to_base NUMERIC,
    total_component_qty NUMERIC,
    total_base_qty NUMERIC,
    line_no SMALLINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF p_bundle_qty IS NULL OR p_bundle_qty <= 0 THEN
        RAISE EXCEPTION 'BUNDLE_QUANTITY_INVALID';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.products p
        WHERE p.company_id = p_company_id
          AND p.id = p_bundle_id
          AND p.is_active
          AND p.is_bundle
    ) THEN
        RAISE EXCEPTION 'ACTIVE_BUNDLE_NOT_FOUND';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.product_bundle_items bi
        WHERE bi.company_id = p_company_id
          AND bi.bundle_id = p_bundle_id
    ) THEN
        RAISE EXCEPTION 'BUNDLE_COMPONENTS_REQUIRED';
    END IF;

    RETURN QUERY
    SELECT
        bi.item_id,
        bi.component_uom_id,
        bi.component_qty,
        pu.factor_to_base,
        bi.component_qty * p_bundle_qty,
        bi.component_qty * p_bundle_qty * pu.factor_to_base,
        bi.line_no
    FROM public.product_bundle_items bi
    JOIN public.products component
      ON component.company_id = bi.company_id
     AND component.id = bi.item_id
     AND component.is_active
     AND NOT component.is_bundle
    JOIN public.product_uoms pu
      ON pu.company_id = bi.company_id
     AND pu.product_id = bi.item_id
     AND pu.uom_id = bi.component_uom_id
     AND pu.is_active
    WHERE bi.company_id = p_company_id
      AND bi.bundle_id = p_bundle_id
    ORDER BY bi.line_no;
END;
$$;

REVOKE ALL ON FUNCTION private.resolve_bundle_components(UUID,UUID,NUMERIC)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.resolve_bundle_components(UUID,UUID,NUMERIC)
TO service_role;

-- -------------------------------------------------------------------------
-- 4. Atomic guarded Bundle Product + composition save
-- -------------------------------------------------------------------------

CREATE FUNCTION public.save_bundle_with_components(
    p_bundle_id UUID,
    p_master_version BIGINT,
    p_sku TEXT,
    p_name TEXT,
    p_category_id UUID,
    p_sales_uom_id UUID,
    p_sale_price NUMERIC,
    p_barcode TEXT,
    p_image_url TEXT,
    p_is_active BOOLEAN,
    p_components JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_bundle_id UUID := COALESCE(p_bundle_id,gen_random_uuid());
    v_existing public.products%ROWTYPE;
    v_category_name TEXT;
    v_sales_uom_code TEXT;
    v_item JSONB;
    v_line_no INTEGER;
    v_component_id UUID;
    v_component_uom_id UUID;
    v_component_qty NUMERIC(24,6);
    v_component_factor NUMERIC(24,6);
    v_component_weight NUMERIC(14,3);
    v_weight_reference_factor NUMERIC(24,6);
    v_bundle_weight NUMERIC(24,6) := 0;
    v_seen TEXT[] := ARRAY[]::TEXT[];
    v_key TEXT;
    v_before JSONB;
    v_after JSONB;
    v_result_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'AUTHENTICATION_REQUIRED';
    END IF;
    IF v_company IS NULL THEN
        RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND';
    END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,
        ARRAY[
            'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'
        ]::TEXT[]
    ) THEN
        RAISE EXCEPTION 'CATALOG_MANAGER_REQUIRED';
    END IF;
    IF btrim(COALESCE(p_sku,'')) = ''
       OR char_length(btrim(p_sku)) > 100 THEN
        RAISE EXCEPTION 'INVALID_PRODUCT_SKU';
    END IF;
    IF btrim(COALESCE(p_name,'')) = ''
       OR char_length(btrim(p_name)) > 200 THEN
        RAISE EXCEPTION 'INVALID_PRODUCT_NAME';
    END IF;
    IF p_sale_price IS NULL OR p_sale_price < 0 THEN
        RAISE EXCEPTION 'BUNDLE_SALE_PRICE_INVALID';
    END IF;
    IF p_barcode IS NOT NULL AND btrim(p_barcode) = '' THEN
        RAISE EXCEPTION 'BUNDLE_BARCODE_INVALID';
    END IF;
    IF p_image_url IS NOT NULL
       AND btrim(p_image_url) <> ''
       AND btrim(p_image_url) !~* '^https://' THEN
        RAISE EXCEPTION 'PRODUCT_IMAGE_HTTPS_REQUIRED';
    END IF;
    IF jsonb_typeof(p_components) IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_components) = 0
       OR jsonb_array_length(p_components) > 100 THEN
        RAISE EXCEPTION 'BUNDLE_COMPONENTS_ARRAY_REQUIRED';
    END IF;

    SELECT pc.category_name INTO v_category_name
    FROM public.product_categories pc
    WHERE pc.company_id = v_company
      AND pc.id = p_category_id
      AND pc.is_active;
    IF v_category_name IS NULL THEN
        RAISE EXCEPTION 'ACTIVE_PRODUCT_CATEGORY_NOT_FOUND';
    END IF;

    SELECT u.code INTO v_sales_uom_code
    FROM public.uoms u
    WHERE u.company_id = v_company
      AND u.id = p_sales_uom_id
      AND u.is_active;
    IF v_sales_uom_code IS NULL THEN
        RAISE EXCEPTION 'ACTIVE_BUNDLE_SALES_UOM_NOT_FOUND';
    END IF;

    FOR v_item,v_line_no IN
        SELECT value,ordinality::INTEGER
        FROM jsonb_array_elements(p_components) WITH ORDINALITY
    LOOP
        BEGIN
            v_component_id := (v_item->>'productId')::UUID;
            v_component_uom_id := (v_item->>'uomId')::UUID;
            v_component_qty := (v_item->>'quantity')::NUMERIC;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'INVALID_BUNDLE_COMPONENT_ROW';
        END;

        IF v_component_qty IS NULL OR v_component_qty <= 0 THEN
            RAISE EXCEPTION 'BUNDLE_COMPONENT_QUANTITY_INVALID';
        END IF;
        IF v_component_id = v_bundle_id THEN
            RAISE EXCEPTION 'BUNDLE_SELF_COMPONENT_NOT_ALLOWED';
        END IF;
        IF EXISTS (
            SELECT 1 FROM public.products p
            WHERE p.company_id = v_company
              AND p.id = v_component_id
              AND p.is_bundle
        ) THEN
            RAISE EXCEPTION 'NESTED_BUNDLE_NOT_ALLOWED';
        END IF;
        v_key := v_component_id::TEXT || '|' || v_component_uom_id::TEXT;
        IF v_key = ANY(v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_BUNDLE_COMPONENT';
        END IF;
        v_seen := array_append(v_seen,v_key);

        SELECT
            selected_uom.factor_to_base,
            component.weight_per_uom_kg,
            reference_uom.factor_to_base
        INTO
            v_component_factor,
            v_component_weight,
            v_weight_reference_factor
        FROM public.products component
        JOIN public.product_uoms selected_uom
          ON selected_uom.company_id = component.company_id
         AND selected_uom.product_id = component.id
         AND selected_uom.uom_id = v_component_uom_id
         AND selected_uom.is_active
        JOIN public.product_uoms reference_uom
          ON reference_uom.company_id = component.company_id
         AND reference_uom.product_id = component.id
         AND reference_uom.uom_id = component.weight_reference_uom_id
         AND reference_uom.is_active
        WHERE component.company_id = v_company
          AND component.id = v_component_id
          AND component.is_active
          AND NOT component.is_bundle;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'ACTIVE_STOCK_COMPONENT_UOM_NOT_FOUND';
        END IF;
        IF v_component_weight <= 0
           OR v_weight_reference_factor <= 0 THEN
            RAISE EXCEPTION 'COMPONENT_WEIGHT_CONTRACT_INVALID';
        END IF;

        v_bundle_weight := v_bundle_weight
            + (
                v_component_qty
                * v_component_factor
                * v_component_weight
                / v_weight_reference_factor
            );
    END LOOP;

    IF p_bundle_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;

        INSERT INTO public.products(
            id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
            weight_reference_uom_id,weight_per_uom_kg,is_bundle,is_active,
            image_url,created_by,updated_by
        ) VALUES (
            v_bundle_id,v_company,upper(btrim(p_sku)),btrim(p_name),
            v_category_name,p_category_id,p_sale_price,0,
            upper(btrim(v_sales_uom_code)),p_sales_uom_id,
            p_sales_uom_id,round(v_bundle_weight,3),TRUE,
            COALESCE(p_is_active,TRUE),NULLIF(btrim(p_image_url),''),
            v_actor,v_actor
        )
        RETURNING master_version INTO v_result_version;
    ELSE
        SELECT p.* INTO v_existing
        FROM public.products p
        WHERE p.company_id = v_company
          AND p.id = p_bundle_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'BUNDLE_PRODUCT_NOT_FOUND';
        END IF;
        IF NOT v_existing.is_bundle THEN
            RAISE EXCEPTION 'PRODUCT_TYPE_IMMUTABLE';
        END IF;
        IF p_master_version IS NULL
           OR p_master_version <> v_existing.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;

        SELECT jsonb_build_object(
            'product',to_jsonb(p),
            'uoms',COALESCE((
                SELECT jsonb_agg(to_jsonb(pu) ORDER BY pu.id)
                FROM public.product_uoms pu
                WHERE pu.company_id = p.company_id
                  AND pu.product_id = p.id
            ),'[]'::jsonb),
            'components',COALESCE((
                SELECT jsonb_agg(to_jsonb(bi) ORDER BY bi.line_no)
                FROM public.product_bundle_items bi
                WHERE bi.company_id = p.company_id
                  AND bi.bundle_id = p.id
            ),'[]'::jsonb)
        ) INTO v_before
        FROM public.products p
        WHERE p.company_id = v_company AND p.id = p_bundle_id;

        UPDATE public.products
        SET sku = upper(btrim(p_sku)),
            name = btrim(p_name),
            category = v_category_name,
            category_id = p_category_id,
            price = p_sale_price,
            cogs = 0,
            uom = upper(btrim(v_sales_uom_code)),
            uom_id = p_sales_uom_id,
            weight_reference_uom_id = p_sales_uom_id,
            weight_per_uom_kg = round(v_bundle_weight,3),
            is_active = COALESCE(p_is_active,TRUE),
            image_url = NULLIF(btrim(p_image_url),''),
            updated_by = v_actor
        WHERE company_id = v_company AND id = p_bundle_id
        RETURNING master_version INTO v_result_version;
    END IF;

    UPDATE public.product_uoms
    SET is_active = FALSE,
        purchase_allowed = FALSE,
        sales_allowed = FALSE,
        updated_by = v_actor
    WHERE company_id = v_company
      AND product_id = v_bundle_id
      AND uom_id <> p_sales_uom_id;

    INSERT INTO public.product_uoms(
        company_id,product_id,uom_id,factor_to_base,
        purchase_allowed,sales_allowed,purchase_price,sale_price,
        barcode,is_active,created_by,updated_by
    ) VALUES (
        v_company,v_bundle_id,p_sales_uom_id,1,
        FALSE,TRUE,NULL,p_sale_price,
        NULLIF(btrim(p_barcode),''),TRUE,v_actor,v_actor
    )
    ON CONFLICT (company_id,product_id,uom_id) DO UPDATE SET
        factor_to_base = 1,
        purchase_allowed = FALSE,
        sales_allowed = TRUE,
        purchase_price = NULL,
        sale_price = EXCLUDED.sale_price,
        barcode = EXCLUDED.barcode,
        is_active = TRUE,
        updated_by = v_actor;

    DELETE FROM public.product_bundle_items
    WHERE company_id = v_company AND bundle_id = v_bundle_id;

    FOR v_item,v_line_no IN
        SELECT value,ordinality::INTEGER
        FROM jsonb_array_elements(p_components) WITH ORDINALITY
    LOOP
        INSERT INTO public.product_bundle_items(
            company_id,bundle_id,item_id,qty,
            component_uom_id,component_qty,line_no,
            created_by,updated_by
        ) VALUES (
            v_company,v_bundle_id,(v_item->>'productId')::UUID,
            (v_item->>'quantity')::NUMERIC,
            (v_item->>'uomId')::UUID,(v_item->>'quantity')::NUMERIC,
            v_line_no,v_actor,v_actor
        );
    END LOOP;

    SELECT jsonb_build_object(
        'product',to_jsonb(p),
        'uoms',COALESCE((
            SELECT jsonb_agg(to_jsonb(pu) ORDER BY pu.id)
            FROM public.product_uoms pu
            WHERE pu.company_id = p.company_id
              AND pu.product_id = p.id
        ),'[]'::jsonb),
        'components',COALESCE((
            SELECT jsonb_agg(to_jsonb(bi) ORDER BY bi.line_no)
            FROM public.product_bundle_items bi
            WHERE bi.company_id = p.company_id
              AND bi.bundle_id = p.id
        ),'[]'::jsonb)
    ) INTO v_after
    FROM public.products p
    WHERE p.company_id = v_company AND p.id = v_bundle_id;

    INSERT INTO public.product_master_audit(
        company_id,product_id,action,actor_id,before_snapshot,after_snapshot
    ) VALUES (
        v_company,v_bundle_id,
        CASE WHEN p_bundle_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
        v_actor,v_before,v_after
    );
    INSERT INTO public.product_bundle_master_audit(
        company_id,bundle_id,action,actor_id,before_snapshot,after_snapshot
    ) VALUES (
        v_company,v_bundle_id,
        CASE WHEN p_bundle_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
        v_actor,v_before,v_after
    );

    RETURN jsonb_build_object(
        'bundleId',v_bundle_id,
        'masterVersion',v_result_version,
        'derivedWeightKg',round(v_bundle_weight,3),
        'action',CASE WHEN p_bundle_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END
    );
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'DUPLICATE_BUNDLE_OR_BARCODE';
END;
$$;

-- -------------------------------------------------------------------------
-- 5. Reviewer availability read model
-- -------------------------------------------------------------------------

CREATE FUNCTION public.get_bundle_availability(
    p_bundle_id UUID,
    p_warehouse_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_company UUID := public.private_active_company_id();
    v_available BIGINT;
    v_components JSONB;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHENTICATION_REQUIRED';
    END IF;
    IF v_company IS NULL THEN
        RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND';
    END IF;
    IF NOT public.private_inventory_reviewer_visible(v_company) THEN
        RAISE EXCEPTION 'INVENTORY_REVIEWER_REQUIRED';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.warehouses w
        WHERE w.company_id = v_company
          AND w.id = p_warehouse_id
          AND w.is_active
    ) THEN
        RAISE EXCEPTION 'ACTIVE_WAREHOUSE_NOT_FOUND';
    END IF;

    WITH resolved AS (
        SELECT *
        FROM private.resolve_bundle_components(v_company,p_bundle_id,1)
    ), capacity AS (
        SELECT
            r.*,
            p.name AS component_name,
            u.name AS component_uom_name,
            COALESCE(ps.stock_qty,0) AS on_hand_base_qty,
            floor(
                COALESCE(ps.stock_qty,0) / NULLIF(r.total_base_qty,0)
            )::BIGINT AS component_capacity
        FROM resolved r
        JOIN public.products p
          ON p.company_id = v_company
         AND p.id = r.component_product_id
        JOIN public.uoms u
          ON u.company_id = v_company
         AND u.id = r.component_uom_id
        LEFT JOIN public.product_stocks ps
          ON ps.company_id = v_company
         AND ps.product_id = r.component_product_id
         AND ps.warehouse_id = p_warehouse_id
    )
    SELECT
        COALESCE(min(component_capacity),0),
        COALESCE(jsonb_agg(
            jsonb_build_object(
                'componentProductId',component_product_id,
                'componentName',component_name,
                'componentUomId',component_uom_id,
                'componentUomName',component_uom_name,
                'quantityPerBundle',component_qty_per_bundle,
                'requiredBaseQty',total_base_qty,
                'onHandBaseQty',on_hand_base_qty,
                'capacity',component_capacity
            )
            ORDER BY line_no
        ),'[]'::jsonb)
    INTO v_available,v_components
    FROM capacity;

    RETURN jsonb_build_object(
        'bundleId',p_bundle_id,
        'warehouseId',p_warehouse_id,
        'availableQuantity',v_available,
        'components',v_components
    );
END;
$$;

-- -------------------------------------------------------------------------
-- 6. RLS and exact privileges
-- -------------------------------------------------------------------------

ALTER TABLE public.product_bundle_master_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Bundle audit readable by catalog managers"
ON public.product_bundle_master_audit FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY[
            'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER',
            'WAREHOUSE_ADMIN','FINANCE','ACCOUNTING'
        ]::TEXT[]
    )
);

REVOKE INSERT,UPDATE,DELETE ON public.product_bundle_items
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.product_bundle_items TO authenticated;
GRANT ALL ON public.product_bundle_items TO service_role;

REVOKE ALL ON public.product_bundle_master_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.product_bundle_master_audit TO authenticated;
GRANT ALL ON public.product_bundle_master_audit TO service_role;

REVOKE ALL ON FUNCTION public.save_bundle_with_components(
    UUID,BIGINT,TEXT,TEXT,UUID,UUID,NUMERIC,TEXT,TEXT,BOOLEAN,JSONB
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_bundle_with_components(
    UUID,BIGINT,TEXT,TEXT,UUID,UUID,NUMERIC,TEXT,TEXT,BOOLEAN,JSONB
) TO authenticated,service_role;

REVOKE ALL ON FUNCTION public.get_bundle_availability(UUID,UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_bundle_availability(UUID,UUID)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260729010000',
    'g3_phase12_bundle_foundation',
    'STK-006 atomic Bundle Product/composition master, immutable Product type, virtual-stock guards, audit/versioning, private expansion, and reviewer availability; checkout remains G4'
);

COMMIT;
