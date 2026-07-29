-- G4 phase 4 behavioral test: server-authoritative Draft/Post Sale.
-- SAFETY: all Auth, master, stock, Sale, FIFO, payment, movement, event, and
-- audit fixtures are rolled back.

BEGIN;

INSERT INTO auth.users(
    id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at
) VALUES (
    '00000000-0000-0000-0000-000000051091',
    'g4-sale-cashier@example.invalid',
    '00000000-0000-0000-0000-000000000000',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"name":"G4 Sale Cashier"}'::JSONB,
    FALSE,'authenticated','authenticated',clock_timestamp()
);

INSERT INTO public.profiles(id,email,name,role)
VALUES (
    '00000000-0000-0000-0000-000000051091',
    'g4-sale-cashier@example.invalid',
    'G4 Sale Cashier','cashier'::public.user_role
)
ON CONFLICT(id) DO UPDATE SET name=EXCLUDED.name,role=EXCLUDED.role;

INSERT INTO public.companies(
    id,company_code,company_name,company_slug,status
) VALUES
    (
        '00000000-0000-0000-0000-000000051001',
        'G51A','G51 Company A','g51-company-a','ACTIVE'
    ),
    (
        '00000000-0000-0000-0000-000000051002',
        'G51B','G51 Company B','g51-company-b','ACTIVE'
    );

INSERT INTO public.stores(id,company_id,store_code,store_name,status)
VALUES (
    '00000000-0000-0000-0000-000000051011',
    '00000000-0000-0000-0000-000000051001',
    'A1','G51 Store A','ACTIVE'
);

INSERT INTO public.pos_terminals(
    id,company_id,store_id,pos_code,pos_name,status
) VALUES (
    '00000000-0000-0000-0000-000000051021',
    '00000000-0000-0000-0000-000000051001',
    '00000000-0000-0000-0000-000000051011',
    'POS1','G51 POS 1','ACTIVE'
);

INSERT INTO public.company_memberships(
    company_id,user_id,role_code,status,is_default_company
) VALUES (
    '00000000-0000-0000-0000-000000051001',
    '00000000-0000-0000-0000-000000051091',
    'CASHIER','ACTIVE',TRUE
);

INSERT INTO public.store_memberships(
    company_id,store_id,user_id,role_code,status
) VALUES (
    '00000000-0000-0000-0000-000000051001',
    '00000000-0000-0000-0000-000000051011',
    '00000000-0000-0000-0000-000000051091',
    'CASHIER','ACTIVE'
);

INSERT INTO public.warehouses(
    id,company_id,code,name,warehouse_type,store_id,
    is_sale_source,is_purchase_destination,is_active
) VALUES (
    '00000000-0000-0000-0000-000000051031',
    '00000000-0000-0000-0000-000000051001',
    'SWA','G51 Sales Warehouse','STORE',
    '00000000-0000-0000-0000-000000051011',
    TRUE,FALSE,TRUE
);

INSERT INTO public.product_categories(
    id,company_id,category_code,category_name
) VALUES
    (
        '00000000-0000-0000-0000-000000051041',
        '00000000-0000-0000-0000-000000051001',
        'TEST','Test Product'
    ),
    (
        '00000000-0000-0000-0000-000000051042',
        '00000000-0000-0000-0000-000000051002',
        'TEST','Test Product'
    );

INSERT INTO public.uoms(
    id,company_id,code,name,uom_type,allow_decimal,decimal_precision
) VALUES
    (
        '00000000-0000-0000-0000-000000051051',
        '00000000-0000-0000-0000-000000051001',
        'PCS','Piece','UNIT',FALSE,0
    ),
    (
        '00000000-0000-0000-0000-000000051052',
        '00000000-0000-0000-0000-000000051002',
        'PCS','Piece','UNIT',FALSE,0
    );

