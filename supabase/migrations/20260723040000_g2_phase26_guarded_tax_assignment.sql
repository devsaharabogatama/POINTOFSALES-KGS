-- KGS POS G2 phase 26: guarded Product Category/Product Tax assignment.
-- Resolver, checkout/Purchase calculation, posting, and reporting remain disabled.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260723010000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 22 Tax foundation is required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260723040000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260723040000';
    END IF;
END
$migration_guard$;

-- -------------------------------------------------------------------------
-- 1. Assignment audit
-- -------------------------------------------------------------------------

CREATE TABLE public.tax_assignment_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    entity_type TEXT NOT NULL,
    entity_id UUID NOT NULL,
    action TEXT NOT NULL DEFAULT 'UPDATE',
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB NOT NULL,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT tax_assignment_audit_entity_check
        CHECK(entity_type IN ('PRODUCT_CATEGORY','PRODUCT')),
    CONSTRAINT tax_assignment_audit_action_check CHECK(action = 'UPDATE')
);

CREATE INDEX idx_tax_assignment_audit_entity_created
    ON public.tax_assignment_audit(
        company_id,entity_type,entity_id,created_at DESC
    );

ALTER TABLE public.tax_assignment_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Tax assignment audit readable by authorized roles"
ON public.tax_assignment_audit FOR SELECT TO authenticated
USING(
    public.private_request_company_matches(company_id)
    AND (
        public.private_user_has_any_company_or_store_role(
            company_id,
            ARRAY[
                'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER',
                'WAREHOUSE_ADMIN','FINANCE','ACCOUNTING'
            ]::TEXT[]
        )
        OR public.private_finance_company_visible(company_id)
    )
);

-- -------------------------------------------------------------------------
-- 2. Strong assignment guard
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.trg_g2_guard_tax_assignment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_sales_tax_rule_id UUID;
    v_purchase_tax_rule_id UUID;
    v_sales_changed BOOLEAN;
    v_purchase_changed BOOLEAN;
BEGIN
    IF TG_TABLE_NAME = 'product_categories' THEN
        v_sales_tax_rule_id := NEW.default_sales_tax_rule_id;
        v_purchase_tax_rule_id := NEW.default_purchase_tax_rule_id;
        IF TG_OP = 'INSERT' THEN
            v_sales_changed := TRUE;
            v_purchase_changed := TRUE;
        ELSE
            v_sales_changed := NEW.default_sales_tax_rule_id
                IS DISTINCT FROM OLD.default_sales_tax_rule_id;
            v_purchase_changed := NEW.default_purchase_tax_rule_id
                IS DISTINCT FROM OLD.default_purchase_tax_rule_id;
        END IF;
    ELSIF TG_TABLE_NAME = 'products' THEN
        v_sales_tax_rule_id := NEW.sales_tax_rule_id;
        v_purchase_tax_rule_id := NEW.purchase_tax_rule_id;
        IF TG_OP = 'INSERT' THEN
            v_sales_changed := TRUE;
            v_purchase_changed := TRUE;
        ELSE
            v_sales_changed := NEW.sales_tax_rule_id
                IS DISTINCT FROM OLD.sales_tax_rule_id;
            v_purchase_changed := NEW.purchase_tax_rule_id
                IS DISTINCT FROM OLD.purchase_tax_rule_id;
        END IF;
    ELSE
        RAISE EXCEPTION 'UNSUPPORTED_TAX_ASSIGNMENT_TABLE: %',TG_TABLE_NAME;
    END IF;

    IF v_sales_changed AND v_sales_tax_rule_id IS NOT NULL THEN
        IF NOT public.private_company_feature_enabled(
            NEW.company_id,'tax_sales_enabled'
        ) THEN
            RAISE EXCEPTION 'TAX_SALES_FEATURE_DISABLED';
        END IF;
        IF (
            SELECT count(*)
            FROM public.tax_rules r
            JOIN public.tax_rule_versions v
              ON v.company_id = r.company_id AND v.tax_rule_id = r.id
            WHERE r.company_id = NEW.company_id
              AND r.id = v_sales_tax_rule_id
              AND r.tax_scope = 'SALES'
              AND r.is_active
              AND v.status = 'ACTIVE'
              AND v.effective_from <= CURRENT_TIMESTAMP
              AND (v.effective_to IS NULL OR v.effective_to > CURRENT_TIMESTAMP)
        ) <> 1 THEN
            RAISE EXCEPTION 'CURRENT_SALES_TAX_RULE_REQUIRED';
        END IF;
    END IF;

    IF v_purchase_changed AND v_purchase_tax_rule_id IS NOT NULL THEN
        IF NOT public.private_company_feature_enabled(
            NEW.company_id,'tax_purchase_enabled'
        ) THEN
            RAISE EXCEPTION 'TAX_PURCHASE_FEATURE_DISABLED';
        END IF;
        IF (
            SELECT count(*)
            FROM public.tax_rules r
            JOIN public.tax_rule_versions v
              ON v.company_id = r.company_id AND v.tax_rule_id = r.id
            WHERE r.company_id = NEW.company_id
              AND r.id = v_purchase_tax_rule_id
              AND r.tax_scope = 'PURCHASE'
              AND r.is_active
              AND v.status = 'ACTIVE'
              AND v.effective_from <= CURRENT_TIMESTAMP
              AND (v.effective_to IS NULL OR v.effective_to > CURRENT_TIMESTAMP)
        ) <> 1 THEN
            RAISE EXCEPTION 'CURRENT_PURCHASE_TAX_RULE_REQUIRED';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_guard_tax_assignment()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_guard_tax_assignment()
