-- G3 phase 6 behavioral test: canonical Stock Transfer.
-- SAFETY: every fixture, balance, batch, movement, and document is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_document_id UUID;
    v_cancel_id UUID;
    v_failed_id UUID;
    v_result JSONB;
    v_replay JSONB;
    v_count BIGINT;
    v_value NUMERIC;
    v_rejected BOOLEAN;
    v_key UUID := '00000000-0000-0000-0000-000000016091';
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::user_role
    ORDER BY p.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
        ('00000000-0000-0000-0000-000000016001',
         'G16A','G16 Company A','g16-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000016002',
         'G16B','G16 Company B','g16-company-b','ACTIVE');

    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES (
        '00000000-0000-0000-0000-000000016011',
        '00000000-0000-0000-0000-000000016001','G16','G16 Category'
    );
    INSERT INTO public.uoms(id,company_id,code,name) VALUES (
        '00000000-0000-0000-0000-000000016021',
        '00000000-0000-0000-0000-000000016001','PCS','Piece'
    );
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES (
        '00000000-0000-0000-0000-000000016031',
        '00000000-0000-0000-0000-000000016001','G16-P','G16 Product',
        'G16 Category','00000000-0000-0000-0000-000000016011',
        100,50,'PCS','00000000-0000-0000-0000-000000016021',
        '00000000-0000-0000-0000-000000016021',1,TRUE,FALSE
    );
    INSERT INTO public.product_uoms(
        company_id,product_id,uom_id,factor_to_base,purchase_allowed,
        sales_allowed,purchase_price,sale_price
    ) VALUES (
        '00000000-0000-0000-0000-000000016001',
        '00000000-0000-0000-0000-000000016031',
        '00000000-0000-0000-0000-000000016021',
        1,TRUE,TRUE,50,100
    );
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,is_active
    ) VALUES
        ('00000000-0000-0000-0000-000000016041',
         '00000000-0000-0000-0000-000000016001',
         'S16','G16 Source','CENTRAL',TRUE),
        ('00000000-0000-0000-0000-000000016042',
         '00000000-0000-0000-0000-000000016001',
         'D16','G16 Destination','CENTRAL',TRUE),
        ('00000000-0000-0000-0000-000000016043',
         '00000000-0000-0000-0000-000000016002',
         'F16','G16 Foreign','CENTRAL',TRUE);

    INSERT INTO public.product_stocks(
        product_id,warehouse_id,stock_qty,company_id
    ) VALUES (
        '00000000-0000-0000-0000-000000016031',
        '00000000-0000-0000-0000-000000016041',10,
        '00000000-0000-0000-0000-000000016001'
    );
    INSERT INTO public.product_batches(
        id,product_id,warehouse_id,qty_purchased,qty_remaining,cogs_unit,
        company_id
    ) VALUES
        ('00000000-0000-0000-0000-000000016051',
         '00000000-0000-0000-0000-000000016031',
         '00000000-0000-0000-0000-000000016041',6,6,5,
         '00000000-0000-0000-0000-000000016001'),
        ('00000000-0000-0000-0000-000000016052',
         '00000000-0000-0000-0000-000000016031',
         '00000000-0000-0000-0000-000000016041',4,4,7,
         '00000000-0000-0000-0000-000000016001');
    INSERT INTO public.stock_movements(
        product_id,warehouse_id,qty_change,movement_type,
        reference_table,reference_id,company_id,
        base_uom_id,base_uom_name_snapshot,balance_after_base_qty,
        actor_id,posted_at,movement_status,source_line_id,notes
    ) VALUES (
        '00000000-0000-0000-0000-000000016031',
        '00000000-0000-0000-0000-000000016041',10,
        'PURCHASE'::public.stock_movement_type,'G3_PHASE6_TEST',
        '00000000-0000-0000-0000-000000016061',
        '00000000-0000-0000-0000-000000016001',
        '00000000-0000-0000-0000-000000016021','Piece',10,
        v_actor,clock_timestamp(),'POSTED',
        '00000000-0000-0000-0000-000000016062','Fixture balance'
    );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000016001','G3_PHASE6_TEST'
    );

    v_result := public.save_stock_transfer_document(
        NULL,NULL,
        '00000000-0000-0000-0000-000000016041',
        '00000000-0000-0000-0000-000000016042',
        CURRENT_DATE,'Transfer test',
        jsonb_build_array(jsonb_build_object(
            'productId','00000000-0000-0000-0000-000000016031',
            'quantityBase',8,'notes','Move FIFO'
        ))
    );
    v_document_id := (v_result->>'documentId')::UUID;
    IF (v_result->>'masterVersion')::BIGINT <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: create version invalid';
    END IF;

    v_result := public.post_stock_transfer(v_document_id,1,v_key);
    IF v_result->>'status' <> 'POSTED'
       OR (v_result->>'masterVersion')::BIGINT <> 2
       OR (v_result->>'totalCost')::NUMERIC <> 44 THEN
        RAISE EXCEPTION 'TEST_FAILED: post result invalid %',v_result;
    END IF;

    SELECT stock_qty INTO v_value FROM public.product_stocks
    WHERE company_id = '00000000-0000-0000-0000-000000016001'
      AND product_id = '00000000-0000-0000-0000-000000016031'
      AND warehouse_id = '00000000-0000-0000-0000-000000016041';
    IF v_value <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: source balance %, expected 2',v_value;
    END IF;
    SELECT stock_qty INTO v_value FROM public.product_stocks
    WHERE company_id = '00000000-0000-0000-0000-000000016001'
      AND product_id = '00000000-0000-0000-0000-000000016031'
      AND warehouse_id = '00000000-0000-0000-0000-000000016042';
    IF v_value <> 8 THEN
        RAISE EXCEPTION 'TEST_FAILED: destination balance %, expected 8',v_value;
    END IF;

    SELECT sum(qty_remaining) INTO v_value FROM public.product_batches
    WHERE company_id = '00000000-0000-0000-0000-000000016001'
      AND product_id = '00000000-0000-0000-0000-000000016031'
      AND warehouse_id = '00000000-0000-0000-0000-000000016041';
    IF v_value <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: source FIFO %, expected 2',v_value;
    END IF;
    SELECT sum(qty_remaining * cogs_unit) INTO v_value
    FROM public.product_batches
    WHERE company_id = '00000000-0000-0000-0000-000000016001'
      AND product_id = '00000000-0000-0000-0000-000000016031'
      AND warehouse_id = '00000000-0000-0000-0000-000000016042';
    IF v_value <> 44 THEN
        RAISE EXCEPTION 'TEST_FAILED: destination FIFO value %, expected 44',
            v_value;
    END IF;

    SELECT count(*) INTO v_count FROM public.stock_transfer_fifo_allocations
    WHERE document_id = v_document_id;
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: FIFO allocations %, expected 2',v_count;
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_movements
    WHERE reference_table = 'stock_transfer_documents'
      AND reference_id = v_document_id
      AND source_line_id IS NOT NULL
      AND base_uom_name_snapshot = 'Piece';
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: paired canonical movement invalid';
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_transfer_audit
    WHERE document_id = v_document_id
      AND action IN ('CREATE','POST');
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: transfer audit missing';
    END IF;

    v_replay := public.post_stock_transfer(v_document_id,2,v_key);
    IF NOT (v_replay->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: idempotent replay not detected';
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_movements
    WHERE reference_table = 'stock_transfer_documents'
      AND reference_id = v_document_id;
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: replay duplicated movement';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_stock_transfer_document(
            NULL,NULL,
            '00000000-0000-0000-0000-000000016041',
            '00000000-0000-0000-0000-000000016042',
            CURRENT_DATE,NULL,
            jsonb_build_array(jsonb_build_object(
                'productId','00000000-0000-0000-0000-000000016031',
                'quantityBase',-1
            ))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'STOCK_TRANSFER_QUANTITY_MUST_BE_POSITIVE' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: negative transfer accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_stock_transfer_document(
            NULL,NULL,
            '00000000-0000-0000-0000-000000016041',
            '00000000-0000-0000-0000-000000016043',
            CURRENT_DATE,NULL,
            jsonb_build_array(jsonb_build_object(
                'productId','00000000-0000-0000-0000-000000016031',
                'quantityBase',1
            ))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_TRANSFER_WAREHOUSE_NOT_FOUND' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company warehouse accepted';
    END IF;

    v_result := public.save_stock_transfer_document(
        NULL,NULL,
        '00000000-0000-0000-0000-000000016041',
        '00000000-0000-0000-0000-000000016042',
        CURRENT_DATE,NULL,
        jsonb_build_array(jsonb_build_object(
            'productId','00000000-0000-0000-0000-000000016031',
            'quantityBase',3
        ))
    );
    v_failed_id := (v_result->>'documentId')::UUID;
    v_rejected := FALSE;
    BEGIN
        PERFORM public.post_stock_transfer(
            v_failed_id,1,
            '00000000-0000-0000-0000-000000016092'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'INSUFFICIENT_STOCK' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: insufficient transfer accepted';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.stock_transfer_documents
        WHERE id = v_failed_id AND status <> 'DRAFT'
    ) OR EXISTS (
        SELECT 1 FROM public.stock_movements
        WHERE reference_table = 'stock_transfer_documents'
          AND reference_id = v_failed_id
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: failed transfer partially persisted';
    END IF;

    v_result := public.save_stock_transfer_document(
        NULL,NULL,
        '00000000-0000-0000-0000-000000016041',
        '00000000-0000-0000-0000-000000016042',
        CURRENT_DATE,NULL,
        jsonb_build_array(jsonb_build_object(
            'productId','00000000-0000-0000-0000-000000016031',
            'quantityBase',1
        ))
    );
    v_cancel_id := (v_result->>'documentId')::UUID;
    v_result := public.cancel_stock_transfer(v_cancel_id,1);
    IF v_result->>'status' <> 'CANCELED' THEN
        RAISE EXCEPTION 'TEST_FAILED: cancel failed';
    END IF;

    IF has_function_privilege(
        'authenticated',
        'public.transfer_product_stock(uuid,uuid,uuid,numeric)',
        'EXECUTE'
    ) OR has_function_privilege(
        'service_role',
        'public.transfer_product_stock(uuid,uuid,uuid,numeric)',
        'EXECUTE'
    ) OR has_table_privilege(
        'authenticated','public.stock_transfer_documents',
        'INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.post_stock_transfer(uuid,bigint,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Transfer privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: Stock Transfer is atomic, positive-only, tenant-safe, FIFO-preserving, paired, idempotent, and audited.';
END
$test$;

ROLLBACK;
