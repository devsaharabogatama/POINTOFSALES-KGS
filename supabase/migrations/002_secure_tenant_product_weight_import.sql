-- Security hardening, tenant-scoped master keys, and atomic product import.
-- Apply after 001_multi_company_setup.sql and inventory_migration.sql.

ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'super_admin';

ALTER TABLE public.products
    ADD COLUMN IF NOT EXISTS weight_per_uom_kg NUMERIC(14,3) NOT NULL DEFAULT 0;

ALTER TABLE public.products
    DROP CONSTRAINT IF EXISTS products_weight_per_uom_kg_check;
ALTER TABLE public.products
    ADD CONSTRAINT products_weight_per_uom_kg_check CHECK (weight_per_uom_kg >= 0);

-- Business identifiers may repeat in another tenant.
ALTER TABLE public.products DROP CONSTRAINT IF EXISTS products_sku_key;
ALTER TABLE public.warehouses DROP CONSTRAINT IF EXISTS warehouses_code_key;
ALTER TABLE public.customers DROP CONSTRAINT IF EXISTS customers_code_key;
ALTER TABLE public.uoms DROP CONSTRAINT IF EXISTS uoms_code_key;

CREATE UNIQUE INDEX IF NOT EXISTS uq_products_company_sku
    ON public.products (company_id, sku);
CREATE UNIQUE INDEX IF NOT EXISTS uq_warehouses_company_code
    ON public.warehouses (company_id, code);
CREATE UNIQUE INDEX IF NOT EXISTS uq_customers_company_code
    ON public.customers (company_id, code);
CREATE UNIQUE INDEX IF NOT EXISTS uq_uoms_company_code
    ON public.uoms (company_id, code);

CREATE OR REPLACE FUNCTION public.private_is_super_admin(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.profiles
        WHERE id = p_user_id
          AND role = 'super_admin'::user_role
    );
$$;

