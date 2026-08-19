-- G4 phase 60 behavior: authorized online shortage and replenishment.
-- SAFETY: every fixture/final effect is rolled back.
BEGIN;

INSERT INTO auth.users(
    id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at
) VALUES(
    '00000000-0000-0000-0000-000000089091',
    'g4-phase60-negative@example.invalid',
    '00000000-0000-0000-0000-000000000000',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"name":"G4 Phase 60 Negative Test"}'::JSONB,
    FALSE,'authenticated','authenticated',clock_timestamp()
) ON CONFLICT(id) DO NOTHING;
INSERT INTO public.profiles(id,email,name,role)
VALUES(
    '00000000-0000-0000-0000-000000089091',
    'g4-phase60-negative@example.invalid','G4 Phase 60 Negative Test',
    'super_admin'::public.user_role
) ON CONFLICT(id) DO UPDATE SET
    email=EXCLUDED.email,name=EXCLUDED.name,role=EXCLUDED.role;

DO $test$
DECLARE v_actor UUID:='00000000-0000-0000-0000-000000089091';
    v_company UUID:='00000000-0000-0000-0000-000000089001';
    v_store UUID:='00000000-0000-0000-0000-000000089011';
    v_terminal UUID:='00000000-0000-0000-0000-000000089021';
    v_warehouse UUID:='00000000-0000-0000-0000-000000089031';
    v_category UUID:='00000000-0000-0000-0000-000000089041';
    v_uom UUID:='00000000-0000-0000-0000-000000089051';
    v_product UUID:='00000000-0000-0000-0000-000000089061';
    v_product_uom UUID:='00000000-0000-0000-0000-000000089071';
    v_session UUID; v_customer UUID; v_cash UUID; v_sale UUID;
    v_result JSONB; v_payload JSONB; v_value NUMERIC; v_count BIGINT;
