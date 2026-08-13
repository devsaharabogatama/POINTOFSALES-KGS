-- G2 phase 36 behavioral test: automatic hidden technical codes.
-- SAFETY: every fixture, counter allocation, and audit row is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_category_id UUID;
    v_uom_id UUID;
    v_reserved_uom_code TEXT;
    v_warehouse_id UUID;
    v_supplier_id UUID;
    v_supplier_2_id UUID;
    v_customer_category_id UUID;
    v_pricelist_id UUID;
    v_payment_method_id UUID;
    v_payment_sequence_before BIGINT;
    v_transaction_category_id UUID;
    v_result JSONB;
    v_code TEXT;
    v_system_key TEXT;
    v_rejected BOOLEAN;
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id=p.id
    WHERE p.role='super_admin'::user_role
    ORDER BY p.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    SELECT system_key INTO v_system_key
    FROM public.system_events
    WHERE is_active
    ORDER BY system_key LIMIT 1;
    IF v_system_key IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: active System Event required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
        ('00000000-0000-0000-0000-000000014001',
         'G14A','G14 Company A','g14-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000014002',
         'G14B','G14 Company B','g14-company-b','ACTIVE');

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000014001','G2_PHASE36_TEST'
    );

    INSERT INTO public.product_categories(
        company_id,category_code,category_name,created_by,updated_by
    ) VALUES (
        '00000000-0000-0000-0000-000000014001',
        NULL,'G14 Category',v_actor,v_actor
    ) RETURNING id,category_code INTO v_category_id,v_code;
    IF v_code<>'CAT-000001' THEN
        RAISE EXCEPTION 'TEST_FAILED: Category code %',v_code;
    END IF;

    INSERT INTO public.uoms(
        company_id,code,name,created_by,updated_by
    ) VALUES (
        '00000000-0000-0000-0000-000000014001',
        NULL,'G14 Unit',v_actor,v_actor
    ) RETURNING id,code INTO v_uom_id,v_code;
    IF v_code<>'UOM-000001' THEN
        RAISE EXCEPTION 'TEST_FAILED: UOM code %',v_code;
    END IF;

    INSERT INTO public.uoms(
        company_id,code,name,created_by,updated_by
    ) VALUES (
        '00000000-0000-0000-0000-000000014001',
        'UOM-000010','G14 Reserved Unit',v_actor,v_actor
    );
    INSERT INTO public.uoms(
        company_id,code,name,created_by,updated_by
    ) VALUES (
        '00000000-0000-0000-0000-000000014001',
        NULL,'G14 Unit After Reserve',v_actor,v_actor
    ) RETURNING code INTO v_reserved_uom_code;
    IF v_reserved_uom_code<>'UOM-000011' THEN
        RAISE EXCEPTION
            'TEST_FAILED: explicit compatibility code was not reserved, got %',
            v_reserved_uom_code;
    END IF;

    INSERT INTO public.warehouses(
        company_id,code,name,warehouse_type,created_by,updated_by
    ) VALUES (
        '00000000-0000-0000-0000-000000014001',
        NULL,'G14 Warehouse','CENTRAL',v_actor,v_actor
    ) RETURNING id,code INTO v_warehouse_id,v_code;
    IF v_code<>'WH-000001' THEN
        RAISE EXCEPTION 'TEST_FAILED: Warehouse code %',v_code;
    END IF;

    v_result := public.save_supplier(
        NULL,NULL,'G14 Supplier',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,TRUE
    );
    v_supplier_id := (v_result->>'supplierId')::UUID;
    SELECT supplier_code INTO v_code FROM public.suppliers
    WHERE id=v_supplier_id;
    IF v_code<>'SUP-000001' THEN
        RAISE EXCEPTION 'TEST_FAILED: Supplier code %',v_code;
    END IF;

    v_result := public.save_customer_category(
        NULL,NULL,'G14 Customer Category',TRUE
    );
    v_customer_category_id := (v_result->>'customerCategoryId')::UUID;
    SELECT category_code INTO v_code FROM public.customer_categories
    WHERE id=v_customer_category_id;
    IF v_code<>'CC-000001' THEN
        RAISE EXCEPTION 'TEST_FAILED: Customer Category code %',v_code;
    END IF;

    v_result := public.save_reusable_pricelist_with_rules(
        NULL,NULL,'G14 Customer Price','CUSTOMER',10,FALSE,TRUE,
        ARRAY[]::UUID[],NULL,NULL,TRUE,NULL,'[]'::JSONB
    );
    v_pricelist_id := (v_result->>'pricelistId')::UUID;
    SELECT code INTO v_code FROM public.pricelists WHERE id=v_pricelist_id;
    IF v_code<>'PL-000001' THEN
        RAISE EXCEPTION 'TEST_FAILED: Pricelist code %',v_code;
    END IF;

    -- Later Customer Balance provisioning legitimately consumes the first
    -- PAYMENT_METHOD sequence for its system-owned tender. Assert the next
    -- tenant counter value instead of the obsolete hard-coded PAY-000001.
    SELECT COALESCE(last_value,0) INTO v_payment_sequence_before
    FROM private.master_code_counters
    WHERE company_id='00000000-0000-0000-0000-000000014001'
      AND entity_type='PAYMENT_METHOD';
    v_payment_sequence_before:=COALESCE(v_payment_sequence_before,0);

    v_result := public.save_payment_method(
        NULL,NULL,'G14 Petty Cash','CASH','CASH_DRAWER',FALSE,TRUE,
        ARRAY[]::UUID[],'OPTIONAL',FALSE,NULL,NULL,NULL,NULL,NULL,NULL,
        clock_timestamp(),NULL,TRUE
    );
    v_payment_method_id := (v_result->>'paymentMethodId')::UUID;
    SELECT payment_method_code INTO v_code FROM public.payment_methods
    WHERE id=v_payment_method_id;
    IF v_code<>(
        'PAY-'||lpad((v_payment_sequence_before+1)::TEXT,6,'0')
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Payment Method code %',v_code;
    END IF;

    v_result := public.save_transaction_category(
        NULL,NULL,'G14 Transaction Category',v_system_key,NULL,TRUE
    );
    v_transaction_category_id := (v_result->>'categoryId')::UUID;
    SELECT category_code INTO v_code FROM public.transaction_categories
    WHERE id=v_transaction_category_id;
    IF v_code<>'TC-000001' THEN
        RAISE EXCEPTION 'TEST_FAILED: Transaction Category code %',v_code;
    END IF;

    -- Failed create rolls its allocation back with the row.
    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_supplier(
            NULL,NULL,'G14 Supplier',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='DUPLICATE_SUPPLIER' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: duplicate Supplier accepted';
    END IF;

    v_result := public.save_supplier(
        NULL,NULL,'G14 Supplier Two',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,TRUE
    );
    v_supplier_2_id := (v_result->>'supplierId')::UUID;
    SELECT supplier_code INTO v_code FROM public.suppliers
    WHERE id=v_supplier_2_id;
    IF v_code<>'SUP-000002' THEN
        RAISE EXCEPTION
            'TEST_FAILED: failed allocation was not rolled back, got %',v_code;
    END IF;

    -- Wrapper update preserves the immutable code.
    v_result := public.save_supplier(
        v_supplier_id,1,'G14 Supplier Updated',NULL,NULL,NULL,NULL,NULL,
        NULL,NULL,NULL,TRUE
    );
    SELECT supplier_code INTO v_code FROM public.suppliers
    WHERE id=v_supplier_id;
    IF v_code<>'SUP-000001'
       OR (v_result->>'masterVersion')::BIGINT<>2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Supplier update changed identity';
    END IF;

    v_rejected := FALSE;
    BEGIN
        UPDATE public.product_categories
        SET category_code='USER-CODE'
        WHERE id=v_category_id;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='SYSTEM_CODE_IMMUTABLE' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: technical code mutation accepted';
    END IF;

    -- Counter is tenant-scoped; Company B starts at one.
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000014002','G2_PHASE36_TEST'
    );
    INSERT INTO public.product_categories(
        company_id,category_code,category_name,created_by,updated_by
    ) VALUES (
        '00000000-0000-0000-0000-000000014002',
        NULL,'G14 Category B',v_actor,v_actor
    ) RETURNING category_code INTO v_code;
    IF v_code<>'CAT-000001' THEN
        RAISE EXCEPTION 'TEST_FAILED: Company counter leaked, got %',v_code;
    END IF;

    -- The allocator remains private. ACP-5B intentionally quarantines the
    -- legacy Supplier RPC and exposes the permission-guarded Contacts wrapper
    -- to authenticated clients instead.
    IF has_function_privilege(
        'authenticated',
        'private.allocate_master_code(uuid,text)','EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: authenticated can execute private code allocator';
    END IF;

    IF has_function_privilege(
        'anon',
        'public.save_contacts_supplier(uuid,bigint,text,text,text,text,text,text,text,text,text,boolean)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: anon can execute guarded Supplier wrapper';
    END IF;

    IF has_function_privilege(
        'authenticated',
        'public.save_supplier(uuid,bigint,text,text,text,text,text,text,text,text,text,boolean)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: authenticated can execute legacy Supplier RPC';
    END IF;

    IF NOT has_function_privilege(
        'authenticated',
        'public.save_contacts_supplier(uuid,bigint,text,text,text,text,text,text,text,text,text,boolean)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: authenticated cannot execute guarded Supplier wrapper';
    END IF;

    RAISE NOTICE
        'TEST PASSED: codes auto-generate per Company, remain immutable, rollback with failed creates, and wrappers preserve compatibility.';
END
$test$;

ROLLBACK;
