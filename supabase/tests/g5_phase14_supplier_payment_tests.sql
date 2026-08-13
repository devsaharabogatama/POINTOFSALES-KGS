-- G5 Phase 14 Behavioral Test: Supplier Payment / AP Settlement.
-- SAFETY: All fixtures, payments, and event effects are strictly ROLLED BACK at the end of execution.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID := '00000000-0000-0000-0000-000000095001';
    v_supplier UUID := '00000000-0000-0000-0000-000000095011';
    v_uom UUID := '00000000-0000-0000-0000-000000095021';
    v_category UUID := '00000000-0000-0000-0000-000000095031';
    v_product UUID := '00000000-0000-0000-0000-000000095041';
    v_invoice UUID := '00000000-0000-0000-0000-000000095051';
    v_invoice_line UUID := '00000000-0000-0000-0000-000000095052';
    v_tx_category UUID := '00000000-0000-0000-0000-000000095061';
    v_event UUID := '00000000-0000-0000-0000-000000095071';
    v_draft_result JSONB;
    v_invoice_draft_result JSONB;
    v_invoice_validate_result JSONB;
    v_payment_id UUID;
    v_validate_result JSONB;
    v_cancel_draft_result JSONB;
    v_cancel_payment_id UUID;
    v_cancel_result JSONB;
    v_idempotency UUID := gen_random_uuid();
    v_alloc_key UUID := gen_random_uuid();
    v_alloc_key2 UUID := gen_random_uuid();
    v_rejected BOOLEAN := FALSE;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id = profile.id
    WHERE profile.role = 'super_admin'::public.user_role
    ORDER BY profile.id LIMIT 1;

    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Super Admin profile required';
    END IF;

    -- Setup minimal test fixtures
    INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
    VALUES (v_company,'C950','Company 950','company-950','ACTIVE');

    INSERT INTO public.company_memberships(company_id,user_id,role_code,status)
    VALUES (v_company,v_actor,'COMPANY_OWNER','ACTIVE');

    INSERT INTO public.suppliers(id,company_id,supplier_code,supplier_name,created_by,updated_by)
    VALUES (v_supplier,v_company,'SUP950','Supplier 950',v_actor,v_actor);

    INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,decimal_precision)
    VALUES (v_uom,v_company,'PCS950','Pcs','UNIT',FALSE,0);

    INSERT INTO public.product_categories(id,company_id,category_code,category_name)
    VALUES (v_category,v_company,'CAT950','Cat 950');

    INSERT INTO public.products(id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle)
    VALUES (v_product,v_company,'PROD950','Product 950','Cat 950',v_category,100,45,'Pcs',v_uom,v_uom,1,TRUE,FALSE);

    INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,purchase_allowed,sales_allowed,purchase_price,sale_price,is_active)
    VALUES (v_company,v_product,v_uom,1,TRUE,TRUE,45,100,TRUE);

    SELECT category.id INTO v_tx_category
    FROM public.transaction_categories category
    WHERE category.company_id = v_company
      AND category.system_key = 'SUPPLIER_PAYMENT'
    LIMIT 1;

    IF v_tx_category IS NULL THEN
        INSERT INTO public.transaction_categories(
            company_id,category_code,category_name,system_key,is_active
        ) VALUES (
            v_company,'TC-SPAY950','Pembayaran Supplier','SUPPLIER_PAYMENT',TRUE
        ) RETURNING id INTO v_tx_category;
    END IF;

    -- Setup 1 VALIDATED Supplier Invoice via canonical RPCs (Grand Total: 100,000)
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT, TRUE);
    PERFORM set_config('request.jwt.claim.sub',v_actor::TEXT,TRUE);
    PERFORM public.set_active_company_context(v_company,'G5_PHASE14_TEST');

    v_invoice_draft_result := public.save_supplier_invoice_draft(
        NULL,NULL,v_supplier,'INV-SUPP-950',CURRENT_DATE,CURRENT_DATE + 30,
        'EXCLUSIVE','Test Invoice Fixture',NULL,
        jsonb_build_array(
            jsonb_build_object(
                'clientLineKey',gen_random_uuid(),
                'productId',v_product,
                'invoiceUomId',v_uom,
                'invoiceQty',10,
                'unitPrice',10000
            )
        )
    );
    v_invoice := (v_invoice_draft_result->>'documentId')::UUID;

    INSERT INTO public.financial_events(
        id,event_code,event_type,source_table,source_id,root_sales_id,event_date,
        event_version,idempotency_key,amounts,status,error_message,created_by,
        company_id,store_id,system_event_key,transaction_category_id
    ) VALUES (
        v_event,'SINV-950-EVT','SUPPLIER_INVOICE_VALIDATED'::public.event_type,
        'supplier_invoice_documents',v_invoice,NULL,clock_timestamp(),1,
        'TEST-SINV-950-KEY',jsonb_build_object('test',true),'HOLD'::public.event_status,
        'CANONICAL_FINANCE_POSTING_NOT_ENABLED',v_actor,v_company,NULL,
        'SUPPLIER_INVOICE',v_tx_category
    );

    UPDATE public.supplier_invoice_documents
    SET status = 'VALIDATED',
        matching_status = 'MATCHED',
        validated_by = v_actor,
        validated_at = clock_timestamp(),
        validation_idempotency_key = gen_random_uuid(),
        financial_event_id = v_event
    WHERE company_id = v_company AND id = v_invoice;

    -- TEST 1: Save Supplier Payment Draft (Partial settlement Rp 80,000 of Rp 100,000)
    PERFORM set_config('request.jwt.claim.sub',v_actor::TEXT,TRUE);
    v_draft_result := public.save_supplier_payment_draft(
        NULL,NULL,v_supplier,CURRENT_DATE,'BANK_TRANSFER',NULL,
        'BCA','1234567890','PT Supplier 950','REF-950','Pembayaran Parsial Faktur 950',
        'https://evidence.example.com/spay950.pdf',
        jsonb_build_array(
            jsonb_build_object(
                'clientAllocationKey',v_alloc_key,
                'invoiceId',v_invoice,
                'allocatedAmount',80000
            )
        )
    );

    IF v_draft_result->>'status' <> 'DRAFT' OR (v_draft_result->>'totalAmount')::NUMERIC <> 80000 THEN
        RAISE EXCEPTION 'TEST_FAILED: save_supplier_payment_draft returned unexpected draft state';
    END IF;

    v_payment_id := (v_draft_result->>'documentId')::UUID;

    -- TEST 2: Validate Supplier Payment
    v_validate_result := public.validate_supplier_payment(
        v_payment_id,
        (v_draft_result->>'masterVersion')::BIGINT,
        v_idempotency
    );

    IF v_validate_result->>'status' <> 'VALIDATED' THEN
        RAISE EXCEPTION 'TEST_FAILED: validate_supplier_payment did not validate document';
    END IF;

    -- TEST 3: Idempotent Replay on Validate
    v_validate_result := public.validate_supplier_payment(
        v_payment_id,
        (v_validate_result->>'masterVersion')::BIGINT,
        v_idempotency
    );

    IF (v_validate_result->>'idempotentReplay')::BOOLEAN <> TRUE THEN
        RAISE EXCEPTION 'TEST_FAILED: validate_supplier_payment replay failed';
    END IF;

    -- TEST 4: Attempting to edit a VALIDATED payment must raise FINAL_SUPPLIER_PAYMENT_IMMUTABLE
    BEGIN
        v_rejected := FALSE;
        PERFORM public.save_supplier_payment_draft(
            v_payment_id,
            (v_validate_result->>'masterVersion')::BIGINT,
            v_supplier,CURRENT_DATE,'CASH',NULL,
            '','','','','Edit Test',NULL,
            jsonb_build_array(
                jsonb_build_object(
                    'clientAllocationKey',v_alloc_key,
                    'invoiceId',v_invoice,
                    'allocatedAmount',50000
                )
            )
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%FINAL_SUPPLIER_PAYMENT_IMMUTABLE%' THEN
            v_rejected := TRUE;
        END IF;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: modification of VALIDATED payment was not rejected';
    END IF;

    -- TEST 5: Cancel a draft payment
    v_cancel_draft_result := public.save_supplier_payment_draft(
        NULL,NULL,v_supplier,CURRENT_DATE,'CASH',NULL,
        '','','','','Draft to Cancel',NULL,
        jsonb_build_array(
            jsonb_build_object(
                'clientAllocationKey',v_alloc_key2,
                'invoiceId',v_invoice,
                'allocatedAmount',10000
            )
        )
    );

    v_cancel_payment_id := (v_cancel_draft_result->>'documentId')::UUID;

    v_cancel_result := public.cancel_supplier_payment(
        v_cancel_payment_id,
        (v_cancel_draft_result->>'masterVersion')::BIGINT,
        'Salah nominal pelunasan'
    );

    IF v_cancel_result->>'status' <> 'CANCELED' THEN
        RAISE EXCEPTION 'TEST_FAILED: cancel_supplier_payment failed';
    END IF;

    RAISE NOTICE 'G5 Phase 14 Supplier Payment Behavioral Tests PASS';
END
$test$;

ROLLBACK;
