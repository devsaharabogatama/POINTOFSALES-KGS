-- G4 phase 56 behavior: full Customer Balance tender is atomic and exact.
-- SAFETY: all fixtures, Sale effects, ledger, Event, and audit are rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID:='00000000-0000-0000-0000-000000086001';
    v_store UUID:='00000000-0000-0000-0000-000000086011';
    v_terminal UUID:='00000000-0000-0000-0000-000000086021';
    v_warehouse UUID:='00000000-0000-0000-0000-000000086031';
    v_category UUID:='00000000-0000-0000-0000-000000086041';
    v_uom UUID:='00000000-0000-0000-0000-000000086051';
    v_product UUID:='00000000-0000-0000-0000-000000086061';
    v_product_uom UUID:='00000000-0000-0000-0000-000000086071';
    v_customer UUID:='00000000-0000-0000-0000-000000086081';
    v_customer_category UUID; v_cash UUID; v_balance_method UUID;
    v_session UUID; v_sale UUID; v_partial_sale UUID; v_short_sale UUID;
    v_result JSONB; v_payload JSONB; v_count BIGINT; v_value NUMERIC;
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
    ) VALUES(v_company,'G86','G86 Balance Tender','g86-balance-tender','ACTIVE');
    INSERT INTO public.stores(id,company_id,store_code,store_name,status)
    VALUES(v_store,v_company,'G86S','G86 Store','ACTIVE');
    INSERT INTO public.pos_terminals(
        id,company_id,store_id,pos_code,pos_name,status
    ) VALUES(v_terminal,v_company,v_store,'G86P','G86 POS','ACTIVE');
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,store_id,
        is_sale_source,is_purchase_destination,is_active
    ) VALUES(
        v_warehouse,v_company,'G86W','G86 Warehouse','STORE',v_store,
        TRUE,FALSE,TRUE
    );
    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES(v_category,v_company,'G86CAT','G86 Product');
    INSERT INTO public.uoms(
        id,company_id,code,name,uom_type,allow_decimal,decimal_precision
    ) VALUES(v_uom,v_company,'G86PCS','Piece','UNIT',FALSE,0);
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES(
        v_product,v_company,'G86-PROD','G86 Product','G86 Product',
        v_category,100,50,'G86PCS',v_uom,v_uom,1,TRUE,FALSE
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
        '00000000-0000-0000-0000-000000086072',v_product,v_warehouse,
        5,5,50,v_company
    );
    INSERT INTO public.stock_movements(
        product_id,warehouse_id,qty_change,movement_type,
        reference_table,reference_id,company_id,base_uom_id,
        base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
        movement_status,source_line_id,notes
    ) VALUES(
        v_product,v_warehouse,5,'PURCHASE'::public.stock_movement_type,
        'G4_PHASE56_TEST','00000000-0000-0000-0000-000000086073',
        v_company,v_uom,'Piece',5,v_actor,clock_timestamp(),'POSTED',
        '00000000-0000-0000-0000-000000086074','Rollback fixture'
    );

    SELECT id INTO v_customer_category
    FROM public.customer_categories
    WHERE company_id=v_company AND is_system_category
    ORDER BY id LIMIT 1;
    INSERT INTO public.customers(
        id,company_id,code,name,customer_category_id,customer_type,
        current_balance,credit_limit,is_active,is_system_customer
    ) VALUES(
        v_customer,v_company,'G86-CUST','G86 Customer',v_customer_category,
        'INDIVIDUAL',60,0,TRUE,FALSE
    );
    INSERT INTO public.company_features(
        company_id,feature_code,is_enabled,config,updated_by
    ) VALUES(
        v_company,'customer_balance_enabled',TRUE,'{}'::JSONB,v_actor
    ) ON CONFLICT(company_id,feature_code) DO UPDATE SET
        is_enabled=excluded.is_enabled,config=excluded.config,
        updated_by=excluded.updated_by,updated_at=clock_timestamp();

    PERFORM set_config('request.jwt.claims',jsonb_build_object(
        'sub',v_actor,'role','authenticated'
    )::TEXT,TRUE);
    PERFORM public.set_active_company_context(v_company,'G4_PHASE56_TEST');
    SELECT id INTO v_cash FROM public.payment_methods
    WHERE company_id=v_company AND method_type='CASH' AND is_active
    ORDER BY is_default DESC,id LIMIT 1;
    SELECT id INTO v_balance_method FROM public.payment_methods
    WHERE company_id=v_company AND method_type='CUSTOMER_BALANCE' AND is_active
    ORDER BY id LIMIT 1;
    IF v_cash IS NULL OR v_balance_method IS NULL
       OR v_customer_category IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: provisioned master missing';
    END IF;
    v_result:=public.open_cashier_session(v_terminal,v_warehouse,100);
    v_session:=(v_result->>'cashierSessionId')::UUID;

    -- Balance 60 must be used fully; the external Cash leg settles the rest.
    v_payload:=jsonb_build_object(
        'clientTransactionId','00000000-0000-0000-0000-000000086101',
        'cashierSessionId',v_session,'customerId',v_customer,
        'roundingDirection','NONE',
        'lines',jsonb_build_array(jsonb_build_object(
            'lineKey','G86-LINE-1','productUomId',v_product_uom,'quantity',1
        )),
        'payments',jsonb_build_array(
            jsonb_build_object(
                'clientPaymentKey','00000000-0000-0000-0000-000000086111',
                'paymentMethodId',v_balance_method,'amount',60,
                'tenderedAmount',60
            ),
            jsonb_build_object(
                'clientPaymentKey','00000000-0000-0000-0000-000000086112',
                'paymentMethodId',v_cash,'amount',40,'tenderedAmount',40
            )
        )
    );
    v_result:=public.save_pos_sale_draft(v_payload);
    v_sale:=(v_result->>'salesId')::UUID;
    v_result:=public.post_pos_sale(
        v_sale,(v_result->>'masterVersion')::BIGINT,
        '00000000-0000-0000-0000-000000086121'
    );
    IF v_result->>'documentStatus'<>'POSTED'
       OR (v_result->>'customerBalanceUsageTotal')::NUMERIC<>60 THEN
        RAISE EXCEPTION 'TEST_FAILED: full Balance Sale invalid: %',v_result;
    END IF;
    SELECT current_balance INTO v_value FROM public.customers
    WHERE company_id=v_company AND id=v_customer;
    IF v_value<>0 THEN
        RAISE EXCEPTION 'TEST_FAILED: remaining Customer Balance %',v_value;
    END IF;
    SELECT count(*) INTO v_count
    FROM public.sales_payments payment
    JOIN public.customer_balance_ledger_entries entry
      ON entry.company_id=payment.company_id
     AND entry.id=payment.customer_balance_usage_ledger_entry_id
    WHERE payment.company_id=v_company AND payment.sales_id=v_sale
      AND payment.payment_method_type_snapshot='CUSTOMER_BALANCE'
      AND payment.customer_balance_usage_amount=60
      AND entry.direction='DEBIT' AND entry.source_type='SALE_PAYMENT'
      AND entry.source_id=payment.id AND entry.balance_before=60
      AND entry.balance_after=0;
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Balance Payment/Ledger snapshot invalid';
    END IF;
    IF COALESCE((v_result->'receipt'->'payments'->0
        ->>'customerBalanceUsageAmount')::NUMERIC,0)<>60 THEN
        RAISE EXCEPTION 'TEST_FAILED: receipt usage snapshot missing';
    END IF;

    -- Exact retry cannot duplicate stock, Payment, ledger, or Event.
    v_result:=public.post_pos_sale(
        v_sale,1,'00000000-0000-0000-0000-000000086121'
    );
    SELECT count(*) INTO v_count FROM public.customer_balance_ledger_entries
    WHERE company_id=v_company AND source_type='SALE_PAYMENT';
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: retry duplicated Balance debit';
    END IF;
    SELECT stock_qty INTO v_value FROM public.product_stocks
    WHERE company_id=v_company AND product_id=v_product
      AND warehouse_id=v_warehouse;
    IF v_value<>4 THEN
        RAISE EXCEPTION 'TEST_FAILED: retry duplicated stock effect';
    END IF;

    -- Partial use is forbidden and produces no final Sale effect.
    UPDATE public.customers SET current_balance=60 WHERE id=v_customer;
    v_payload:=jsonb_set(v_payload,'{clientTransactionId}',
        '"00000000-0000-0000-0000-000000086102"'::JSONB);
    v_payload:=jsonb_set(v_payload,'{payments,0,amount}','50'::JSONB);
    v_payload:=jsonb_set(v_payload,'{payments,0,tenderedAmount}','50'::JSONB);
    v_payload:=jsonb_set(v_payload,'{payments,1,amount}','50'::JSONB);
    v_payload:=jsonb_set(v_payload,'{payments,1,tenderedAmount}','50'::JSONB);
    v_result:=public.save_pos_sale_draft(v_payload);
    v_partial_sale:=(v_result->>'salesId')::UUID;
    v_rejected:=FALSE;
    BEGIN
        PERFORM public.post_pos_sale(
            v_partial_sale,(v_result->>'masterVersion')::BIGINT,
            '00000000-0000-0000-0000-000000086122'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'FULL_CUSTOMER_BALANCE_USAGE_REQUIRED:%' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected OR EXISTS(
        SELECT 1 FROM public.sales_headers sale
        WHERE sale.id=v_partial_sale AND sale.document_status='POSTED'
    ) THEN RAISE EXCEPTION 'TEST_FAILED: partial Balance use accepted'; END IF;

    -- Balance greater than total blocks checkout and reports the shortfall.
    UPDATE public.customers SET current_balance=120 WHERE id=v_customer;
    v_payload:=jsonb_set(v_payload,'{clientTransactionId}',
        '"00000000-0000-0000-0000-000000086103"'::JSONB);
    v_payload:=jsonb_set(v_payload,'{payments}',jsonb_build_array(
        jsonb_build_object(
            'clientPaymentKey','00000000-0000-0000-0000-000000086113',
            'paymentMethodId',v_cash,'amount',100,'tenderedAmount',100
        )
    ));
    v_result:=public.save_pos_sale_draft(v_payload);
    v_short_sale:=(v_result->>'salesId')::UUID;
    v_rejected:=FALSE;
    BEGIN
        PERFORM public.post_pos_sale(
            v_short_sale,(v_result->>'masterVersion')::BIGINT,
            '00000000-0000-0000-0000-000000086123'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='CUSTOMER_BALANCE_EXCEEDS_SALE_TOTAL:20.0000'
           OR SQLERRM='CUSTOMER_BALANCE_EXCEEDS_SALE_TOTAL:20' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: Balance greater than total accepted';
    END IF;

    IF has_table_privilege(
           'authenticated','public.customer_balance_ledger_entries',
           'INSERT,UPDATE,DELETE'
       ) OR has_table_privilege(
           'authenticated','public.sales_payments','INSERT,UPDATE,DELETE'
       ) OR NOT has_function_privilege(
           'authenticated','public.post_pos_sale(uuid,bigint,uuid)','EXECUTE'
       ) THEN
        RAISE EXCEPTION 'TEST_FAILED: browser write boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: Customer Balance is fully consumed as an atomic, idempotent online Sale tender.';
END
$test$;

ROLLBACK;
