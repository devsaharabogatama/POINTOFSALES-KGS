-- G1 phase 5A behavioral RLS test.
-- SAFETY: fixtures, profile role changes, and mutations are rolled back.

BEGIN;

INSERT INTO auth.users (
    id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at
) VALUES
    (
        '00000000-0000-0000-0000-000000005091','g1p5-admin@example.invalid',
        '00000000-0000-0000-0000-000000000000',
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{"name":"G1 P5 Admin"}'::jsonb,FALSE,'authenticated','authenticated',now()
    ),
    (
        '00000000-0000-0000-0000-000000005092','g1p5-cashier@example.invalid',
        '00000000-0000-0000-0000-000000000000',
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{"name":"G1 P5 Cashier"}'::jsonb,FALSE,'authenticated','authenticated',now()
    );

INSERT INTO public.profiles (id,email,name,role) VALUES
    ('00000000-0000-0000-0000-000000005091','g1p5-admin@example.invalid','G1 P5 Admin','cashier'::user_role),
    ('00000000-0000-0000-0000-000000005092','g1p5-cashier@example.invalid','G1 P5 Cashier','cashier'::user_role)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

INSERT INTO public.companies (id,company_code,company_name,company_slug,status) VALUES
    ('00000000-0000-0000-0000-000000005001','G5A','G5 Company A','g5-company-a','ACTIVE'),
    ('00000000-0000-0000-0000-000000005002','G5B','G5 Company B','g5-company-b','ACTIVE');

INSERT INTO public.stores (id,company_id,store_code,store_name,status) VALUES
    ('00000000-0000-0000-0000-000000005011','00000000-0000-0000-0000-000000005001','A1','G5 Store A1','ACTIVE'),
    ('00000000-0000-0000-0000-000000005012','00000000-0000-0000-0000-000000005001','A2','G5 Store A2','ACTIVE'),
    ('00000000-0000-0000-0000-000000005013','00000000-0000-0000-0000-000000005002','B1','G5 Store B1','ACTIVE');

INSERT INTO public.company_memberships (
    company_id,user_id,role_code,status,is_default_company
) VALUES
    ('00000000-0000-0000-0000-000000005001','00000000-0000-0000-0000-000000005091','COMPANY_ADMIN','ACTIVE',TRUE),
    ('00000000-0000-0000-0000-000000005001','00000000-0000-0000-0000-000000005092','CASHIER','ACTIVE',TRUE);

INSERT INTO public.store_memberships (
    company_id,store_id,user_id,role_code,status
) VALUES (
    '00000000-0000-0000-0000-000000005001',
    '00000000-0000-0000-0000-000000005011',
    '00000000-0000-0000-0000-000000005092','CASHIER','ACTIVE'
);

SET LOCAL ROLE authenticated;

DO $test$
DECLARE
    v_count BIGINT;
    v_blocked BOOLEAN := FALSE;
BEGIN
    -- Company Admin can work only in the selected/owned Company.
    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000005091","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000005001','G1_PHASE5A_TEST'
    );

    SELECT count(*) INTO v_count FROM public.companies;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Company Admin saw % Companies, expected 1',v_count;
    END IF;

    INSERT INTO public.stores (company_id,store_code,store_name,status)
    VALUES ('00000000-0000-0000-0000-000000005001','A3','G5 Store A3','ACTIVE');

    BEGIN
        INSERT INTO public.stores (company_id,store_code,store_name,status)
        VALUES ('00000000-0000-0000-0000-000000005002','BX','Forged Store','ACTIVE');
    EXCEPTION WHEN insufficient_privilege THEN
        v_blocked := TRUE;
    END;
    IF NOT v_blocked THEN
        RAISE EXCEPTION 'TEST_FAILED: Company Admin inserted cross-Company Store';
    END IF;

    -- Cashier sees only the assigned Store and cannot mutate master Store.
    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000005092","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000005001','G1_PHASE5A_TEST'
    );

    SELECT count(*) INTO v_count FROM public.stores;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier saw % Stores, expected assigned Store only',v_count;
    END IF;

    v_blocked := FALSE;
    BEGIN
        INSERT INTO public.stores (company_id,store_code,store_name,status)
        VALUES ('00000000-0000-0000-0000-000000005001','CX','Cashier Store','ACTIVE');
    EXCEPTION WHEN insufficient_privilege THEN
        v_blocked := TRUE;
    END;
    IF NOT v_blocked THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier inserted Store master';
    END IF;

    IF has_table_privilege('authenticated','public.profiles','UPDATE')
       OR has_table_privilege('authenticated','public.company_memberships','INSERT') THEN
        RAISE EXCEPTION 'TEST_FAILED: identity privilege permits escalation path';
    END IF;

    RAISE NOTICE 'TEST PASSED: core role/RLS prevents cross-Company and privilege escalation.';
END
$test$;

RESET ROLE;
ROLLBACK;
