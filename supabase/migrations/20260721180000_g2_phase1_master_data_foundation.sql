-- KGS POS G2 phase 1: additive canonical master-data foundation.
-- Requirements: MST-001, MST-002, MST-003, MST-004
-- Dependency: G1 security closure through 20260721150000.
--
-- EXPAND-ONLY COMPATIBILITY:
-- - legacy products.category and products.uom remain available;
-- - legacy product_uom_conversions remains available;
-- - new canonical category/product-UOM references are nullable on Product;
-- - no legacy import or active UI path is cut over in this phase.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260721150000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G1 security closure chain is incomplete';
    END IF;

    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260721180000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260721180000';
    END IF;
END
$migration_guard$;

-- The approved preflight reported an empty legacy master surface. Stop if the
-- state changed; generating Category codes or Warehouse types is a business
-- decision and must never happen silently.
DO $empty_surface_guard$
DECLARE
    v_products BIGINT;
    v_uoms BIGINT;
    v_warehouses BIGINT;
    v_conversions BIGINT;
BEGIN
    SELECT count(*) INTO v_products FROM public.products;
    SELECT count(*) INTO v_uoms FROM public.uoms;
    SELECT count(*) INTO v_warehouses FROM public.warehouses;
    SELECT count(*) INTO v_conversions FROM public.product_uom_conversions;

    IF v_products <> 0 OR v_uoms <> 0
       OR v_warehouses <> 0 OR v_conversions <> 0 THEN
        RAISE EXCEPTION
            'G2_PHASE1_STATE_CHANGED: products %, uoms %, warehouses %, conversions %; rerun preflight and design explicit backfill',
            v_products, v_uoms, v_warehouses, v_conversions;
    END IF;
END
$empty_surface_guard$;

-- -------------------------------------------------------------------------
-- 1. Product Category master
-- -------------------------------------------------------------------------

CREATE TABLE public.product_categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    category_code TEXT NOT NULL,
    category_name TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT product_categories_company_id_id_unique
        UNIQUE (company_id, id),
    CONSTRAINT product_categories_code_not_blank
        CHECK (btrim(category_code) <> ''),
    CONSTRAINT product_categories_name_not_blank
        CHECK (btrim(category_name) <> ''),
    CONSTRAINT product_categories_version_positive
        CHECK (master_version > 0)
);

CREATE UNIQUE INDEX uq_product_categories_company_normalized_code
    ON public.product_categories (
        company_id,
        upper(regexp_replace(btrim(category_code), '\s+', ' ', 'g'))
    );
CREATE UNIQUE INDEX uq_product_categories_company_normalized_name
    ON public.product_categories (
        company_id,
        lower(regexp_replace(btrim(category_name), '\s+', ' ', 'g'))
    );
CREATE INDEX idx_product_categories_company_active
    ON public.product_categories (company_id, is_active, category_name);

-- COA fallback columns are intentionally deferred. Their final count and
-- requiredness belong to the Finance/Transaction Category contract.

-- -------------------------------------------------------------------------
-- 2. Expand existing UOM, Warehouse, and Product masters
-- -------------------------------------------------------------------------

ALTER TABLE public.uoms
    ADD COLUMN uom_type TEXT NOT NULL DEFAULT 'UNIT',
    ADD COLUMN allow_decimal BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN decimal_precision SMALLINT NOT NULL DEFAULT 0,
    ADD COLUMN is_active BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN master_version BIGINT NOT NULL DEFAULT 1,
    ADD COLUMN created_by UUID REFERENCES public.profiles(id),
    ADD COLUMN updated_by UUID REFERENCES public.profiles(id),
    ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    ADD CONSTRAINT uoms_type_check CHECK (
        uom_type IN ('UNIT','PACKAGING','WEIGHT','VOLUME','LENGTH','OTHER')
    ),
    ADD CONSTRAINT uoms_precision_check CHECK (
        (NOT allow_decimal AND decimal_precision = 0)
        OR (allow_decimal AND decimal_precision BETWEEN 1 AND 6)
    ),
    ADD CONSTRAINT uoms_version_positive CHECK (master_version > 0),
    ADD CONSTRAINT uoms_code_not_blank CHECK (btrim(code) <> ''),
    ADD CONSTRAINT uoms_name_not_blank CHECK (btrim(name) <> '');

