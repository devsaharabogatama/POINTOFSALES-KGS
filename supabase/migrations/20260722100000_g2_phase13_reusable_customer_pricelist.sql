-- KGS POS G2 phase 13 forward fix: reusable Customer Pricelist assignment.
-- Assignment moves from Pricelist header to Customer. Checkout remains unchanged.

BEGIN;

DO $guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260722080000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G2 phase 13 default guard missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260722100000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260722100000';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.pricelists WHERE scope = 'CUSTOMER'
    ) THEN
        RAISE EXCEPTION
            'G2_PHASE13_STATE_CHANGED: Customer Pricelist appeared; rerun assignment preflight and design explicit backfill';
    END IF;
    IF EXISTS (SELECT 1 FROM public.sales_details WHERE pricelist_id IS NOT NULL) THEN
        RAISE EXCEPTION
            'G2_PHASE13_STATE_CHANGED: priced Sales history appeared; rerun assignment preflight';
    END IF;
END
$guard$;

ALTER TABLE public.customers
    ADD COLUMN default_pricelist_id UUID,
    ADD CONSTRAINT customers_system_has_no_pricelist CHECK (
        NOT is_system_customer OR default_pricelist_id IS NULL
    ),
    ADD CONSTRAINT fk_customers_company_default_pricelist
        FOREIGN KEY (company_id,default_pricelist_id)
        REFERENCES public.pricelists(company_id,id) ON DELETE RESTRICT;

CREATE INDEX idx_customers_company_default_pricelist
    ON public.customers(company_id,default_pricelist_id)
    WHERE default_pricelist_id IS NOT NULL;

ALTER TABLE public.pricelists
    DROP CONSTRAINT pricelists_scope_customer_check,
    DROP CONSTRAINT fk_pricelists_company_customer;
DROP INDEX public.uq_pricelists_one_active_default_customer;

ALTER TABLE public.pricelists
    ADD CONSTRAINT pricelists_reusable_customer_scope_check CHECK (
        customer_id IS NULL
        AND (scope = 'GLOBAL' OR NOT is_default)
    );

CREATE FUNCTION private.trg_g2_guard_customer_pricelist_assignment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.default_pricelist_id IS NOT NULL THEN
        IF NEW.is_system_customer THEN
            RAISE EXCEPTION 'SYSTEM_CUSTOMER_CANNOT_HAVE_PRICELIST';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM public.pricelists p
            WHERE p.company_id = NEW.company_id
              AND p.id = NEW.default_pricelist_id
              AND p.scope = 'CUSTOMER'
              AND p.is_active
        ) THEN
            RAISE EXCEPTION 'ACTIVE_CUSTOMER_PRICELIST_NOT_FOUND';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g2_guard_assigned_pricelist_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.customers c
        WHERE c.company_id = OLD.company_id
          AND c.default_pricelist_id = OLD.id
    ) AND (
        NEW.company_id IS DISTINCT FROM OLD.company_id
        OR NEW.scope <> 'CUSTOMER'
        OR NOT NEW.is_active
    ) THEN
        RAISE EXCEPTION 'PRICELIST_ASSIGNED_TO_CUSTOMER';
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_guard_customer_pricelist_assignment()
FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.trg_g2_guard_assigned_pricelist_lifecycle()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.trg_g2_guard_customer_pricelist_assignment(),
    private.trg_g2_guard_assigned_pricelist_lifecycle()
TO service_role;

CREATE TRIGGER g2_guard_customer_pricelist_assignment
BEFORE INSERT OR UPDATE OF company_id,default_pricelist_id,is_system_customer
ON public.customers
FOR EACH ROW EXECUTE FUNCTION
    private.trg_g2_guard_customer_pricelist_assignment();

CREATE TRIGGER g2_guard_assigned_pricelist_lifecycle
BEFORE UPDATE OF company_id,scope,is_active ON public.pricelists
FOR EACH ROW EXECUTE FUNCTION
    private.trg_g2_guard_assigned_pricelist_lifecycle();

