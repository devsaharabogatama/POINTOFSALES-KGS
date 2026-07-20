-- G1 phase 1 behavioral test for feature entitlement.
--
-- PRECONDITION:
-- - migration 20260720090000 is applied;
-- - at least one Super Admin profile linked to auth.users exists.
--
-- A normal actor uses a non-existent UUID because the authorization function
-- must reject any actor that is not a Super Admin. If no Company exists, this
-- test creates a transaction-local Company fixture. All mutations roll back.

BEGIN;

DO $test$
DECLARE
    v_super_admin UUID;
    v_normal_user UUID := '00000000-0000-0000-0000-000000000099';
    v_company_id UUID;
    v_rejected BOOLEAN := FALSE;
    v_audit_before BIGINT;
    v_audit_after BIGINT;
BEGIN
    SELECT p.id INTO v_super_admin
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::user_role
    ORDER BY p.id
    LIMIT 1;

    SELECT id INTO v_company_id
    FROM public.companies
    ORDER BY id
    LIMIT 1;

    IF v_super_admin IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: no Super Admin profile linked to auth.users';
    END IF;

    IF v_company_id IS NULL THEN
        v_company_id := '00000000-0000-0000-0000-000000000098';
        INSERT INTO public.companies (
            id,
            company_code,
            company_name,
            company_slug,
            status
        ) VALUES (
            v_company_id,
            'G1TST',
            'G1 Transaction Test',
            'g1-transaction-test',
            'ACTIVE'
        );
    END IF;

    IF has_function_privilege(
        'authenticated',
        'public.process_financial_events_queue()',
        'EXECUTE'
    ) OR has_function_privilege(
        'authenticated',
        'public.transfer_product_stock(uuid,uuid,uuid,numeric)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: authenticated still has unsafe RPC execute';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object(
            'sub', v_normal_user,
            'role', 'authenticated'
        )::text,
        TRUE
    );

    BEGIN
        PERFORM public.set_company_feature(
            v_company_id,
            'tax_sales_enabled',
            TRUE,
            '{"test":true}'::jsonb
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'SUPER_ADMIN_REQUIRED' THEN
            v_rejected := TRUE;
        ELSE
            RAISE EXCEPTION 'TEST_FAILED with unexpected normal-user error: %', SQLERRM;
        END IF;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: normal user changed Company feature';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object(
            'sub', v_super_admin,
            'role', 'authenticated'
        )::text,
        TRUE
    );

    SELECT count(*) INTO v_audit_before
    FROM public.company_feature_audit
    WHERE company_id = v_company_id
      AND feature_code = 'tax_sales_enabled';

    PERFORM public.set_company_feature(
        v_company_id,
        'tax_sales_enabled',
        TRUE,
        '{"test":true}'::jsonb
    );

    IF NOT public.private_company_feature_enabled(
        v_company_id,
        'tax_sales_enabled'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: enabled feature guard returned false';
    END IF;

    SELECT count(*) INTO v_audit_after
    FROM public.company_feature_audit
    WHERE company_id = v_company_id
      AND feature_code = 'tax_sales_enabled';

    IF v_audit_after <> v_audit_before + 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: expected one audit row, before %, after %',
            v_audit_before,
            v_audit_after;
    END IF;

    RAISE NOTICE 'TEST PASSED: only Super Admin changed feature and audit was written.';
END
$test$;

ROLLBACK;
