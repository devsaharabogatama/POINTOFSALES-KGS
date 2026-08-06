-- G4 phase 18: POS Customer quick-create.
-- Scope: create-only Customer identity for the actor's active Company.
-- No credit, balance, parent, Pricelist, or cross-Company authority is opened.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260730010000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 phase 14 dependency missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260730040000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260730040000';
    END IF;
    IF to_regprocedure(
        'public.quick_create_pos_customer(text,text,text,text,text)'
    ) IS NOT NULL THEN
        RAISE EXCEPTION 'G4_PHASE18_CANONICAL_ROUTINE_ALREADY_EXISTS';
    END IF;
END
$migration_guard$;

CREATE FUNCTION public.quick_create_pos_customer(
    p_customer_name TEXT,
    p_phone TEXT,
    p_email TEXT,
    p_address TEXT,
    p_customer_type TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_category UUID;
    v_customer_id UUID;
    v_code TEXT;
    v_sequence BIGINT;
    v_after JSONB;
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'AUTHENTICATION_REQUIRED';
    END IF;
    IF v_company IS NULL THEN
        RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM public.cashier_sessions cs
        WHERE cs.company_id = v_company
          AND cs.cashier_id = v_actor
          AND cs.status = 'OPEN'::public.session_status
    ) THEN
        RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
    END IF;
    IF btrim(COALESCE(p_customer_name,'')) = ''
       OR char_length(btrim(p_customer_name)) > 200 THEN
        RAISE EXCEPTION 'INVALID_CUSTOMER_NAME';
    END IF;
    IF upper(COALESCE(p_customer_type,'INDIVIDUAL'))
       NOT IN ('INDIVIDUAL','BUSINESS') THEN
        RAISE EXCEPTION 'INVALID_CUSTOMER_TYPE';
    END IF;
    IF p_phone IS NOT NULL AND char_length(btrim(p_phone)) > 100 THEN
        RAISE EXCEPTION 'INVALID_CUSTOMER_PHONE';
    END IF;
    IF p_email IS NOT NULL AND char_length(btrim(p_email)) > 320 THEN
        RAISE EXCEPTION 'INVALID_CUSTOMER_EMAIL';
    END IF;
    IF NULLIF(btrim(p_email),'') IS NOT NULL
       AND btrim(p_email) !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    THEN
        RAISE EXCEPTION 'INVALID_CUSTOMER_EMAIL';
    END IF;
    IF p_address IS NOT NULL AND char_length(btrim(p_address)) > 1000 THEN
        RAISE EXCEPTION 'INVALID_CUSTOMER_ADDRESS';
    END IF;

    SELECT cc.id
    INTO v_category
    FROM public.customer_categories cc
    WHERE cc.company_id = v_company
      AND cc.is_active
    ORDER BY cc.is_system_category DESC,cc.category_name,cc.id
    LIMIT 1;
    IF v_category IS NULL THEN
        RAISE EXCEPTION 'ACTIVE_CUSTOMER_CATEGORY_NOT_FOUND';
    END IF;

    INSERT INTO private.customer_code_sequences(company_id,next_value)
    VALUES (v_company,2)
    ON CONFLICT (company_id) DO UPDATE
    SET next_value = private.customer_code_sequences.next_value + 1
    RETURNING next_value - 1 INTO v_sequence;
    v_code := 'CUST-' || lpad(v_sequence::TEXT,6,'0');

    INSERT INTO public.customers(
        company_id,code,name,customer_category_id,phone,email,address,
        customer_type,credit_limit,credit_term_days,notes,is_active,
        current_balance,is_system_customer,parent_customer_id,
        default_pricelist_id,created_by,updated_by
    ) VALUES (
        v_company,v_code,btrim(p_customer_name),v_category,
        NULLIF(btrim(p_phone),''),
        NULLIF(lower(btrim(p_email)),''),
        NULLIF(btrim(p_address),''),
        upper(COALESCE(p_customer_type,'INDIVIDUAL')),
        0,NULL,NULL,TRUE,0,FALSE,NULL,NULL,v_actor,v_actor
    )
    RETURNING id INTO v_customer_id;

    SELECT to_jsonb(c) INTO v_after
    FROM public.customers c
    WHERE c.company_id = v_company AND c.id = v_customer_id;

    INSERT INTO public.customer_master_audit(
        company_id,customer_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_customer_id,'CREATE',v_actor,NULL,v_after
    );

    RETURN jsonb_build_object(
        'customerId',v_customer_id,
        'customerCode',v_code,
        'customerName',btrim(p_customer_name),
        'companyId',v_company
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'DUPLICATE_CUSTOMER';
END;
$$;

REVOKE ALL ON FUNCTION public.quick_create_pos_customer(
    TEXT,TEXT,TEXT,TEXT,TEXT
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.quick_create_pos_customer(
    TEXT,TEXT,TEXT,TEXT,TEXT
) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260730040000',
    'g4_phase18_pos_customer_quick_create',
    'Create-only POS Customer RPC bound to active Company and open Cashier Session; no credit, balance, parent, Pricelist, or cross-Company authority'
);

NOTIFY pgrst,'reload schema';

COMMIT;