CREATE FUNCTION public.save_reusable_pricelist_with_rules(
    p_pricelist_id UUID,p_master_version BIGINT,p_code TEXT,p_name TEXT,
    p_scope TEXT,p_priority INTEGER,p_is_default BOOLEAN,
    p_applies_all_stores BOOLEAN,p_store_ids UUID[],p_valid_from TIMESTAMPTZ,
    p_valid_until TIMESTAMPTZ,p_is_active BOOLEAN,p_notes TEXT,p_rules JSONB
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
    v_version BIGINT;
    v_before JSONB;
    v_after JSONB;
    v_rule JSONB;
    v_product UUID;
    v_product_uom UUID;
    v_method TEXT;
    v_basis TEXT;
    v_min NUMERIC;
    v_rule_version BIGINT;
    v_old RECORD;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER']::TEXT[]
    ) THEN RAISE EXCEPTION 'PRICELIST_MANAGER_REQUIRED'; END IF;
    IF btrim(COALESCE(p_code,'')) = ''
       OR btrim(COALESCE(p_name,'')) = '' THEN
        RAISE EXCEPTION 'INVALID_PRICELIST_IDENTITY';
    END IF;
    IF upper(COALESCE(p_scope,'')) NOT IN ('GLOBAL','CUSTOMER') THEN
        RAISE EXCEPTION 'INVALID_PRICELIST_SCOPE';
    END IF;
    IF upper(p_scope) = 'CUSTOMER' AND COALESCE(p_is_default,FALSE) THEN
        RAISE EXCEPTION 'CUSTOMER_PRICELIST_CANNOT_BE_GLOBAL_DEFAULT';
    END IF;
    IF p_valid_from IS NOT NULL AND p_valid_until IS NOT NULL
       AND p_valid_until < p_valid_from THEN
        RAISE EXCEPTION 'INVALID_PRICELIST_PERIOD';
    END IF;
    IF NOT COALESCE(p_applies_all_stores,TRUE) THEN
        IF COALESCE(cardinality(p_store_ids),0) = 0 THEN
            RAISE EXCEPTION 'PRICELIST_STORE_REQUIRED';
        END IF;
        IF EXISTS (
            SELECT 1 FROM unnest(p_store_ids) s(id)
            LEFT JOIN public.stores st
              ON st.company_id = v_company
             AND st.id = s.id
             AND st.status = 'ACTIVE'
            WHERE st.id IS NULL
        ) THEN RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND'; END IF;
    END IF;
    IF p_rules IS NULL OR jsonb_typeof(p_rules) <> 'array' THEN
        RAISE EXCEPTION 'PRICELIST_RULES_ARRAY_REQUIRED';
    END IF;

    IF upper(p_scope) = 'GLOBAL'
       AND COALESCE(p_is_default,FALSE)
       AND COALESCE(p_is_active,TRUE) THEN
        FOR v_old IN
            SELECT p.id,to_jsonb(p) AS before_state
            FROM public.pricelists p
            WHERE p.company_id = v_company
              AND p.id IS DISTINCT FROM p_pricelist_id
              AND p.scope = 'GLOBAL'
              AND p.is_default
              AND p.is_active
            FOR UPDATE
        LOOP
            UPDATE public.pricelists
            SET is_default = FALSE,updated_by = v_actor
            WHERE company_id = v_company AND id = v_old.id;
            SELECT to_jsonb(p) INTO v_after FROM public.pricelists p
            WHERE p.company_id = v_company AND p.id = v_old.id;
            INSERT INTO public.pricelist_master_audit(
                company_id,pricelist_id,action,actor_id,before_state,after_state
            ) VALUES (
                v_company,v_old.id,'UPDATE',v_actor,v_old.before_state,v_after
            );
        END LOOP;
    END IF;

    IF p_pricelist_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        INSERT INTO public.pricelists(
            company_id,code,name,scope,customer_id,priority,is_default,
            applies_all_stores,valid_from,valid_until,is_active,notes,
            created_by,updated_by
        ) VALUES (
            v_company,upper(btrim(p_code)),btrim(p_name),upper(p_scope),NULL,
            COALESCE(p_priority,0),
            CASE WHEN upper(p_scope)='GLOBAL'
                 THEN COALESCE(p_is_default,FALSE) ELSE FALSE END,
            COALESCE(p_applies_all_stores,TRUE),p_valid_from,p_valid_until,
            COALESCE(p_is_active,TRUE),NULLIF(btrim(p_notes),''),v_actor,v_actor
        ) RETURNING id,master_version INTO v_id,v_version;
    ELSE
        SELECT to_jsonb(p),p.master_version INTO v_before,v_version
        FROM public.pricelists p
        WHERE p.company_id = v_company AND p.id = p_pricelist_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'PRICELIST_NOT_FOUND'; END IF;
        IF p_master_version IS NULL OR p_master_version <> v_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        UPDATE public.pricelists SET
            code = upper(btrim(p_code)),name = btrim(p_name),
            scope = upper(p_scope),customer_id = NULL,
            priority = COALESCE(p_priority,0),
            is_default = CASE WHEN upper(p_scope)='GLOBAL'
                              THEN COALESCE(p_is_default,FALSE) ELSE FALSE END,
            applies_all_stores = COALESCE(p_applies_all_stores,TRUE),
            valid_from = p_valid_from,valid_until = p_valid_until,
            is_active = COALESCE(p_is_active,TRUE),
            notes = NULLIF(btrim(p_notes),''),updated_by = v_actor
        WHERE company_id = v_company AND id = p_pricelist_id
        RETURNING id,master_version INTO v_id,v_version;
        UPDATE public.pricelist_rules
        SET is_active = FALSE,updated_by = v_actor
        WHERE company_id = v_company AND pricelist_id = v_id AND is_active;
        DELETE FROM public.pricelist_store_assignments
        WHERE company_id = v_company AND pricelist_id = v_id;
    END IF;

    IF NOT COALESCE(p_applies_all_stores,TRUE) THEN
        INSERT INTO public.pricelist_store_assignments(
            company_id,pricelist_id,store_id,created_by
        ) SELECT v_company,v_id,s.id,v_actor FROM unnest(p_store_ids) s(id);
    END IF;

    FOR v_rule IN SELECT value FROM jsonb_array_elements(p_rules)
    LOOP
        v_product := (v_rule->>'productId')::UUID;
        v_product_uom := (v_rule->>'productUomId')::UUID;
        v_method := upper(COALESCE(v_rule->>'pricingMethod',''));
        v_basis := upper(COALESCE(v_rule->>'tierQtyBasis','SALES_UOM'));
        v_min := COALESCE((v_rule->>'minQty')::NUMERIC,1);
        IF v_min <= 0
           OR v_method NOT IN ('FIXED_PRICE','DISCOUNT_AMOUNT','DISCOUNT_PERCENT')
           OR v_basis NOT IN ('SALES_UOM','BASE_UOM_EQUIVALENT') THEN
            RAISE EXCEPTION 'INVALID_PRICELIST_RULE';
        END IF;
        IF (v_method='FIXED_PRICE' AND (
                v_rule->>'fixedUnitPrice' IS NULL
                OR (v_rule->>'fixedUnitPrice')::NUMERIC < 0
            )) OR (v_method='DISCOUNT_AMOUNT' AND (
                v_rule->>'discountAmountPerUnit' IS NULL
                OR (v_rule->>'discountAmountPerUnit')::NUMERIC < 0
            )) OR (v_method='DISCOUNT_PERCENT' AND (
                v_rule->>'discountPercent' IS NULL
                OR (v_rule->>'discountPercent')::NUMERIC NOT BETWEEN 0 AND 100
            )) THEN RAISE EXCEPTION 'INVALID_PRICELIST_RULE_VALUE'; END IF;
        IF upper(p_scope) = 'CUSTOMER' AND v_min <> 1 THEN
            RAISE EXCEPTION 'CUSTOMER_PRICELIST_TIER_NOT_ALLOWED';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM public.product_uoms pu
            WHERE pu.company_id = v_company
              AND pu.id = v_product_uom
              AND pu.product_id = v_product
              AND pu.is_active
              AND pu.sales_allowed
        ) THEN RAISE EXCEPTION 'ACTIVE_SALES_PRODUCT_UOM_NOT_FOUND'; END IF;
        SELECT COALESCE(max(rule_version),0)+1 INTO v_rule_version
        FROM public.pricelist_rules
        WHERE company_id = v_company
          AND pricelist_id = v_id
          AND product_uom_id = v_product_uom;
        INSERT INTO public.pricelist_rules(
            company_id,pricelist_id,product_id,product_uom_id,min_qty,
            tier_qty_basis,pricing_method,fixed_unit_price,
            discount_amount_per_unit,discount_percent,valid_from,valid_until,
            is_active,rule_version,created_by,updated_by
        ) VALUES (
            v_company,v_id,v_product,v_product_uom,v_min,v_basis,v_method,
            CASE WHEN v_method='FIXED_PRICE'
                 THEN (v_rule->>'fixedUnitPrice')::NUMERIC END,
            CASE WHEN v_method='DISCOUNT_AMOUNT'
                 THEN (v_rule->>'discountAmountPerUnit')::NUMERIC END,
            CASE WHEN v_method='DISCOUNT_PERCENT'
                 THEN (v_rule->>'discountPercent')::NUMERIC END,
            NULLIF(v_rule->>'validFrom','')::TIMESTAMPTZ,
            NULLIF(v_rule->>'validUntil','')::TIMESTAMPTZ,
            COALESCE((v_rule->>'isActive')::BOOLEAN,TRUE),v_rule_version,
            v_actor,v_actor
        );
    END LOOP;

    SELECT to_jsonb(p) INTO v_after FROM public.pricelists p
    WHERE p.company_id = v_company AND p.id = v_id;
    INSERT INTO public.pricelist_master_audit(
        company_id,pricelist_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_id,
        CASE WHEN p_pricelist_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
        v_actor,v_before,v_after
    );
    RETURN jsonb_build_object('pricelistId',v_id,'masterVersion',v_version);
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'DUPLICATE_OR_DEFAULT_PRICELIST_CONFLICT';
END;
$$;

