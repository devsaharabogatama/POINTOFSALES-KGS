-- KGS POS G2 phase 10: one-level Customer parent/grouping and normalized
-- Warehouse-name uniqueness. Additive; transaction ownership remains on child.

BEGIN;

DO $guard$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260722010000') THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer foundation missing';
    END IF;
    IF EXISTS (SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260722040000') THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260722040000';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.warehouses
        GROUP BY company_id,lower(regexp_replace(btrim(name),'\s+',' ','g'))
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'DUPLICATE_NORMALIZED_WAREHOUSE_NAME';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.uoms
        GROUP BY company_id,upper(regexp_replace(btrim(code),'\s+',' ','g'))
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'DUPLICATE_NORMALIZED_UOM_CODE';
    END IF;
END
$guard$;

ALTER TABLE public.customers
    ADD COLUMN parent_customer_id UUID,
    ADD CONSTRAINT customers_parent_not_self CHECK (
        parent_customer_id IS NULL OR parent_customer_id <> id
    ),
    ADD CONSTRAINT customers_system_has_no_parent CHECK (
        NOT is_system_customer OR parent_customer_id IS NULL
    ),
    ADD CONSTRAINT fk_customers_company_parent
        FOREIGN KEY (company_id,parent_customer_id)
        REFERENCES public.customers(company_id,id) ON DELETE RESTRICT;

CREATE INDEX idx_customers_company_parent
    ON public.customers(company_id,parent_customer_id)
    WHERE parent_customer_id IS NOT NULL;

CREATE UNIQUE INDEX uq_warehouses_company_normalized_name
    ON public.warehouses(
        company_id,lower(regexp_replace(btrim(name),'\s+',' ','g'))
    );

CREATE UNIQUE INDEX uq_uoms_company_normalized_code
    ON public.uoms(
        company_id,upper(regexp_replace(btrim(code),'\s+',' ','g'))
    );

CREATE FUNCTION public.save_customer_with_parent(
    p_customer_id UUID,
    p_master_version BIGINT,
    p_customer_code TEXT,
    p_customer_name TEXT,
    p_customer_category_id UUID,
    p_phone TEXT,
    p_email TEXT,
    p_address TEXT,
    p_customer_type TEXT,
    p_credit_limit NUMERIC,
    p_credit_term_days INTEGER,
    p_notes TEXT,
    p_is_active BOOLEAN,
    p_parent_customer_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company_id UUID := public.private_active_company_id();
    v_result JSONB;
    v_id UUID;
    v_version BIGINT;
    v_current_parent UUID;
    v_before JSONB;
    v_after JSONB;
BEGIN
    v_result := public.save_customer(
        p_customer_id,p_master_version,p_customer_code,p_customer_name,
        p_customer_category_id,p_phone,p_email,p_address,p_customer_type,
        p_credit_limit,p_credit_term_days,p_notes,p_is_active
    );
    v_id := (v_result->>'customerId')::UUID;

    SELECT c.parent_customer_id,to_jsonb(c)
    INTO v_current_parent,v_before
    FROM public.customers c
    WHERE c.company_id=v_company_id AND c.id=v_id
    FOR UPDATE;

    IF p_parent_customer_id IS DISTINCT FROM v_current_parent THEN
        IF NOT public.private_user_has_any_company_or_store_role(
            v_company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER']::TEXT[]
        ) THEN
            RAISE EXCEPTION 'CUSTOMER_MANAGER_REQUIRED';
        END IF;
        IF p_parent_customer_id = v_id THEN
            RAISE EXCEPTION 'CUSTOMER_CANNOT_PARENT_ITSELF';
        END IF;
        IF p_parent_customer_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM public.customers p
            WHERE p.company_id=v_company_id AND p.id=p_parent_customer_id
              AND p.is_active AND NOT p.is_system_customer
              AND p.parent_customer_id IS NULL
        ) THEN
            RAISE EXCEPTION 'ACTIVE_ROOT_PARENT_CUSTOMER_NOT_FOUND';
        END IF;
        IF p_parent_customer_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.customers child
            WHERE child.company_id=v_company_id AND child.parent_customer_id=v_id
        ) THEN
            RAISE EXCEPTION 'CUSTOMER_WITH_CHILDREN_CANNOT_BECOME_CHILD';
        END IF;

        UPDATE public.customers
        SET parent_customer_id=p_parent_customer_id,updated_by=v_actor
        WHERE company_id=v_company_id AND id=v_id
        RETURNING master_version INTO v_version;

        SELECT to_jsonb(c) INTO v_after FROM public.customers c
        WHERE c.company_id=v_company_id AND c.id=v_id;
        INSERT INTO public.customer_master_audit(
            company_id,customer_id,action,actor_id,before_state,after_state
        ) VALUES (v_company_id,v_id,'UPDATE',v_actor,v_before,v_after);
        v_result := jsonb_set(v_result,'{masterVersion}',to_jsonb(v_version));
    END IF;

    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.save_customer_with_parent(
    UUID,BIGINT,TEXT,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,
    NUMERIC,INTEGER,TEXT,BOOLEAN,UUID
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_customer_with_parent(
    UUID,BIGINT,TEXT,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,
    NUMERIC,INTEGER,TEXT,BOOLEAN,UUID
) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES ('20260722040000','g2_phase10_customer_grouping',
        'One-level Customer parent grouping with child-level transaction ownership and normalized Warehouse-name uniqueness');

NOTIFY pgrst, 'reload schema';

COMMIT;