INSERT INTO public.products(
    id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
    weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
) VALUES
    (
        '00000000-0000-0000-0000-000000051061',
        '00000000-0000-0000-0000-000000051001',
        'G51-PROD','G51 Product','Test Product',
        '00000000-0000-0000-0000-000000051041',
        100,50,'PCS',
        '00000000-0000-0000-0000-000000051051',
        '00000000-0000-0000-0000-000000051051',
        1,TRUE,FALSE
    ),
    (
        '00000000-0000-0000-0000-000000051062',
        '00000000-0000-0000-0000-000000051002',
        'G51-CROSS','G51 Cross Product','Test Product',
        '00000000-0000-0000-0000-000000051042',
        100,50,'PCS',
        '00000000-0000-0000-0000-000000051052',
        '00000000-0000-0000-0000-000000051052',
        1,TRUE,FALSE
    ),
    (
        '00000000-0000-0000-0000-000000051063',
        '00000000-0000-0000-0000-000000051001',
        'G51-BUNDLE','G51 Bundle','Test Product',
        '00000000-0000-0000-0000-000000051041',
        250,0,'PCS',
        '00000000-0000-0000-0000-000000051051',
        '00000000-0000-0000-0000-000000051051',
        2,TRUE,TRUE
    );

INSERT INTO public.product_uoms(
    id,company_id,product_id,uom_id,factor_to_base,
    purchase_allowed,sales_allowed,purchase_price,sale_price,is_active
) VALUES
    (
        '00000000-0000-0000-0000-000000051071',
        '00000000-0000-0000-0000-000000051001',
        '00000000-0000-0000-0000-000000051061',
        '00000000-0000-0000-0000-000000051051',
        1,TRUE,TRUE,50,100,TRUE
    ),
    (
        '00000000-0000-0000-0000-000000051072',
        '00000000-0000-0000-0000-000000051002',
        '00000000-0000-0000-0000-000000051062',
        '00000000-0000-0000-0000-000000051052',
        1,TRUE,TRUE,50,100,TRUE
    ),
    (
        '00000000-0000-0000-0000-000000051073',
        '00000000-0000-0000-0000-000000051001',
        '00000000-0000-0000-0000-000000051063',
        '00000000-0000-0000-0000-000000051051',
        1,FALSE,TRUE,NULL,250,TRUE
    );

INSERT INTO public.product_bundle_items(
    company_id,bundle_id,item_id,qty,component_uom_id,component_qty,
    line_no,created_by,updated_by
) VALUES (
    '00000000-0000-0000-0000-000000051001',
    '00000000-0000-0000-0000-000000051063',
    '00000000-0000-0000-0000-000000051061',2,
    '00000000-0000-0000-0000-000000051051',2,1,
    '00000000-0000-0000-0000-000000051091',
    '00000000-0000-0000-0000-000000051091'
);

INSERT INTO public.product_stocks(
    company_id,product_id,warehouse_id,stock_qty
) VALUES (
    '00000000-0000-0000-0000-000000051001',
    '00000000-0000-0000-0000-000000051061',
    '00000000-0000-0000-0000-000000051031',5
);

INSERT INTO public.product_batches(
    id,product_id,warehouse_id,qty_purchased,qty_remaining,cogs_unit,
    company_id
) VALUES
    (
        '00000000-0000-0000-0000-000000051081',
        '00000000-0000-0000-0000-000000051061',
        '00000000-0000-0000-0000-000000051031',
        2,2,40,'00000000-0000-0000-0000-000000051001'
    ),
    (
        '00000000-0000-0000-0000-000000051082',
        '00000000-0000-0000-0000-000000051061',
        '00000000-0000-0000-0000-000000051031',
        3,3,60,'00000000-0000-0000-0000-000000051001'
    );

