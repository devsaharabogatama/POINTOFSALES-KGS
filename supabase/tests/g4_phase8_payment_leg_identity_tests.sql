-- G4 phase 8 behavior: payment-leg key normalization and duplicate guards.
-- SAFETY: every fixture and mutation is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_customer UUID;
    v_method_a UUID;
    v_method_b UUID;
    v_payload JSONB;
    v_count BIGINT;
    v_rejected BOOLEAN;
    v_key UUID := '00000000-0000-0000-0000-000000058091';
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::public.user_role
    ORDER BY p.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES (
        '00000000-0000-0000-0000-000000058001',
        'G58A','G58 Company A','g58-company-a','ACTIVE'
    );
    -- Company provisioning intentionally creates only the mandatory Cash
    -- method. Add a rollback-only second type so this focused split fixture
    -- does not depend on user master data.
    INSERT INTO public.payment_methods(
        id,company_id,payment_method_code,payment_method_name,method_type,
        settlement_route,is_default,available_all_stores,proof_mode,
        fee_enabled,is_active
    ) VALUES (
        '00000000-0000-0000-0000-000000058071',
        '00000000-0000-0000-0000-000000058001',
        'ALT','G58 Alternate','CUSTOM','CASH_DRAWER',
        FALSE,TRUE,'OPTIONAL',FALSE,TRUE
    );
    INSERT INTO public.stores(
        id,company_id,store_code,store_name,status
    ) VALUES (
        '00000000-0000-0000-0000-000000058011',
        '00000000-0000-0000-0000-000000058001',
        'S1','G58 Store','ACTIVE'
    );
    INSERT INTO public.pos_terminals(
        id,company_id,store_id,pos_code,pos_name,status
    ) VALUES (
        '00000000-0000-0000-0000-000000058021',
        '00000000-0000-0000-0000-000000058001',
        '00000000-0000-0000-0000-000000058011',
        'POS1','G58 POS 1','ACTIVE'
    );
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,store_id,
        is_sale_source,is_purchase_destination,is_active
    ) VALUES (
        '00000000-0000-0000-0000-000000058031',
        '00000000-0000-0000-0000-000000058001',
        'SWA','G58 Warehouse','STORE',
        '00000000-0000-0000-0000-000000058011',
        TRUE,FALSE,TRUE
    );
    SELECT id INTO v_customer
    FROM public.customers
    WHERE company_id = '00000000-0000-0000-0000-000000058001'
      AND is_system_customer
      AND upper(btrim(code)) = 'WALK-IN';
    SELECT id INTO v_method_a
    FROM public.payment_methods
    WHERE company_id = '00000000-0000-0000-0000-000000058001'
      AND is_active
      AND method_type = 'CASH'
    ORDER BY id LIMIT 1;
    v_method_b := '00000000-0000-0000-0000-000000058071';
    IF v_customer IS NULL OR v_method_a IS NULL
       OR v_method_b IS NULL OR v_method_a = v_method_b THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: Walk-In and two methods required';
    END IF;

    INSERT INTO public.cashier_sessions(
        id,session_code,cashier_id,opening_balance,expected_cash,
        actual_cash,difference,status,company_id,store_id,pos_id,
        sales_warehouse_id,opening_cash_actual
    ) VALUES (
        '00000000-0000-0000-0000-000000058041',
        'G58-SESSION',v_actor,0,0,0,0,'OPEN',
        '00000000-0000-0000-0000-000000058001',
        '00000000-0000-0000-0000-000000058011',
        '00000000-0000-0000-0000-000000058021',
        '00000000-0000-0000-0000-000000058031',0
    );

    v_payload := jsonb_build_object(
        'payments',jsonb_build_array(
            jsonb_build_object(
                'clientPaymentKey',v_key,
                'paymentMethodId',v_method_a,
                'amount',40,'tenderedAmount',40
            ),
            jsonb_build_object(
                'paymentMethodId',v_method_b,
                'amount',60,'tenderedAmount',60
            )
        )
    );
    INSERT INTO public.sales_headers(
        id,invoice_no,session_id,customer_id,created_by,payload_snapshot,
        company_id,store_id,pos_id,sales_warehouse_id
    ) VALUES (
        '00000000-0000-0000-0000-000000058051',
        'G58-DRAFT',
        '00000000-0000-0000-0000-000000058041',
        v_customer,v_actor,v_payload,
        '00000000-0000-0000-0000-000000058001',
        '00000000-0000-0000-0000-000000058011',
        '00000000-0000-0000-0000-000000058021',
        '00000000-0000-0000-0000-000000058031'
    );

    SELECT count(DISTINCT payment->>'clientPaymentKey')
    INTO v_count
    FROM public.sales_headers sh
    CROSS JOIN LATERAL jsonb_array_elements(
        sh.payload_snapshot->'payments'
    ) payment
    WHERE sh.id = '00000000-0000-0000-0000-000000058051';
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: payment keys not normalized';
    END IF;

    v_rejected := FALSE;
    BEGIN
        UPDATE public.sales_headers
        SET payload_snapshot = jsonb_build_object(
            'payments',jsonb_build_array(
                jsonb_build_object(
                    'clientPaymentKey',gen_random_uuid(),
                    'paymentMethodId',v_method_a,'amount',40
                ),
                jsonb_build_object(
                    'clientPaymentKey',gen_random_uuid(),
                    'paymentMethodId',v_method_a,'amount',60
                )
            )
        )
        WHERE id = '00000000-0000-0000-0000-000000058051';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'DUPLICATE_PAYMENT_METHOD' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: duplicate payment method accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        UPDATE public.sales_headers
        SET payload_snapshot = jsonb_build_object(
            'payments',jsonb_build_array(
                jsonb_build_object(
                    'clientPaymentKey',v_key,
                    'paymentMethodId',v_method_a,'amount',40
                ),
                jsonb_build_object(
                    'clientPaymentKey',v_key,
                    'paymentMethodId',v_method_b,'amount',60
                )
            )
        )
        WHERE id = '00000000-0000-0000-0000-000000058051';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'DUPLICATE_PAYMENT_LEG_KEY' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: duplicate payment key accepted';
    END IF;

    INSERT INTO public.sales_payments(
        payment_no,sales_id,session_id,payment_method,amount,company_id,
        client_payment_key
    ) VALUES (
        'G58-PAY-1','00000000-0000-0000-0000-000000058051',
        '00000000-0000-0000-0000-000000058041',
        'Cash'::public.payment_method,40,
        '00000000-0000-0000-0000-000000058001',v_key
    );
    v_rejected := FALSE;
    BEGIN
        INSERT INTO public.sales_payments(
            payment_no,sales_id,session_id,payment_method,amount,company_id,
            client_payment_key
        ) VALUES (
            'G58-PAY-2','00000000-0000-0000-0000-000000058051',
            '00000000-0000-0000-0000-000000058041',
            'Transfer'::public.payment_method,60,
            '00000000-0000-0000-0000-000000058001',v_key
        );
    EXCEPTION WHEN unique_violation THEN
        v_rejected := TRUE;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: duplicate persisted payment key accepted';
    END IF;

    IF has_table_privilege(
        'authenticated','public.sales_payments','INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: authenticated can write Sale Payment rows directly';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.oid =
            'public.post_pos_sale(uuid,bigint,uuid)'::regprocedure
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: canonical public Sale Post wrapper missing';
    END IF;

    -- Phase 52/56 moved Payment-Leg mapping behind the public wrapper. Check
    -- the current private execution-chain member instead of expecting the
    -- implementation to remain embedded in public.post_pos_sale forever.
    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.oid =
            'private.post_pos_sale_phase52_public_core(uuid,bigint,uuid)'::regprocedure
          AND p.prosrc LIKE '%clientPaymentKey%'
          AND p.prosrc LIKE '%PAYMENT_LEG_IDENTITY_MAPPING_FAILED%'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: canonical private Payment-Leg mapping runtime missing';
    END IF;

    IF has_function_privilege(
        'authenticated',
        'private.post_pos_sale_phase52_public_core(uuid,bigint,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: authenticated can execute private Sale Post core';
    END IF;

    IF NOT has_function_privilege(
        'authenticated','public.post_pos_sale(uuid,bigint,uuid)','EXECUTE'
    ) OR has_function_privilege(
        'anon','public.post_pos_sale(uuid,bigint,uuid)','EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: public Sale Post wrapper privilege boundary invalid';
    END IF;

    RAISE NOTICE
        'TEST PASSED: payment-leg keys normalize, duplicate key/method is rejected, persisted identity is unique, and browser writes remain closed.';
END
$test$;

ROLLBACK;
