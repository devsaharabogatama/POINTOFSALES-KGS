-- KGS POS G2 phase 8: canonical Customer Category and Customer foundation.
-- Requirements: G2 canonical master data; Customer identity/category contract.
-- Dependency: 20260721230000_g2_phase6_supplier_foundation.sql
--
-- This phase does not implement Customer Balance ledger, TEMPO, Pricelist,
-- checkout, Finance posting, or Cashier quick-create.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260721230000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G2 Supplier foundation is incomplete';
    END IF;

    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260722010000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260722010000';
    END IF;

    IF to_regclass('public.customer_categories') IS NOT NULL
       OR to_regclass('public.customer_master_audit') IS NOT NULL
       OR to_regclass('public.customer_category_audit') IS NOT NULL
       OR to_regclass('private.customer_code_sequences') IS NOT NULL THEN
        RAISE EXCEPTION 'G2_PHASE8_CANONICAL_OBJECT_ALREADY_EXISTS';
    END IF;
END
$migration_guard$;

-- The approved preflight reported no Customer rows. Stop instead of silently
-- inventing categories or balance provenance if live state has changed.
DO $live_state_guard$
DECLARE
    v_customers BIGINT;
    v_nonzero_balance BIGINT;
BEGIN
    SELECT count(*),count(*) FILTER (WHERE current_balance <> 0)
    INTO v_customers,v_nonzero_balance
    FROM public.customers;

    IF v_customers <> 0 OR v_nonzero_balance <> 0 THEN
        RAISE EXCEPTION
            'G2_PHASE8_STATE_CHANGED: customers %, nonzero balances %; rerun preflight and design explicit backfill',
            v_customers,v_nonzero_balance;
    END IF;
END
$live_state_guard$;

CREATE TABLE public.customer_categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    category_code TEXT NOT NULL,
    category_name TEXT NOT NULL,
    is_system_category BOOLEAN NOT NULL DEFAULT FALSE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT customer_categories_company_id_id_unique
        UNIQUE (company_id,id),
    CONSTRAINT customer_categories_code_not_blank
        CHECK (btrim(category_code) <> ''),
    CONSTRAINT customer_categories_name_not_blank
        CHECK (btrim(category_name) <> ''),
    CONSTRAINT customer_categories_version_positive
        CHECK (master_version > 0),
    CONSTRAINT customer_categories_system_invariant CHECK (
        NOT is_system_category
        OR (upper(btrim(category_code)) = 'GENERAL' AND is_active)
    )
);

CREATE UNIQUE INDEX uq_customer_categories_company_normalized_code
    ON public.customer_categories (
        company_id,
        upper(regexp_replace(btrim(category_code),'\s+',' ','g'))
    );
CREATE UNIQUE INDEX uq_customer_categories_company_normalized_name
    ON public.customer_categories (
        company_id,
        lower(regexp_replace(btrim(category_name),'\s+',' ','g'))
    );
CREATE INDEX idx_customer_categories_company_active
    ON public.customer_categories(company_id,is_active,category_name);

ALTER TABLE public.customers
    ADD COLUMN customer_category_id UUID,
    ADD COLUMN email TEXT,
    ADD COLUMN customer_type TEXT NOT NULL DEFAULT 'INDIVIDUAL',
    ADD COLUMN credit_term_days INTEGER,
    ADD COLUMN is_active BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN is_system_customer BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN notes TEXT,
    ADD COLUMN master_version BIGINT NOT NULL DEFAULT 1,
    ADD COLUMN created_by UUID REFERENCES public.profiles(id),
    ADD COLUMN updated_by UUID REFERENCES public.profiles(id),
    ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    ADD CONSTRAINT customers_type_check CHECK (
        customer_type IN ('INDIVIDUAL','BUSINESS','WALK_IN')
    ),
    ADD CONSTRAINT customers_credit_limit_nonnegative CHECK (credit_limit >= 0),
    ADD CONSTRAINT customers_balance_nonnegative CHECK (current_balance >= 0),
    ADD CONSTRAINT customers_credit_term_check CHECK (
        credit_term_days IS NULL OR credit_term_days BETWEEN 0 AND 3650
    ),
    ADD CONSTRAINT customers_version_positive CHECK (master_version > 0),
    ADD CONSTRAINT customers_system_invariant CHECK (
        NOT is_system_customer
        OR (
            upper(btrim(code)) = 'WALK-IN'
            AND customer_type = 'WALK_IN'
            AND is_active
            AND current_balance = 0
            AND credit_limit = 0
        )
    );