CREATE OR REPLACE FUNCTION public.private_user_has_company_access(p_company_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT public.private_is_super_admin(auth.uid())
        OR EXISTS (
            SELECT 1
            FROM public.company_memberships
            WHERE company_id = p_company_id
              AND user_id = auth.uid()
              AND status = 'ACTIVE'
        );
$$;

CREATE OR REPLACE FUNCTION public.get_user_role_in_company(p_company_id UUID)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT CASE
        WHEN public.private_is_super_admin(auth.uid()) THEN 'COMPANY_OWNER'
        ELSE (
            SELECT role_code
            FROM public.company_memberships
            WHERE company_id = p_company_id
              AND user_id = auth.uid()
              AND status = 'ACTIVE'
            LIMIT 1
        )
    END;
$$;

CREATE OR REPLACE FUNCTION public.private_user_has_store_access(p_store_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT public.private_is_super_admin(auth.uid())
        OR EXISTS (
            SELECT 1
            FROM public.stores s
            JOIN public.company_memberships cm ON cm.company_id = s.company_id
            WHERE s.id = p_store_id
              AND cm.user_id = auth.uid()
              AND cm.status = 'ACTIVE'
              AND cm.role_code IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
        )
        OR EXISTS (
            SELECT 1
            FROM public.store_memberships sm
            WHERE sm.store_id = p_store_id
              AND sm.user_id = auth.uid()
              AND sm.status = 'ACTIVE'
        );
$$;

-- The temporary bootstrap RPC made every login an owner of Company A.
DROP FUNCTION IF EXISTS public.bootstrap_tenant_data(UUID);

-- Tenant-core tables must be protected too.
ALTER TABLE public.stores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_terminals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_memberships ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Stores readable in accessible companies" ON public.stores;
CREATE POLICY "Stores readable in accessible companies" ON public.stores
    FOR SELECT TO authenticated
    USING (public.private_user_has_company_access(company_id));

DROP POLICY IF EXISTS "Stores manageable by company admins" ON public.stores;
CREATE POLICY "Stores manageable by company admins" ON public.stores
    FOR ALL TO authenticated
    USING (public.get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN'))
    WITH CHECK (public.get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN'));

DROP POLICY IF EXISTS "POS terminals readable in accessible companies" ON public.pos_terminals;
CREATE POLICY "POS terminals readable in accessible companies" ON public.pos_terminals
    FOR SELECT TO authenticated
    USING (public.private_user_has_company_access(company_id));

DROP POLICY IF EXISTS "Company memberships readable by authorized users" ON public.company_memberships;
CREATE POLICY "Company memberships readable by authorized users" ON public.company_memberships
    FOR SELECT TO authenticated
    USING (
        user_id = auth.uid()
        OR public.private_is_super_admin(auth.uid())
        OR public.get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
    );

DROP POLICY IF EXISTS "Store memberships readable by authorized users" ON public.store_memberships;
CREATE POLICY "Store memberships readable by authorized users" ON public.store_memberships
    FOR SELECT TO authenticated
    USING (
        user_id = auth.uid()
        OR public.private_is_super_admin(auth.uid())
        OR public.get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
    );

-- A company admin may only see profiles that share the same company.
DROP POLICY IF EXISTS "Profiles are viewable by owner, manager, or self" ON public.profiles;
CREATE POLICY "Profiles are viewable by authorized company users" ON public.profiles
    FOR SELECT TO authenticated
    USING (
        id = auth.uid()
        OR public.private_is_super_admin(auth.uid())
        OR EXISTS (
            SELECT 1
            FROM public.company_memberships mine
            JOIN public.company_memberships theirs
              ON theirs.company_id = mine.company_id
            WHERE mine.user_id = auth.uid()
              AND mine.status = 'ACTIVE'
              AND mine.role_code IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
              AND theirs.user_id = profiles.id
              AND theirs.status = 'ACTIVE'
        )
    );

DROP POLICY IF EXISTS "Profiles can be updated by owners or self" ON public.profiles;
CREATE POLICY "Profiles can update their own non privileged data" ON public.profiles
    FOR UPDATE TO authenticated
    USING (id = auth.uid())
    WITH CHECK (id = auth.uid());

-- Table-level UPDATE would also allow changing role. Grant only safe columns.
REVOKE UPDATE ON public.profiles FROM authenticated;
GRANT UPDATE (name) ON public.profiles TO authenticated;

-- Remove broad anonymous privileges introduced by fix_permissions.sql.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM anon;
GRANT USAGE ON SCHEMA public TO anon, authenticated;

-- Authenticated users need ordinary API access; RLS remains the authorization layer.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;
REVOKE UPDATE ON public.profiles FROM authenticated;
GRANT UPDATE (name) ON public.profiles TO authenticated;

CREATE OR REPLACE FUNCTION public.import_products_for_company(
    p_company_id UUID,
    p_rows JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_row JSONB;
    v_product_id UUID;
    v_uom_id UUID;
    v_warehouse_id UUID;
    v_stock_id UUID;
    v_existing_stock NUMERIC;
    v_batch_id UUID;
    v_count INTEGER := 0;
    v_sku TEXT;
    v_uom_code TEXT;
    v_warehouse_code TEXT;
    v_initial_stock NUMERIC;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHENTICATION_REQUIRED';
    END IF;

    IF public.get_user_role_in_company(p_company_id) NOT IN ('COMPANY_OWNER', 'COMPANY_ADMIN') THEN
        RAISE EXCEPTION 'COMPANY_ADMIN_REQUIRED';
    END IF;

    IF jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN
        RAISE EXCEPTION 'IMPORT_ROWS_REQUIRED';
    END IF;

    FOR v_row IN SELECT value FROM jsonb_array_elements(p_rows)
    LOOP
        v_sku := upper(trim(v_row->>'sku'));
        v_uom_code := upper(trim(v_row->>'uom_code'));
        v_warehouse_code := upper(trim(v_row->>'warehouse_code'));
        v_initial_stock := COALESCE((v_row->>'initial_stock')::NUMERIC, 0);

        IF v_sku = '' OR trim(v_row->>'name') = '' OR v_uom_code = '' OR v_warehouse_code = '' THEN
            RAISE EXCEPTION 'INVALID_IMPORT_ROW: sku, name, uom, and warehouse are required';
        END IF;
        IF v_initial_stock < 0 OR COALESCE((v_row->>'weight_per_uom_kg')::NUMERIC, 0) < 0 THEN
            RAISE EXCEPTION 'INVALID_IMPORT_ROW: stock and weight cannot be negative';
        END IF;

        INSERT INTO public.uoms (company_id, code, name)
        VALUES (p_company_id, v_uom_code, v_uom_code)
        ON CONFLICT (company_id, code) DO UPDATE SET name = EXCLUDED.name
        RETURNING id INTO v_uom_id;

        INSERT INTO public.warehouses (company_id, code, name, is_active)
        VALUES (p_company_id, v_warehouse_code, 'Gudang ' || v_warehouse_code, TRUE)
        ON CONFLICT (company_id, code) DO UPDATE SET is_active = TRUE
        RETURNING id INTO v_warehouse_id;

        INSERT INTO public.products (
            company_id, sku, name, category, price, cogs, uom, uom_id,
            weight_per_uom_kg, is_active
        ) VALUES (
            p_company_id, v_sku, trim(v_row->>'name'), NULLIF(trim(v_row->>'category'), ''),
            COALESCE((v_row->>'price')::NUMERIC, 0),
            COALESCE((v_row->>'cogs')::NUMERIC, 0),
            v_uom_code, v_uom_id,
            COALESCE((v_row->>'weight_per_uom_kg')::NUMERIC, 0), TRUE
        )
        ON CONFLICT (company_id, sku) DO UPDATE SET
            name = EXCLUDED.name,
            category = EXCLUDED.category,
            price = EXCLUDED.price,
            cogs = EXCLUDED.cogs,
            uom = EXCLUDED.uom,
            uom_id = EXCLUDED.uom_id,
            weight_per_uom_kg = EXCLUDED.weight_per_uom_kg,
            is_active = TRUE
        RETURNING id INTO v_product_id;

        SELECT id, stock_qty
        INTO v_stock_id, v_existing_stock
        FROM public.product_stocks
        WHERE company_id = p_company_id
          AND product_id = v_product_id
          AND warehouse_id = v_warehouse_id
        FOR UPDATE;

        IF v_stock_id IS NULL THEN
            INSERT INTO public.product_stocks (
                company_id, product_id, warehouse_id, stock_qty
            ) VALUES (
                p_company_id, v_product_id, v_warehouse_id, v_initial_stock
            );

            IF v_initial_stock > 0 THEN
                INSERT INTO public.product_batches (
                    company_id, product_id, warehouse_id,
                    qty_purchased, qty_remaining, cogs_unit
                ) VALUES (
                    p_company_id, v_product_id, v_warehouse_id,
                    v_initial_stock, v_initial_stock,
                    COALESCE((v_row->>'cogs')::NUMERIC, 0)
                ) RETURNING id INTO v_batch_id;

                INSERT INTO public.stock_movements (
                    company_id, product_id, warehouse_id, qty_change,
                    movement_type, reference_table, reference_id
                ) VALUES (
                    p_company_id, v_product_id, v_warehouse_id, v_initial_stock,
                    'PURCHASE'::stock_movement_type, 'product_batches', v_batch_id
                );
            END IF;
        ELSIF v_existing_stock <> v_initial_stock THEN
            RAISE EXCEPTION
                'INITIAL_STOCK_CONFLICT for SKU %: existing %, import %',
                v_sku, v_existing_stock, v_initial_stock;
        END IF;

        v_count := v_count + 1;
    END LOOP;

    RETURN jsonb_build_object('processed', v_count, 'company_id', p_company_id);
END;
$$;

REVOKE ALL ON FUNCTION public.import_products_for_company(UUID, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.import_products_for_company(UUID, JSONB) TO authenticated;
