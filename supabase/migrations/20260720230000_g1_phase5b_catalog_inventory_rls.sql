-- KGS POS G1 phase 5B: canonical catalog and inventory-read RLS.
-- Requirement: TEN-001, TEN-002
-- Dependency: 20260720210000_g1_phase5a_core_role_rls.sql
--
-- Direct balance/FIFO mutation remains forbidden. Catalog master mutation is
-- constrained by active Company and role. The legacy Product import remains
-- available through a guarded wrapper until G2 replaces its data contract.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260720210000'
       ) THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: G1 phase 5A not recorded';
    END IF;

    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260720230000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260720230000';
    END IF;
END
$migration_guard$;

DO $data_preflight$
DECLARE
    v_violations BIGINT;
BEGIN
    SELECT count(*) INTO v_violations
    FROM (
        SELECT ps.id
        FROM public.product_stocks ps
        WHERE ps.stock_qty < 0

        UNION ALL

        SELECT pb.id
        FROM public.product_batches pb
        WHERE pb.qty_purchased < 0
           OR pb.qty_remaining < 0
           OR pb.qty_remaining > pb.qty_purchased

    ) violations;

    IF v_violations > 0 THEN
        RAISE EXCEPTION 'G1_PHASE5B_DATA_PRECONDITION_FAILED: % violation(s)', v_violations;
    END IF;

    IF to_regprocedure('public.import_products_for_company(uuid,jsonb)') IS NULL THEN
        RAISE EXCEPTION 'G1_PHASE5B_IMPORT_RPC_PRECONDITION_FAILED';
    END IF;
END
$data_preflight$;

-- Preserve the legacy implementation by OID/name, remove it from the API
-- surface, and expose an active-Company guarded compatibility wrapper.
ALTER FUNCTION public.import_products_for_company(UUID, JSONB)
    RENAME TO private_import_products_for_company_g1_legacy;

REVOKE ALL ON FUNCTION
    public.private_import_products_for_company_g1_legacy(UUID, JSONB)
FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.import_products_for_company(
    p_company_id UUID,
    p_rows JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHENTICATION_REQUIRED';
    END IF;

    IF NOT public.private_request_company_matches(p_company_id) THEN
        RAISE EXCEPTION 'ACTIVE_COMPANY_MISMATCH';
    END IF;

    IF NOT public.private_user_has_any_company_role(
        p_company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    ) THEN
        RAISE EXCEPTION 'COMPANY_ADMIN_REQUIRED';
    END IF;

    RETURN public.private_import_products_for_company_g1_legacy(
        p_company_id,
        p_rows
    );
END;
$$;

DO $drop_catalog_policies$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT tablename, policyname
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = ANY(ARRAY[
              'products','product_bundle_items','product_stocks','customers',
              'uoms','product_uom_conversions','product_batches'
          ])
    LOOP
        EXECUTE format('DROP POLICY %I ON public.%I', r.policyname, r.tablename);
    END LOOP;
END
$drop_catalog_policies$;

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_bundle_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_stocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uoms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_uom_conversions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_batches ENABLE ROW LEVEL SECURITY;

-- Product and reusable Product master.
CREATE POLICY "Products readable in active Company"
ON public.products FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);
CREATE POLICY "Products insertable by catalog managers"
ON public.products FOR INSERT TO authenticated
WITH CHECK (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN']::TEXT[]
    )
);
CREATE POLICY "Products updateable by catalog managers"
ON public.products FOR UPDATE TO authenticated
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

CREATE POLICY "Bundle items readable in active Company"
ON public.product_bundle_items FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);
CREATE POLICY "Bundle items insertable by catalog managers"
ON public.product_bundle_items FOR INSERT TO authenticated
WITH CHECK (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN']::TEXT[]
    )
);
CREATE POLICY "Bundle items updateable by catalog managers"
ON public.product_bundle_items FOR UPDATE TO authenticated
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

CREATE POLICY "UOM readable in active Company"
ON public.uoms FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);
CREATE POLICY "UOM insertable by catalog managers"
ON public.uoms FOR INSERT TO authenticated
WITH CHECK (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN']::TEXT[]
    )
);
CREATE POLICY "UOM updateable by catalog managers"
ON public.uoms FOR UPDATE TO authenticated
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

CREATE POLICY "UOM conversions readable in active Company"
ON public.product_uom_conversions FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);
CREATE POLICY "UOM conversions insertable by catalog managers"
ON public.product_uom_conversions FOR INSERT TO authenticated
WITH CHECK (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN']::TEXT[]
    )
);
CREATE POLICY "UOM conversions updateable by catalog managers"
ON public.product_uom_conversions FOR UPDATE TO authenticated
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

-- Customer master is editable by managers/Finance, but balance is never a
-- browser-editable column. Cashier quick-create remains a future RPC/API.
CREATE POLICY "Customers readable in active Company"
ON public.customers FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);
CREATE POLICY "Customers insertable by authorized staff"
ON public.customers FOR INSERT TO authenticated
WITH CHECK (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE','ACCOUNTING']::TEXT[]
    )
);
CREATE POLICY "Customers updateable by authorized staff"
ON public.customers FOR UPDATE TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE','ACCOUNTING']::TEXT[]
    )
)
WITH CHECK (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE','ACCOUNTING']::TEXT[]
    )
);

-- Stock balance and FIFO are read models from the browser. All changes must
-- pass through transactional stock/purchase/checkout workflows.
CREATE POLICY "Product stock readable in active Company"
ON public.product_stocks FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);

CREATE POLICY "Product batches readable by inventory and Finance roles"
ON public.product_batches FOR SELECT TO authenticated
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

-- Exact browser privileges. DELETE is intentionally absent everywhere.
REVOKE ALL ON public.products, public.product_bundle_items,
    public.product_stocks, public.customers, public.uoms,
    public.product_uom_conversions, public.product_batches
FROM PUBLIC, anon, authenticated;

GRANT SELECT ON public.products, public.product_bundle_items,
    public.product_stocks, public.customers, public.uoms,
    public.product_uom_conversions, public.product_batches
TO authenticated;

GRANT INSERT, UPDATE ON public.products, public.product_bundle_items,
    public.uoms, public.product_uom_conversions
TO authenticated;

GRANT INSERT (company_id, code, name, phone, address, credit_limit)
ON public.customers TO authenticated;
GRANT UPDATE (code, name, phone, address, credit_limit)
ON public.customers TO authenticated;

GRANT ALL ON public.products, public.product_bundle_items,
    public.product_stocks, public.customers, public.uoms,
    public.product_uom_conversions, public.product_batches
TO service_role;

REVOKE ALL ON FUNCTION public.import_products_for_company(UUID, JSONB)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.import_products_for_company(UUID, JSONB)
TO authenticated, service_role;

INSERT INTO private.kgs_schema_migrations (version, migration_name, notes)
VALUES (
    '20260720230000',
    'g1_phase5b_catalog_inventory_rls',
    'TEN-001/TEN-002 active-Company catalog/master RLS and read-only stock/FIFO browser boundary; canonical Pricelist deferred to G2'
);

COMMIT;
