-- G5 phase 2 behavior: Stock Request -> Supplier Order without Stock/Finance effect.
-- SAFETY: every fixture, document, allocation, and audit row is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID:='00000000-0000-0000-0000-000000090001';
    v_company_b UUID:='00000000-0000-0000-0000-000000090002';
    v_store UUID:='00000000-0000-0000-0000-000000090011';
    v_terminal UUID:='00000000-0000-0000-0000-000000090021';
    v_warehouse UUID:='00000000-0000-0000-0000-000000090031';
    v_category UUID:='00000000-0000-0000-0000-000000090041';
    v_uom UUID:='00000000-0000-0000-0000-000000090051';
    v_product UUID:='00000000-0000-0000-0000-000000090061';
    v_supplier UUID:='00000000-0000-0000-0000-000000090071';
    v_supplier_b UUID:='00000000-0000-0000-0000-000000090072';
    v_session UUID:='00000000-0000-0000-0000-000000090081';
    v_request UUID; v_request_line UUID; v_order UUID;
    v_result JSONB; v_count BIGINT; v_version BIGINT;
    v_status TEXT;
    v_stock_before BIGINT; v_batch_before BIGINT; v_movement_before BIGINT;
    v_event_before BIGINT; v_rejected BOOLEAN;
BEGIN
    SELECT p.id INTO v_actor FROM public.profiles p
    JOIN auth.users u ON u.id=p.id
    WHERE p.role='super_admin'::public.user_role
      AND NOT EXISTS(SELECT 1 FROM public.cashier_sessions s
          WHERE s.cashier_id=p.id AND s.status='OPEN'::public.session_status)
    ORDER BY p.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: available linked Super Admin required';
    END IF;

    INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
    VALUES
        (v_company,'G90A','G90 Company A','g90-company-a','ACTIVE'),
        (v_company_b,'G90B','G90 Company B','g90-company-b','ACTIVE');
    INSERT INTO public.stores(id,company_id,store_code,store_name,status)
    VALUES(v_store,v_company,'G90S','G90 Store','ACTIVE');
    INSERT INTO public.pos_terminals(id,company_id,store_id,pos_code,pos_name,status)
    VALUES(v_terminal,v_company,v_store,'G90P','G90 POS','ACTIVE');
    INSERT INTO public.warehouses(id,company_id,code,name,warehouse_type,store_id,
        is_sale_source,is_purchase_destination,is_active)
    VALUES(v_warehouse,v_company,'G90W','G90 Purchase Warehouse','STORE',v_store,
        FALSE,TRUE,TRUE);
    INSERT INTO public.product_categories(id,company_id,category_code,category_name)
    VALUES(v_category,v_company,'G90CAT','G90 Product');
    INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,decimal_precision)
    VALUES(v_uom,v_company,'G90PCS','Piece','UNIT',FALSE,0);
    INSERT INTO public.products(id,company_id,sku,name,category,category_id,
        price,cogs,uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,
        is_active,is_bundle)
    VALUES(v_product,v_company,'G90-PROD','G90 Product','G90 Product',v_category,
        100,50,'G90PCS',v_uom,v_uom,1,TRUE,FALSE);
    INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,
        purchase_allowed,sales_allowed,purchase_price,sale_price,is_active)
    VALUES(v_company,v_product,v_uom,1,TRUE,TRUE,50,100,TRUE);
    INSERT INTO public.suppliers(id,company_id,supplier_code,supplier_name,
        created_by,updated_by)
    VALUES
        (v_supplier,v_company,'G90SUP','G90 Supplier',v_actor,v_actor),
        (v_supplier_b,v_company_b,'G90SUPB','G90 Supplier B',v_actor,v_actor);
    INSERT INTO public.cashier_sessions(id,session_code,cashier_id,company_id,
        store_id,pos_id,status,sales_warehouse_id)
    VALUES(v_session,'G90-SESSION',v_actor,v_company,v_store,v_terminal,
        'OPEN'::public.session_status,v_warehouse);

    PERFORM set_config('request.jwt.claims',jsonb_build_object(
        'sub',v_actor,'role','authenticated')::TEXT,TRUE);
    PERFORM public.set_active_company_context(v_company,'G5_PHASE2_TEST');

    SELECT count(*) INTO v_stock_before FROM public.product_stocks;
    SELECT count(*) INTO v_batch_before FROM public.product_batches;
    SELECT count(*) INTO v_movement_before FROM public.stock_movements;
    SELECT count(*) INTO v_event_before FROM public.financial_events;

    v_result:=public.save_stock_request(NULL,NULL,v_session,current_date+2,
        'Store replenishment',jsonb_build_array(jsonb_build_object(
            'clientLineKey','00000000-0000-0000-0000-000000090101',
            'productId',v_product,'uomId',v_uom,'quantity',10,
            'notes','Need ten pieces')));
    v_request:=(v_result->>'documentId')::UUID;
    IF v_result->>'status'<>'DRAFT' OR (v_result->>'masterVersion')::BIGINT<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Stock Request create invalid: %',v_result;
    END IF;
    SELECT id INTO v_request_line FROM public.stock_request_lines
    WHERE company_id=v_company AND document_id=v_request;
    v_result:=public.submit_stock_request(v_request,1);
    IF v_result->>'status'<>'SUBMITTED' OR
       (v_result->>'masterVersion')::BIGINT<>2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Stock Request submit invalid: %',v_result;
    END IF;

    v_rejected:=FALSE;
    BEGIN
        PERFORM public.save_supplier_order(NULL,NULL,v_store,v_warehouse,
            v_supplier_b,current_date,current_date+2,NULL,
            jsonb_build_array(jsonb_build_object(
                'clientLineKey','00000000-0000-0000-0000-000000090111',
                'productId',v_product,'uomId',v_uom,'quantity',10,
                'estimatedUnitPrice',45)),jsonb_build_array(jsonb_build_object(
                'orderLineKey','00000000-0000-0000-0000-000000090111',
                'requestLineId',v_request_line,'allocatedBaseQty',10)));
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='ACTIVE_SUPPLIER_NOT_FOUND' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company Supplier accepted';
    END IF;

    v_result:=public.save_supplier_order(NULL,NULL,v_store,v_warehouse,
        v_supplier,current_date,current_date+2,'Purchase for Request',
        jsonb_build_array(jsonb_build_object(
            'clientLineKey','00000000-0000-0000-0000-000000090121',
            'productId',v_product,'uomId',v_uom,'quantity',12,
            'estimatedUnitPrice',45)),jsonb_build_array(jsonb_build_object(
            'orderLineKey','00000000-0000-0000-0000-000000090121',
            'requestLineId',v_request_line,'allocatedBaseQty',10)));
    v_order:=(v_result->>'documentId')::UUID;
    v_result:=public.confirm_supplier_order(v_order,1,
        '00000000-0000-0000-0000-000000090131');
    IF v_result->>'status'<>'CONFIRMED' OR
       (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: Supplier Order confirmation invalid: %',v_result;
    END IF;
    SELECT status,master_version INTO v_status,v_version
    FROM public.stock_request_documents WHERE id=v_request;
    IF v_status<>'ORDERED' OR v_version<>3 THEN
        RAISE EXCEPTION 'TEST_FAILED: Request was not moved to ORDERED';
    END IF;

    v_result:=public.confirm_supplier_order(v_order,2,
        '00000000-0000-0000-0000-000000090131');
    IF NOT (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: confirmation replay was not idempotent';
    END IF;
    SELECT count(*) INTO v_count FROM public.supplier_order_audit
    WHERE document_id=v_order AND action='CONFIRM';
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: confirmation audit count %, expected 1',v_count;
    END IF;

    IF (SELECT count(*) FROM public.product_stocks)<>v_stock_before
       OR (SELECT count(*) FROM public.product_batches)<>v_batch_before
       OR (SELECT count(*) FROM public.stock_movements)<>v_movement_before
       OR (SELECT count(*) FROM public.financial_events)<>v_event_before THEN
        RAISE EXCEPTION 'TEST_FAILED: Request/Order produced Stock or Finance effect';
    END IF;

    v_result:=public.cancel_supplier_order(v_order,2,'Supplier unavailable');
    IF v_result->>'status'<>'CANCELED' THEN
        RAISE EXCEPTION 'TEST_FAILED: Supplier Order cancel invalid';
    END IF;
    SELECT status,master_version INTO v_status,v_version
    FROM public.stock_request_documents WHERE id=v_request;
    IF v_status<>'SUBMITTED' OR v_version<>4 THEN
        RAISE EXCEPTION 'TEST_FAILED: canceled Order did not reopen Request';
    END IF;
    v_result:=public.close_stock_request(v_request,4);
    IF v_result->>'status'<>'CLOSED' THEN
        RAISE EXCEPTION 'TEST_FAILED: Stock Request close invalid';
    END IF;

    IF has_table_privilege('authenticated','public.stock_request_documents',
            'INSERT,UPDATE,DELETE')
       OR has_table_privilege('authenticated','public.supplier_order_documents',
            'INSERT,UPDATE,DELETE')
       OR NOT has_function_privilege('authenticated',
            'public.save_stock_request(uuid,bigint,uuid,date,text,jsonb)','EXECUTE')
       OR NOT has_function_privilege('authenticated',
            'public.save_supplier_order(uuid,bigint,uuid,uuid,uuid,date,date,text,jsonb,jsonb)',
            'EXECUTE') THEN
        RAISE EXCEPTION 'TEST_FAILED: Purchase write privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: Stock Request and Supplier Order are tenant-safe, versioned, idempotent, audited, and have zero Stock/FIFO/Finance effect.';
END
$test$;

ROLLBACK;