CREATE UNIQUE INDEX uq_customers_company_normalized_code
    ON public.customers (
        company_id,
        upper(regexp_replace(btrim(code),'\s+',' ','g'))
    );
CREATE UNIQUE INDEX uq_customers_company_normalized_name
    ON public.customers (
        company_id,
        lower(regexp_replace(btrim(name),'\s+',' ','g'))
    );
CREATE UNIQUE INDEX uq_customers_one_system_walk_in
    ON public.customers(company_id)
    WHERE is_system_customer;
CREATE INDEX idx_customers_company_category_active
    ON public.customers(company_id,customer_category_id,is_active);

CREATE TABLE private.customer_code_sequences (
    company_id UUID PRIMARY KEY
        REFERENCES public.companies(id) ON DELETE CASCADE,
    next_value BIGINT NOT NULL DEFAULT 1 CHECK (next_value > 0)
);

CREATE TABLE public.customer_category_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    customer_category_id UUID NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('CREATE','UPDATE')),
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fk_customer_category_audit_category
        FOREIGN KEY (company_id,customer_category_id)
        REFERENCES public.customer_categories(company_id,id)
        ON DELETE RESTRICT
);

CREATE TABLE public.customer_master_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    customer_id UUID NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('CREATE','UPDATE')),
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fk_customer_master_audit_customer
        FOREIGN KEY (company_id,customer_id)
        REFERENCES public.customers(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_customer_category_audit_created
    ON public.customer_category_audit(
        company_id,customer_category_id,created_at DESC
    );
CREATE INDEX idx_customer_master_audit_created
    ON public.customer_master_audit(company_id,customer_id,created_at DESC);

-- Provision a reusable system category and immutable Walk-In Customer for all
-- existing Companies. No business Customer data existed at approved preflight.
INSERT INTO public.customer_categories(
    company_id,category_code,category_name,is_system_category,is_active
)
SELECT id,'GENERAL','Umum',TRUE,TRUE
FROM public.companies;

INSERT INTO public.customers(
    company_id,code,name,customer_category_id,customer_type,
    current_balance,credit_limit,is_active,is_system_customer
)
SELECT
    c.id,'WALK-IN','Pelanggan Umum',cc.id,'WALK_IN',0,0,TRUE,TRUE
FROM public.companies c
JOIN public.customer_categories cc
  ON cc.company_id = c.id
 AND cc.category_code = 'GENERAL';

INSERT INTO private.customer_code_sequences(company_id,next_value)
SELECT id,1 FROM public.companies;

ALTER TABLE public.customers
    ALTER COLUMN customer_category_id SET NOT NULL,
    ADD CONSTRAINT fk_customers_company_category
        FOREIGN KEY (company_id,customer_category_id)
        REFERENCES public.customer_categories(company_id,id)
        ON DELETE RESTRICT;

CREATE TRIGGER g2_touch_customer_categories
BEFORE INSERT OR UPDATE ON public.customer_categories
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();

CREATE TRIGGER g2_touch_customers
BEFORE INSERT OR UPDATE ON public.customers
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();

CREATE FUNCTION private.trg_g2_provision_customer_defaults()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_category_id UUID;
BEGIN
    INSERT INTO public.customer_categories(
        company_id,category_code,category_name,is_system_category,is_active
    ) VALUES (NEW.id,'GENERAL','Umum',TRUE,TRUE)
    RETURNING id INTO v_category_id;

    INSERT INTO public.customers(
        company_id,code,name,customer_category_id,customer_type,
        current_balance,credit_limit,is_active,is_system_customer
    ) VALUES (
        NEW.id,'WALK-IN','Pelanggan Umum',v_category_id,'WALK_IN',
        0,0,TRUE,TRUE
    );

    INSERT INTO private.customer_code_sequences(company_id,next_value)
    VALUES (NEW.id,1);
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_provision_customer_defaults()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_provision_customer_defaults()
TO service_role;

CREATE TRIGGER g2_provision_customer_defaults
AFTER INSERT ON public.companies
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_provision_customer_defaults();

CREATE FUNCTION public.save_customer_category(
    p_customer_category_id UUID,
    p_master_version BIGINT,
    p_category_code TEXT,
    p_category_name TEXT,
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
    v_id UUID;
    v_version BIGINT;
    v_before JSONB;
    v_after JSONB;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company_id IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER']::TEXT[]
    ) THEN
        RAISE EXCEPTION 'CUSTOMER_MANAGER_REQUIRED';
    END IF;
    IF btrim(COALESCE(p_category_code,'')) = ''
       OR char_length(btrim(p_category_code)) > 100 THEN
        RAISE EXCEPTION 'INVALID_CUSTOMER_CATEGORY_CODE';
    END IF;
    IF btrim(COALESCE(p_category_name,'')) = ''
       OR char_length(btrim(p_category_name)) > 200 THEN
        RAISE EXCEPTION 'INVALID_CUSTOMER_CATEGORY_NAME';
    END IF;

    IF p_customer_category_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        INSERT INTO public.customer_categories(
            company_id,category_code,category_name,is_active,
            created_by,updated_by
        ) VALUES (
            v_company_id,upper(btrim(p_category_code)),
            btrim(p_category_name),COALESCE(p_is_active,TRUE),v_actor,v_actor
        ) RETURNING id,master_version INTO v_id,v_version;

        SELECT to_jsonb(c) INTO v_after
        FROM public.customer_categories c
        WHERE c.company_id = v_company_id AND c.id = v_id;
        INSERT INTO public.customer_category_audit(
            company_id,customer_category_id,action,actor_id,
            before_state,after_state
        ) VALUES (v_company_id,v_id,'CREATE',v_actor,NULL,v_after);
    ELSE
        SELECT to_jsonb(c),c.master_version INTO v_before,v_version
        FROM public.customer_categories c
        WHERE c.company_id = v_company_id
          AND c.id = p_customer_category_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_CATEGORY_NOT_FOUND'; END IF;
        IF (v_before->>'is_system_category')::BOOLEAN THEN
            RAISE EXCEPTION 'SYSTEM_CUSTOMER_CATEGORY_IMMUTABLE';
        END IF;
        IF p_master_version IS NULL OR p_master_version <> v_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;

        UPDATE public.customer_categories
        SET category_code = upper(btrim(p_category_code)),
            category_name = btrim(p_category_name),
            is_active = COALESCE(p_is_active,TRUE),
            updated_by = v_actor
        WHERE company_id = v_company_id AND id = p_customer_category_id
        RETURNING id,master_version INTO v_id,v_version;

        SELECT to_jsonb(c) INTO v_after
        FROM public.customer_categories c
        WHERE c.company_id = v_company_id AND c.id = v_id;
        INSERT INTO public.customer_category_audit(
            company_id,customer_category_id,action,actor_id,
            before_state,after_state
        ) VALUES (v_company_id,v_id,'UPDATE',v_actor,v_before,v_after);
    END IF;

    RETURN jsonb_build_object(
        'customerCategoryId',v_id,'masterVersion',v_version
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'DUPLICATE_CUSTOMER_CATEGORY';
END;
$$;

CREATE FUNCTION public.save_customer(
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
    v_is_master_manager BOOLEAN;
    v_is_credit_manager BOOLEAN;
    v_id UUID;
    v_version BIGINT;
    v_code TEXT;
    v_sequence BIGINT;
    v_before JSONB;
    v_after JSONB;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company_id IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;

    v_is_master_manager := public.private_user_has_any_company_or_store_role(
        v_company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER']::TEXT[]
    );
    v_is_credit_manager := public.private_user_has_any_company_or_store_role(
        v_company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
    );

    IF btrim(COALESCE(p_customer_name,'')) = ''
       OR char_length(btrim(p_customer_name)) > 200 THEN
        RAISE EXCEPTION 'INVALID_CUSTOMER_NAME';
    END IF;
    IF upper(COALESCE(p_customer_type,'INDIVIDUAL'))
       NOT IN ('INDIVIDUAL','BUSINESS') THEN
        RAISE EXCEPTION 'INVALID_CUSTOMER_TYPE';
    END IF;
    IF COALESCE(p_credit_limit,0) < 0 THEN
        RAISE EXCEPTION 'INVALID_CUSTOMER_CREDIT_LIMIT';
    END IF;
    IF p_credit_term_days IS NOT NULL
       AND p_credit_term_days NOT BETWEEN 0 AND 3650 THEN
        RAISE EXCEPTION 'INVALID_CUSTOMER_CREDIT_TERM';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.customer_categories c
        WHERE c.company_id = v_company_id
          AND c.id = p_customer_category_id
          AND c.is_active
    ) THEN
        RAISE EXCEPTION 'ACTIVE_CUSTOMER_CATEGORY_NOT_FOUND';
    END IF;

    IF p_customer_id IS NULL THEN
        IF NOT v_is_master_manager THEN
            RAISE EXCEPTION 'CUSTOMER_MANAGER_REQUIRED';
        END IF;
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        IF (COALESCE(p_credit_limit,0) <> 0 OR p_credit_term_days IS NOT NULL)
           AND NOT v_is_credit_manager THEN
            RAISE EXCEPTION 'CUSTOMER_CREDIT_MANAGER_REQUIRED';
        END IF;

        IF btrim(COALESCE(p_customer_code,'')) = '' THEN
            INSERT INTO private.customer_code_sequences(company_id,next_value)
            VALUES (v_company_id,2)
            ON CONFLICT (company_id) DO UPDATE
            SET next_value = private.customer_code_sequences.next_value + 1
            RETURNING next_value - 1 INTO v_sequence;
            v_code := 'CUST-' || lpad(v_sequence::TEXT,6,'0');
        ELSE
            v_code := upper(btrim(p_customer_code));
        END IF;
        IF char_length(v_code) > 100 THEN
            RAISE EXCEPTION 'INVALID_CUSTOMER_CODE';
        END IF;

        INSERT INTO public.customers(
            company_id,code,name,customer_category_id,phone,email,address,
            customer_type,credit_limit,credit_term_days,notes,is_active,
            current_balance,is_system_customer,created_by,updated_by
        ) VALUES (
            v_company_id,v_code,btrim(p_customer_name),
            p_customer_category_id,NULLIF(btrim(p_phone),''),
            NULLIF(lower(btrim(p_email)),''),NULLIF(btrim(p_address),''),
            upper(COALESCE(p_customer_type,'INDIVIDUAL')),
            COALESCE(p_credit_limit,0),p_credit_term_days,
            NULLIF(btrim(p_notes),''),COALESCE(p_is_active,TRUE),
            0,FALSE,v_actor,v_actor
        ) RETURNING id,master_version INTO v_id,v_version;

        SELECT to_jsonb(c) INTO v_after FROM public.customers c
        WHERE c.company_id = v_company_id AND c.id = v_id;
        INSERT INTO public.customer_master_audit(
            company_id,customer_id,action,actor_id,before_state,after_state
        ) VALUES (v_company_id,v_id,'CREATE',v_actor,NULL,v_after);
    ELSE
        SELECT to_jsonb(c),c.master_version INTO v_before,v_version
        FROM public.customers c
        WHERE c.company_id = v_company_id AND c.id = p_customer_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_NOT_FOUND'; END IF;
        IF (v_before->>'is_system_customer')::BOOLEAN THEN
            RAISE EXCEPTION 'SYSTEM_CUSTOMER_IMMUTABLE';
        END IF;
        IF p_master_version IS NULL OR p_master_version <> v_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;

        v_code := upper(btrim(COALESCE(p_customer_code,'')));
        IF v_code = '' OR char_length(v_code) > 100 THEN
            RAISE EXCEPTION 'INVALID_CUSTOMER_CODE';
        END IF;

        IF NOT v_is_master_manager AND (
            v_code IS DISTINCT FROM (v_before->>'code')
            OR btrim(p_customer_name) IS DISTINCT FROM (v_before->>'name')
            OR p_customer_category_id IS DISTINCT FROM
                (v_before->>'customer_category_id')::UUID
            OR NULLIF(btrim(p_phone),'') IS DISTINCT FROM (v_before->>'phone')
            OR NULLIF(lower(btrim(p_email)),'') IS DISTINCT FROM
                (v_before->>'email')
            OR NULLIF(btrim(p_address),'') IS DISTINCT FROM
                (v_before->>'address')
            OR upper(COALESCE(p_customer_type,'INDIVIDUAL')) IS DISTINCT FROM
                (v_before->>'customer_type')
            OR NULLIF(btrim(p_notes),'') IS DISTINCT FROM (v_before->>'notes')
            OR COALESCE(p_is_active,TRUE) IS DISTINCT FROM
                (v_before->>'is_active')::BOOLEAN
        ) THEN
            RAISE EXCEPTION 'CUSTOMER_MANAGER_REQUIRED';
        END IF;

        IF NOT v_is_credit_manager AND (
            COALESCE(p_credit_limit,0) IS DISTINCT FROM
                (v_before->>'credit_limit')::NUMERIC
            OR p_credit_term_days IS DISTINCT FROM
                (v_before->>'credit_term_days')::INTEGER
        ) THEN
            RAISE EXCEPTION 'CUSTOMER_CREDIT_MANAGER_REQUIRED';
        END IF;

        UPDATE public.customers
        SET code = v_code,
            name = btrim(p_customer_name),
            customer_category_id = p_customer_category_id,
            phone = NULLIF(btrim(p_phone),''),
            email = NULLIF(lower(btrim(p_email)),''),
            address = NULLIF(btrim(p_address),''),
            customer_type = upper(COALESCE(p_customer_type,'INDIVIDUAL')),
            credit_limit = COALESCE(p_credit_limit,0),
            credit_term_days = p_credit_term_days,
            notes = NULLIF(btrim(p_notes),''),
            is_active = COALESCE(p_is_active,TRUE),
            updated_by = v_actor
        WHERE company_id = v_company_id AND id = p_customer_id
        RETURNING id,master_version INTO v_id,v_version;

        SELECT to_jsonb(c) INTO v_after FROM public.customers c
        WHERE c.company_id = v_company_id AND c.id = v_id;
        INSERT INTO public.customer_master_audit(
            company_id,customer_id,action,actor_id,before_state,after_state
        ) VALUES (v_company_id,v_id,'UPDATE',v_actor,v_before,v_after);
    END IF;

    RETURN jsonb_build_object(
        'customerId',v_id,'customerCode',v_code,'masterVersion',v_version
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'DUPLICATE_CUSTOMER';
END;
$$;

ALTER TABLE public.customer_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_category_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_master_audit ENABLE ROW LEVEL SECURITY;

DO $drop_customer_policies$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT policyname FROM pg_policies
        WHERE schemaname = 'public' AND tablename = 'customers'
    LOOP
        EXECUTE format('DROP POLICY %I ON public.customers',r.policyname);
    END LOOP;
END
$drop_customer_policies$;

CREATE POLICY "Customers readable in active Company"
ON public.customers FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);

CREATE POLICY "Customer categories readable in active Company"
ON public.customer_categories FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);

CREATE POLICY "Customer managers read category audit"
ON public.customer_category_audit FOR SELECT TO authenticated
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

CREATE POLICY "Customer managers read Customer audit"
ON public.customer_master_audit FOR SELECT TO authenticated
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

REVOKE ALL ON public.customers,public.customer_categories,
    public.customer_category_audit,public.customer_master_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.customers,public.customer_categories,
    public.customer_category_audit,public.customer_master_audit
TO authenticated;
GRANT ALL ON public.customers,public.customer_categories,
    public.customer_category_audit,public.customer_master_audit
TO service_role;

REVOKE ALL ON FUNCTION public.save_customer_category(
    UUID,BIGINT,TEXT,TEXT,BOOLEAN
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.save_customer(
    UUID,BIGINT,TEXT,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,
    NUMERIC,INTEGER,TEXT,BOOLEAN
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_customer_category(
    UUID,BIGINT,TEXT,TEXT,BOOLEAN
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.save_customer(
    UUID,BIGINT,TEXT,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,
    NUMERIC,INTEGER,TEXT,BOOLEAN
) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260722010000',
    'g2_phase8_customer_foundation',
    'Canonical Customer Category and Customer identity with automatic Walk-In provisioning, tenant RLS, guarded versioned RPCs, audit, and immutable balance boundary'
);

COMMIT;
