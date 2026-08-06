-- G5 phase 8 behavior: Purchase Return is reviewed, atomic, and source-safe.
-- SAFETY: all fixtures and effects are rolled back.
BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID := '00000000-0000-0000-0000-000000092001';
    v_store UUID := '00000000-0000-0000-0000-000000092011';
    v_terminal UUID := '00000000-0000-0000-0000-000000092021';
    v_warehouse UUID := '00000000-0000-0000-0000-000000092031';
    v_category UUID := '00000000-0000-0000-0000-000000092041';
    v_uom UUID := '00000000-0000-0000-0000-000000092051';
    v_purchase_uom UUID := '00000000-0000-0000-0000-000000092052';
    v_product UUID := '00000000-0000-0000-0000-000000092061';
    v_supplier UUID := '00000000-0000-0000-0000-000000092071';
    v_session UUID := '00000000-0000-0000-0000-000000092081';
    v_order UUID := '00000000-0000-0000-0000-000000092091';
    v_order_line UUID := '00000000-0000-0000-0000-000000092092';
    v_receipt UUID;
    v_source_allocation UUID;
    v_return UUID;
    v_cancel_return UUID;
    v_result JSONB;
    v_count BIGINT;
    v_value NUMERIC;
    v_rejected BOOLEAN;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role='super_admin'::public.user_role
      AND NOT EXISTS (
        SELECT 1 FROM public.cashier_sessions session
        WHERE session.cashier_id=profile.id
          AND session.status='OPEN'::public.session_status
      )
    ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: available linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES(v_company,'G92A','G92 Company','g92-company','ACTIVE');
    INSERT INTO public.stores(
        id,company_id,store_code,store_name,status
    ) VALUES(v_store,v_company,'G92S','G92 Store','ACTIVE');
    INSERT INTO public.pos_terminals(
        id,company_id,store_id,pos_code,pos_name,status
    ) VALUES(v_terminal,v_company,v_store,'G92P','G92 POS','ACTIVE');
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,store_id,
        is_sale_source,is_purchase_destination,is_active
    ) VALUES(
        v_warehouse,v_company,'G92WH','G92 Warehouse','STORE',v_store,
        FALSE,TRUE,TRUE
    );
    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES(v_category,v_company,'G92CAT','G92 Product');
    INSERT INTO public.uoms(
        id,company_id,code,name,uom_type,allow_decimal,decimal_precision
    ) VALUES
        (v_uom,v_company,'G92PCS','Piece','UNIT',FALSE,0),
        (v_purchase_uom,v_company,'G92BOX','Box','PACKAGING',FALSE,0);
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES(
        v_product,v_company,'G92-PROD','G92 Product','G92 Product',v_category,
        100,45,'G92PCS',v_uom,v_uom,1,TRUE,FALSE
    );
    INSERT INTO public.product_uoms(
        company_id,product_id,uom_id,factor_to_base,purchase_allowed,
        sales_allowed,purchase_price,sale_price,is_active
    ) VALUES
        (v_company,v_product,v_uom,1,FALSE,TRUE,45,100,TRUE),
        (v_company,v_product,v_purchase_uom,10,TRUE,FALSE,450,1000,TRUE);
    INSERT INTO public.suppliers(
        id,company_id,supplier_code,supplier_name,created_by,updated_by
    ) VALUES(v_supplier,v_company,'G92SUP','G92 Supplier',v_actor,v_actor);
    INSERT INTO public.cashier_sessions(
        id,session_code,cashier_id,company_id,store_id,pos_id,status,
        sales_warehouse_id
    ) VALUES(
        v_session,'G92-SESSION',v_actor,v_company,v_store,v_terminal,
        'OPEN'::public.session_status,v_warehouse
    );
    INSERT INTO public.supplier_order_documents(
        id,company_id,order_no,store_id,destination_warehouse_id,supplier_id,
        order_date,ordered_by,status,confirmed_by,confirmed_at,
        confirmation_idempotency_key,line_count,total_ordered_base_qty,
        estimated_total
    ) VALUES(
        v_order,v_company,'PO-G92',v_store,v_warehouse,v_supplier,current_date,
        v_actor,'DRAFT',NULL,NULL,NULL,1,10,450
    );
    INSERT INTO public.supplier_order_lines(
        id,company_id,document_id,line_no,client_line_key,product_id,
        ordered_uom_id,ordered_qty,factor_to_base_snapshot,ordered_base_qty,
        estimated_unit_price,estimated_subtotal,product_sku_snapshot,
        product_name_snapshot,ordered_uom_name_snapshot
    ) VALUES(
        v_order_line,v_company,v_order,1,
        '00000000-0000-0000-0000-000000092094',v_product,
        v_purchase_uom,1,10,10,
        450,450,'G92-PROD','G92 Product','Box'
    );
    UPDATE public.supplier_order_documents SET
        status='CONFIRMED',confirmed_by=v_actor,
        confirmed_at=clock_timestamp(),
        confirmation_idempotency_key=
            '00000000-0000-0000-0000-000000092093',
        master_version=2
    WHERE company_id=v_company AND id=v_order;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G5_PHASE8_TEST');

    v_result := public.save_goods_receipt(
        NULL,NULL,v_session,v_order,'DEL-G92','Return source',
        jsonb_build_array(jsonb_build_object(
            'clientLineKey','00000000-0000-0000-0000-000000092101',
            'supplierOrderLineId',v_order_line,
            'receivedUomId',v_purchase_uom,
            'receivedQty',1,'acceptedGoodQty',1,'damagedQty',0,
            'rejectedQty',0
        ))
    );
    v_receipt := (v_result->>'documentId')::UUID;
    PERFORM public.post_goods_receipt(
        v_receipt,1,'00000000-0000-0000-0000-000000092102'
    );
    SELECT allocation.id INTO v_source_allocation
    FROM public.goods_receipt_condition_allocations allocation
    JOIN public.goods_receipt_lines line
      ON line.company_id=allocation.company_id
     AND line.id=allocation.receipt_line_id
    WHERE line.document_id=v_receipt AND allocation.condition_type='GOOD';

    v_result := public.save_purchase_return_draft(
        NULL,NULL,v_session,v_receipt,v_warehouse,current_date,
        'Kemasan rusak saat penerimaan','SUP-RET-G92','Partial return',
        jsonb_build_array(jsonb_build_object(
            'clientLineKey','00000000-0000-0000-0000-000000092111',
            'sourceConditionAllocationId',v_source_allocation,
            'returnUomId',v_uom,'returnQty',4
        ))
    );
    v_return := (v_result->>'documentId')::UUID;
    SELECT stock_qty INTO v_value FROM public.product_stocks
    WHERE company_id=v_company AND product_id=v_product
      AND warehouse_id=v_warehouse;
    IF v_value<>10 THEN
        RAISE EXCEPTION 'TEST_FAILED: Draft changed stock: %',v_value;
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.post_purchase_return(
            v_return,1,'00000000-0000-0000-0000-000000092112'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='APPROVED_PURCHASE_RETURN_REQUIRED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: unreviewed Return posted';
    END IF;

    v_result := public.review_purchase_return(v_return,1,'APPROVE',NULL);
    IF v_result->>'reviewStatus'<>'APPROVED'
       OR (v_result->>'masterVersion')::BIGINT<>2 THEN
        RAISE EXCEPTION 'TEST_FAILED: review invalid: %',v_result;
    END IF;
    v_result := public.post_purchase_return(
        v_return,2,'00000000-0000-0000-0000-000000092112'
    );
    IF v_result->>'status'<>'POSTED'
       OR (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: post invalid: %',v_result;
    END IF;
    SELECT stock_qty INTO v_value FROM public.product_stocks
    WHERE company_id=v_company AND product_id=v_product
      AND warehouse_id=v_warehouse;
    IF v_value<>6 THEN
        RAISE EXCEPTION 'TEST_FAILED: stock %, expected 6',v_value;
    END IF;
    SELECT qty_remaining INTO v_value FROM public.product_batches
    WHERE company_id=v_company
      AND goods_receipt_condition_allocation_id=v_source_allocation;
    IF v_value<>6 THEN
        RAISE EXCEPTION 'TEST_FAILED: FIFO %, expected 6',v_value;
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_movements
    WHERE company_id=v_company
      AND reference_table='purchase_return_documents'
      AND reference_id=v_return AND movement_type='PURCHASE_RETURN'
      AND qty_change=-4;
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Return Movement count %',v_count;
    END IF;
    SELECT COALESCE(sum(amount),0) INTO v_value
    FROM public.purchase_return_ap_adjustments
    WHERE company_id=v_company AND document_id=v_return
      AND adjustment_route='AP_PROVISIONAL';
    IF v_value<>180 THEN
        RAISE EXCEPTION 'TEST_FAILED: AP adjustment %, expected 180',v_value;
    END IF;
    SELECT count(*) INTO v_count FROM public.financial_events
    WHERE company_id=v_company AND source_table='purchase_return_documents'
      AND source_id=v_return AND system_event_key='PURCHASE_RETURN'
      AND status='HOLD';
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Finance HOLD count %',v_count;
    END IF;

    v_result := public.post_purchase_return(
        v_return,3,'00000000-0000-0000-0000-000000092112'
    );
    IF NOT (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: post replay not idempotent';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_purchase_return_draft(
            NULL,NULL,v_session,v_receipt,v_warehouse,current_date,
            'Exceeds remaining source',NULL,NULL,
            jsonb_build_array(jsonb_build_object(
                'clientLineKey','00000000-0000-0000-0000-000000092121',
                'sourceConditionAllocationId',v_source_allocation,
                'returnUomId',v_uom,'returnQty',7
            ))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='PURCHASE_RETURN_QUANTITY_EXCEEDS_AVAILABLE' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: over-return accepted';
    END IF;

    v_result := public.save_purchase_return_draft(
        NULL,NULL,v_session,v_receipt,v_warehouse,current_date,
        'Draft cancellation',NULL,NULL,
        jsonb_build_array(jsonb_build_object(
            'clientLineKey','00000000-0000-0000-0000-000000092131',
            'sourceConditionAllocationId',v_source_allocation,
            'returnUomId',v_uom,'returnQty',1
        ))
    );
    v_cancel_return := (v_result->>'documentId')::UUID;
    v_result := public.cancel_purchase_return_draft(
        v_cancel_return,1,'Tidak jadi diserahkan'
    );
    IF v_result->>'status'<>'CANCELED' THEN
        RAISE EXCEPTION 'TEST_FAILED: cancel invalid: %',v_result;
    END IF;

    IF has_table_privilege(
        'authenticated','public.purchase_return_documents',
        'INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.purchase_return_lines','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated','public.post_purchase_return(uuid,bigint,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Purchase Return privilege invalid';
    END IF;
    RAISE NOTICE 'TEST PASSED: Purchase Return is reviewed, source-limited, atomic across Stock/FIFO/Movement/AP/Event, idempotent, cancelable, and audited.';
END
$test$;

ROLLBACK;
