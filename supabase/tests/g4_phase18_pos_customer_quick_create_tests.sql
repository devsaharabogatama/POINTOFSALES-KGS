-- G4 phase 18 behavior: POS Customer quick-create is active-Company scoped.
-- SAFETY: the Customer, audit, and sequence increment are rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID;
    v_session UUID;
    v_customer UUID;
    v_result JSONB;
    v_count BIGINT;
    v_rejected BOOLEAN := FALSE;
BEGIN
    SELECT cs.cashier_id,cs.company_id,cs.id
    INTO v_actor,v_company,v_session
    FROM public.cashier_sessions cs
    JOIN auth.users au ON au.id = cs.cashier_id
    WHERE cs.status = 'OPEN'::public.session_status
    ORDER BY cs.opened_at DESC
    LIMIT 1;
    IF v_session IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: one linked open Cashier Session required';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,
        TRUE
    );
    PERFORM public.set_active_company_context(
        v_company,'G4_PHASE18_TEST'
    );

    v_result := public.quick_create_pos_customer(
        'G4 Phase 18 Customer',
        '081234567890',
        'phase18@example.invalid',
        'Rollback-safe test address',
        'BUSINESS'
    );
    v_customer := (v_result->>'customerId')::UUID;

    IF (v_result->>'companyId')::UUID <> v_company
       OR v_result->>'customerCode' !~ '^CUST-[0-9]{6}$' THEN
        RAISE EXCEPTION
            'TEST_FAILED: quick-create response identity invalid';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.customers c
    JOIN public.customer_categories cc
      ON cc.company_id = c.company_id
     AND cc.id = c.customer_category_id
    WHERE c.id = v_customer
      AND c.company_id = v_company
      AND c.name = 'G4 Phase 18 Customer'
      AND c.customer_type = 'BUSINESS'
      AND c.current_balance = 0
      AND c.credit_limit = 0
      AND c.credit_term_days IS NULL
      AND c.parent_customer_id IS NULL
      AND c.default_pricelist_id IS NULL
      AND c.is_active
      AND NOT c.is_system_customer
      AND cc.is_active;
    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: Customer escaped safe quick-create contract';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.customer_master_audit a
    WHERE a.company_id = v_company
      AND a.customer_id = v_customer
      AND a.actor_id = v_actor
      AND a.action = 'CREATE';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Customer create audit missing';
    END IF;

    BEGIN
        PERFORM public.quick_create_pos_customer(
            ' G4   Phase 18 Customer ',
            NULL,NULL,NULL,'INDIVIDUAL'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'DUPLICATE_CUSTOMER' THEN
            v_rejected := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: duplicate normalized Customer name accepted';
    END IF;

    IF has_table_privilege(
        'authenticated','public.customers','INSERT,UPDATE,DELETE'
    ) OR has_function_privilege(
        'anon',
        'public.quick_create_pos_customer(text,text,text,text,text)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.quick_create_pos_customer(text,text,text,text,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: Customer quick-create privilege boundary invalid';
    END IF;

    RAISE NOTICE
        'TEST PASSED: POS Customer quick-create is Company-scoped, safe, unique, and audited.';
END
$test$;

ROLLBACK;
