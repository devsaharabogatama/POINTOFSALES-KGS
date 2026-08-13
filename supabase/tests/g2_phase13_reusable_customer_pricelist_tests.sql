-- G2 phase 13 behavioral test: one Customer Pricelist is reusable.
-- SAFETY: every fixture, assignment, and audit row is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_category UUID;
    v_pricelist UUID;
    v_foreign_pricelist UUID := '00000000-0000-0000-0000-000000014099';
    v_customer_a UUID;
    v_customer_b UUID;
    v_walk_in UUID;
    v_result JSONB;
    v_count BIGINT;
    v_rejected BOOLEAN;
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id=p.id
    WHERE p.role='super_admin'::user_role
    ORDER BY p.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
        ('00000000-0000-0000-0000-000000014001',
         'G14A','G14 Company A','g14-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000014002',
         'G14B','G14 Company B','g14-company-b','ACTIVE');

    INSERT INTO public.pricelists(
        id,company_id,code,name,scope,priority,is_default,
        applies_all_stores,is_active,created_by,updated_by
    ) VALUES (
        v_foreign_pricelist,'00000000-0000-0000-0000-000000014002',
        'G14-FOREIGN','G14 Foreign','CUSTOMER',0,FALSE,TRUE,TRUE,
        v_actor,v_actor
    );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000014001','G2_PHASE13_REUSE_TEST'
    );

    SELECT id INTO v_category FROM public.customer_categories
    WHERE company_id='00000000-0000-0000-0000-000000014001'
      AND is_system_category;
    SELECT id INTO v_walk_in FROM public.customers
    WHERE company_id='00000000-0000-0000-0000-000000014001'
      AND is_system_customer;

    v_result := public.save_reusable_pricelist_with_rules(
        NULL,NULL,'G14-SHARED','G14 Shared','CUSTOMER',10,FALSE,
        TRUE,ARRAY[]::UUID[],NULL,NULL,TRUE,NULL,'[]'::JSONB
    );
    v_pricelist := (v_result->>'pricelistId')::UUID;

    v_result := public.save_customer_with_pricelist(
        NULL,NULL,NULL,'G14 Customer A',v_category,NULL,NULL,NULL,
        'BUSINESS',0,NULL,NULL,TRUE,NULL,v_pricelist
    );
    v_customer_a := (v_result->>'customerId')::UUID;
    v_result := public.save_customer_with_pricelist(
        NULL,NULL,NULL,'G14 Customer B',v_category,NULL,NULL,NULL,
        'BUSINESS',0,NULL,NULL,TRUE,NULL,v_pricelist
    );
    v_customer_b := (v_result->>'customerId')::UUID;

    SELECT count(*) INTO v_count FROM public.customers
    WHERE id IN (v_customer_a,v_customer_b)
      AND default_pricelist_id=v_pricelist;
    IF v_count<>2 THEN
        RAISE EXCEPTION 'TEST_FAILED: shared Pricelist assignment count %',v_count;
    END IF;

    v_rejected := FALSE;
    BEGIN
        UPDATE public.customers SET default_pricelist_id=v_pricelist
        WHERE id=v_walk_in;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='SYSTEM_CUSTOMER_CANNOT_HAVE_PRICELIST' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: Walk-In accepted Customer Pricelist';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_customer_with_pricelist(
            NULL,NULL,NULL,'G14 Cross Customer',v_category,NULL,NULL,NULL,
            'BUSINESS',0,NULL,NULL,TRUE,NULL,v_foreign_pricelist
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='ACTIVE_CUSTOMER_PRICELIST_NOT_FOUND' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company Pricelist accepted';
    END IF;
    IF EXISTS (SELECT 1 FROM public.customers WHERE name='G14 Cross Customer') THEN
        RAISE EXCEPTION 'TEST_FAILED: rejected Customer partially persisted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        UPDATE public.pricelists SET is_active=FALSE WHERE id=v_pricelist;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='PRICELIST_ASSIGNED_TO_CUSTOMER' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: assigned Pricelist deactivated';
    END IF;

    IF has_function_privilege(
        'authenticated',
        'public.save_pricelist_with_rules(uuid,bigint,text,text,text,uuid,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)',
        'EXECUTE'
    ) OR has_function_privilege(
        'authenticated',
        'public.save_reusable_pricelist_with_rules(uuid,bigint,text,text,text,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.save_reusable_pricelist_with_rules(uuid,bigint,text,text,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Pricelist RPC boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: one reusable Customer Pricelist can be assigned to multiple Customers with tenant and lifecycle guards.';
END
$test$;

ROLLBACK;