INSERT INTO public.stock_movements(
    product_id,warehouse_id,qty_change,movement_type,
    reference_table,reference_id,company_id,
    base_uom_id,base_uom_name_snapshot,balance_after_base_qty,
    actor_id,posted_at,movement_status,source_line_id,notes
) VALUES (
    '00000000-0000-0000-0000-000000051061',
    '00000000-0000-0000-0000-000000051031',
    5,'PURCHASE'::public.stock_movement_type,
    'G4_PHASE4_TEST',
    '00000000-0000-0000-0000-000000051083',
    '00000000-0000-0000-0000-000000051001',
    '00000000-0000-0000-0000-000000051051','Piece',5,
    '00000000-0000-0000-0000-000000051091',
    clock_timestamp(),'POSTED',
    '00000000-0000-0000-0000-000000051084',
    'Rollback-only opening fixture'
);

DO $test$
DECLARE
    v_result JSONB;
    v_session UUID;
    v_sale UUID;
    v_cash_method UUID;
    v_customer UUID;
    v_payload JSONB;
    v_count BIGINT;
    v_value NUMERIC;
    v_rejected BOOLEAN;
BEGIN
    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000051091","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000051001',
        'G4_PHASE4_TEST'
    );

    SELECT id INTO v_cash_method
    FROM public.payment_methods
    WHERE company_id = '00000000-0000-0000-0000-000000051001'
      AND method_type = 'CASH'
      AND is_active
    ORDER BY is_default DESC,id
    LIMIT 1;
    SELECT id INTO v_customer
    FROM public.customers
    WHERE company_id = '00000000-0000-0000-0000-000000051001'
      AND is_system_customer
      AND upper(btrim(code)) = 'WALK-IN';
    IF v_cash_method IS NULL OR v_customer IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: provisioned Cash/Walk-In missing';
    END IF;

    v_result := public.open_cashier_session(
        '00000000-0000-0000-0000-000000051021',
        '00000000-0000-0000-0000-000000051031',100
    );
    v_session := (v_result->>'cashierSessionId')::UUID;

    -- Cross-tenant Product-UOM must be rejected before a Draft is persisted.
    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_pos_sale_draft(jsonb_build_object(
            'clientTransactionId',
                '00000000-0000-0000-0000-000000051101',
            'cashierSessionId',v_session,
            'customerId',v_customer,
            'lines',jsonb_build_array(jsonb_build_object(
                'lineKey','CROSS',
                'productUomId',
                    '00000000-0000-0000-0000-000000051072',
                'quantity',1
            ))
        ));
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_SALES_PRODUCT_UOM_NOT_FOUND' THEN
            v_rejected := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company Product-UOM accepted';
    END IF;

    -- Quantity six exceeds stock five. Saving remains a side-effect-free Draft.
    v_payload := jsonb_build_object(
        'clientTransactionId','00000000-0000-0000-0000-000000051102',
        'cashierSessionId',v_session,
        'customerId',v_customer,
        'grandTotal',1,
        'roundingDirection','NONE',
        'lines',jsonb_build_array(jsonb_build_object(
            'lineKey','LINE-1',
            'productUomId','00000000-0000-0000-0000-000000051071',
            'quantity',6,'price',1,'cogsUnit',1
        )),
        'payments',jsonb_build_array(jsonb_build_object(
            'paymentMethodId',v_cash_method,'amount',600,
            'tenderedAmount',600
        ))
    );
    v_result := public.save_pos_sale_draft(v_payload);
    v_sale := (v_result->>'salesId')::UUID;
    IF (v_result->>'masterVersion')::BIGINT <> 1
       OR (v_result->>'grandTotalAfterRounding')::NUMERIC <> 600 THEN
        RAISE EXCEPTION 'TEST_FAILED: initial Draft result invalid: %',v_result;
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.stock_movements
        WHERE reference_table = 'sales_headers' AND reference_id = v_sale
    ) OR EXISTS (
        SELECT 1 FROM public.sales_payments WHERE sales_id = v_sale
    ) OR EXISTS (
        SELECT 1 FROM public.financial_events
        WHERE source_table = 'sales_headers' AND source_id = v_sale
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Draft created final effects';
    END IF;

    v_result := public.post_pos_sale(
        v_sale,1,'00000000-0000-0000-0000-000000051111'
    );
    IF v_result->>'documentStatus' <> 'DRAFT'
       OR v_result->>'draftReason' <> 'STOCK_SHORTAGE'
       OR (v_result->>'masterVersion')::BIGINT <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: shortage result invalid: %',v_result;
    END IF;
    SELECT stock_qty INTO v_value
    FROM public.product_stocks
    WHERE company_id = '00000000-0000-0000-0000-000000051001'
      AND product_id = '00000000-0000-0000-0000-000000051061'
      AND warehouse_id = '00000000-0000-0000-0000-000000051031';
    IF v_value <> 5 THEN
        RAISE EXCEPTION 'TEST_FAILED: shortage changed stock';
    END IF;

    -- Edit the same Draft to two units. Version and totals are server-owned.
    v_payload := v_payload
        || jsonb_build_object(
            'saleId',v_sale,'masterVersion',2,
            'lines',jsonb_build_array(jsonb_build_object(
                'lineKey','LINE-1',
                'productUomId',
                    '00000000-0000-0000-0000-000000051071',
                'quantity',2,
                'lineDiscountType','PERCENT',
                'lineDiscountInput',10
            )),
            'payments',jsonb_build_array(jsonb_build_object(
                'paymentMethodId',v_cash_method,'amount',180,
                'tenderedAmount',200
            ))
        );
    v_result := public.save_pos_sale_draft(v_payload);
    IF (v_result->>'masterVersion')::BIGINT <> 3
       OR (v_result->>'grandTotalAfterRounding')::NUMERIC <> 180 THEN
        RAISE EXCEPTION 'TEST_FAILED: updated Draft invalid: %',v_result;
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.post_pos_sale(
            v_sale,2,'00000000-0000-0000-0000-000000051112'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'MASTER_VERSION_CONFLICT' THEN
            v_rejected := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale Sale post accepted';
    END IF;

    v_result := public.post_pos_sale(
        v_sale,3,'00000000-0000-0000-0000-000000051112'
    );
    IF v_result->>'documentStatus' <> 'POSTED'
       OR (v_result->>'masterVersion')::BIGINT <> 4
       OR (v_result->>'grandTotal')::NUMERIC <> 180
       OR (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: posted Sale result invalid: %',v_result;
    END IF;

    SELECT stock_qty INTO v_value
    FROM public.product_stocks
    WHERE company_id = '00000000-0000-0000-0000-000000051001'
      AND product_id = '00000000-0000-0000-0000-000000051061'
      AND warehouse_id = '00000000-0000-0000-0000-000000051031';
    IF v_value <> 3 THEN
        RAISE EXCEPTION 'TEST_FAILED: posted stock %, expected 3',v_value;
    END IF;
    SELECT COALESCE(sum(qty_remaining),0) INTO v_value
    FROM public.product_batches
    WHERE company_id = '00000000-0000-0000-0000-000000051001'
      AND product_id = '00000000-0000-0000-0000-000000051061'
      AND warehouse_id = '00000000-0000-0000-0000-000000051031';
    IF v_value <> 3 THEN
        RAISE EXCEPTION 'TEST_FAILED: FIFO remaining %, expected 3',v_value;
    END IF;
    SELECT count(*) INTO v_count
    FROM public.sale_fifo_allocations
    WHERE company_id = '00000000-0000-0000-0000-000000051001'
      AND sales_id = v_sale
      AND quantity_base = 2
      AND fifo_cost_total = 80;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: FIFO allocation snapshot invalid';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.stock_movements
    WHERE company_id = '00000000-0000-0000-0000-000000051001'
      AND reference_table = 'sales_headers'
      AND reference_id = v_sale
      AND movement_type = 'SALE'::public.stock_movement_type
      AND qty_change = -2
      AND balance_after_base_qty = 3;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: canonical Sale Movement invalid';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.sales_payments
    WHERE company_id = '00000000-0000-0000-0000-000000051001'
      AND sales_id = v_sale
      AND amount = 180
      AND tendered_amount = 200
      AND change_amount = 20;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: canonical Payment snapshot invalid';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.financial_events
    WHERE company_id = '00000000-0000-0000-0000-000000051001'
      AND source_table = 'sales_headers'
      AND source_id = v_sale
      AND event_type = 'SALE_POSTED'::public.event_type
      AND status = 'HOLD'::public.event_status;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Finance HOLD event missing';
    END IF;

    v_result := public.post_pos_sale(
        v_sale,3,'00000000-0000-0000-0000-000000051112'
    );
    IF NOT (v_result->>'idempotentReplay')::BOOLEAN
       OR (v_result->>'masterVersion')::BIGINT <> 4 THEN
        RAISE EXCEPTION 'TEST_FAILED: Sale retry not idempotent: %',v_result;
    END IF;
    SELECT count(*) INTO v_count
    FROM public.stock_movements
    WHERE reference_table = 'sales_headers' AND reference_id = v_sale;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: retry duplicated Movement';
    END IF;

    -- Bundle remains one commercial line while two component units consume
    -- FIFO and the analytic allocation conserves Bundle revenue.
    v_payload := jsonb_build_object(
        'clientTransactionId','00000000-0000-0000-0000-000000051103',
        'cashierSessionId',v_session,
        'customerId',v_customer,
        'roundingDirection','NONE',
        'lines',jsonb_build_array(jsonb_build_object(
            'lineKey','BUNDLE-1',
            'productUomId','00000000-0000-0000-0000-000000051073',
            'quantity',1
        )),
        'payments',jsonb_build_array(jsonb_build_object(
            'paymentMethodId',v_cash_method,'amount',250,
            'tenderedAmount',250
        ))
    );
    v_result := public.save_pos_sale_draft(v_payload);
    v_sale := (v_result->>'salesId')::UUID;
    v_result := public.post_pos_sale(
        v_sale,1,'00000000-0000-0000-0000-000000051113'
    );
    IF v_result->>'documentStatus' <> 'POSTED'
       OR (v_result->>'grandTotal')::NUMERIC <> 250 THEN
        RAISE EXCEPTION 'TEST_FAILED: Bundle Sale post invalid: %',v_result;
    END IF;
    SELECT stock_qty INTO v_value
    FROM public.product_stocks
    WHERE company_id = '00000000-0000-0000-0000-000000051001'
      AND product_id = '00000000-0000-0000-0000-000000051061'
      AND warehouse_id = '00000000-0000-0000-0000-000000051031';
    IF v_value <> 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: Bundle component stock %, expected 1',v_value;
    END IF;
    SELECT count(*) INTO v_count
    FROM public.bundle_sale_allocations ba
    WHERE ba.company_id = '00000000-0000-0000-0000-000000051001'
      AND ba.sales_id = v_sale
      AND ba.bundle_product_id =
          '00000000-0000-0000-0000-000000051063'
      AND ba.component_product_id =
          '00000000-0000-0000-0000-000000051061'
      AND ba.component_quantity_base = 2
      AND ba.allocated_gross = 250
      AND ba.allocated_discount = 0
      AND ba.allocated_tax = 0
      AND ba.allocated_net = 250
      AND ba.fifo_cost_total = 120;
    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: Bundle component allocation invalid';
    END IF;

    IF has_function_privilege(
        'authenticated',
        'public.create_sales_transaction(text,uuid,uuid,boolean,timestamp with time zone,boolean,text,numeric,numeric,numeric,numeric,numeric,numeric,public.payment_status,uuid,jsonb,jsonb,jsonb)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated','public.save_pos_sale_draft(jsonb)','EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated','public.post_pos_sale(uuid,bigint,uuid)','EXECUTE'
    ) OR has_table_privilege(
        'authenticated','public.sales_headers','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.product_stocks','INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Sale privilege boundary invalid';
    END IF;

    RAISE NOTICE
        'TEST PASSED: Sale Draft/Post is server-priced, shortage-safe, tenant-safe, FIFO-posted, payment-snapshotted, idempotent, and Finance-evented.';
END
$test$;

ROLLBACK;
