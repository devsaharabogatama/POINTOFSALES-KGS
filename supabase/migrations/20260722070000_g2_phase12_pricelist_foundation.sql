-- KGS POS G2 phase 12: canonical Pricelist foundation.
-- Expand-only: checkout and existing Product-UOM fallback remain unchanged.

BEGIN;

DO $guard$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260722040000') THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: G2 phase 10 missing';
    END IF;
    IF EXISTS (SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260722070000') THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260722070000';
    END IF;
    IF EXISTS (SELECT 1 FROM public.sales_headers)
       OR EXISTS (SELECT 1 FROM public.sales_details) THEN
        RAISE EXCEPTION 'G2_PHASE12_STATE_CHANGED: Sales history appeared; rerun preflight and design snapshot backfill';
    END IF;
END
$guard$;

CREATE TABLE public.pricelists (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    scope TEXT NOT NULL CHECK (scope IN ('GLOBAL','CUSTOMER')),
    customer_id UUID,
    priority INTEGER NOT NULL DEFAULT 0,
    is_default BOOLEAN NOT NULL DEFAULT FALSE,
    applies_all_stores BOOLEAN NOT NULL DEFAULT TRUE,
    valid_from TIMESTAMPTZ,
    valid_until TIMESTAMPTZ,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    notes TEXT,
    master_version BIGINT NOT NULL DEFAULT 1 CHECK (master_version > 0),
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT pricelists_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT pricelists_code_not_blank CHECK (btrim(code)<>''),
    CONSTRAINT pricelists_name_not_blank CHECK (btrim(name)<>''),
    CONSTRAINT pricelists_scope_customer_check CHECK (
        (scope='GLOBAL' AND customer_id IS NULL)
        OR (scope='CUSTOMER' AND customer_id IS NOT NULL)
    ),
    CONSTRAINT pricelists_validity_check CHECK (
        valid_from IS NULL OR valid_until IS NULL OR valid_until >= valid_from
    ),
    CONSTRAINT fk_pricelists_company_customer FOREIGN KEY(company_id,customer_id)
        REFERENCES public.customers(company_id,id) ON DELETE RESTRICT
);

-- Pricelist rules carry both Product and Product-UOM for resolver speed. This
-- key makes their relationship enforceable by a composite FK below instead of
-- trusting the RPC alone.
ALTER TABLE public.product_uoms
    ADD CONSTRAINT product_uoms_company_id_id_product_id_unique
        UNIQUE(company_id,id,product_id);

CREATE UNIQUE INDEX uq_pricelists_company_normalized_code ON public.pricelists(
    company_id,upper(regexp_replace(btrim(code),'\s+',' ','g'))
);
CREATE UNIQUE INDEX uq_pricelists_company_normalized_name ON public.pricelists(
    company_id,lower(regexp_replace(btrim(name),'\s+',' ','g'))
);
CREATE UNIQUE INDEX uq_pricelists_one_active_default_global
    ON public.pricelists(company_id) WHERE scope='GLOBAL' AND is_default AND is_active;
CREATE UNIQUE INDEX uq_pricelists_one_active_default_customer
    ON public.pricelists(company_id,customer_id)
    WHERE scope='CUSTOMER' AND is_default AND is_active;
CREATE INDEX idx_pricelists_company_resolver
    ON public.pricelists(company_id,scope,is_active,priority DESC);

CREATE TABLE public.pricelist_store_assignments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    pricelist_id UUID NOT NULL,
    store_id UUID NOT NULL,
    created_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT pricelist_store_assignment_unique UNIQUE(company_id,pricelist_id,store_id),
    CONSTRAINT fk_pricelist_stores_pricelist FOREIGN KEY(company_id,pricelist_id)
        REFERENCES public.pricelists(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_pricelist_stores_store FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.pricelist_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    pricelist_id UUID NOT NULL,
    product_id UUID NOT NULL,
    product_uom_id UUID NOT NULL,
    min_qty NUMERIC(24,6) NOT NULL DEFAULT 1 CHECK (min_qty > 0),
    tier_qty_basis TEXT NOT NULL DEFAULT 'SALES_UOM'
        CHECK (tier_qty_basis IN ('SALES_UOM','BASE_UOM_EQUIVALENT')),
    pricing_method TEXT NOT NULL
        CHECK (pricing_method IN ('FIXED_PRICE','DISCOUNT_AMOUNT','DISCOUNT_PERCENT')),
    fixed_unit_price NUMERIC(20,4),
    discount_amount_per_unit NUMERIC(20,4),
    discount_percent NUMERIC(9,6),
    valid_from TIMESTAMPTZ,
    valid_until TIMESTAMPTZ,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    rule_version BIGINT NOT NULL DEFAULT 1 CHECK (rule_version > 0),
    master_version BIGINT NOT NULL DEFAULT 1 CHECK (master_version > 0),
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT pricelist_rules_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT fk_pricelist_rules_pricelist FOREIGN KEY(company_id,pricelist_id)
        REFERENCES public.pricelists(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_pricelist_rules_product FOREIGN KEY(company_id,product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_pricelist_rules_product_uom FOREIGN KEY(
        company_id,product_uom_id,product_id
    ) REFERENCES public.product_uoms(company_id,id,product_id) ON DELETE RESTRICT,
    CONSTRAINT pricelist_rules_validity_check CHECK (
        valid_from IS NULL OR valid_until IS NULL OR valid_until >= valid_from
    ),
    CONSTRAINT pricelist_rules_method_value_check CHECK (
        (pricing_method='FIXED_PRICE' AND fixed_unit_price IS NOT NULL
         AND fixed_unit_price>=0
         AND discount_amount_per_unit IS NULL AND discount_percent IS NULL)
        OR
        (pricing_method='DISCOUNT_AMOUNT'
         AND discount_amount_per_unit IS NOT NULL
         AND discount_amount_per_unit>=0
         AND fixed_unit_price IS NULL AND discount_percent IS NULL)
        OR
        (pricing_method='DISCOUNT_PERCENT' AND discount_percent IS NOT NULL
         AND discount_percent BETWEEN 0 AND 100
         AND fixed_unit_price IS NULL AND discount_amount_per_unit IS NULL)
    )
);

CREATE UNIQUE INDEX uq_pricelist_rules_active_tier
    ON public.pricelist_rules(company_id,pricelist_id,product_uom_id,min_qty)
    WHERE is_active;
CREATE INDEX idx_pricelist_rules_resolver
    ON public.pricelist_rules(company_id,pricelist_id,product_uom_id,min_qty DESC)
    WHERE is_active;

CREATE TABLE public.pricelist_master_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    pricelist_id UUID NOT NULL,
    action TEXT NOT NULL CHECK(action IN ('CREATE','UPDATE')),
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fk_pricelist_audit_pricelist FOREIGN KEY(company_id,pricelist_id)
        REFERENCES public.pricelists(company_id,id) ON DELETE RESTRICT
);

ALTER TABLE public.sales_details
    ADD COLUMN base_unit_price NUMERIC(20,4),
    ADD COLUMN pricelist_id UUID,
    ADD COLUMN pricelist_rule_id UUID,
    ADD COLUMN resolved_unit_price NUMERIC(20,4),
    ADD COLUMN line_discount_type TEXT
        CHECK (line_discount_type IS NULL OR line_discount_type IN ('AMOUNT','PERCENT')),
    ADD COLUMN line_discount_input NUMERIC(20,6),
    ADD COLUMN line_discount_amount NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK(line_discount_amount>=0),
    ADD COLUMN allocated_order_discount_amount NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK(allocated_order_discount_amount>=0),
    ADD COLUMN unit_price_after_discount NUMERIC(20,4),
    ADD COLUMN line_total NUMERIC(20,4),
    ADD COLUMN pricing_resolved_at TIMESTAMPTZ,
    ADD CONSTRAINT sales_details_snapshot_nonnegative CHECK (
        (base_unit_price IS NULL OR base_unit_price>=0)
        AND (resolved_unit_price IS NULL OR resolved_unit_price>=0)
        AND (line_discount_input IS NULL OR line_discount_input>=0)
        AND (
            line_discount_type IS DISTINCT FROM 'PERCENT'
            OR line_discount_input IS NULL
            OR line_discount_input<=100
        )
        AND (unit_price_after_discount IS NULL OR unit_price_after_discount>=0)
        AND (line_total IS NULL OR line_total>=0)
    ),
    ADD CONSTRAINT fk_sales_details_company_pricelist
        FOREIGN KEY(company_id,pricelist_id)
        REFERENCES public.pricelists(company_id,id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_sales_details_company_pricelist_rule
        FOREIGN KEY(company_id,pricelist_rule_id)
        REFERENCES public.pricelist_rules(company_id,id) ON DELETE RESTRICT;

CREATE TRIGGER g2_touch_pricelists BEFORE INSERT OR UPDATE ON public.pricelists
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();
CREATE TRIGGER g2_touch_pricelist_rules BEFORE INSERT OR UPDATE ON public.pricelist_rules
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();

INSERT INTO public.pricelists(
    company_id,code,name,scope,priority,is_default,applies_all_stores,is_active
)
SELECT c.id,'GLOBAL','Harga Umum','GLOBAL',0,TRUE,TRUE,TRUE
FROM public.companies c WHERE c.status='ACTIVE';

CREATE FUNCTION private.trg_g2_provision_default_pricelist()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
    INSERT INTO public.pricelists(
        company_id,code,name,scope,priority,is_default,applies_all_stores,is_active
    ) VALUES (NEW.id,'GLOBAL','Harga Umum','GLOBAL',0,TRUE,TRUE,TRUE);
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.trg_g2_provision_default_pricelist()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_provision_default_pricelist() TO service_role;
CREATE TRIGGER g2_provision_default_pricelist AFTER INSERT ON public.companies
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_provision_default_pricelist();

CREATE FUNCTION public.save_pricelist_with_rules(
    p_pricelist_id UUID,p_master_version BIGINT,p_code TEXT,p_name TEXT,
    p_scope TEXT,p_customer_id UUID,p_priority INTEGER,p_is_default BOOLEAN,
    p_applies_all_stores BOOLEAN,p_store_ids UUID[],p_valid_from TIMESTAMPTZ,
    p_valid_until TIMESTAMPTZ,p_is_active BOOLEAN,p_notes TEXT,p_rules JSONB
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
    v_actor UUID:=auth.uid();
    v_company UUID:=public.private_active_company_id();
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
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER']::TEXT[]
    ) THEN RAISE EXCEPTION 'PRICELIST_MANAGER_REQUIRED'; END IF;
    IF btrim(COALESCE(p_code,''))='' OR btrim(COALESCE(p_name,''))='' THEN
        RAISE EXCEPTION 'INVALID_PRICELIST_IDENTITY';
    END IF;
    IF upper(COALESCE(p_scope,'')) NOT IN ('GLOBAL','CUSTOMER') THEN
        RAISE EXCEPTION 'INVALID_PRICELIST_SCOPE';
    END IF;
    IF p_valid_from IS NOT NULL AND p_valid_until IS NOT NULL
       AND p_valid_until<p_valid_from THEN RAISE EXCEPTION 'INVALID_PRICELIST_PERIOD'; END IF;
    IF upper(p_scope)='CUSTOMER' THEN
        IF NOT EXISTS(SELECT 1 FROM public.customers c WHERE c.company_id=v_company
          AND c.id=p_customer_id AND c.is_active AND NOT c.is_system_customer) THEN
            RAISE EXCEPTION 'ACTIVE_REGULAR_CUSTOMER_NOT_FOUND';
        END IF;
    ELSIF p_customer_id IS NOT NULL THEN RAISE EXCEPTION 'GLOBAL_PRICELIST_CANNOT_HAVE_CUSTOMER';
    END IF;
    IF NOT COALESCE(p_applies_all_stores,TRUE) THEN
        IF COALESCE(cardinality(p_store_ids),0)=0 THEN RAISE EXCEPTION 'PRICELIST_STORE_REQUIRED'; END IF;
        IF EXISTS(SELECT 1 FROM unnest(p_store_ids) s(id) LEFT JOIN public.stores st
          ON st.company_id=v_company AND st.id=s.id AND st.status='ACTIVE' WHERE st.id IS NULL) THEN
            RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND';
        END IF;
    END IF;
    IF p_rules IS NULL OR jsonb_typeof(p_rules)<>'array' THEN RAISE EXCEPTION 'PRICELIST_RULES_ARRAY_REQUIRED'; END IF;

    IF p_pricelist_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE'; END IF;
        INSERT INTO public.pricelists(company_id,code,name,scope,customer_id,priority,
          is_default,applies_all_stores,valid_from,valid_until,is_active,notes,created_by,updated_by)
        VALUES(v_company,upper(btrim(p_code)),btrim(p_name),upper(p_scope),p_customer_id,
          COALESCE(p_priority,0),COALESCE(p_is_default,FALSE),COALESCE(p_applies_all_stores,TRUE),
          p_valid_from,p_valid_until,COALESCE(p_is_active,TRUE),NULLIF(btrim(p_notes),''),v_actor,v_actor)
        RETURNING id,master_version INTO v_id,v_version;
    ELSE
        SELECT to_jsonb(p),p.master_version INTO v_before,v_version FROM public.pricelists p
        WHERE p.company_id=v_company AND p.id=p_pricelist_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'PRICELIST_NOT_FOUND'; END IF;
        IF p_master_version IS NULL OR p_master_version<>v_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
        UPDATE public.pricelists SET code=upper(btrim(p_code)),name=btrim(p_name),scope=upper(p_scope),
          customer_id=p_customer_id,priority=COALESCE(p_priority,0),is_default=COALESCE(p_is_default,FALSE),
          applies_all_stores=COALESCE(p_applies_all_stores,TRUE),valid_from=p_valid_from,
          valid_until=p_valid_until,is_active=COALESCE(p_is_active,TRUE),notes=NULLIF(btrim(p_notes),''),updated_by=v_actor
        WHERE company_id=v_company AND id=p_pricelist_id RETURNING id,master_version INTO v_id,v_version;
        UPDATE public.pricelist_rules SET is_active=FALSE,updated_by=v_actor
        WHERE company_id=v_company AND pricelist_id=v_id AND is_active;
        DELETE FROM public.pricelist_store_assignments WHERE company_id=v_company AND pricelist_id=v_id;
    END IF;

    IF NOT COALESCE(p_applies_all_stores,TRUE) THEN
        INSERT INTO public.pricelist_store_assignments(company_id,pricelist_id,store_id,created_by)
        SELECT v_company,v_id,s.id,v_actor FROM unnest(p_store_ids) s(id);
    END IF;

    FOR v_rule IN SELECT value FROM jsonb_array_elements(p_rules)
    LOOP
        v_product:=(v_rule->>'productId')::UUID;
        v_product_uom:=(v_rule->>'productUomId')::UUID;
        v_method:=upper(COALESCE(v_rule->>'pricingMethod',''));
        v_basis:=upper(COALESCE(v_rule->>'tierQtyBasis','SALES_UOM'));
        v_min:=COALESCE((v_rule->>'minQty')::NUMERIC,1);
        IF v_min<=0 OR v_method NOT IN ('FIXED_PRICE','DISCOUNT_AMOUNT','DISCOUNT_PERCENT')
           OR v_basis NOT IN ('SALES_UOM','BASE_UOM_EQUIVALENT') THEN
            RAISE EXCEPTION 'INVALID_PRICELIST_RULE';
        END IF;
        IF (v_method='FIXED_PRICE' AND (
                v_rule->>'fixedUnitPrice' IS NULL
                OR (v_rule->>'fixedUnitPrice')::NUMERIC<0
            ))
           OR (v_method='DISCOUNT_AMOUNT' AND (
                v_rule->>'discountAmountPerUnit' IS NULL
                OR (v_rule->>'discountAmountPerUnit')::NUMERIC<0
            ))
           OR (v_method='DISCOUNT_PERCENT' AND (
                v_rule->>'discountPercent' IS NULL
                OR (v_rule->>'discountPercent')::NUMERIC NOT BETWEEN 0 AND 100
            )) THEN
            RAISE EXCEPTION 'INVALID_PRICELIST_RULE_VALUE';
        END IF;
        IF upper(p_scope)='CUSTOMER' AND v_min<>1 THEN RAISE EXCEPTION 'CUSTOMER_PRICELIST_TIER_NOT_ALLOWED'; END IF;
        IF NOT EXISTS(SELECT 1 FROM public.product_uoms pu WHERE pu.company_id=v_company
          AND pu.id=v_product_uom AND pu.product_id=v_product AND pu.is_active AND pu.sales_allowed) THEN
            RAISE EXCEPTION 'ACTIVE_SALES_PRODUCT_UOM_NOT_FOUND';
        END IF;
        SELECT COALESCE(max(rule_version),0)+1 INTO v_rule_version FROM public.pricelist_rules
        WHERE company_id=v_company AND pricelist_id=v_id AND product_uom_id=v_product_uom;
        INSERT INTO public.pricelist_rules(company_id,pricelist_id,product_id,product_uom_id,
          min_qty,tier_qty_basis,pricing_method,fixed_unit_price,discount_amount_per_unit,
          discount_percent,valid_from,valid_until,is_active,rule_version,created_by,updated_by)
        VALUES(v_company,v_id,v_product,v_product_uom,v_min,v_basis,v_method,
          CASE WHEN v_method='FIXED_PRICE' THEN (v_rule->>'fixedUnitPrice')::NUMERIC END,
          CASE WHEN v_method='DISCOUNT_AMOUNT' THEN (v_rule->>'discountAmountPerUnit')::NUMERIC END,
          CASE WHEN v_method='DISCOUNT_PERCENT' THEN (v_rule->>'discountPercent')::NUMERIC END,
          NULLIF(v_rule->>'validFrom','')::TIMESTAMPTZ,NULLIF(v_rule->>'validUntil','')::TIMESTAMPTZ,
          COALESCE((v_rule->>'isActive')::BOOLEAN,TRUE),v_rule_version,v_actor,v_actor);
    END LOOP;

    SELECT to_jsonb(p) INTO v_after FROM public.pricelists p WHERE p.company_id=v_company AND p.id=v_id;
    INSERT INTO public.pricelist_master_audit(company_id,pricelist_id,action,actor_id,before_state,after_state)
    VALUES(v_company,v_id,CASE WHEN p_pricelist_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,v_actor,v_before,v_after);
    RETURN jsonb_build_object('pricelistId',v_id,'masterVersion',v_version);
EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'DUPLICATE_OR_DEFAULT_PRICELIST_CONFLICT';
END;
$$;

ALTER TABLE public.pricelists ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pricelist_store_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pricelist_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pricelist_master_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Pricelists readable in active Company" ON public.pricelists FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id) AND public.private_user_has_company_access(company_id));
CREATE POLICY "Pricelist stores readable in active Company" ON public.pricelist_store_assignments FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id) AND public.private_user_has_company_access(company_id));
CREATE POLICY "Pricelist rules readable in active Company" ON public.pricelist_rules FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id) AND public.private_user_has_company_access(company_id));
CREATE POLICY "Pricelist audit readable by managers" ON public.pricelist_master_audit FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id) AND public.private_user_has_any_company_or_store_role(
 company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER']::TEXT[]));

REVOKE ALL ON public.pricelists,public.pricelist_store_assignments,
 public.pricelist_rules,public.pricelist_master_audit FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.pricelists,public.pricelist_store_assignments,
 public.pricelist_rules,public.pricelist_master_audit TO authenticated;
GRANT ALL ON public.pricelists,public.pricelist_store_assignments,
 public.pricelist_rules,public.pricelist_master_audit TO service_role;
REVOKE ALL ON FUNCTION public.save_pricelist_with_rules(
 UUID,BIGINT,TEXT,TEXT,TEXT,UUID,INTEGER,BOOLEAN,BOOLEAN,UUID[],
 TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_pricelist_with_rules(
 UUID,BIGINT,TEXT,TEXT,TEXT,UUID,INTEGER,BOOLEAN,BOOLEAN,UUID[],
 TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB
) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260722070000','g2_phase12_pricelist_foundation',
 'Canonical Global/Customer Pricelist, store assignment, immutable rule versions, audit, and nullable Sales pricing snapshot foundation');
NOTIFY pgrst,'reload schema';
COMMIT;