TO service_role;

-- -------------------------------------------------------------------------
-- 3. Guarded optimistic-concurrency assignment RPCs
-- -------------------------------------------------------------------------

CREATE FUNCTION public.save_product_category_tax_assignment(
    p_category_id UUID,
    p_master_version BIGINT,
    p_sales_tax_rule_id UUID,
    p_purchase_tax_rule_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_existing public.product_categories%ROWTYPE;
    v_before JSONB;
    v_after JSONB;
    v_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,
        ARRAY[
            'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'
        ]::TEXT[]
    ) THEN RAISE EXCEPTION 'CATALOG_MANAGER_REQUIRED'; END IF;

    SELECT pc.* INTO v_existing
    FROM public.product_categories pc
    WHERE pc.company_id = v_company AND pc.id = p_category_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PRODUCT_CATEGORY_NOT_FOUND'; END IF;
    IF p_master_version IS NULL
       OR p_master_version <> v_existing.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;

    v_before := jsonb_build_object(
        'salesTaxRuleId',v_existing.default_sales_tax_rule_id,
        'purchaseTaxRuleId',v_existing.default_purchase_tax_rule_id,
        'masterVersion',v_existing.master_version
    );
    IF v_existing.default_sales_tax_rule_id
           IS NOT DISTINCT FROM p_sales_tax_rule_id
       AND v_existing.default_purchase_tax_rule_id
           IS NOT DISTINCT FROM p_purchase_tax_rule_id THEN
        RETURN jsonb_build_object(
            'categoryId',p_category_id,
            'masterVersion',v_existing.master_version,
            'action','NO_CHANGE'
        );
    END IF;

    UPDATE public.product_categories
    SET default_sales_tax_rule_id = p_sales_tax_rule_id,
        default_purchase_tax_rule_id = p_purchase_tax_rule_id,
        updated_by = v_actor
    WHERE company_id = v_company AND id = p_category_id
    RETURNING master_version INTO v_version;

    v_after := jsonb_build_object(
        'salesTaxRuleId',p_sales_tax_rule_id,
        'purchaseTaxRuleId',p_purchase_tax_rule_id,
        'masterVersion',v_version
    );
    INSERT INTO public.tax_assignment_audit(
        company_id,entity_type,entity_id,actor_id,before_state,after_state
    ) VALUES (
        v_company,'PRODUCT_CATEGORY',p_category_id,v_actor,v_before,v_after
    );
    RETURN jsonb_build_object(
        'categoryId',p_category_id,'masterVersion',v_version,'action','UPDATE'
    );
END;
$$;

