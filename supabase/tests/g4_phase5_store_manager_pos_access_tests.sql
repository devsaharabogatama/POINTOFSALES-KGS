-- G4 phase 5 behavior: Store Manager may operate only an assigned Store POS.
-- SAFETY: all fixtures and Session writes are rolled back.

BEGIN;

INSERT INTO auth.users(
    id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at
) VALUES (
    '00000000-0000-0000-0000-000000053091',
    'g4-store-manager@example.invalid',
    '00000000-0000-0000-0000-000000000000',
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"name":"G4 Store Manager"}'::jsonb,
    FALSE,'authenticated','authenticated',clock_timestamp()
);

INSERT INTO public.profiles(id,email,name,role)
VALUES (
    '00000000-0000-0000-0000-000000053091',
    'g4-store-manager@example.invalid','G4 Store Manager',
    'cashier'::public.user_role
)
ON CONFLICT(id) DO UPDATE SET
    email = EXCLUDED.email,
    name = EXCLUDED.name,
    role = EXCLUDED.role;

INSERT INTO public.companies(
    id,company_code,company_name,company_slug,status
) VALUES (
    '00000000-0000-0000-0000-000000053001',
    'G53A','G53 Company A','g53-company-a','ACTIVE'
);

INSERT INTO public.stores(
    id,company_id,store_code,store_name,status
) VALUES
    (
        '00000000-0000-0000-0000-000000053011',
        '00000000-0000-0000-0000-000000053001',
        'A1','G53 Assigned Store','ACTIVE'
    ),
    (
        '00000000-0000-0000-0000-000000053012',
        '00000000-0000-0000-0000-000000053001',
        'A2','G53 Other Store','ACTIVE'
    );

INSERT INTO public.pos_terminals(
    id,company_id,store_id,pos_code,pos_name,status
) VALUES
    (
        '00000000-0000-0000-0000-000000053021',
        '00000000-0000-0000-0000-000000053001',
        '00000000-0000-0000-0000-000000053011',
        'POS1','G53 Assigned POS','ACTIVE'
    ),
    (
        '00000000-0000-0000-0000-000000053022',
        '00000000-0000-0000-0000-000000053001',
        '00000000-0000-0000-0000-000000053012',
        'POS2','G53 Other POS','ACTIVE'
    );

INSERT INTO public.warehouses(
    id,company_id,code,name,warehouse_type,store_id,
    is_sale_source,is_purchase_destination,is_active
) VALUES
    (
        '00000000-0000-0000-0000-000000053031',
        '00000000-0000-0000-0000-000000053001',
        'SWA','G53 Assigned Warehouse','STORE',
        '00000000-0000-0000-0000-000000053011',
        TRUE,FALSE,TRUE
    ),
    (
        '00000000-0000-0000-0000-000000053032',
        '00000000-0000-0000-0000-000000053001',
        'SWB','G53 Other Warehouse','STORE',
        '00000000-0000-0000-0000-000000053012',
        TRUE,FALSE,TRUE
    );

INSERT INTO public.company_memberships(
    company_id,user_id,role_code,status,is_default_company
) VALUES (
    '00000000-0000-0000-0000-000000053001',
    '00000000-0000-0000-0000-000000053091',
    'STORE_MANAGER','ACTIVE',TRUE
);

INSERT INTO public.store_memberships(
    company_id,store_id,user_id,role_code,status
) VALUES (
    '00000000-0000-0000-0000-000000053001',
    '00000000-0000-0000-0000-000000053011',
    '00000000-0000-0000-0000-000000053091',
    'STORE_MANAGER','ACTIVE'
);

DO $test$
DECLARE
    v_result JSONB;
    v_rejected BOOLEAN;
BEGIN
    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000053091","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000053001',
        'G4_PHASE5_MANAGER_TEST'
    );

    v_rejected := FALSE;
    BEGIN
        PERFORM public.open_cashier_session(
            '00000000-0000-0000-0000-000000053022',
            '00000000-0000-0000-0000-000000053032',
            100
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
            'TEST_FAILED: Store Manager accessed an unassigned Store POS';
    END IF;

    v_result := public.open_cashier_session(
        '00000000-0000-0000-0000-000000053021',
        '00000000-0000-0000-0000-000000053031',
        100
    );
    IF (v_result->>'cashierSessionId') IS NULL THEN
        RAISE EXCEPTION
            'TEST_FAILED: Store Manager assigned POS was rejected';
    END IF;

    RAISE NOTICE
        'TEST PASSED: Store Manager can operate only the assigned Store POS.';
END
$test$;

ROLLBACK;
