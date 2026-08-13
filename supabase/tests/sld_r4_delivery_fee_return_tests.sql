-- SLD-R4 behavior: Delivery-fee refund is explicit and full-Return only.
-- SAFETY: every Sale, Return, Stock, Payment, audit, and event row rolls back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID:='00000000-0000-0000-0000-000000124001';
    v_store UUID:='00000000-0000-0000-0000-000000124011';
    v_terminal UUID:='00000000-0000-0000-0000-000000124021';
    v_warehouse UUID:='00000000-0000-0000-0000-000000124031';
    v_category UUID:='00000000-0000-0000-0000-000000124041';
    v_uom UUID:='00000000-0000-0000-0000-000000124051';
    v_product UUID:='00000000-0000-0000-0000-000000124061';
    v_product_uom UUID:='00000000-0000-0000-0000-000000124071';
    v_customer UUID:='00000000-0000-0000-0000-000000124081';
    v_customer_category UUID;
    v_cash UUID;
    v_session UUID;
    v_sale UUID;
    v_detail UUID;
    v_document UUID;
    v_payload JSONB;
    v_result JSONB;
    v_version BIGINT;
    v_rejected BOOLEAN;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role='super_admin'::public.user_role
    ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES(v_company,'SLD124','SLD R4 Company','sld-r4-company','ACTIVE');
    INSERT INTO public.stores(
        id,company_id,store_code,store_name,address,status
    ) VALUES(v_store,v_company,'SLD-R4-S','SLD R4 Store','Store','ACTIVE');
    INSERT INTO public.pos_terminals(
        id,company_id,store_id,pos_code,pos_name,status
    ) VALUES(v_terminal,v_company,v_store,'SLD-R4-P','SLD R4 POS','ACTIVE');
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,store_id,
        is_sale_source,is_active
    ) VALUES(
        v_warehouse,v_company,'SLD-R4-W','SLD R4 Warehouse','STORE',
        v_store,TRUE,TRUE
    );
    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES(v_category,v_company,'SLD-R4-C','SLD R4 Product');
    INSERT INTO public.uoms(
        id,company_id,code,name,uom_type,allow_decimal,decimal_precision
    ) VALUES(v_uom,v_company,'SLD-R4-U','Piece','UNIT',FALSE,0);
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES(
        v_product,v_company,'SLD-R4-PROD','SLD R4 Product','SLD R4 Product',
        v_category,100,50,'SLD-R4-U',v_uom,v_uom,1,TRUE,FALSE
    );
    INSERT INTO public.product_uoms(
        id,company_id,product_id,uom_id,factor_to_base,
        purchase_allowed,sales_allowed,purchase_price,sale_price,is_active
    ) VALUES(
        v_product_uom,v_company,v_product,v_uom,1,
        TRUE,TRUE,50,100,TRUE
    );
    INSERT INTO public.product_stocks(
        company_id,product_id,warehouse_id,stock_qty
    ) VALUES(v_company,v_product,v_warehouse,10);
    INSERT INTO public.product_batches(
        id,product_id,warehouse_id,qty_purchased,qty_remaining,cogs_unit,
        company_id
    ) VALUES(
        '00000000-0000-0000-0000-000000124072',v_product,v_warehouse,
        10,10,50,v_company
    );
    INSERT INTO public.stock_movements(
        product_id,warehouse_id,qty_change,movement_type,
        reference_table,reference_id,company_id,base_uom_id,
        base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
        movement_status,source_line_id,notes
    ) VALUES(
        v_product,v_warehouse,10,'PURCHASE'::public.stock_movement_type,
        'SLD_R4_TEST','00000000-0000-0000-0000-000000124073',v_company,
        v_uom,'Piece',10,v_actor,clock_timestamp(),'POSTED',
        '00000000-0000-0000-0000-000000124074','Rollback fixture'
    );

    SELECT category.id INTO v_customer_category
    FROM public.customer_categories category
    WHERE category.company_id=v_company AND category.is_system_category
    ORDER BY category.id LIMIT 1;
    INSERT INTO public.customers(
        id,company_id,code,name,customer_category_id,phone,address,
        customer_type,current_balance,credit_limit,is_active,is_system_customer
    ) VALUES(
        v_customer,v_company,'SLD-R4-CUST','SLD R4 Customer',
        v_customer_category,'0800000000','Customer Address','INDIVIDUAL',
        0,0,TRUE,FALSE
    );

    PERFORM set_config('request.jwt.claims',jsonb_build_object(
        'sub',v_actor,'role','authenticated'
    )::TEXT,TRUE);
    PERFORM public.set_active_company_context(v_company,'SLD_R4_TEST');
    SELECT method.id INTO v_cash FROM public.payment_methods method
    WHERE method.company_id=v_company AND method.method_type='CASH'
      AND method.is_active ORDER BY method.is_default DESC,method.id LIMIT 1;
    IF v_cash IS NULL OR v_customer_category IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: provisioned master missing';
    END IF;
    v_result:=public.open_cashier_session(v_terminal,v_warehouse,100);
    v_session:=(v_result->>'cashierSessionId')::UUID;

    v_payload:=jsonb_build_object(
        'clientTransactionId','00000000-0000-0000-0000-000000124101',
        'cashierSessionId',v_session,'customerId',v_customer,
        'roundingDirection','NONE','fulfillmentMode','DELIVERY',
        'deliveryRecipientName','Receiving Person',
        'deliveryRecipientPhone','0811111111',
        'deliveryAddress','Delivery Address','deliveryFeeAmount',25,
        'deliveryFeeInvoiceDisplayMode','SHOW_SEPARATE',
        'lines',jsonb_build_array(jsonb_build_object(
            'lineKey','SLD-R4-L1','productUomId',v_product_uom,'quantity',2
        )),
        'payments',jsonb_build_array(jsonb_build_object(
            'clientPaymentKey','00000000-0000-0000-0000-000000124112',
            'paymentMethodId',v_cash,'amount',225,'tenderedAmount',225
        ))
    );
    v_result:=public.save_pos_sale_draft(v_payload);
    v_sale:=(v_result->>'salesId')::UUID;
    v_version:=(v_result->>'masterVersion')::BIGINT;
    PERFORM public.post_pos_sale(
        v_sale,v_version,'00000000-0000-0000-0000-000000124122'
    );
    SET CONSTRAINTS sld_finalize_posted_sale IMMEDIATE;
    SET CONSTRAINTS sld_finalize_posted_sale DEFERRED;
    SELECT detail.id INTO v_detail
    FROM public.sales_details detail
    WHERE detail.company_id=v_company AND detail.sales_id=v_sale;

    -- Partial Return can never request Delivery fee.
    v_rejected:=FALSE;
    BEGIN
        PERFORM public.save_sales_return_draft_with_delivery_fee(
            NULL,NULL,v_sale,v_session,'NONE','Partial fee must fail',
            jsonb_build_array(jsonb_build_object(
                'sourceSalesDetailId',v_detail,'quantity',1,
                'condition','SALEABLE'
            )),
            jsonb_build_array(jsonb_build_object(
                'clientRefundKey',gen_random_uuid(),
                'paymentMethodId',v_cash,'amount',125
            )),TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='DELIVERY_FEE_REFUND_FULL_RETURN_REQUIRED' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: partial Return accepted Delivery fee';
    END IF;

    -- Full Return defaults to Product-only refund when fee is not requested.
    v_result:=public.save_sales_return_draft_with_delivery_fee(
        NULL,NULL,v_sale,v_session,'NONE','Full Product-only refund',
        jsonb_build_array(jsonb_build_object(
            'sourceSalesDetailId',v_detail,'quantity',2,
            'condition','SALEABLE'
        )),
        jsonb_build_array(jsonb_build_object(
            'clientRefundKey',gen_random_uuid(),
            'paymentMethodId',v_cash,'amount',200
        )),FALSE
    );
    v_document:=(v_result->>'documentId')::UUID;
    IF (v_result->>'refundTotal')::NUMERIC<>200 OR EXISTS(
        SELECT 1 FROM public.sales_return_documents document
        WHERE document.id=v_document AND (
            document.delivery_fee_refund_requested
            OR document.delivery_fee_refund_amount<>0
            OR document.source_delivery_fee_amount_snapshot<>25
        )
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Product-only full Return total invalid';
    END IF;
    PERFORM public.cancel_sales_return_draft(
        v_document,(v_result->>'masterVersion')::BIGINT,
        'Rollback fixture replaced by explicit fee Return'
    );

    -- Explicit full Return includes the fee and snapshots approval/event data.
    v_result:=public.save_sales_return_draft_with_delivery_fee(
        NULL,NULL,v_sale,v_session,'NONE','Full refund with Delivery fee',
        jsonb_build_array(jsonb_build_object(
            'sourceSalesDetailId',v_detail,'quantity',2,
            'condition','SALEABLE'
        )),
        jsonb_build_array(jsonb_build_object(
            'clientRefundKey',gen_random_uuid(),
            'paymentMethodId',v_cash,'amount',225
        )),TRUE
    );
    v_document:=(v_result->>'documentId')::UUID;
    v_result:=public.post_sales_return(
        v_document,(v_result->>'masterVersion')::BIGINT,
        '00000000-0000-0000-0000-000000124132'
    );
    IF v_result->>'status'<>'POSTED' OR NOT EXISTS(
        SELECT 1 FROM public.sales_return_documents document
        WHERE document.id=v_document
          AND document.refund_total=225
          AND document.delivery_fee_refund_requested
          AND document.delivery_fee_refund_amount=25
          AND document.delivery_fee_refund_decided_by=v_actor
          AND document.delivery_fee_refund_decided_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: explicit Delivery-fee refund invalid';
    END IF;
    IF NOT EXISTS(
        SELECT 1 FROM public.financial_events event
        WHERE event.company_id=v_company
          AND event.source_table='sales_return_documents'
          AND event.source_id=v_document
          AND (event.amounts->>'deliveryFeeRefundRequested')::BOOLEAN
          AND (event.amounts->>'deliveryFeeRefund')::NUMERIC=25
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: refund Event fee snapshot missing';
    END IF;
    IF has_table_privilege(
        'authenticated','public.sales_return_documents','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.save_sales_return_draft_with_delivery_fee(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb,boolean)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Return write boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: Delivery fee refund is explicit, full-Return-only, approval-snapshotted, payment-balanced, and event-audited.';
END
$test$;

ROLLBACK;
