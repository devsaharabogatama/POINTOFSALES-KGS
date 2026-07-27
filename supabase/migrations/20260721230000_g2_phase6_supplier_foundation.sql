-- KGS POS G2 phase 6: canonical Supplier and Product-Supplier foundation.
-- Dependency: 20260721210000_g2_phase4_atomic_product_crud.sql
--
-- This migration does not create Supplier Orders, receive stock, or alter the
-- legacy Purchase execution path. The approved preflight reported zero legacy
-- Purchase rows, so no Supplier-name backfill is required.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260721210000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G2 phase 4 is incomplete';
    END IF;

    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260721230000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260721230000';
    END IF;

    IF to_regclass('public.suppliers') IS NOT NULL
       OR to_regclass('public.product_suppliers') IS NOT NULL THEN
        RAISE EXCEPTION 'G2_PHASE6_CANONICAL_TABLE_ALREADY_EXISTS';
    END IF;
END
$migration_guard$;

DO $live_state_guard$
DECLARE
    v_purchase_rows BIGINT;
BEGIN
    SELECT count(*) INTO v_purchase_rows FROM public.purchases_headers;
    IF v_purchase_rows <> 0 THEN
        RAISE EXCEPTION
            'G2_PHASE6_STATE_CHANGED: % legacy Purchase row(s); rerun preflight and design explicit Supplier mapping',
            v_purchase_rows;
    END IF;
END
$live_state_guard$;

CREATE TABLE public.suppliers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    supplier_code TEXT NOT NULL,
    supplier_name TEXT NOT NULL,
    contact_name TEXT,
    phone TEXT,
    address TEXT,
    npwp TEXT,
    payment_term TEXT,
    bank_name TEXT,
    bank_account_number TEXT,
    bank_account_holder TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT suppliers_company_id_id_unique UNIQUE (company_id, id),
    CONSTRAINT suppliers_code_not_blank CHECK (btrim(supplier_code) <> ''),
    CONSTRAINT suppliers_name_not_blank CHECK (btrim(supplier_name) <> ''),
    CONSTRAINT suppliers_version_positive CHECK (master_version > 0),
    CONSTRAINT suppliers_bank_account_not_blank CHECK (
        bank_account_number IS NULL OR btrim(bank_account_number) <> ''
    )
);

CREATE UNIQUE INDEX uq_suppliers_company_normalized_code
    ON public.suppliers (
        company_id,
        upper(regexp_replace(btrim(supplier_code), '\s+', ' ', 'g'))
    );
CREATE UNIQUE INDEX uq_suppliers_company_normalized_name
    ON public.suppliers (
        company_id,
        lower(regexp_replace(btrim(supplier_name), '\s+', ' ', 'g'))
    );
CREATE INDEX idx_suppliers_company_active_name
    ON public.suppliers (company_id, is_active, supplier_name);

CREATE TABLE public.product_suppliers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    product_id UUID NOT NULL,
    supplier_id UUID NOT NULL,
    supplier_product_code TEXT,
    purchase_uom_id UUID NOT NULL,
    reference_purchase_price NUMERIC(20,4),
    last_purchase_price NUMERIC(20,4),
    is_preferred_supplier BOOLEAN NOT NULL DEFAULT FALSE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    last_price_updated_at TIMESTAMPTZ,
    last_price_source_document_id UUID,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT product_suppliers_company_id_id_unique
        UNIQUE (company_id, id),
    CONSTRAINT product_suppliers_company_product_supplier_unique
        UNIQUE (company_id, product_id, supplier_id),
    CONSTRAINT fk_product_suppliers_company_product
        FOREIGN KEY (company_id, product_id)
        REFERENCES public.products(company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_product_suppliers_company_supplier
        FOREIGN KEY (company_id, supplier_id)
        REFERENCES public.suppliers(company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_product_suppliers_company_product_uom
        FOREIGN KEY (company_id, product_id, purchase_uom_id)
        REFERENCES public.product_uoms(company_id, product_id, uom_id)
        ON DELETE RESTRICT,
    CONSTRAINT product_suppliers_supplier_code_not_blank CHECK (
        supplier_product_code IS NULL
        OR btrim(supplier_product_code) <> ''
    ),
    CONSTRAINT product_suppliers_reference_price_nonnegative CHECK (
        reference_purchase_price IS NULL OR reference_purchase_price >= 0
    ),
    CONSTRAINT product_suppliers_last_price_nonnegative CHECK (
        last_purchase_price IS NULL OR last_purchase_price >= 0
    ),
    CONSTRAINT product_suppliers_preferred_active CHECK (
        NOT is_preferred_supplier OR is_active
    ),
    CONSTRAINT product_suppliers_last_price_metadata CHECK (
        last_purchase_price IS NULL OR last_price_updated_at IS NOT NULL
    ),
    CONSTRAINT product_suppliers_version_positive CHECK (master_version > 0)
);

CREATE UNIQUE INDEX uq_product_suppliers_one_active_preferred
    ON public.product_suppliers (company_id, product_id)
    WHERE is_active AND is_preferred_supplier;
CREATE INDEX idx_product_suppliers_company_supplier_active
    ON public.product_suppliers (company_id, supplier_id, is_active);
CREATE INDEX idx_product_suppliers_company_product_active
    ON public.product_suppliers (company_id, product_id, is_active);

CREATE TABLE public.supplier_master_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    supplier_id UUID NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('CREATE','UPDATE')),
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fk_supplier_audit_company_supplier
        FOREIGN KEY (company_id, supplier_id)
        REFERENCES public.suppliers(company_id, id) ON DELETE RESTRICT
);