CREATE UNIQUE INDEX uq_uoms_company_normalized_name
    ON public.uoms (
        company_id,
        lower(regexp_replace(btrim(name), '\s+', ' ', 'g'))
    );
CREATE INDEX idx_uoms_company_active
    ON public.uoms (company_id, is_active, code);

ALTER TABLE public.warehouses
    ADD COLUMN warehouse_type TEXT,
    ADD COLUMN store_id UUID,
    ADD COLUMN location TEXT,
    ADD COLUMN is_sale_source BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN is_purchase_destination BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN allow_negative_stock BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN master_version BIGINT NOT NULL DEFAULT 1,
    ADD COLUMN created_by UUID REFERENCES public.profiles(id),
    ADD COLUMN updated_by UUID REFERENCES public.profiles(id),
    ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    ADD CONSTRAINT warehouses_type_check CHECK (
        warehouse_type IS NULL
        OR warehouse_type IN ('CENTRAL','STORE','DAMAGED','TRANSIT')
    ),
    ADD CONSTRAINT warehouses_store_scope_check CHECK (
        warehouse_type IS DISTINCT FROM 'STORE' OR store_id IS NOT NULL
    ),
    ADD CONSTRAINT warehouses_nonnegative_only_check CHECK (
        allow_negative_stock = FALSE
    ),
    ADD CONSTRAINT warehouses_version_positive CHECK (master_version > 0),
    ADD CONSTRAINT fk_warehouses_company_store
        FOREIGN KEY (company_id, store_id)
        REFERENCES public.stores(company_id, id) ON DELETE RESTRICT;

CREATE INDEX idx_warehouses_company_store
    ON public.warehouses (company_id, store_id)
    WHERE store_id IS NOT NULL;
CREATE INDEX idx_warehouses_company_type_active
    ON public.warehouses (company_id, warehouse_type, is_active);

-- warehouse_type remains nullable during expand compatibility because the
-- current Company provisioning/import paths do not supply it yet. G2 cutover
-- will update those paths before the column becomes mandatory.

