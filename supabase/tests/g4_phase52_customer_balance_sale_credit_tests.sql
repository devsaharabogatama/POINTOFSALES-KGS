-- G4 phase 52 behavior: atomic Sale overpayment -> Customer Balance credit.
-- SAFETY: every fixture, Sale, stock effect, ledger, event, and audit is rolled
-- back. No existing business row is retained or modified after completion.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID:='00000000-0000-0000-0000-000000082001';
    v_store UUID:='00000000-0000-0000-0000-000000082011';
    v_terminal UUID:='00000000-0000-0000-0000-000000082021';
    v_warehouse UUID:='00000000-0000-0000-0000-000000082031';
    v_category UUID:='00000000-0000-0000-0000-000000082041';
    v_uom UUID:='00000000-0000-0000-0000-000000082051';
    v_product UUID:='00000000-0000-0000-0000-000000082061';
    v_product_uom UUID:='00000000-0000-0000-0000-000000082071';
    v_customer_category UUID;
    v_customer UUID:='00000000-0000-0000-0000-000000082081';
    v_walk_in UUID;
    v_cash UUID;
    v_session UUID;
    v_sale UUID;
    v_returned_sale UUID;
    v_blocked_sale UUID;
    v_result JSONB;
    v_payload JSONB;
    v_count BIGINT;
    v_value NUMERIC;
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
    ) VALUES(v_company,'G82','G82 Balance Sale','g82-balance-sale','ACTIVE');
    INSERT INTO public.stores(id,company_id,store_code,store_name,status)
    VALUES(v_store,v_company,'G82S','G82 Store','ACTIVE');
    INSERT INTO public.pos_terminals(
        id,company_id,store_id,pos_code,pos_name,status
    ) VALUES(v_terminal,v_company,v_store,'G82P','G82 POS','ACTIVE');
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,store_id,
        is_sale_source,is_purchase_destination,is_active
    ) VALUES(
        v_warehouse,v_company,'G82W','G82 Warehouse','STORE',v_store,
        TRUE,FALSE,TRUE
    );
    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES(v_category,v_company,'G82CAT','G82 Product');
    INSERT INTO public.uoms(
        id,company_id,code,name,uom_type,allow_decimal,decimal_precision
    ) VALUES(v_uom,v_company,'G82PCS','Piece','UNIT',FALSE,0);
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES(
        v_product,v_company,'G82-PROD','G82 Product','G82 Product',
        v_category,100,50,'G82PCS',v_uom,v_uom,1,TRUE,FALSE
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
    ) VALUES(v_company,v_product,v_warehouse,3);
    INSERT INTO public.product_batches(
        id,product_id,warehouse_id,qty_purchased,qty_remaining,cogs_unit,
        company_id
    ) VALUES(
        '00000000-0000-0000-0000-000000082072',v_product,v_warehouse,
        3,3,50,v_company
    );
    INSERT INTO public.stock_movements(
        product_id,warehouse_id,qty_change,movement_type,
        reference_table,reference_id,company_id,base_uom_id,
        base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
        movement_status,source_line_id,notes
    ) VALUES(
        v_product,v_warehouse,3,'PURCHASE'::public.stock_movement_type,
        'G4_PHASE52_TEST','00000000-0000-0000-0000-000000082073',
        v_company,v_uom,'Piece',3,v_actor,clock_timestamp(),'POSTED',
        '00000000-0000-0000-0000-000000082074',
        'Rollback-only stock fixture'
    );

    SELECT id INTO v_customer_category
    FROM public.customer_categories
    WHERE company_id=v_company AND is_system_category
    ORDER BY id LIMIT 1;
    INSERT INTO public.customers(
        id,company_id,code,name,customer_category_id,customer_type,
        current_balance,credit_limit,is_active,is_system_customer
    ) VALUES(
        v_customer,v_company,'G82-CUST','G82 Customer',v_customer_category,
        'INDIVIDUAL',0,0,TRUE,FALSE
    );
    INSERT INTO public.company_features(
        company_id,feature_code,is_enabled,config,updated_by
    ) VALUES(
        v_company,'customer_balance_enabled',TRUE,'{}'::JSONB,v_actor
    ) ON CONFLICT(company_id,feature_code) DO UPDATE SET
        is_enabled=excluded.is_enabled,config=excluded.config,
        updated_by=excluded.updated_by,updated_at=clock_timestamp();

    PERFORM set_config(
        'request.jwt.claims',jsonb_build_object(
            'sub',v_actor,'role','authenticated'
        )::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G4_PHASE52_TEST');
    SELECT id INTO v_cash FROM public.payment_methods
    WHERE company_id=v_company AND method_type='CASH' AND is_active
    ORDER BY is_default DESC,id LIMIT 1;
    SELECT id INTO v_walk_in FROM public.customers
    WHERE company_id=v_company AND is_system_customer
      AND upper(btrim(code))='WALK-IN'
    ORDER BY id LIMIT 1;
    IF v_cash IS NULL OR v_customer_category IS NULL OR v_walk_in IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: provisioned master missing';
    END IF;
    v_result:=public.open_cashier_session(v_terminal,v_warehouse,100);
    v_session:=(v_result->>'cashierSessionId')::UUID;

    -- Explicitly save Rp20 Cash overpayment as Customer Balance.
    v_payload:=jsonb_build_object(
        'clientTransactionId','00000000-0000-0000-0000-000000082101',
        'cashierSessionId',v_session,'customerId',v_customer,
        'roundingDirection','NONE',
        'lines',jsonb_build_array(jsonb_build_object(
            'lineKey','G82-LINE-1','productUomId',v_product_uom,'quantity',1
        )),
        'payments',jsonb_build_array(jsonb_build_object(
            'clientPaymentKey','00000000-0000-0000-0000-000000082111',
            'paymentMethodId',v_cash,'amount',100,'tenderedAmount',120,
            'overpaymentDisposition','CUSTOMER_BALANCE'
        ))
    );
    v_result:=public.save_pos_sale_draft(v_payload);
    v_sale:=(v_result->>'salesId')::UUID;
    v_result:=public.post_pos_sale(
        v_sale,(v_result->>'masterVersion')::BIGINT,
        '00000000-0000-0000-0000-000000082121'
    );
    IF v_result->>'documentStatus'<>'POSTED'
       OR (v_result->>'customerBalanceCreditTotal')::NUMERIC<>20 THEN
        RAISE EXCEPTION 'TEST_FAILED: credited Sale result invalid: %',v_result;
    END IF;
    SELECT current_balance INTO v_value FROM public.customers
    WHERE company_id=v_company AND id=v_customer;
    IF v_value<>20 THEN
        RAISE EXCEPTION 'TEST_FAILED: Customer balance %, expected 20',v_value;
    END IF;
    SELECT count(*) INTO v_count
    FROM public.sales_payments payment
    JOIN public.customer_balance_ledger_entries entry
      ON entry.company_id=payment.company_id
     AND entry.id=payment.customer_balance_ledger_entry_id
    WHERE payment.company_id=v_company AND payment.sales_id=v_sale
      AND payment.overpayment_disposition='CUSTOMER_BALANCE'
      AND payment.customer_balance_credit_amount=20
      AND payment.change_amount=0
      AND entry.source_type='SALE_OVERPAYMENT'
      AND entry.source_id=payment.id AND entry.amount=20
      AND entry.balance_before=0 AND entry.balance_after=20;
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Payment/ledger credit snapshot invalid';
    END IF;
    SELECT count(*) INTO v_count FROM public.financial_events event
    JOIN public.customer_balance_ledger_entries entry
      ON entry.company_id=event.company_id AND entry.financial_event_id=event.id
    WHERE entry.company_id=v_company AND entry.source_type='SALE_OVERPAYMENT'
      AND event.event_type='CUSTOMER_BALANCE_ADJUSTMENT'::public.event_type
      AND event.source_table='sales_payments'
      AND event.status='HOLD'::public.event_status;
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Customer Balance HOLD event missing';
    END IF;
    IF private.calculate_cashier_session_expected_cash(v_company,v_session)
       <>220 THEN
        RAISE EXCEPTION
            'TEST_FAILED: credited Cash not included in expected drawer cash';
    END IF;
    IF COALESCE((v_result->'receipt'->'payments'->0
        ->>'customerBalanceCreditAmount')::NUMERIC,0)<>20
       OR v_result->'receipt'->'payments'->0
        ->>'overpaymentDisposition'<>'CUSTOMER_BALANCE' THEN
        RAISE EXCEPTION 'TEST_FAILED: returned receipt credit snapshot invalid';
    END IF;

    -- Retry the same final Post: no second credit, ledger, event, or stock.
    v_result:=public.post_pos_sale(
        v_sale,1,'00000000-0000-0000-0000-000000082121'
    );
    SELECT count(*) INTO v_count FROM public.customer_balance_ledger_entries
    WHERE company_id=v_company AND source_type='SALE_OVERPAYMENT';
    IF v_count<>1 OR (SELECT current_balance FROM public.customers
        WHERE id=v_customer)<>20 THEN
        RAISE EXCEPTION 'TEST_FAILED: idempotent replay duplicated balance';
    END IF;
    SELECT stock_qty INTO v_value FROM public.product_stocks
    WHERE company_id=v_company AND product_id=v_product
      AND warehouse_id=v_warehouse;
    IF v_value<>2 THEN
        RAISE EXCEPTION 'TEST_FAILED: idempotent replay duplicated stock';
    END IF;

    -- Cash overpayment without the Phase-53 choice remains returned change.
    v_payload:=jsonb_build_object(
        'clientTransactionId','00000000-0000-0000-0000-000000082102',
        'cashierSessionId',v_session,'customerId',v_customer,
        'roundingDirection','NONE',
        'lines',jsonb_build_array(jsonb_build_object(
            'lineKey','G82-LINE-2','productUomId',v_product_uom,'quantity',1
        )),
        'payments',jsonb_build_array(jsonb_build_object(
            'clientPaymentKey','00000000-0000-0000-0000-000000082112',
            'paymentMethodId',v_cash,'amount',100,'tenderedAmount',120
        ))
    );
    v_result:=public.save_pos_sale_draft(v_payload);
    v_returned_sale:=(v_result->>'salesId')::UUID;
    v_result:=public.post_pos_sale(
        v_returned_sale,(v_result->>'masterVersion')::BIGINT,
        '00000000-0000-0000-0000-000000082122'
    );
    SELECT count(*) INTO v_count FROM public.sales_payments
    WHERE company_id=v_company AND sales_id=v_returned_sale
      AND overpayment_disposition='RETURNED' AND change_amount=20
      AND customer_balance_credit_amount=0
      AND customer_balance_ledger_entry_id IS NULL;
    IF v_count<>1 OR (SELECT current_balance FROM public.customers
        WHERE id=v_customer)<>20 THEN
        RAISE EXCEPTION 'TEST_FAILED: returned Cash change became balance';
    END IF;
    IF private.calculate_cashier_session_expected_cash(v_company,v_session)
       <>320 THEN
        RAISE EXCEPTION
            'TEST_FAILED: returned change incorrectly increased expected cash';
    END IF;

    -- Walk-In cannot receive a balance. The failure must roll back the Sale
    -- final effects produced earlier in the same Post transaction.
    v_payload:=jsonb_build_object(
        'clientTransactionId','00000000-0000-0000-0000-000000082103',
        'cashierSessionId',v_session,'customerId',v_walk_in,
        'roundingDirection','NONE',
        'lines',jsonb_build_array(jsonb_build_object(
            'lineKey','G82-LINE-3','productUomId',v_product_uom,'quantity',1
        )),
        'payments',jsonb_build_array(jsonb_build_object(
            'clientPaymentKey','00000000-0000-0000-0000-000000082113',
            'paymentMethodId',v_cash,'amount',100,'tenderedAmount',120,
            'overpaymentDisposition','CUSTOMER_BALANCE'
        ))
    );
    v_result:=public.save_pos_sale_draft(v_payload);
    v_blocked_sale:=(v_result->>'salesId')::UUID;
    v_rejected:=FALSE;
    BEGIN
        PERFORM public.post_pos_sale(
            v_blocked_sale,(v_result->>'masterVersion')::BIGINT,
            '00000000-0000-0000-0000-000000082123'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='CUSTOMER_BALANCE_ELIGIBLE_CUSTOMER_REQUIRED' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected OR EXISTS(
        SELECT 1 FROM public.stock_movements
        WHERE company_id=v_company AND reference_table='sales_headers'
          AND reference_id=v_blocked_sale
    ) OR EXISTS(
        SELECT 1 FROM public.sales_payments
        WHERE company_id=v_company AND sales_id=v_blocked_sale
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: rejected Walk-In credit retained final effects';
    END IF;
    SELECT stock_qty INTO v_value FROM public.product_stocks
    WHERE company_id=v_company AND product_id=v_product
      AND warehouse_id=v_warehouse;
    IF v_value<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: rejected credit changed stock';
    END IF;

    IF has_table_privilege(
        'authenticated','public.customer_balance_ledger_entries',
        'INSERT,UPDATE,DELETE'
    ) OR has_column_privilege(
        'authenticated','public.customers','current_balance','UPDATE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: browser Customer Balance writes opened';
    END IF;

    RAISE NOTICE 'TEST PASSED: ONLINE Sale overpayment credit is atomic, idempotent, customer-scoped, receipt-snapshotted, and Cash returned-change compatible.';
END
$test$;

ROLLBACK;
