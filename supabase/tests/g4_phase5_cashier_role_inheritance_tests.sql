-- G4 phase 5 behavioral regression: approved role inheritance may open a
-- Cashier Session, while an unassigned ordinary Cashier remains rejected.
-- SAFETY: every Auth, Company, Session, and audit fixture is rolled back.

BEGIN;

INSERT INTO auth.users(
    id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at
) VALUES
    (
        '00000000-0000-0000-0000-000000052091',
        'g4-inherit-super@example.invalid',
        '00000000-0000-0000-0000-000000000000',
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{"name":"G4 Inherited Super"}'::jsonb,
        FALSE,'authenticated','authenticated',clock_timestamp()
    ),
    (
        '00000000-0000-0000-0000-000000052092',
        'g4-inherit-admin@example.invalid',
        '00000000-0000-0000-0000-000000000000',
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{"name":"G4 Inherited Admin"}'::jsonb,
        FALSE,'authenticated','authenticated',clock_timestamp()
    ),
    (
        '00000000-0000-0000-0000-000000052093',
        'g4-unassigned-cashier@example.invalid',
        '00000000-0000-0000-0000-000000000000',
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{"name":"G4 Unassigned Cashier"}'::jsonb,
        FALSE,'authenticated','authenticated',clock_timestamp()
    );

INSERT INTO public.profiles(id,email,name,role) VALUES
    (
        '00000000-0000-0000-0000-000000052091',
        'g4-inherit-super@example.invalid','G4 Inherited Super',
        'super_admin'::public.user_role
    ),
    (
        '00000000-0000-0000-0000-000000052092',
        'g4-inherit-admin@example.invalid','G4 Inherited Admin',
        'cashier'::public.user_role
    ),
    (
        '00000000-0000-0000-0000-000000052093',
        'g4-unassigned-cashier@example.invalid','G4 Unassigned Cashier',
        'cashier'::public.user_role
    )
ON CONFLICT(id) DO UPDATE SET
    email = EXCLUDED.email,
    name = EXCLUDED.name,
    role = EXCLUDED.role;

INSERT INTO public.companies(
    id,company_code,company_name,company_slug,status
) VALUES (
    '00000000-0000-0000-0000-000000052001',
    'G52A','G52 Company A','g52-company-a','ACTIVE'
);

INSERT INTO public.stores(
    id,company_id,store_code,store_name,status
) VALUES (
    '00000000-0000-0000-0000-000000052011',
    '00000000-0000-0000-0000-000000052001',
    'A1','G52 Store A','ACTIVE'
);

INSERT INTO public.pos_terminals(
    id,company_id,store_id,pos_code,pos_name,status
) VALUES (
    '00000000-0000-0000-0000-000000052021',
    '00000000-0000-0000-0000-000000052001',
    '00000000-0000-0000-0000-000000052011',
    'POS1','G52 POS 1','ACTIVE'
);

INSERT INTO public.warehouses(
    id,company_id,code,name,warehouse_type,store_id,
    is_sale_source,is_purchase_destination,is_active
) VALUES (
    '00000000-0000-0000-0000-000000052031',
    '00000000-0000-0000-0000-000000052001',
    'SWA','G52 Sales Warehouse','STORE',
    '00000000-0000-0000-0000-000000052011',
    TRUE,FALSE,TRUE
);

INSERT INTO public.company_memberships(
    company_id,user_id,role_code,status,is_default_company
) VALUES
    (
        '00000000-0000-0000-0000-000000052001',
        '00000000-0000-0000-0000-000000052092',
        'COMPANY_ADMIN','ACTIVE',TRUE
    ),
    (
        '00000000-0000-0000-0000-000000052001',
        '00000000-0000-0000-0000-000000052093',
        'CASHIER','ACTIVE',FALSE
    );

DO $test$
DECLARE
    v_result JSONB;
    v_rejected BOOLEAN;
BEGIN
    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000052091","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000052001',
        'G4_PHASE5_INHERITANCE_TEST'
    );
    v_result := public.open_cashier_session(
        '00000000-0000-0000-0000-000000052021',
        '00000000-0000-0000-0000-000000052031',
        100
    );
    IF (v_result->>'cashierSessionId') IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: Super Admin inheritance was rejected';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000052092","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000052001',
        'G4_PHASE5_INHERITANCE_TEST'
    );
    v_result := public.open_cashier_session(
        '00000000-0000-0000-0000-000000052021',
        '00000000-0000-0000-0000-000000052031',
        200
    );
    IF (v_result->>'cashierSessionId') IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: Company Admin inheritance was rejected';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000052093","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000052001',
        'G4_PHASE5_INHERITANCE_TEST'
    );
    v_rejected := FALSE;
    BEGIN
        PERFORM public.open_cashier_session(
            '00000000-0000-0000-0000-000000052021',
            '00000000-0000-0000-0000-000000052031',
            300
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_CASHIER_ASSIGNMENT_REQUIRED' THEN
            v_rejected := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: unassigned ordinary Cashier opened a Session';
    END IF;

    RAISE NOTICE
        'TEST PASSED: Super/Admin inheritance works and ordinary Cashier remains Store-assignment scoped.';
END
$test$;

ROLLBACK;