CREATE FUNCTION public.save_product_tax_assignment(
    p_product_id UUID,
    p_master_version BIGINT,
    p_sales_tax_rule_id UUID,
    p_purchase_tax_rule_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_existing public.products%ROWTYPE;
    v_before JSONB;
    v_after JSONB;
    v_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,
        ARRAY[
            'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'
        ]::TEXT[]
    ) THEN RAISE EXCEPTION 'CATALOG_MANAGER_REQUIRED'; END IF;

    SELECT p.* INTO v_existing
    FROM public.products p
    WHERE p.company_id = v_company AND p.id = p_product_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PRODUCT_NOT_FOUND'; END IF;
    IF p_master_version IS NULL
       OR p_master_version <> v_existing.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;

    v_before := jsonb_build_object(
        'salesTaxRuleId',v_existing.sales_tax_rule_id,
        'purchaseTaxRuleId',v_existing.purchase_tax_rule_id,
        'masterVersion',v_existing.master_version
    );
    IF v_existing.sales_tax_rule_id IS NOT DISTINCT FROM p_sales_tax_rule_id
       AND v_existing.purchase_tax_rule_id
           IS NOT DISTINCT FROM p_purchase_tax_rule_id THEN
        RETURN jsonb_build_object(
            'productId',p_product_id,
            'masterVersion',v_existing.master_version,
            'action','NO_CHANGE'
        );
    END IF;

    UPDATE public.products
    SET sales_tax_rule_id = p_sales_tax_rule_id,
        purchase_tax_rule_id = p_purchase_tax_rule_id,
        updated_by = v_actor
    WHERE company_id = v_company AND id = p_product_id
    RETURNING master_version INTO v_version;

    v_after := jsonb_build_object(
        'salesTaxRuleId',p_sales_tax_rule_id,
        'purchaseTaxRuleId',p_purchase_tax_rule_id,
        'masterVersion',v_version
    );
    INSERT INTO public.tax_assignment_audit(
        company_id,entity_type,entity_id,actor_id,before_state,after_state
    ) VALUES (
        v_company,'PRODUCT',p_product_id,v_actor,v_before,v_after
    );
    RETURN jsonb_build_object(
        'productId',p_product_id,'masterVersion',v_version,'action','UPDATE'
    );
END;
$$;

-- Atomic compatibility overload: Product + Product-UOM + Tax overrides are
-- committed or rolled back as one PostgreSQL transaction.
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
    p_uoms JSONB,
    p_sales_tax_rule_id UUID,
    p_purchase_tax_rule_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_product JSONB;
    v_assignment JSONB;
BEGIN
    v_product := public.save_product_with_uoms(
        p_product_id,p_master_version,p_sku,p_name,p_category_id,
        p_base_uom_id,p_weight_reference_uom_id,
        p_weight_per_reference_uom_kg,p_is_bundle,p_image_url,p_is_active,p_uoms
    );
    v_assignment := public.save_product_tax_assignment(
        (v_product->>'productId')::UUID,
        (v_product->>'masterVersion')::BIGINT,
        p_sales_tax_rule_id,p_purchase_tax_rule_id
    );
    RETURN v_product || jsonb_build_object(
        'masterVersion',(v_assignment->>'masterVersion')::BIGINT,
        'taxAssignmentAction',v_assignment->>'action'
    );
END;
$$;

REVOKE ALL ON FUNCTION public.save_product_category_tax_assignment(
    UUID,BIGINT,UUID,UUID
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.save_product_tax_assignment(
    UUID,BIGINT,UUID,UUID
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.save_product_with_uoms(
    UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,NUMERIC,BOOLEAN,TEXT,BOOLEAN,
    JSONB,UUID,UUID
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_product_category_tax_assignment(
    UUID,BIGINT,UUID,UUID
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.save_product_tax_assignment(
    UUID,BIGINT,UUID,UUID
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.save_product_with_uoms(
    UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,NUMERIC,BOOLEAN,TEXT,BOOLEAN,
    JSONB,UUID,UUID
) TO authenticated,service_role;

-- Category identity remains backward-compatible through column grants, while
-- Tax assignment columns can only be written by SECURITY DEFINER RPC.
REVOKE INSERT,UPDATE ON public.product_categories
FROM PUBLIC,anon,authenticated;
GRANT INSERT(company_id,category_code,category_name,is_active)
ON public.product_categories TO authenticated;
GRANT UPDATE(category_code,category_name,is_active)
ON public.product_categories TO authenticated;

REVOKE ALL ON public.tax_assignment_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.tax_assignment_audit TO authenticated;
GRANT ALL ON public.tax_assignment_audit TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260723040000',
    'g2_phase26_guarded_tax_assignment',
    'Guarded optimistic-concurrency Product Category/Product Tax assignment, effective-version/entitlement validation, audit, column privilege closure, and atomic Product-UOM-Tax overload; resolver remains disabled'
);

COMMIT;