BEGIN
    INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
    VALUES(v_company,'G89','G89 Negative Stock','g89-negative-stock','ACTIVE');
    INSERT INTO public.stores(id,company_id,store_code,store_name,status)
    VALUES(v_store,v_company,'G89S','G89 Store','ACTIVE');
    INSERT INTO public.pos_terminals(id,company_id,store_id,pos_code,pos_name,status)
    VALUES(v_terminal,v_company,v_store,'G89P','G89 POS','ACTIVE');
    INSERT INTO public.warehouses(id,company_id,code,name,warehouse_type,store_id,
        is_sale_source,is_purchase_destination,is_active)
    VALUES(v_warehouse,v_company,'G89W','G89 Warehouse','STORE',v_store,
        TRUE,FALSE,TRUE);
    INSERT INTO public.product_categories(id,company_id,category_code,category_name)
    VALUES(v_category,v_company,'G89CAT','G89 Product');
    INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,decimal_precision)
    VALUES(v_uom,v_company,'G89PCS','Piece','UNIT',FALSE,0);
    INSERT INTO public.products(id,company_id,sku,name,category,category_id,
        price,cogs,uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,
        is_active,is_bundle)
    VALUES(v_product,v_company,'G89-PROD','G89 Product','G89 Product',v_category,
        100,50,'G89PCS',v_uom,v_uom,1,TRUE,FALSE);
    INSERT INTO public.product_uoms(id,company_id,product_id,uom_id,
        factor_to_base,purchase_allowed,sales_allowed,purchase_price,sale_price,is_active)
    VALUES(v_product_uom,v_company,v_product,v_uom,1,TRUE,TRUE,50,100,TRUE);
    INSERT INTO public.product_stocks(company_id,product_id,warehouse_id,stock_qty)
    VALUES(v_company,v_product,v_warehouse,1);
    INSERT INTO public.product_batches(id,product_id,warehouse_id,qty_purchased,
        qty_remaining,cogs_unit,company_id)
    VALUES('00000000-0000-0000-0000-000000089072',v_product,v_warehouse,1,1,50,v_company);
    INSERT INTO public.stock_movements(product_id,warehouse_id,qty_change,
        movement_type,reference_table,reference_id,company_id,base_uom_id,
        base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
        movement_status,source_line_id,notes)
    VALUES(v_product,v_warehouse,1,'PURCHASE'::public.stock_movement_type,
        'G4_PHASE60_TEST','00000000-0000-0000-0000-000000089073',v_company,
        v_uom,'Piece',1,v_actor,clock_timestamp(),'POSTED',
        '00000000-0000-0000-0000-000000089074','Rollback fixture');
    PERFORM set_config('request.jwt.claims',jsonb_build_object(
        'sub',v_actor,'role','authenticated')::TEXT,TRUE);
    PERFORM public.set_active_company_context(v_company,'G4_PHASE60_TEST');
    PERFORM public.set_company_feature(v_company,'pos_negative_stock_enabled',TRUE,'{}');
    PERFORM public.save_pos_negative_stock_policy(1,TRUE,TRUE,10);
    PERFORM public.set_warehouse_negative_stock_opt_in(v_warehouse,TRUE);
    PERFORM public.save_pos_negative_stock_permission(NULL,NULL,v_warehouse,
        v_actor,10,clock_timestamp()+interval '1 day','Rollback permission',TRUE);
    SELECT id INTO v_customer FROM public.customers
    WHERE company_id=v_company AND is_system_customer ORDER BY id LIMIT 1;
    SELECT id INTO v_cash FROM public.payment_methods
    WHERE company_id=v_company AND method_type='CASH' AND is_active
    ORDER BY is_default DESC,id LIMIT 1;
    IF v_customer IS NULL OR v_cash IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: provisioned POS master missing';
    END IF;
    v_result:=public.open_cashier_session(v_terminal,v_warehouse,0);
    v_session:=(v_result->>'cashierSessionId')::UUID;
    v_payload:=jsonb_build_object(
        'clientTransactionId','00000000-0000-0000-0000-000000089101',
        'cashierSessionId',v_session,'customerId',v_customer,
        'negativeStockReason','Emergency sale approved for rollback test',
        'roundingDirection','NONE','lines',jsonb_build_array(jsonb_build_object(
            'lineKey','G89-L1','productUomId',v_product_uom,'quantity',3)),
        'payments',jsonb_build_array(jsonb_build_object(
            'clientPaymentKey','00000000-0000-0000-0000-000000089111',
            'paymentMethodId',v_cash,'amount',300,'tenderedAmount',300)));
    v_result:=public.save_pos_sale_draft(v_payload);
    v_sale:=(v_result->>'salesId')::UUID;
    v_result:=public.post_pos_sale(v_sale,(v_result->>'masterVersion')::BIGINT,
        '00000000-0000-0000-0000-000000089121');
    IF v_result->>'documentStatus'<>'POSTED' THEN
        RAISE EXCEPTION 'TEST_FAILED: authorized Sale not posted: %',v_result;
    END IF;
    SELECT stock_qty INTO v_value FROM public.product_stocks
    WHERE company_id=v_company AND product_id=v_product AND warehouse_id=v_warehouse;
    IF v_value<>-2 THEN RAISE EXCEPTION 'TEST_FAILED: stock %, expected -2',v_value; END IF;
    SELECT count(*) INTO v_count FROM public.pos_negative_stock_authorizations authz
    JOIN public.negative_stock_sale_allocations allocation
      ON allocation.company_id=authz.company_id AND allocation.authorization_id=authz.id
    WHERE authz.company_id=v_company AND authz.sales_id=v_sale
      AND authz.shortage_base_qty=2 AND allocation.shortage_base_qty=2
      AND allocation.provisional_cost_total=100;
    IF v_count<>1 THEN RAISE EXCEPTION 'TEST_FAILED: authorization/allocation invalid'; END IF;
    INSERT INTO public.product_batches(id,product_id,warehouse_id,qty_purchased,
        qty_remaining,cogs_unit,company_id)
    VALUES('00000000-0000-0000-0000-000000089131',v_product,v_warehouse,5,5,60,v_company);
    UPDATE public.product_stocks SET stock_qty=stock_qty+5
    WHERE company_id=v_company AND product_id=v_product AND warehouse_id=v_warehouse;
    INSERT INTO public.stock_movements(product_id,warehouse_id,qty_change,
        movement_type,reference_table,reference_id,company_id,base_uom_id,
        base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
        movement_status,source_line_id,notes)
    VALUES(v_product,v_warehouse,5,'PURCHASE'::public.stock_movement_type,
        'G4_PHASE60_REPLENISH','00000000-0000-0000-0000-000000089132',v_company,
        v_uom,'Piece',3,v_actor,clock_timestamp(),'POSTED',
        '00000000-0000-0000-0000-000000089133','Rollback replenishment');
    SELECT count(*) INTO v_count FROM public.negative_stock_sale_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.sales_id=v_sale
      AND allocation.replenished_base_qty=2 AND allocation.reconciled_at IS NOT NULL
      AND allocation.actual_cost_total=120 AND allocation.cost_variance_total=20;
    IF v_count<>1 THEN RAISE EXCEPTION 'TEST_FAILED: replenishment reconciliation invalid'; END IF;
    SELECT qty_remaining INTO v_value FROM public.product_batches
    WHERE id='00000000-0000-0000-0000-000000089131';
    IF v_value<>3 THEN RAISE EXCEPTION 'TEST_FAILED: replenishment FIFO %, expected 3',v_value; END IF;

    RAISE NOTICE 'TEST PASSED: authorized online shortage is atomic, provisional-costed, source-linked, and automatically reconciled by incoming FIFO.';
END
$test$;
ROLLBACK;
