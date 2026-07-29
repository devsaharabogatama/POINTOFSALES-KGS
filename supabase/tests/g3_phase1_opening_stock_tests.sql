-- G3 phase 1 behavioral test: Opening Stock atomic posting.
-- SAFETY: every fixture, document, movement, balance, FIFO layer, event, and
-- audit row is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_result JSONB;
    v_document_a UUID;
    v_document_b UUID;
    v_version_a BIGINT;
    v_version_b BIGINT;
    v_event_id UUID;
    v_count BIGINT;
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
        (
            '00000000-0000-0000-0000-000000048001',
            'G48A','G48 Company A','g48-company-a','ACTIVE'
        ),
        (
            '00000000-0000-0000-0000-000000048002',
            'G48B','G48 Company B','g48-company-b','ACTIVE'
        );
    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES (
        '00000000-0000-0000-0000-000000048011',
        '00000000-0000-0000-0000-000000048001',
        'G48-CAT','G48 Food'
    );
    INSERT INTO public.uoms(id,company_id,code,name) VALUES (
        '00000000-0000-0000-0000-000000048021',
        '00000000-0000-0000-0000-000000048001',
        'G48-KTL','G48 Ketul'
    );
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES (
        '00000000-0000-0000-0000-000000048031',
        '00000000-0000-0000-0000-000000048001',
        'G48-KEBAB','G48 Kebab','G48 Food',
        '00000000-0000-0000-0000-000000048011',
        100,50,'G48-KTL',
        '00000000-0000-0000-0000-000000048021',
        '00000000-0000-0000-0000-000000048021',
        2.1,TRUE,FALSE
    );
    INSERT INTO public.product_uoms(
        company_id,product_id,uom_id,factor_to_base,purchase_allowed,
        sales_allowed,purchase_price,sale_price
    ) VALUES (
        '00000000-0000-0000-0000-000000048001',
        '00000000-0000-0000-0000-000000048031',
        '00000000-0000-0000-0000-000000048021',
        1,TRUE,TRUE,50,100
    );
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type
    ) VALUES
        (
            '00000000-0000-0000-0000-000000048041',
            '00000000-0000-0000-0000-000000048001',
            'GHA','G48 Gudang Utama','CENTRAL'
        ),
        (
            '00000000-0000-0000-0000-000000048042',
            '00000000-0000-0000-0000-000000048002',
            'GHB','G48 Gudang Asing','CENTRAL'
        );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000048001','G3_PHASE1_TEST'
    );

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_opening_stock_document(
            NULL,NULL,
            '00000000-0000-0000-0000-000000048041',
            CURRENT_DATE,'Invalid zero cost',
            jsonb_build_array(jsonb_build_object(
                'productId','00000000-0000-0000-0000-000000048031',
                'quantityBase',10,'unitCostBase',0
            ))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'OPENING_STOCK_ZERO_COST_REASON_REQUIRED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: zero cost without reason was accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_opening_stock_document(
            NULL,NULL,
            '00000000-0000-0000-0000-000000048042',
            CURRENT_DATE,'Cross Company',
            jsonb_build_array(jsonb_build_object(
                'productId','00000000-0000-0000-0000-000000048031',
                'quantityBase',10,'unitCostBase',50
            ))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM IN (
            'OPENING_STOCK_PREPARER_REQUIRED','ACTIVE_WAREHOUSE_NOT_FOUND'
        ) THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: cross-Company Warehouse was accepted';
    END IF;

    v_result := public.save_opening_stock_document(
        NULL,NULL,
        '00000000-0000-0000-0000-000000048041',
        CURRENT_DATE,'Opening A',
        jsonb_build_array(jsonb_build_object(
            'productId','00000000-0000-0000-0000-000000048031',
            'quantityBase',10,'unitCostBase',50
        ))
    );
    v_document_a := (v_result->>'documentId')::UUID;
    v_version_a := (v_result->>'masterVersion')::BIGINT;
    IF v_version_a <> 1
       OR (v_result->>'lineCount')::INTEGER <> 1
       OR (v_result->>'totalCost')::NUMERIC <> 500 THEN
        RAISE EXCEPTION
            'TEST_FAILED: Opening Stock Draft A totals/version invalid';
    END IF;

    -- A second Draft for the same pair is allowed to exist, but only one can
    -- win posting. The loser must remain Draft without partial stock effects.
    v_result := public.save_opening_stock_document(
        NULL,NULL,
        '00000000-0000-0000-0000-000000048041',
        CURRENT_DATE,'Opening B',
        jsonb_build_array(jsonb_build_object(
            'productId','00000000-0000-0000-0000-000000048031',
            'quantityBase',4,'unitCostBase',55
        ))
    );
    v_document_b := (v_result->>'documentId')::UUID;
    v_version_b := (v_result->>'masterVersion')::BIGINT;

    v_result := public.save_opening_stock_document(
        v_document_b,v_version_b,
        '00000000-0000-0000-0000-000000048041',
        CURRENT_DATE,'Opening B updated',
        jsonb_build_array(jsonb_build_object(
            'productId','00000000-0000-0000-0000-000000048031',
            'quantityBase',4,'unitCostBase',55
        ))
    );
    v_version_b := (v_result->>'masterVersion')::BIGINT;
    IF v_version_b <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Draft update version invalid';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_opening_stock_document(
            v_document_b,1,
            '00000000-0000-0000-0000-000000048041',
            CURRENT_DATE,'Stale edit',
            jsonb_build_array(jsonb_build_object(
                'productId','00000000-0000-0000-0000-000000048031',
                'quantityBase',5,'unitCostBase',55
            ))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'MASTER_VERSION_CONFLICT' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale Draft update was accepted';
    END IF;

    v_result := public.post_opening_stock(
        v_document_a,v_version_a,
        '00000000-0000-0000-0000-000000048101'
    );
    v_event_id := (v_result->>'financialEventId')::UUID;
    IF v_result->>'status' <> 'POSTED'
       OR (v_result->>'masterVersion')::BIGINT <> 2
       OR (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: first post response invalid';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.product_stocks ps
    WHERE ps.company_id = '00000000-0000-0000-0000-000000048001'
      AND ps.product_id = '00000000-0000-0000-0000-000000048031'
      AND ps.warehouse_id = '00000000-0000-0000-0000-000000048041'
      AND ps.stock_qty = 10;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: materialized stock balance invalid';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.stock_movements sm
    WHERE sm.company_id = '00000000-0000-0000-0000-000000048001'
      AND sm.reference_table = 'opening_stock_documents'
      AND sm.reference_id = v_document_a
      AND sm.movement_type =
          'OPENING_BALANCE'::public.stock_movement_type
      AND sm.qty_change = 10;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Opening Stock movement invalid';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.product_batches pb
    JOIN public.opening_stock_lines l
      ON l.company_id = pb.company_id
     AND l.id = pb.opening_stock_line_id
    WHERE l.document_id = v_document_a
      AND pb.qty_purchased = 10
      AND pb.qty_remaining = 10
      AND pb.cogs_unit = 50;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: FIFO opening layer invalid';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.financial_events fe
    WHERE fe.id = v_event_id
      AND fe.company_id = '00000000-0000-0000-0000-000000048001'
      AND fe.event_type = 'STOCK_OPENING'::public.event_type
      AND fe.status = 'HOLD'::public.event_status
      AND fe.system_event_key = 'STOCK_OPENING'
      AND (fe.amounts->>'inventoryDebit')::NUMERIC = 500
      AND (fe.amounts->>'openingBalanceCredit')::NUMERIC = 500;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: HOLD Finance event invalid';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.journal_entries je
        WHERE je.financial_event_id = v_event_id
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: Opening Stock prematurely created journal';
    END IF;

    v_result := public.post_opening_stock(
        v_document_a,v_version_a,
        '00000000-0000-0000-0000-000000048101'
    );
    IF NOT (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: same-key retry was not idempotent';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.stock_movements
    WHERE reference_table = 'opening_stock_documents'
      AND reference_id = v_document_a;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: retry duplicated movement';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.post_opening_stock(
            v_document_a,2,
            '00000000-0000-0000-0000-000000048102'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'OPENING_STOCK_ALREADY_POSTED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: posted document accepted a different retry key';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.post_opening_stock(
            v_document_b,v_version_b,
            '00000000-0000-0000-0000-000000048103'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'OPENING_STOCK_MOVEMENT_ALREADY_EXISTS' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: second Opening Stock for moved pair posted';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.opening_stock_documents
    WHERE id = v_document_b
      AND status = 'DRAFT'
      AND financial_event_id IS NULL;
    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: rejected second post partially changed document';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.opening_stock_audit
    WHERE document_id = v_document_a
      AND action IN ('CREATE','POST');
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Opening Stock audit incomplete';
    END IF;

    IF has_table_privilege(
        'authenticated','public.opening_stock_documents',
        'INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.opening_stock_lines',
        'INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.product_stocks','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.stock_movements','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.save_opening_stock_document(uuid,bigint,uuid,date,text,jsonb)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.post_opening_stock(uuid,bigint,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: Opening Stock privilege boundary invalid';
    END IF;

    RAISE NOTICE
        'TEST PASSED: Opening Stock is tenant-safe, atomic, FIFO-backed, idempotent, audited, and rejects prior movement.';
END
$test$;

ROLLBACK;
