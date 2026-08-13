-- SLD phase 2 behavior: Invoice snapshot and delivery-only Surat Jalan.
-- SAFETY: all fixtures, Sale/Stock/Finance effects, documents, and audit rollback.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID:='00000000-0000-0000-0000-000000121001';
    v_company_b UUID:='00000000-0000-0000-0000-000000121002';
    v_store UUID:='00000000-0000-0000-0000-000000121011';
    v_terminal UUID:='00000000-0000-0000-0000-000000121021';
    v_warehouse UUID:='00000000-0000-0000-0000-000000121031';
    v_category UUID:='00000000-0000-0000-0000-000000121041';
    v_uom UUID:='00000000-0000-0000-0000-000000121051';
    v_product UUID:='00000000-0000-0000-0000-000000121061';
    v_product_uom UUID:='00000000-0000-0000-0000-000000121071';
    v_customer UUID:='00000000-0000-0000-0000-000000121081';
    v_customer_category UUID; v_cash UUID; v_session UUID;
    v_pickup_sale UUID; v_delivery_sale UUID; v_delivery_document UUID;
    v_result JSONB; v_payload JSONB; v_count BIGINT; v_version BIGINT;
    v_rejected BOOLEAN; v_logo_path TEXT;
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
        id,company_code,company_name,company_slug,legal_name,status
    ) VALUES
        (v_company,'SLD121A','SLD Company A','sld-company-a',
         'SLD Company A Legal','ACTIVE'),
        (v_company_b,'SLD121B','SLD Company B','sld-company-b',
         'SLD Company B Legal','ACTIVE');
    INSERT INTO public.stores(
        id,company_id,store_code,store_name,address,status
    ) VALUES(v_store,v_company,'SLD-S','SLD Store','Store Address','ACTIVE');
    INSERT INTO public.pos_terminals(
        id,company_id,store_id,pos_code,pos_name,status
    ) VALUES(v_terminal,v_company,v_store,'SLD-P','SLD POS','ACTIVE');
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,store_id,
        is_sale_source,is_purchase_destination,is_active
    ) VALUES(
        v_warehouse,v_company,'SLD-W','SLD Warehouse','STORE',v_store,
        TRUE,FALSE,TRUE
    );
    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES(v_category,v_company,'SLD-CAT','SLD Product');
    INSERT INTO public.uoms(
        id,company_id,code,name,uom_type,allow_decimal,decimal_precision
    ) VALUES(v_uom,v_company,'SLD-PCS','Piece','UNIT',FALSE,0);
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES(
        v_product,v_company,'SLD-PROD','SLD Product','SLD Product',
        v_category,100,50,'SLD-PCS',v_uom,v_uom,1,TRUE,FALSE
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
        '00000000-0000-0000-0000-000000121072',v_product,v_warehouse,
        10,10,50,v_company
    );
    INSERT INTO public.stock_movements(
        product_id,warehouse_id,qty_change,movement_type,
        reference_table,reference_id,company_id,base_uom_id,
        base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
        movement_status,source_line_id,notes
    ) VALUES(
        v_product,v_warehouse,10,'PURCHASE'::public.stock_movement_type,
        'SLD_PHASE2_TEST','00000000-0000-0000-0000-000000121073',
        v_company,v_uom,'Piece',10,v_actor,clock_timestamp(),'POSTED',
        '00000000-0000-0000-0000-000000121074','Rollback fixture'
    );

    SELECT category.id INTO v_customer_category
    FROM public.customer_categories category
    WHERE category.company_id=v_company AND category.is_system_category
    ORDER BY category.id LIMIT 1;
    INSERT INTO public.customers(
        id,company_id,code,name,customer_category_id,phone,address,
        customer_type,current_balance,credit_limit,is_active,is_system_customer
    ) VALUES(
        v_customer,v_company,'SLD-CUST','SLD Customer',v_customer_category,
        '0800000000','Customer Address','INDIVIDUAL',0,0,TRUE,FALSE
    );

    v_logo_path:=v_company::TEXT||'/logo/v1-'||repeat('a',12)||'.png';
    INSERT INTO storage.objects(bucket_id,name)
    VALUES('company-branding',v_logo_path);

    PERFORM set_config(
        'request.jwt.claims',jsonb_build_object(
            'sub',v_actor,'role','authenticated'
        )::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'SLD_PHASE2_TEST');
    PERFORM public.save_company_branding_logo(
        NULL,v_logo_path,
        'https://example.invalid/storage/v1/object/public/company-branding/'
            ||v_logo_path,
        'image/png',100,repeat('a',64)
    );

    SELECT method.id INTO v_cash FROM public.payment_methods method
    WHERE method.company_id=v_company AND method.method_type='CASH'
      AND method.is_active ORDER BY method.is_default DESC,method.id LIMIT 1;
    IF v_cash IS NULL OR v_customer_category IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: provisioned master missing';
    END IF;
    v_result:=public.open_cashier_session(v_terminal,v_warehouse,100);
    v_session:=(v_result->>'cashierSessionId')::UUID;

    -- PICKUP: exactly one Invoice and no Surat Jalan.
    v_payload:=jsonb_build_object(
        'clientTransactionId','00000000-0000-0000-0000-000000121101',
        'cashierSessionId',v_session,'customerId',v_customer,
        'roundingDirection','NONE','fulfillmentMode','PICKUP',
        'lines',jsonb_build_array(jsonb_build_object(
            'lineKey','SLD-PICKUP-L1','productUomId',v_product_uom,'quantity',1
        )),
        'payments',jsonb_build_array(jsonb_build_object(
            'clientPaymentKey','00000000-0000-0000-0000-000000121111',
            'paymentMethodId',v_cash,'amount',100,'tenderedAmount',100
        ))
    );
    v_result:=public.save_pos_sale_draft(v_payload);
    v_pickup_sale:=(v_result->>'salesId')::UUID;
    v_result:=public.post_pos_sale(
        v_pickup_sale,(v_result->>'masterVersion')::BIGINT,
        '00000000-0000-0000-0000-000000121121'
    );
    SET CONSTRAINTS sld_finalize_posted_sale IMMEDIATE;
    SET CONSTRAINTS sld_finalize_posted_sale DEFERRED;
    SELECT count(*) INTO v_count FROM public.sales_invoice_snapshots invoice
    WHERE invoice.company_id=v_company AND invoice.sales_id=v_pickup_sale
      AND invoice.snapshot_provenance='LIVE_POST'
      AND invoice.branding_logo_object_path=v_logo_path;
    IF v_count<>1 OR EXISTS(
        SELECT 1 FROM public.sales_delivery_documents delivery
        WHERE delivery.company_id=v_company AND delivery.sales_id=v_pickup_sale
    ) THEN RAISE EXCEPTION 'TEST_FAILED: Pickup document shape invalid'; END IF;

    -- DELIVERY: configuration is versioned, then finalization is atomic.
    v_payload:=jsonb_set(v_payload,'{clientTransactionId}',
        '"00000000-0000-0000-0000-000000121102"'::JSONB);
    v_payload:=jsonb_set(v_payload,'{lines,0,lineKey}',
        '"SLD-DELIVERY-L1"'::JSONB);
    v_payload:=jsonb_set(v_payload,'{payments,0,clientPaymentKey}',
        '"00000000-0000-0000-0000-000000121112"'::JSONB);
    v_result:=public.save_pos_sale_draft(v_payload);
    v_delivery_sale:=(v_result->>'salesId')::UUID;
    v_result:=public.configure_pos_sale_fulfillment(
        v_delivery_sale,(v_result->>'masterVersion')::BIGINT,'DELIVERY',
        'Receiving Person','0811111111','Delivery Address',
        clock_timestamp()+interval '1 day','Handle carefully'
    );
    v_version:=(v_result->>'masterVersion')::BIGINT;
    v_result:=public.post_pos_sale(
        v_delivery_sale,v_version,
        '00000000-0000-0000-0000-000000121122'
    );
    SET CONSTRAINTS sld_finalize_posted_sale IMMEDIATE;
    SET CONSTRAINTS sld_finalize_posted_sale DEFERRED;

    SELECT delivery.id INTO v_delivery_document
    FROM public.sales_delivery_documents delivery
    WHERE delivery.company_id=v_company AND delivery.sales_id=v_delivery_sale
      AND delivery.delivery_no~'^SJ/[0-9]{4}/[0-9]{2}/[0-9]{6}$'
      AND delivery.status='READY';
    IF v_delivery_document IS NULL OR (
        SELECT count(*) FROM public.sales_delivery_lines line
        WHERE line.company_id=v_company
          AND line.delivery_document_id=v_delivery_document
    )<>1 THEN RAISE EXCEPTION 'TEST_FAILED: Delivery document invalid'; END IF;

    -- Exact retry cannot duplicate document, Stock, Payment, or Event.
    PERFORM public.post_pos_sale(
        v_delivery_sale,v_version,
        '00000000-0000-0000-0000-000000121122'
    );
    SET CONSTRAINTS sld_finalize_posted_sale IMMEDIATE;
    SET CONSTRAINTS sld_finalize_posted_sale DEFERRED;
    SELECT count(*) INTO v_count
    FROM public.sales_delivery_documents delivery
    WHERE delivery.company_id=v_company AND delivery.sales_id=v_delivery_sale;
    IF v_count<>1 OR (
        SELECT count(*) FROM public.financial_events event
        WHERE event.company_id=v_company
          AND event.source_table='sales_headers'
          AND event.source_id=v_delivery_sale
          AND event.event_type='SALE_POSTED'::public.event_type
    )<>1 OR (
        SELECT count(*) FROM public.stock_movements movement
        WHERE movement.company_id=v_company
          AND movement.reference_table='sales_headers'
          AND movement.reference_id=v_delivery_sale
    )<>1 THEN RAISE EXCEPTION 'TEST_FAILED: retry duplicated final effect'; END IF;

    -- Lifecycle and print are audited without a second Stock/Finance effect.
    v_result:=public.update_sales_delivery_status(
        v_delivery_document,1,'DISPATCH',NULL
    );
    v_result:=public.update_sales_delivery_status(
        v_delivery_document,(v_result->>'masterVersion')::BIGINT,'DELIVER',NULL
    );
    PERFORM public.record_sales_document_print(
        'SALES_DELIVERY',v_delivery_document
    );
    SELECT count(*) INTO v_count FROM public.sales_document_audit audit
    WHERE audit.company_id=v_company AND audit.document_id=v_delivery_document
      AND audit.action IN ('CREATE','DISPATCH','DELIVER','PRINT');
    IF v_count<>4 THEN
        RAISE EXCEPTION 'TEST_FAILED: Delivery lifecycle audit invalid';
    END IF;
    IF NOT public.company_branding_logo_is_referenced(v_logo_path) THEN
        RAISE EXCEPTION 'TEST_FAILED: finalized logo reference not retained';
    END IF;

    -- Immutable snapshot and cross-Company access fail closed.
    v_rejected:=FALSE;
    BEGIN
        UPDATE public.sales_invoice_snapshots SET snapshot_version=2
        WHERE company_id=v_company AND sales_id=v_delivery_sale;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='FINAL_SALES_DOCUMENT_HISTORY_IMMUTABLE' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: Invoice history mutable';
    END IF;

    PERFORM public.set_active_company_context(v_company_b,'SLD_PHASE2_TEST');
    v_rejected:=FALSE;
    BEGIN
        PERFORM public.get_sales_invoice_document(v_delivery_sale);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='SALES_DOCUMENT_NOT_FOUND' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company Invoice readable';
    END IF;

    IF has_table_privilege(
        'authenticated','public.sales_invoice_snapshots','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.sales_delivery_documents','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.sales_delivery_lines','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated','public.get_sales_invoice_document(uuid)','EXECUTE'
    ) THEN RAISE EXCEPTION 'TEST_FAILED: browser boundary invalid'; END IF;

    RAISE NOTICE 'TEST PASSED: Invoice and delivery-only Surat Jalan are tenant-safe, immutable, idempotent, audited, and zero-extra-effect.';
END
$test$;

ROLLBACK;
