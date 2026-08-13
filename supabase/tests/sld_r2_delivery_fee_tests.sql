-- SLD-R2 behavior: delivery fee is server-authoritative and retry-safe.
-- SAFETY: every fixture and final transaction effect is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID:='00000000-0000-0000-0000-000000122001';
    v_store UUID:='00000000-0000-0000-0000-000000122011';
    v_terminal UUID:='00000000-0000-0000-0000-000000122021';
    v_warehouse UUID:='00000000-0000-0000-0000-000000122031';
    v_category UUID:='00000000-0000-0000-0000-000000122041';
    v_uom UUID:='00000000-0000-0000-0000-000000122051';
    v_product UUID:='00000000-0000-0000-0000-000000122061';
    v_product_uom UUID:='00000000-0000-0000-0000-000000122071';
    v_customer UUID:='00000000-0000-0000-0000-000000122081';
    v_customer_category UUID; v_cash UUID; v_session UUID; v_sale UUID;
    v_payload JSONB; v_result JSONB; v_version BIGINT; v_count BIGINT;
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
    ) VALUES(v_company,'SLD122','SLD R2 Company','sld-r2-company','ACTIVE');
    INSERT INTO public.stores(
        id,company_id,store_code,store_name,address,status
    ) VALUES(v_store,v_company,'SLD-R2-S','SLD R2 Store','Store','ACTIVE');
    INSERT INTO public.pos_terminals(
        id,company_id,store_id,pos_code,pos_name,status
    ) VALUES(v_terminal,v_company,v_store,'SLD-R2-P','SLD R2 POS','ACTIVE');
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,store_id,
        is_sale_source,is_active
    ) VALUES(
        v_warehouse,v_company,'SLD-R2-W','SLD R2 Warehouse','STORE',
        v_store,TRUE,TRUE
    );
    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES(v_category,v_company,'SLD-R2-C','SLD R2 Product');
    INSERT INTO public.uoms(
        id,company_id,code,name,uom_type,allow_decimal,decimal_precision
    ) VALUES(v_uom,v_company,'SLD-R2-U','Piece','UNIT',FALSE,0);
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES(
        v_product,v_company,'SLD-R2-PROD','SLD R2 Product','SLD R2 Product',
        v_category,100,50,'SLD-R2-U',v_uom,v_uom,1,TRUE,FALSE
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
    ) VALUES(v_company,v_product,v_warehouse,5);
    INSERT INTO public.product_batches(
        id,product_id,warehouse_id,qty_purchased,qty_remaining,cogs_unit,
        company_id
    ) VALUES(
        '00000000-0000-0000-0000-000000122072',v_product,v_warehouse,
        5,5,50,v_company
    );
    INSERT INTO public.stock_movements(
        product_id,warehouse_id,qty_change,movement_type,
        reference_table,reference_id,company_id,base_uom_id,
        base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
        movement_status,source_line_id,notes
    ) VALUES(
        v_product,v_warehouse,5,'PURCHASE'::public.stock_movement_type,
        'SLD_R2_TEST','00000000-0000-0000-0000-000000122073',v_company,
        v_uom,'Piece',5,v_actor,clock_timestamp(),'POSTED',
        '00000000-0000-0000-0000-000000122074','Rollback fixture'
    );

    SELECT category.id INTO v_customer_category
    FROM public.customer_categories category
    WHERE category.company_id=v_company AND category.is_system_category
    ORDER BY category.id LIMIT 1;
    INSERT INTO public.customers(
        id,company_id,code,name,customer_category_id,phone,address,
        customer_type,current_balance,credit_limit,is_active,is_system_customer
    ) VALUES(
        v_customer,v_company,'SLD-R2-CUST','SLD R2 Customer',
        v_customer_category,'0800000000','Customer Address','INDIVIDUAL',
        0,0,TRUE,FALSE
    );

    PERFORM set_config('request.jwt.claims',jsonb_build_object(
        'sub',v_actor,'role','authenticated'
    )::TEXT,TRUE);
    PERFORM public.set_active_company_context(v_company,'SLD_R2_TEST');
    SELECT method.id INTO v_cash FROM public.payment_methods method
    WHERE method.company_id=v_company AND method.method_type='CASH'
      AND method.is_active ORDER BY method.is_default DESC,method.id LIMIT 1;
    IF v_cash IS NULL OR v_customer_category IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: provisioned master missing';
    END IF;
    v_result:=public.open_cashier_session(v_terminal,v_warehouse,100);
    v_session:=(v_result->>'cashierSessionId')::UUID;

    -- A Pickup cannot charge delivery fee.
    v_rejected:=FALSE;
    BEGIN
        PERFORM public.save_pos_sale_draft(jsonb_build_object(
            'clientTransactionId','00000000-0000-0000-0000-000000122101',
            'cashierSessionId',v_session,'customerId',v_customer,
            'fulfillmentMode','PICKUP','deliveryFeeAmount',25,
            'lines',jsonb_build_array(jsonb_build_object(
                'lineKey','SLD-R2-REJECT','productUomId',v_product_uom,
                'quantity',1
            )),'payments','[]'::JSONB
        ));
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='PICKUP_DELIVERY_FEE_NOT_ALLOWED' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: Pickup delivery fee accepted';
    END IF;

    v_payload:=jsonb_build_object(
        'clientTransactionId','00000000-0000-0000-0000-000000122102',
        'cashierSessionId',v_session,'customerId',v_customer,
        'roundingDirection','NONE','fulfillmentMode','DELIVERY',
        'deliveryRecipientName','Receiving Person',
        'deliveryRecipientPhone','0811111111',
        'deliveryAddress','Delivery Address',
        'deliveryFeeAmount',25,
        'deliveryFeeInvoiceDisplayMode','HIDE_BREAKDOWN',
        'lines',jsonb_build_array(jsonb_build_object(
            'lineKey','SLD-R2-L1','productUomId',v_product_uom,'quantity',1
        )),
        'payments',jsonb_build_array(jsonb_build_object(
            'clientPaymentKey','00000000-0000-0000-0000-000000122112',
            'paymentMethodId',v_cash,'amount',125,'tenderedAmount',125
        ))
    );
    v_result:=public.save_pos_sale_draft(v_payload);
    v_sale:=(v_result->>'salesId')::UUID;
    v_version:=(v_result->>'masterVersion')::BIGINT;
    IF (v_result->>'grandTotalAfterRounding')::NUMERIC<>125 THEN
        RAISE EXCEPTION 'TEST_FAILED: delivery fee missing from Draft total';
    END IF;

    -- Re-save the same Draft: fee stays 25, total stays 125.
    v_payload:=v_payload||jsonb_build_object(
        'saleId',v_sale,'masterVersion',v_version
    );
    v_result:=public.save_pos_sale_draft(v_payload);
    v_version:=(v_result->>'masterVersion')::BIGINT;
    IF (v_result->>'grandTotalAfterRounding')::NUMERIC<>125 OR EXISTS(
        SELECT 1 FROM public.sales_headers sale
        WHERE sale.company_id=v_company AND sale.id=v_sale
          AND (sale.delivery_fee_amount<>25
               OR sale.grand_total_after_rounding<>125)
    ) THEN RAISE EXCEPTION 'TEST_FAILED: Draft fee retry compounded'; END IF;

    PERFORM public.post_pos_sale(
        v_sale,v_version,'00000000-0000-0000-0000-000000122122'
    );
    SET CONSTRAINTS sld_finalize_posted_sale IMMEDIATE;
    SET CONSTRAINTS sld_finalize_posted_sale DEFERRED;

    IF NOT EXISTS(
        SELECT 1 FROM public.sales_headers sale
        WHERE sale.company_id=v_company AND sale.id=v_sale
          AND sale.document_status='POSTED'
          AND sale.delivery_fee_amount=25
          AND sale.grand_total_after_rounding=125
          AND sale.paid_amount=125 AND sale.sisa_piutang=0
          AND (sale.receipt_snapshot->>'deliveryFeeAmount')::NUMERIC=25
    ) THEN RAISE EXCEPTION 'TEST_FAILED: posted Sale fee invalid'; END IF;

    IF NOT EXISTS(
        SELECT 1 FROM public.sales_invoice_snapshots invoice
        WHERE invoice.company_id=v_company AND invoice.sales_id=v_sale
          AND (invoice.snapshot_payload->'totals'
                ->>'deliveryFee')::NUMERIC=25
          AND invoice.snapshot_payload->'totals'
                ->>'deliveryFeeInvoiceDisplayMode'='HIDE_BREAKDOWN'
          AND (invoice.snapshot_payload->'totals'
                ->>'grandTotal')::NUMERIC=125
    ) THEN RAISE EXCEPTION 'TEST_FAILED: Invoice fee snapshot invalid'; END IF;

    IF NOT EXISTS(
        SELECT 1 FROM public.financial_events event
        WHERE event.company_id=v_company AND event.source_id=v_sale
          AND event.system_event_key='SALE_POSTED'
          AND (event.amounts->>'deliveryFee')::NUMERIC=25
          AND (event.amounts->>'netSalesInclusiveTax')::NUMERIC=100
          AND (event.amounts->>'grandTotal')::NUMERIC=125
    ) THEN RAISE EXCEPTION 'TEST_FAILED: Finance fee snapshot invalid'; END IF;

    SELECT count(*) INTO v_count
    FROM public.chart_of_accounts account
    JOIN public.company_account_function_fallbacks fallback
      ON fallback.company_id=account.company_id
     AND fallback.account_id=account.id AND fallback.status='ACTIVE'
    WHERE account.company_id=v_company AND account.is_active
      AND account.system_function_key='DELIVERY_FEE_REVENUE'
      AND fallback.account_function_key='DELIVERY_FEE_REVENUE';
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: delivery revenue mapping invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: delivery fee is server-authoritative, retry-safe, payment-reconciled, and separately snapshotted for Finance.';
END
$test$;

ROLLBACK;
