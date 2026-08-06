-- G5 phase 11 behavior: Supplier Invoice matching is exact, atomic, and safe.
-- SAFETY: every fixture and effect is rolled back.
BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID := '00000000-0000-0000-0000-000000093001';
    v_store UUID := '00000000-0000-0000-0000-000000093011';
    v_terminal UUID := '00000000-0000-0000-0000-000000093021';
    v_warehouse UUID := '00000000-0000-0000-0000-000000093031';
    v_category UUID := '00000000-0000-0000-0000-000000093041';
    v_uom UUID := '00000000-0000-0000-0000-000000093051';
    v_purchase_uom UUID := '00000000-0000-0000-0000-000000093052';
    v_product UUID := '00000000-0000-0000-0000-000000093061';
    v_supplier UUID := '00000000-0000-0000-0000-000000093071';
    v_product_supplier UUID := '00000000-0000-0000-0000-000000093072';
    v_session UUID := '00000000-0000-0000-0000-000000093081';
    v_order UUID := '00000000-0000-0000-0000-000000093091';
    v_order_line UUID := '00000000-0000-0000-0000-000000093092';
    v_receipt UUID;
    v_provisional UUID;
    v_exception_invoice UUID;
    v_invoice UUID;
    v_result JSONB;
    v_value NUMERIC;
    v_count BIGINT;
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
    ) VALUES(v_company,'G93A','G93 Company','g93-company','ACTIVE');
    INSERT INTO public.stores(
        id,company_id,store_code,store_name,status
    ) VALUES(v_store,v_company,'G93S','G93 Store','ACTIVE');
    INSERT INTO public.pos_terminals(
        id,company_id,store_id,pos_code,pos_name,status
    ) VALUES(v_terminal,v_company,v_store,'G93P','G93 POS','ACTIVE');
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,store_id,
        is_sale_source,is_purchase_destination,is_active
    ) VALUES(
        v_warehouse,v_company,'G93WH','G93 Warehouse','STORE',v_store,
        FALSE,TRUE,TRUE
    );
    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES(v_category,v_company,'G93CAT','G93 Product');
    INSERT INTO public.uoms(
        id,company_id,code,name,uom_type,allow_decimal,decimal_precision
    ) VALUES
        (v_uom,v_company,'G93PCS','Piece','UNIT',FALSE,0),
        (v_purchase_uom,v_company,'G93BOX','Box','PACKAGING',FALSE,0);
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES(
        v_product,v_company,'G93-PROD','G93 Product','G93 Product',v_category,
        100,45,'G93PCS',v_uom,v_uom,1,TRUE,FALSE
    );
    INSERT INTO public.product_uoms(
        company_id,product_id,uom_id,factor_to_base,purchase_allowed,
        sales_allowed,purchase_price,sale_price,is_active
    ) VALUES
        (v_company,v_product,v_uom,1,FALSE,TRUE,45,100,TRUE),
        (v_company,v_product,v_purchase_uom,10,TRUE,FALSE,450,1000,TRUE);
    INSERT INTO public.suppliers(
        id,company_id,supplier_code,supplier_name,created_by,updated_by
    ) VALUES(v_supplier,v_company,'G93SUP','G93 Supplier',v_actor,v_actor);
    INSERT INTO public.product_suppliers(
        id,company_id,product_id,supplier_id,purchase_uom_id,
        reference_purchase_price,is_preferred_supplier,
        created_by,updated_by
    ) VALUES(
        v_product_supplier,v_company,v_product,v_supplier,v_purchase_uom,
        450,TRUE,v_actor,v_actor
    );
    INSERT INTO public.cashier_sessions(
        id,session_code,cashier_id,company_id,store_id,pos_id,status,
        sales_warehouse_id
    ) VALUES(
        v_session,'G93-SESSION',v_actor,v_company,v_store,v_terminal,
        'OPEN'::public.session_status,v_warehouse
    );
    INSERT INTO public.supplier_order_documents(
        id,company_id,order_no,store_id,destination_warehouse_id,supplier_id,
        order_date,ordered_by,status,confirmed_by,confirmed_at,
        confirmation_idempotency_key,line_count,total_ordered_base_qty,
        estimated_total
    ) VALUES(
        v_order,v_company,'PO-G93',v_store,v_warehouse,v_supplier,current_date,
        v_actor,'DRAFT',NULL,NULL,NULL,1,10,450
    );
    INSERT INTO public.supplier_order_lines(
        id,company_id,document_id,line_no,client_line_key,product_id,
        ordered_uom_id,ordered_qty,factor_to_base_snapshot,ordered_base_qty,
        estimated_unit_price,estimated_subtotal,product_sku_snapshot,
        product_name_snapshot,ordered_uom_name_snapshot
    ) VALUES(
        v_order_line,v_company,v_order,1,
        '00000000-0000-0000-0000-000000093094',v_product,
        v_purchase_uom,1,10,10,450,450,'G93-PROD','G93 Product','Box'
    );
    UPDATE public.supplier_order_documents SET
        status='CONFIRMED',confirmed_by=v_actor,
        confirmed_at=clock_timestamp(),
        confirmation_idempotency_key=
            '00000000-0000-0000-0000-000000093093',
        master_version=2
    WHERE company_id=v_company AND id=v_order;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G5_PHASE11_TEST');

    v_result := public.save_goods_receipt(
        NULL,NULL,v_session,v_order,'DEL-G93','Invoice source',
        jsonb_build_array(jsonb_build_object(
            'clientLineKey','00000000-0000-0000-0000-000000093101',
            'supplierOrderLineId',v_order_line,
            'receivedUomId',v_purchase_uom,'receivedQty',1,
            'acceptedGoodQty',1,'damagedQty',0,'rejectedQty',0
        ))
    );
    v_receipt := (v_result->>'documentId')::UUID;
    PERFORM public.post_goods_receipt(
        v_receipt,1,'00000000-0000-0000-0000-000000093102'
    );
    SELECT provisional.id INTO v_provisional
    FROM public.goods_receipt_ap_provisionals provisional
    WHERE provisional.company_id=v_company
      AND provisional.receipt_id=v_receipt;

    -- Price outside zero default tolerance is persisted as EXCEPTION/HOLD,
    -- without AP Final or any stock effect.
    v_result := public.save_supplier_invoice_draft(
        NULL,NULL,v_supplier,'VENDOR-G93-EX',current_date,current_date+30,
        'EXCLUSIVE','Expected variance',NULL,
        jsonb_build_array(jsonb_build_object(
            'clientLineKey','00000000-0000-0000-0000-000000093111',
            'productId',v_product,'invoiceUomId',v_uom,
            'invoiceQty',10,'unitPrice',50,
            'allocations',jsonb_build_array(jsonb_build_object(
                'clientAllocationKey',
                    '00000000-0000-0000-0000-000000093112',
                'sourceApProvisionalId',v_provisional,'quantityBase',10
            ))
        ))
    );
    v_exception_invoice := (v_result->>'documentId')::UUID;
    IF v_result->>'matchingStatus'<>'EXCEPTION' THEN
        RAISE EXCEPTION 'TEST_FAILED: variance not classified EXCEPTION: %',
            v_result;
    END IF;
    v_result := public.validate_supplier_invoice(
        v_exception_invoice,1,
        '00000000-0000-0000-0000-000000093113'
    );
    IF v_result->>'status'<>'HOLD' THEN
        RAISE EXCEPTION 'TEST_FAILED: exception invoice not held: %',v_result;
    END IF;
    PERFORM public.cancel_supplier_invoice(
        v_exception_invoice,2,'Supplier invoice value will be corrected'
    );

    -- Exact invoice consumes the Receipt residual and creates AP Final HOLD.
    v_result := public.save_supplier_invoice_draft(
        NULL,NULL,v_supplier,'VENDOR-G93-OK',current_date,current_date+30,
        'EXCLUSIVE','Exact three-way match',NULL,
        jsonb_build_array(jsonb_build_object(
            'clientLineKey','00000000-0000-0000-0000-000000093121',
            'productId',v_product,'invoiceUomId',v_uom,
            'invoiceQty',10,'unitPrice',45,
            'allocations',jsonb_build_array(jsonb_build_object(
                'clientAllocationKey',
                    '00000000-0000-0000-0000-000000093122',
                'sourceApProvisionalId',v_provisional,'quantityBase',10
            ))
        ))
    );
    v_invoice := (v_result->>'documentId')::UUID;
    IF v_result->>'matchingStatus'<>'MATCHED' THEN
        RAISE EXCEPTION 'TEST_FAILED: exact invoice not matched: %',v_result;
    END IF;
    SELECT stock_qty INTO v_value FROM public.product_stocks
    WHERE company_id=v_company AND product_id=v_product
      AND warehouse_id=v_warehouse;
    IF v_value<>10 THEN
        RAISE EXCEPTION 'TEST_FAILED: Draft invoice changed stock: %',v_value;
    END IF;
    v_result := public.validate_supplier_invoice(
        v_invoice,1,'00000000-0000-0000-0000-000000093123'
    );
    IF v_result->>'status'<>'VALIDATED'
       OR (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: validation invalid: %',v_result;
    END IF;
    SELECT stock_qty INTO v_value FROM public.product_stocks
    WHERE company_id=v_company AND product_id=v_product
      AND warehouse_id=v_warehouse;
    IF v_value<>10 THEN
        RAISE EXCEPTION 'TEST_FAILED: validation changed stock: %',v_value;
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_movements
    WHERE company_id=v_company
      AND reference_table='supplier_invoice_documents';
    IF v_count<>0 THEN
        RAISE EXCEPTION 'TEST_FAILED: Supplier Invoice wrote Movement';
    END IF;
    SELECT count(*) INTO v_count FROM public.financial_events
    WHERE company_id=v_company
      AND source_table='supplier_invoice_documents'
      AND source_id=v_invoice AND system_event_key='SUPPLIER_INVOICE'
      AND status='HOLD';
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: AP Final HOLD Event count %',v_count;
    END IF;
    SELECT count(*) INTO v_count
    FROM public.goods_receipt_ap_provisionals provisional
    WHERE provisional.company_id=v_company AND provisional.id=v_provisional
      AND provisional.status='MATCHED';
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: provisional residual not closed';
    END IF;
    SELECT last_purchase_price INTO v_value
    FROM public.product_suppliers relation
    WHERE relation.company_id=v_company AND relation.id=v_product_supplier;
    IF v_value<>450 THEN
        RAISE EXCEPTION 'TEST_FAILED: last purchase price %, expected 450',
            v_value;
    END IF;

    v_result := public.validate_supplier_invoice(
        v_invoice,999,'00000000-0000-0000-0000-000000093123'
    );
    IF NOT (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: validation replay not idempotent';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_supplier_invoice_draft(
            NULL,NULL,v_supplier,'VENDOR-G93-DUP',current_date,NULL,
            'EXCLUSIVE',NULL,NULL,
            jsonb_build_array(jsonb_build_object(
                'clientLineKey','00000000-0000-0000-0000-000000093131',
                'productId',v_product,'invoiceUomId',v_uom,
                'invoiceQty',1,'unitPrice',45,
                'allocations',jsonb_build_array(jsonb_build_object(
                    'clientAllocationKey',
                        '00000000-0000-0000-0000-000000093132',
                    'sourceApProvisionalId',v_provisional,'quantityBase',1
                ))
            ))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='OPEN_AP_PROVISIONAL_NOT_FOUND' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: matched Receipt allocated twice';
    END IF;

    IF has_table_privilege(
        'authenticated','public.supplier_invoice_documents',
        'INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.supplier_invoice_allocations',
        'INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.validate_supplier_invoice(uuid,bigint,uuid)','EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Supplier Invoice privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: Supplier Invoice matching is source-exact, tolerance-aware, idempotent, AP-reconciled, and stock-neutral.';
END
$test$;

ROLLBACK;