ALTER TABLE public.products
    ADD COLUMN category_id UUID,
    ADD COLUMN weight_reference_uom_id UUID,
    ADD COLUMN image_url TEXT,
    ADD COLUMN master_version BIGINT NOT NULL DEFAULT 1,
    ADD COLUMN created_by UUID REFERENCES public.profiles(id),
    ADD COLUMN updated_by UUID REFERENCES public.profiles(id),
    ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    ADD CONSTRAINT products_version_positive CHECK (master_version > 0),
    ADD CONSTRAINT products_external_image_https_check CHECK (
        image_url IS NULL OR image_url ~* '^https://'
    ),
    ADD CONSTRAINT fk_products_company_category
        FOREIGN KEY (company_id, category_id)
        REFERENCES public.product_categories(company_id, id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT fk_products_company_weight_reference_uom
        FOREIGN KEY (company_id, weight_reference_uom_id)
        REFERENCES public.uoms(company_id, id)
        ON DELETE RESTRICT;

CREATE INDEX idx_products_company_category
    ON public.products (company_id, category_id);
CREATE INDEX idx_products_company_weight_reference_uom
    ON public.products (company_id, weight_reference_uom_id);
CREATE UNIQUE INDEX uq_products_company_normalized_name
    ON public.products (
        company_id,
        lower(regexp_replace(btrim(name), '\s+', ' ', 'g'))
    );

-- -------------------------------------------------------------------------
-- 3. Canonical Product-UOM and manual price master
-- -------------------------------------------------------------------------

CREATE TABLE public.product_uoms (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    product_id UUID NOT NULL,
    uom_id UUID NOT NULL,
    factor_to_base NUMERIC(24,6) NOT NULL,
    purchase_allowed BOOLEAN NOT NULL DEFAULT FALSE,
    sales_allowed BOOLEAN NOT NULL DEFAULT FALSE,
    purchase_price NUMERIC(20,4),
    sale_price NUMERIC(20,4),
    barcode TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    conversion_version BIGINT NOT NULL DEFAULT 1,
    master_version BIGINT NOT NULL DEFAULT 1,
    effective_from TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT product_uoms_company_id_id_unique
        UNIQUE (company_id, id),
    CONSTRAINT product_uoms_company_product_uom_unique
        UNIQUE (company_id, product_id, uom_id),
    CONSTRAINT fk_product_uoms_company_product
        FOREIGN KEY (company_id, product_id)
        REFERENCES public.products(company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_product_uoms_company_uom
        FOREIGN KEY (company_id, uom_id)
        REFERENCES public.uoms(company_id, id) ON DELETE RESTRICT,
    CONSTRAINT product_uoms_factor_positive CHECK (factor_to_base > 0),
    CONSTRAINT product_uoms_purchase_price_check CHECK (
        purchase_price IS NULL OR purchase_price >= 0
    ),
    CONSTRAINT product_uoms_sale_price_check CHECK (
        sale_price IS NULL OR sale_price >= 0
    ),
    CONSTRAINT product_uoms_purchase_enabled_price_check CHECK (
        NOT purchase_allowed OR purchase_price IS NOT NULL
    ),
    CONSTRAINT product_uoms_sales_enabled_price_check CHECK (
        NOT sales_allowed OR sale_price IS NOT NULL
    ),
    CONSTRAINT product_uoms_conversion_version_positive
        CHECK (conversion_version > 0),
    CONSTRAINT product_uoms_master_version_positive
        CHECK (master_version > 0),
    CONSTRAINT product_uoms_barcode_not_blank CHECK (
        barcode IS NULL OR btrim(barcode) <> ''
    )
);

CREATE UNIQUE INDEX uq_product_uoms_company_normalized_barcode
    ON public.product_uoms (
        company_id,
        upper(regexp_replace(btrim(barcode), '\s+', '', 'g'))
    )
    WHERE barcode IS NOT NULL;
CREATE INDEX idx_product_uoms_company_active_sales
    ON public.product_uoms (company_id, product_id, sales_allowed)
    WHERE is_active;

-- -------------------------------------------------------------------------
-- 4. Version/audit and historical conversion guards
-- -------------------------------------------------------------------------

CREATE FUNCTION private.trg_g2_touch_master()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.master_version := COALESCE(NEW.master_version, 1);
        NEW.created_at := COALESCE(NEW.created_at, clock_timestamp());
        NEW.updated_at := COALESCE(NEW.updated_at, NEW.created_at);
        IF auth.uid() IS NOT NULL THEN
            NEW.created_by := COALESCE(NEW.created_by, auth.uid());
            NEW.updated_by := COALESCE(NEW.updated_by, auth.uid());
        END IF;
    ELSE
        NEW.master_version := OLD.master_version + 1;
        NEW.updated_at := clock_timestamp();
        IF auth.uid() IS NOT NULL THEN
            NEW.updated_by := auth.uid();
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g2_guard_product_base_uom()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.uom_id IS DISTINCT FROM OLD.uom_id
       AND EXISTS (
           SELECT 1 FROM public.stock_movements sm
           WHERE sm.company_id = OLD.company_id
             AND sm.product_id = OLD.id
       ) THEN
        RAISE EXCEPTION 'PRODUCT_BASE_UOM_LOCKED_BY_MOVEMENT';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g2_guard_product_uom()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_base_uom_id UUID;
BEGIN
    SELECT p.uom_id INTO v_base_uom_id
    FROM public.products p
    WHERE p.company_id = NEW.company_id
      AND p.id = NEW.product_id;

    IF v_base_uom_id IS NOT NULL
       AND NEW.uom_id = v_base_uom_id
       AND NEW.factor_to_base <> 1 THEN
        RAISE EXCEPTION 'BASE_UOM_FACTOR_MUST_EQUAL_ONE';
    END IF;

    IF TG_OP = 'UPDATE'
       AND (
           NEW.company_id IS DISTINCT FROM OLD.company_id
           OR NEW.product_id IS DISTINCT FROM OLD.product_id
           OR NEW.uom_id IS DISTINCT FROM OLD.uom_id
           OR NEW.factor_to_base IS DISTINCT FROM OLD.factor_to_base
       )
       AND EXISTS (
           SELECT 1 FROM public.stock_movements sm
           WHERE sm.company_id = OLD.company_id
             AND sm.product_id = OLD.product_id
       ) THEN
        RAISE EXCEPTION 'PRODUCT_UOM_CONVERSION_LOCKED_BY_MOVEMENT';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF NEW.factor_to_base IS DISTINCT FROM OLD.factor_to_base THEN
            NEW.conversion_version := OLD.conversion_version + 1;
        ELSE
            NEW.conversion_version := OLD.conversion_version;
        END IF;
    ELSE
        NEW.conversion_version := COALESCE(NEW.conversion_version, 1);
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_touch_master()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.trg_g2_guard_product_base_uom()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.trg_g2_guard_product_uom()
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_touch_master(),
    private.trg_g2_guard_product_base_uom(),
    private.trg_g2_guard_product_uom()
TO service_role;

CREATE TRIGGER g2_touch_product_categories
BEFORE INSERT OR UPDATE ON public.product_categories
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();
CREATE TRIGGER g2_touch_uoms
BEFORE INSERT OR UPDATE ON public.uoms
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();
CREATE TRIGGER g2_touch_warehouses
BEFORE INSERT OR UPDATE ON public.warehouses
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();
CREATE TRIGGER g2_guard_products_base_uom
BEFORE UPDATE ON public.products
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_guard_product_base_uom();
CREATE TRIGGER g2_touch_products
BEFORE INSERT OR UPDATE ON public.products
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();
CREATE TRIGGER g2_guard_product_uoms
BEFORE INSERT OR UPDATE ON public.product_uoms
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_guard_product_uom();
CREATE TRIGGER g2_touch_product_uoms
BEFORE INSERT OR UPDATE ON public.product_uoms
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();

-- -------------------------------------------------------------------------
-- 5. Active-Company RLS and exact browser grants for new tables
-- -------------------------------------------------------------------------

ALTER TABLE public.product_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_uoms ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Product categories readable in active Company"
ON public.product_categories FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);
CREATE POLICY "Product categories insertable by catalog managers"
ON public.product_categories FOR INSERT TO authenticated
WITH CHECK (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN']::TEXT[]
    )
);
CREATE POLICY "Product categories updateable by catalog managers"
ON public.product_categories FOR UPDATE TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN']::TEXT[]
    )
)
WITH CHECK (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN']::TEXT[]
    )
);

CREATE POLICY "Product UOM readable in active Company"
ON public.product_uoms FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);
CREATE POLICY "Product UOM insertable by catalog managers"
ON public.product_uoms FOR INSERT TO authenticated
WITH CHECK (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN']::TEXT[]
    )
);
CREATE POLICY "Product UOM updateable by catalog managers"
ON public.product_uoms FOR UPDATE TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN']::TEXT[]
    )
)
WITH CHECK (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN']::TEXT[]
    )
);

REVOKE ALL ON public.product_categories, public.product_uoms
FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE
ON public.product_categories, public.product_uoms
TO authenticated;
GRANT ALL ON public.product_categories, public.product_uoms TO service_role;

INSERT INTO private.kgs_schema_migrations(version, migration_name, notes)
VALUES (
    '20260721180000',
    'g2_phase1_master_data_foundation',
    'MST-001..004 expand-only Product Category, Product-UOM, UOM/Warehouse/Product metadata, master versioning, and history guards'
);

COMMIT;