CREATE FUNCTION public.save_customer_with_pricelist(
    p_customer_id UUID,p_master_version BIGINT,p_customer_code TEXT,
    p_customer_name TEXT,p_customer_category_id UUID,p_phone TEXT,p_email TEXT,
    p_address TEXT,p_customer_type TEXT,p_credit_limit NUMERIC,
    p_credit_term_days INTEGER,p_notes TEXT,p_is_active BOOLEAN,
    p_parent_customer_id UUID,p_default_pricelist_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_result JSONB;
    v_id UUID;
    v_version BIGINT;
    v_current UUID;
    v_system BOOLEAN;
    v_before JSONB;
    v_after JSONB;
BEGIN
    v_result := public.save_customer_with_parent(
        p_customer_id,p_master_version,p_customer_code,p_customer_name,
        p_customer_category_id,p_phone,p_email,p_address,p_customer_type,
        p_credit_limit,p_credit_term_days,p_notes,p_is_active,
        p_parent_customer_id
    );
    v_id := (v_result->>'customerId')::UUID;

    SELECT c.default_pricelist_id,c.is_system_customer,to_jsonb(c)
    INTO v_current,v_system,v_before
    FROM public.customers c
    WHERE c.company_id = v_company AND c.id = v_id
    FOR UPDATE;

    IF p_default_pricelist_id IS DISTINCT FROM v_current THEN
        IF NOT public.private_user_has_any_company_or_store_role(
            v_company,
            ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER']::TEXT[]
        ) THEN RAISE EXCEPTION 'CUSTOMER_MANAGER_REQUIRED'; END IF;
        IF v_system AND p_default_pricelist_id IS NOT NULL THEN
            RAISE EXCEPTION 'SYSTEM_CUSTOMER_CANNOT_HAVE_PRICELIST';
        END IF;
        IF p_default_pricelist_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM public.pricelists p
            WHERE p.company_id = v_company
              AND p.id = p_default_pricelist_id
              AND p.scope = 'CUSTOMER'
              AND p.is_active
        ) THEN RAISE EXCEPTION 'ACTIVE_CUSTOMER_PRICELIST_NOT_FOUND'; END IF;

        UPDATE public.customers
        SET default_pricelist_id = p_default_pricelist_id,updated_by = v_actor
        WHERE company_id = v_company AND id = v_id
        RETURNING master_version INTO v_version;
        SELECT to_jsonb(c) INTO v_after FROM public.customers c
        WHERE c.company_id = v_company AND c.id = v_id;
        INSERT INTO public.customer_master_audit(
            company_id,customer_id,action,actor_id,before_state,after_state
        ) VALUES (v_company,v_id,'UPDATE',v_actor,v_before,v_after);
        v_result := jsonb_set(v_result,'{masterVersion}',to_jsonb(v_version));
    END IF;
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.save_pricelist_with_rules(
    UUID,BIGINT,TEXT,TEXT,TEXT,UUID,INTEGER,BOOLEAN,BOOLEAN,UUID[],
    TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB
) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.save_reusable_pricelist_with_rules(
    UUID,BIGINT,TEXT,TEXT,TEXT,INTEGER,BOOLEAN,BOOLEAN,UUID[],
    TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.save_customer_with_pricelist(
    UUID,BIGINT,TEXT,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,NUMERIC,INTEGER,TEXT,
    BOOLEAN,UUID,UUID
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_reusable_pricelist_with_rules(
    UUID,BIGINT,TEXT,TEXT,TEXT,INTEGER,BOOLEAN,BOOLEAN,UUID[],
    TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.save_customer_with_pricelist(
    UUID,BIGINT,TEXT,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,NUMERIC,INTEGER,TEXT,
    BOOLEAN,UUID,UUID
) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260722100000',
    'g2_phase13_reusable_customer_pricelist',
    'Reusable Customer Pricelist headers assigned from Customer master with tenant-safe FK, lifecycle guards, audited RPC, and legacy writer closure'
);

NOTIFY pgrst,'reload schema';
COMMIT;
