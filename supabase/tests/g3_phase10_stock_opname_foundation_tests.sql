-- G3 phase 10 behavior: blind, non-blocking Stock Opname.
-- SAFETY: every fixture, count, Movement, Adjustment, and audit is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_result JSONB;
    v_opname UUID;
    v_detail UUID;
    v_old_opname UUID;
    v_old_detail UUID;
    v_version BIGINT;
    v_qty NUMERIC;
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
        ('00000000-0000-0000-0000-000000050001',
         'G50A','G50 Company A','g50-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000050002',
         'G50B','G50 Company B','g50-company-b','ACTIVE');
    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES (
        '00000000-0000-0000-0000-000000050011',
        '00000000-0000-0000-0000-000000050001','TEST','Test'
    );
    INSERT INTO public.uoms(id,company_id,code,name) VALUES (
        '00000000-0000-0000-0000-000000050021',
        '00000000-0000-0000-0000-000000050001','PCS','Piece'
    );
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type
    ) VALUES
        ('00000000-0000-0000-0000-000000050031',
         '00000000-0000-0000-0000-000000050001',
         'WHA','G50 Warehouse A','CENTRAL'),
        ('00000000-0000-0000-0000-000000050032',
         '00000000-0000-0000-0000-000000050002',
         'WHB','G50 Warehouse B','CENTRAL');
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES (
        '00000000-0000-0000-0000-000000050041',
        '00000000-0000-0000-0000-000000050001',
        'G50-P','G50 Product','Test',
        '00000000-0000-0000-0000-000000050011',100,50,'PCS',
        '00000000-0000-0000-0000-000000050021',
        '00000000-0000-0000-0000-000000050021',1,TRUE,FALSE
    );
    INSERT INTO public.product_uoms(
        company_id,product_id,uom_id,factor_to_base,
        purchase_allowed,sales_allowed,purchase_price,sale_price
    ) VALUES (
        '00000000-0000-0000-0000-000000050001',
        '00000000-0000-0000-0000-000000050041',
        '00000000-0000-0000-0000-000000050021',
        1,TRUE,TRUE,50,100
    );
    INSERT INTO public.product_stocks(
        product_id,warehouse_id,stock_qty,company_id
    ) VALUES (
        '00000000-0000-0000-0000-000000050041',
        '00000000-0000-0000-0000-000000050031',10,
        '00000000-0000-0000-0000-000000050001'
    );
    INSERT INTO public.product_batches(
        product_id,warehouse_id,qty_purchased,qty_remaining,cogs_unit,
        company_id
    ) VALUES (
        '00000000-0000-0000-0000-000000050041',
        '00000000-0000-0000-0000-000000050031',10,10,50,
        '00000000-0000-0000-0000-000000050001'
    );
    INSERT INTO public.stock_movements(
        product_id,warehouse_id,qty_change,movement_type,
        reference_table,reference_id,company_id,base_uom_id,
        base_uom_name_snapshot,balance_after_base_qty,actor_id,
        posted_at,movement_status
    ) VALUES (
        '00000000-0000-0000-0000-000000050041',
        '00000000-0000-0000-0000-000000050031',10,
        'PURCHASE'::public.stock_movement_type,'G3_PHASE10_TEST',
        '00000000-0000-0000-0000-000000050061',
        '00000000-0000-0000-0000-000000050001',
        '00000000-0000-0000-0000-000000050021','Piece',10,
        v_actor,clock_timestamp(),'POSTED'
    );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000050001','G3_PHASE10_TEST'
    );

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_stock_opname_session(
            NULL,NULL,'00000000-0000-0000-0000-000000050032',
            'ALL',NULL,NULL,NULL
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'STOCK_OPNAME_COUNTER_REQUIRED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company warehouse accepted';
    END IF;

    -- An older completed result remains active until a newer valid count for
    -- the same Product-Warehouse supersedes it.
    v_result := public.save_stock_opname_session(
        NULL,NULL,'00000000-0000-0000-0000-000000050031',
        'SELECTED',NULL,
        jsonb_build_array('00000000-0000-0000-0000-000000050041'),
        'Older count'
    );
    v_old_opname := (v_result->>'opnameId')::UUID;
    v_version := (v_result->>'masterVersion')::BIGINT;
    SELECT id INTO v_old_detail FROM public.stock_opname_details
    WHERE company_id = '00000000-0000-0000-0000-000000050001'
      AND opname_id = v_old_opname;
    v_result := public.start_stock_opname(v_old_opname,v_version);
    v_version := (v_result->>'masterVersion')::BIGINT;
    v_result := public.record_stock_opname_count(
        v_old_opname,v_version,
        '00000000-0000-0000-0000-000000050041',10,NULL
    );
    v_version := (v_result->>'masterVersion')::BIGINT;
    v_result := public.complete_stock_opname(v_old_opname,v_version);

    v_result := public.save_stock_opname_session(
        NULL,NULL,'00000000-0000-0000-0000-000000050031',
        'SELECTED',NULL,
        jsonb_build_array('00000000-0000-0000-0000-000000050041'),
        'Blind nonblocking test'
    );
    v_opname := (v_result->>'opnameId')::UUID;
    v_version := (v_result->>'masterVersion')::BIGINT;
    SELECT id INTO v_detail FROM public.stock_opname_details
    WHERE company_id = '00000000-0000-0000-0000-000000050001'
      AND opname_id = v_opname;

    v_result := public.get_stock_opname_blind_session(v_opname);
    IF (v_result->'lines'->0) ? 'expectedQuantityAtCount'
       OR (v_result->'lines'->0) ? 'systemQuantity'
       OR (v_result->'lines'->0) ? 'varianceAtCount'
       OR (v_result->'lines'->0) ? 'physicalQuantity' THEN
        RAISE EXCEPTION 'TEST_FAILED: blind payload leaked quantity';
    END IF;

    v_result := public.start_stock_opname(v_opname,v_version);
    v_version := (v_result->>'masterVersion')::BIGINT;

    -- A sale-like movement during the count window keeps operation running,
    -- but the first count must require a recount.
    UPDATE public.product_stocks SET stock_qty = 9
    WHERE product_id = '00000000-0000-0000-0000-000000050041'
      AND warehouse_id = '00000000-0000-0000-0000-000000050031';
    UPDATE public.product_batches SET qty_remaining = 9
    WHERE company_id = '00000000-0000-0000-0000-000000050001'
      AND product_id = '00000000-0000-0000-0000-000000050041';
    INSERT INTO public.stock_movements(
        product_id,warehouse_id,qty_change,movement_type,
        reference_table,reference_id,company_id,base_uom_id,
        base_uom_name_snapshot,balance_after_base_qty,actor_id,
        posted_at,movement_status
    ) VALUES (
        '00000000-0000-0000-0000-000000050041',
        '00000000-0000-0000-0000-000000050031',-1,
        'SALE'::public.stock_movement_type,'G3_PHASE10_TEST',
        '00000000-0000-0000-0000-000000050062',
        '00000000-0000-0000-0000-000000050001',
        '00000000-0000-0000-0000-000000050021','Piece',9,
        v_actor,clock_timestamp(),'POSTED'
    );
    v_result := public.record_stock_opname_count(
        v_opname,v_version,
        '00000000-0000-0000-0000-000000050041',8,NULL
    );
    v_version := (v_result->>'masterVersion')::BIGINT;
    IF v_result->>'lineStatus' <> 'RECOUNT_REQUIRED' THEN
        RAISE EXCEPTION 'TEST_FAILED: movement window did not require recount';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.complete_stock_opname(v_opname,v_version);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'STOCK_OPNAME_UNRESOLVED_LINE' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: unresolved recount completed';
    END IF;

    -- The counter opens a fresh window for an automatically required recount.
    v_result := public.request_stock_opname_recount(
        v_opname,v_version,v_detail
    );
    v_version := (v_result->>'masterVersion')::BIGINT;
    v_result := public.record_stock_opname_count(
        v_opname,v_version,
        '00000000-0000-0000-0000-000000050041',8,'Second count'
    );
    v_version := (v_result->>'masterVersion')::BIGINT;
    IF v_result->>'lineStatus' <> 'COUNTED' THEN
        RAISE EXCEPTION 'TEST_FAILED: clean recount was not accepted';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.stock_opname_details
        WHERE company_id = '00000000-0000-0000-0000-000000050001'
          AND id = v_old_detail AND line_status = 'SUPERSEDED'
          AND superseded_by_line_id = v_detail
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: older valid count not superseded';
    END IF;
    v_result := public.complete_stock_opname(v_opname,v_version);
    v_version := (v_result->>'masterVersion')::BIGINT;

    -- Movement after counted_at is allowed. Posting applies only variance -1
    -- to current stock 7, producing final stock 6.
    UPDATE public.product_stocks SET stock_qty = 7
    WHERE product_id = '00000000-0000-0000-0000-000000050041'
      AND warehouse_id = '00000000-0000-0000-0000-000000050031';
    UPDATE public.product_batches SET qty_remaining = 7
    WHERE company_id = '00000000-0000-0000-0000-000000050001'
      AND product_id = '00000000-0000-0000-0000-000000050041';
    INSERT INTO public.stock_movements(
        product_id,warehouse_id,qty_change,movement_type,
        reference_table,reference_id,company_id,base_uom_id,
        base_uom_name_snapshot,balance_after_base_qty,actor_id,
        posted_at,movement_status
    ) VALUES (
        '00000000-0000-0000-0000-000000050041',
        '00000000-0000-0000-0000-000000050031',-2,
        'SALE'::public.stock_movement_type,'G3_PHASE10_TEST',
        '00000000-0000-0000-0000-000000050063',
        '00000000-0000-0000-0000-000000050001',
        '00000000-0000-0000-0000-000000050021','Piece',7,
        v_actor,clock_timestamp(),'POSTED'
    );
    v_result := public.post_stock_opname(
        v_opname,v_version,
        '00000000-0000-0000-0000-000000050071'
    );
    IF v_result->>'status' <> 'POSTED'
       OR v_result->>'adjustmentDocumentId' IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: Opname posting result invalid';
    END IF;
    SELECT stock_qty INTO v_qty FROM public.product_stocks
    WHERE product_id = '00000000-0000-0000-0000-000000050041'
      AND warehouse_id = '00000000-0000-0000-0000-000000050031';
    IF v_qty <> 6 THEN
        RAISE EXCEPTION 'TEST_FAILED: expected final stock 6, got %',v_qty;
    END IF;
    SELECT count(*) INTO v_count
    FROM public.stock_adjustment_lines
    WHERE company_id = '00000000-0000-0000-0000-000000050001'
      AND opname_detail_id = v_detail;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Opname Adjustment linkage missing';
    END IF;

    v_result := public.post_stock_opname(
        v_opname,v_version,
        '00000000-0000-0000-0000-000000050071'
    );
    IF NOT (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: Opname replay not idempotent';
    END IF;

    IF has_table_privilege(
        'authenticated','public.stock_opnames','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.stock_opname_details','INSERT,UPDATE,DELETE'
    ) OR has_function_privilege(
        'anon','public.post_stock_opname(uuid,bigint,uuid)','EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.record_stock_opname_count(uuid,bigint,uuid,numeric,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Opname privilege boundary invalid';
    END IF;

    RAISE NOTICE
        'TEST PASSED: blind count, movement-window recount, current-balance variance posting, Adjustment linkage, and idempotency are enforced.';
END
$test$;

ROLLBACK;
