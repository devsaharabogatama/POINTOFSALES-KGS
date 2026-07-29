-- G3 phase 8 behavior: final-quantity Adjustment is atomic and FIFO-safe.
-- SAFETY: every fixture, posting, Movement, event, and audit is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_reason_a UUID;
    v_reason_b UUID;
    v_result JSONB;
    v_loss_document UUID;
    v_gain_document UUID;
    v_count BIGINT;
    v_qty NUMERIC;
    v_value NUMERIC;
    v_rejected BOOLEAN;
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::user_role
    ORDER BY p.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
        ('00000000-0000-0000-0000-000000048001',
         'G48A','G48 Company A','g48-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000048002',
         'G48B','G48 Company B','g48-company-b','ACTIVE');

    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES (
        '00000000-0000-0000-0000-000000048011',
        '00000000-0000-0000-0000-000000048001','TEST','Test'
    );
    INSERT INTO public.uoms(id,company_id,code,name) VALUES (
        '00000000-0000-0000-0000-000000048021',
        '00000000-0000-0000-0000-000000048001','PCS','Piece'
    );
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type
    ) VALUES (
        '00000000-0000-0000-0000-000000048031',
        '00000000-0000-0000-0000-000000048001',
        'WHA','G48 Warehouse','CENTRAL'
    );
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES (
        '00000000-0000-0000-0000-000000048041',
        '00000000-0000-0000-0000-000000048001',
        'G48-P','G48 Product','Test',
        '00000000-0000-0000-0000-000000048011',100,50,'PCS',
        '00000000-0000-0000-0000-000000048021',
        '00000000-0000-0000-0000-000000048021',1,TRUE,FALSE
    );
    INSERT INTO public.product_uoms(
        company_id,product_id,uom_id,factor_to_base,
        purchase_allowed,sales_allowed,purchase_price,sale_price
    ) VALUES (
        '00000000-0000-0000-0000-000000048001',
        '00000000-0000-0000-0000-000000048041',
        '00000000-0000-0000-0000-000000048021',
        1,TRUE,TRUE,50,100
    );
    INSERT INTO public.product_stocks(
        product_id,warehouse_id,stock_qty,company_id
    ) VALUES (
        '00000000-0000-0000-0000-000000048041',
        '00000000-0000-0000-0000-000000048031',10,
        '00000000-0000-0000-0000-000000048001'
    );
    INSERT INTO public.product_batches(
        product_id,warehouse_id,qty_purchased,qty_remaining,cogs_unit,
        company_id
    ) VALUES (
        '00000000-0000-0000-0000-000000048041',
        '00000000-0000-0000-0000-000000048031',10,10,50,
        '00000000-0000-0000-0000-000000048001'
    );
    INSERT INTO public.stock_movements(
        product_id,warehouse_id,qty_change,movement_type,
        reference_table,reference_id,company_id,
        base_uom_id,base_uom_name_snapshot,balance_after_base_qty,
        actor_id,posted_at,movement_status
    ) VALUES (
        '00000000-0000-0000-0000-000000048041',
        '00000000-0000-0000-0000-000000048031',10,
        'PURCHASE'::public.stock_movement_type,'G3_PHASE8_TEST',
        '00000000-0000-0000-0000-000000048061',
        '00000000-0000-0000-0000-000000048001',
        '00000000-0000-0000-0000-000000048021','Piece',10,
        v_actor,clock_timestamp(),'POSTED'
    );

    SELECT id INTO v_reason_a
    FROM public.stock_adjustment_reasons
    WHERE company_id = '00000000-0000-0000-0000-000000048001'
      AND reason_name = 'Selisih Stok';
    SELECT id INTO v_reason_b
    FROM public.stock_adjustment_reasons
    WHERE company_id = '00000000-0000-0000-0000-000000048002'
      AND reason_name = 'Selisih Stok';
    IF v_reason_a IS NULL OR v_reason_b IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: default reason provisioning missing';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000048001','G3_PHASE8_TEST'
    );

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_stock_adjustment_document(
            NULL,NULL,'00000000-0000-0000-0000-000000048031',
            CURRENT_DATE,NULL,
            jsonb_build_array(jsonb_build_object(
                'productId','00000000-0000-0000-0000-000000048041',
                'reasonId',v_reason_b,'finalPhysicalQuantity',7
            ))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_STOCK_ADJUSTMENT_REASON_NOT_FOUND' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company reason accepted';
    END IF;

    v_result := public.save_stock_adjustment_document(
        NULL,NULL,'00000000-0000-0000-0000-000000048031',
        CURRENT_DATE,'Loss test',
        jsonb_build_array(jsonb_build_object(
            'productId','00000000-0000-0000-0000-000000048041',
            'reasonId',v_reason_a,'finalPhysicalQuantity',7
        ))
    );
    v_loss_document := (v_result->>'documentId')::UUID;
    IF (v_result->>'totalLossQuantityBase')::NUMERIC <> 3 THEN
        RAISE EXCEPTION 'TEST_FAILED: loss difference not derived';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_stock_adjustment_document(
            v_loss_document,2,
            '00000000-0000-0000-0000-000000048031',
            CURRENT_DATE,NULL,
            jsonb_build_array(jsonb_build_object(
                'productId','00000000-0000-0000-0000-000000048041',
                'reasonId',v_reason_a,'finalPhysicalQuantity',7
            ))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'MASTER_VERSION_CONFLICT' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale Adjustment update accepted';
    END IF;

    v_result := public.post_stock_adjustment(
        v_loss_document,1,
        '00000000-0000-0000-0000-000000048071'
    );
    IF v_result->>'status' <> 'POSTED'
       OR (v_result->>'totalLossValue')::NUMERIC <> 150 THEN
        RAISE EXCEPTION 'TEST_FAILED: loss posting result invalid';
    END IF;
    SELECT stock_qty INTO v_qty FROM public.product_stocks
    WHERE company_id = '00000000-0000-0000-0000-000000048001'
      AND product_id = '00000000-0000-0000-0000-000000048041'
      AND warehouse_id = '00000000-0000-0000-0000-000000048031';
    IF v_qty <> 7 THEN RAISE EXCEPTION 'TEST_FAILED: loss balance %',v_qty; END IF;

    v_result := public.post_stock_adjustment(
        v_loss_document,1,
        '00000000-0000-0000-0000-000000048071'
    );
    IF NOT (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: post replay not idempotent';
    END IF;

    v_result := public.save_stock_adjustment_document(
        NULL,NULL,'00000000-0000-0000-0000-000000048031',
        CURRENT_DATE,'Gain test',
        jsonb_build_array(jsonb_build_object(
            'productId','00000000-0000-0000-0000-000000048041',
            'reasonId',v_reason_a,'finalPhysicalQuantity',9,
            'unitCostBase',60,'costOverrideReason','Latest vendor quote'
        ))
    );
    v_gain_document := (v_result->>'documentId')::UUID;
    v_result := public.post_stock_adjustment(
        v_gain_document,1,
        '00000000-0000-0000-0000-000000048072'
    );
    IF (v_result->>'totalGainValue')::NUMERIC <> 120 THEN
        RAISE EXCEPTION 'TEST_FAILED: gain value invalid';
    END IF;
    SELECT stock_qty INTO v_qty FROM public.product_stocks
    WHERE company_id = '00000000-0000-0000-0000-000000048001'
      AND product_id = '00000000-0000-0000-0000-000000048041'
      AND warehouse_id = '00000000-0000-0000-0000-000000048031';
    IF v_qty <> 9 THEN RAISE EXCEPTION 'TEST_FAILED: gain balance %',v_qty; END IF;

    SELECT sum(qty_remaining) INTO v_qty FROM public.product_batches
    WHERE company_id = '00000000-0000-0000-0000-000000048001'
      AND product_id = '00000000-0000-0000-0000-000000048041'
      AND warehouse_id = '00000000-0000-0000-0000-000000048031';
    IF v_qty <> 9 THEN RAISE EXCEPTION 'TEST_FAILED: FIFO balance %',v_qty; END IF;
    SELECT sum(total_value) INTO v_value
    FROM public.stock_adjustment_fifo_allocations
    WHERE document_id IN (v_loss_document,v_gain_document);
    IF v_value <> 270 THEN
        RAISE EXCEPTION 'TEST_FAILED: FIFO allocation value %',v_value;
    END IF;
    SELECT count(*) INTO v_count FROM public.financial_events
    WHERE company_id = '00000000-0000-0000-0000-000000048001'
      AND source_table = 'stock_adjustment_documents'
      AND status = 'HOLD'::public.event_status;
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: expected two HOLD events, got %',v_count;
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_movements
    WHERE company_id = '00000000-0000-0000-0000-000000048001'
      AND movement_type = 'ADJUSTMENT'::public.stock_movement_type;
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: expected two Adjustment movements';
    END IF;

    IF has_table_privilege(
        'authenticated','public.stock_adjustment_documents',
        'INSERT,UPDATE,DELETE'
    ) OR has_function_privilege(
        'anon','public.post_stock_adjustment(uuid,bigint,uuid)','EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.save_stock_adjustment_document(uuid,bigint,uuid,date,text,jsonb)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Adjustment privilege boundary invalid';
    END IF;

    RAISE NOTICE
        'TEST PASSED: Adjustment derives final-stock delta, consumes/adds FIFO, posts immutable Movement and HOLD Finance events atomically.';
END
$test$;

ROLLBACK;