CREATE TABLE public.product_supplier_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    product_supplier_id UUID NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('CREATE','UPDATE')),
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fk_product_supplier_audit_company_relation
        FOREIGN KEY (company_id, product_supplier_id)
        REFERENCES public.product_suppliers(company_id, id) ON DELETE RESTRICT
);

CREATE INDEX idx_supplier_master_audit_supplier_created
    ON public.supplier_master_audit (company_id, supplier_id, created_at DESC);
CREATE INDEX idx_product_supplier_audit_relation_created
    ON public.product_supplier_audit (
        company_id, product_supplier_id, created_at DESC
    );

CREATE TRIGGER g2_touch_suppliers
BEFORE INSERT OR UPDATE ON public.suppliers
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();

CREATE TRIGGER g2_touch_product_suppliers
BEFORE INSERT OR UPDATE ON public.product_suppliers
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();

CREATE FUNCTION public.save_supplier(
    p_supplier_id UUID,
    p_master_version BIGINT,
    p_supplier_code TEXT,
    p_supplier_name TEXT,
    p_contact_name TEXT,
    p_phone TEXT,
    p_address TEXT,
    p_npwp TEXT,
    p_payment_term TEXT,
    p_bank_name TEXT,
    p_bank_account_number TEXT,
    p_bank_account_holder TEXT,
    p_is_active BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company_id UUID := public.private_active_company_id();
    v_supplier_id UUID;
    v_result_version BIGINT;
    v_before JSONB;
    v_after JSONB;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company_id IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company_id,
        ARRAY[
            'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER',
            'FINANCE','ACCOUNTING'
        ]::TEXT[]
    ) THEN
        RAISE EXCEPTION 'SUPPLIER_MANAGER_REQUIRED';
    END IF;
    IF btrim(COALESCE(p_supplier_code,'')) = ''
       OR char_length(btrim(p_supplier_code)) > 100 THEN
        RAISE EXCEPTION 'INVALID_SUPPLIER_CODE';
    END IF;
    IF btrim(COALESCE(p_supplier_name,'')) = ''
       OR char_length(btrim(p_supplier_name)) > 200 THEN
        RAISE EXCEPTION 'INVALID_SUPPLIER_NAME';
    END IF;

    IF p_supplier_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        INSERT INTO public.suppliers(
            company_id,supplier_code,supplier_name,contact_name,phone,address,
            npwp,payment_term,bank_name,bank_account_number,
            bank_account_holder,is_active,created_by,updated_by
        ) VALUES (
            v_company_id,upper(btrim(p_supplier_code)),btrim(p_supplier_name),
            NULLIF(btrim(p_contact_name),''),NULLIF(btrim(p_phone),''),
            NULLIF(btrim(p_address),''),NULLIF(btrim(p_npwp),''),
            NULLIF(btrim(p_payment_term),''),NULLIF(btrim(p_bank_name),''),
            NULLIF(btrim(p_bank_account_number),''),
            NULLIF(btrim(p_bank_account_holder),''),
            COALESCE(p_is_active,TRUE),v_actor,v_actor
        )
        RETURNING id,master_version INTO v_supplier_id,v_result_version;

        SELECT to_jsonb(s) INTO v_after FROM public.suppliers s
        WHERE s.company_id = v_company_id AND s.id = v_supplier_id;
        INSERT INTO public.supplier_master_audit(
            company_id,supplier_id,action,actor_id,before_state,after_state
        ) VALUES (v_company_id,v_supplier_id,'CREATE',v_actor,NULL,v_after);
    ELSE
        SELECT to_jsonb(s),s.master_version INTO v_before,v_result_version
        FROM public.suppliers s
        WHERE s.company_id = v_company_id AND s.id = p_supplier_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_NOT_FOUND'; END IF;
        IF p_master_version IS NULL OR p_master_version <> v_result_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;

        UPDATE public.suppliers
        SET supplier_code = upper(btrim(p_supplier_code)),
            supplier_name = btrim(p_supplier_name),
            contact_name = NULLIF(btrim(p_contact_name),''),
            phone = NULLIF(btrim(p_phone),''),
            address = NULLIF(btrim(p_address),''),
            npwp = NULLIF(btrim(p_npwp),''),
            payment_term = NULLIF(btrim(p_payment_term),''),
            bank_name = NULLIF(btrim(p_bank_name),''),
            bank_account_number = NULLIF(btrim(p_bank_account_number),''),
            bank_account_holder = NULLIF(btrim(p_bank_account_holder),''),
            is_active = COALESCE(p_is_active,TRUE),
            updated_by = v_actor
        WHERE company_id = v_company_id AND id = p_supplier_id
        RETURNING id,master_version INTO v_supplier_id,v_result_version;

        SELECT to_jsonb(s) INTO v_after FROM public.suppliers s
        WHERE s.company_id = v_company_id AND s.id = v_supplier_id;
        INSERT INTO public.supplier_master_audit(
            company_id,supplier_id,action,actor_id,before_state,after_state
        ) VALUES (v_company_id,v_supplier_id,'UPDATE',v_actor,v_before,v_after);
    END IF;

    RETURN jsonb_build_object(
        'supplierId',v_supplier_id,'masterVersion',v_result_version
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'DUPLICATE_SUPPLIER';
END;
$$;

CREATE FUNCTION public.save_product_supplier(
    p_product_supplier_id UUID,
    p_master_version BIGINT,
    p_product_id UUID,
    p_supplier_id UUID,
    p_purchase_uom_id UUID,
    p_supplier_product_code TEXT,
    p_reference_purchase_price NUMERIC,
    p_is_preferred_supplier BOOLEAN,
    p_is_active BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company_id UUID := public.private_active_company_id();
    v_relation_id UUID;
    v_result_version BIGINT;
    v_before JSONB;
    v_after JSONB;
    v_constraint TEXT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company_id IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company_id,
        ARRAY[
            'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'
        ]::TEXT[]
    ) THEN
        RAISE EXCEPTION 'SUPPLIER_MANAGER_REQUIRED';
    END IF;
    IF p_reference_purchase_price IS NOT NULL
       AND p_reference_purchase_price < 0 THEN
        RAISE EXCEPTION 'REFERENCE_PURCHASE_PRICE_NEGATIVE';
    END IF;
    IF COALESCE(p_is_preferred_supplier,FALSE)
       AND NOT COALESCE(p_is_active,TRUE) THEN
        RAISE EXCEPTION 'PREFERRED_SUPPLIER_MUST_BE_ACTIVE';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.products p
        WHERE p.company_id = v_company_id
          AND p.id = p_product_id
          AND (NOT COALESCE(p_is_active,TRUE) OR p.is_active)
    ) THEN RAISE EXCEPTION 'ACTIVE_PRODUCT_NOT_FOUND'; END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.suppliers s
        WHERE s.company_id = v_company_id
          AND s.id = p_supplier_id
          AND (NOT COALESCE(p_is_active,TRUE) OR s.is_active)
    ) THEN RAISE EXCEPTION 'ACTIVE_SUPPLIER_NOT_FOUND'; END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.product_uoms pu
        WHERE pu.company_id = v_company_id
          AND pu.product_id = p_product_id
          AND pu.uom_id = p_purchase_uom_id
          AND (
              NOT COALESCE(p_is_active,TRUE)
              OR (pu.is_active AND pu.purchase_allowed)
          )
    ) THEN RAISE EXCEPTION 'ACTIVE_PURCHASE_PRODUCT_UOM_NOT_FOUND'; END IF;

    IF p_product_supplier_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        INSERT INTO public.product_suppliers(
            company_id,product_id,supplier_id,supplier_product_code,
            purchase_uom_id,reference_purchase_price,is_preferred_supplier,
            is_active,created_by,updated_by
        ) VALUES (
            v_company_id,p_product_id,p_supplier_id,
            NULLIF(btrim(p_supplier_product_code),''),p_purchase_uom_id,
            p_reference_purchase_price,
            COALESCE(p_is_preferred_supplier,FALSE),
            COALESCE(p_is_active,TRUE),v_actor,v_actor
        ) RETURNING id,master_version INTO v_relation_id,v_result_version;

        SELECT to_jsonb(ps) INTO v_after FROM public.product_suppliers ps
        WHERE ps.company_id = v_company_id AND ps.id = v_relation_id;
        INSERT INTO public.product_supplier_audit(
            company_id,product_supplier_id,action,actor_id,
            before_state,after_state
        ) VALUES (v_company_id,v_relation_id,'CREATE',v_actor,NULL,v_after);
    ELSE
        SELECT to_jsonb(ps),ps.master_version INTO v_before,v_result_version
        FROM public.product_suppliers ps
        WHERE ps.company_id = v_company_id
          AND ps.id = p_product_supplier_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'PRODUCT_SUPPLIER_NOT_FOUND'; END IF;
        IF p_master_version IS NULL OR p_master_version <> v_result_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;

        UPDATE public.product_suppliers
        SET product_id = p_product_id,
            supplier_id = p_supplier_id,
            supplier_product_code = NULLIF(btrim(p_supplier_product_code),''),
            purchase_uom_id = p_purchase_uom_id,
            reference_purchase_price = p_reference_purchase_price,
            is_preferred_supplier = COALESCE(
                p_is_preferred_supplier,FALSE
            ),
            is_active = COALESCE(p_is_active,TRUE),
            updated_by = v_actor
        WHERE company_id = v_company_id AND id = p_product_supplier_id
        RETURNING id,master_version INTO v_relation_id,v_result_version;

        SELECT to_jsonb(ps) INTO v_after FROM public.product_suppliers ps
        WHERE ps.company_id = v_company_id AND ps.id = v_relation_id;
        INSERT INTO public.product_supplier_audit(
            company_id,product_supplier_id,action,actor_id,
            before_state,after_state
        ) VALUES (v_company_id,v_relation_id,'UPDATE',v_actor,v_before,v_after);
    END IF;

    RETURN jsonb_build_object(
        'productSupplierId',v_relation_id,
        'masterVersion',v_result_version
    );
EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    IF v_constraint = 'uq_product_suppliers_one_active_preferred' THEN
        RAISE EXCEPTION 'PREFERRED_SUPPLIER_ALREADY_EXISTS';
    END IF;
    RAISE EXCEPTION 'PRODUCT_SUPPLIER_ALREADY_EXISTS';
END;
$$;

ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_master_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_supplier_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Supplier managers read active Company Suppliers"
ON public.suppliers FOR SELECT TO authenticated
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

CREATE POLICY "Supplier managers read active Company Product Suppliers"
ON public.product_suppliers FOR SELECT TO authenticated
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

CREATE POLICY "Supplier managers read Supplier audit"
ON public.supplier_master_audit FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY[
            'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER',
            'FINANCE','ACCOUNTING'
        ]::TEXT[]
    )
);

CREATE POLICY "Supplier managers read Product Supplier audit"
ON public.product_supplier_audit FOR SELECT TO authenticated
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

REVOKE ALL ON public.suppliers,public.product_suppliers,
    public.supplier_master_audit,public.product_supplier_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.suppliers,public.product_suppliers,
    public.supplier_master_audit,public.product_supplier_audit
TO authenticated;
GRANT ALL ON public.suppliers,public.product_suppliers,
    public.supplier_master_audit,public.product_supplier_audit
TO service_role;

REVOKE ALL ON FUNCTION public.save_supplier(
    UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.save_product_supplier(
    UUID,BIGINT,UUID,UUID,UUID,TEXT,NUMERIC,BOOLEAN,BOOLEAN
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_supplier(
    UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.save_product_supplier(
    UUID,BIGINT,UUID,UUID,UUID,TEXT,NUMERIC,BOOLEAN,BOOLEAN
) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260721230000',
    'g2_phase6_supplier_foundation',
    'Canonical Supplier and Product-Supplier master with active-Company RLS, optimistic versioning, guarded RPC writes, preferred uniqueness, bank-reference audit, and no Purchase/stock cutover'
);

COMMIT;
