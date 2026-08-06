-- G4 phase 12 behavior: Offline submission -> canonical Sale Post.
-- SAFETY: all Auth/master/stock/allowance/Sale/exception fixtures roll back.

BEGIN;

INSERT INTO auth.users(
    id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at
) VALUES (
    '00000000-0000-0000-0000-000000070091',
    'g4-offline-sync@example.invalid',
    '00000000-0000-0000-0000-000000000000',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"name":"G4 Offline Sync Cashier"}'::JSONB,
    FALSE,'authenticated','authenticated',clock_timestamp()
);

INSERT INTO public.profiles(id,email,name,role)
VALUES (
    '00000000-0000-0000-0000-000000070091',
    'g4-offline-sync@example.invalid',
    'G4 Offline Sync Cashier','cashier'::public.user_role
)
ON CONFLICT(id) DO UPDATE SET
    email = EXCLUDED.email,
    name = EXCLUDED.name,
    role = EXCLUDED.role;

INSERT INTO public.companies(
    id,company_code,company_name,company_slug,status
) VALUES (
    '00000000-0000-0000-0000-000000070001',
    'G70A','G70 Company A','g70-company-a','ACTIVE'
);

INSERT INTO public.stores(id,company_id,store_code,store_name,status)
VALUES (
    '00000000-0000-0000-0000-000000070011',
    '00000000-0000-0000-0000-000000070001',
    'S1','G70 Store','ACTIVE'
);

INSERT INTO public.pos_terminals(
    id,company_id,store_id,pos_code,pos_name,status
) VALUES (
    '00000000-0000-0000-0000-000000070021',
    '00000000-0000-0000-0000-000000070001',
    '00000000-0000-0000-0000-000000070011',
    'POS1','G70 POS','ACTIVE'
);

INSERT INTO public.company_memberships(
    company_id,user_id,role_code,status,is_default_company
) VALUES (
    '00000000-0000-0000-0000-000000070001',
    '00000000-0000-0000-0000-000000070091',
    'CASHIER','ACTIVE',TRUE
);

INSERT INTO public.store_memberships(
    company_id,store_id,user_id,role_code,status
) VALUES (
    '00000000-0000-0000-0000-000000070001',
    '00000000-0000-0000-0000-000000070011',
    '00000000-0000-0000-0000-000000070091',
    'CASHIER','ACTIVE'
);

INSERT INTO public.warehouses(
    id,company_id,code,name,warehouse_type,store_id,
    is_sale_source,is_purchase_destination,is_active
) VALUES (
    '00000000-0000-0000-0000-000000070031',
    '00000000-0000-0000-0000-000000070001',
    'SWA','G70 Sales Warehouse','STORE',
    '00000000-0000-0000-0000-000000070011',
    TRUE,FALSE,TRUE
);

INSERT INTO public.product_categories(
    id,company_id,category_code,category_name
) VALUES (
    '00000000-0000-0000-0000-000000070041',
    '00000000-0000-0000-0000-000000070001',
    'TEST','Test Product'
);

INSERT INTO public.uoms(
    id,company_id,code,name,uom_type,allow_decimal,decimal_precision
) VALUES (
    '00000000-0000-0000-0000-000000070051',
    '00000000-0000-0000-0000-000000070001',
    'PCS','Piece','UNIT',FALSE,0
);

INSERT INTO public.products(
    id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
    weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
) VALUES (
    '00000000-0000-0000-0000-000000070061',
    '00000000-0000-0000-0000-000000070001',
    'G70-PROD','G70 Product','Test Product',
    '00000000-0000-0000-0000-000000070041',
    100,50,'PCS',
    '00000000-0000-0000-0000-000000070051',
    '00000000-0000-0000-0000-000000070051',
    1,TRUE,FALSE
);

INSERT INTO public.product_uoms(
    id,company_id,product_id,uom_id,factor_to_base,
    purchase_allowed,sales_allowed,purchase_price,sale_price,is_active
) VALUES (
    '00000000-0000-0000-0000-000000070071',
    '00000000-0000-0000-0000-000000070001',
    '00000000-0000-0000-0000-000000070061',
    '00000000-0000-0000-0000-000000070051',
    1,TRUE,TRUE,50,100,TRUE
);

INSERT INTO public.product_stocks(
    company_id,product_id,warehouse_id,stock_qty
) VALUES (
    '00000000-0000-0000-0000-000000070001',
    '00000000-0000-0000-0000-000000070061',
    '00000000-0000-0000-0000-000000070031',10
);

INSERT INTO public.product_batches(
    id,product_id,warehouse_id,qty_purchased,qty_remaining,
    cogs_unit,company_id
) VALUES
    (
        '00000000-0000-0000-0000-000000070081',
        '00000000-0000-0000-0000-000000070061',
        '00000000-0000-0000-0000-000000070031',
        4,4,40,'00000000-0000-0000-0000-000000070001'
    ),
    (
        '00000000-0000-0000-0000-000000070082',
        '00000000-0000-0000-0000-000000070061',
        '00000000-0000-0000-0000-000000070031',
        6,6,60,'00000000-0000-0000-0000-000000070001'
    );

INSERT INTO public.stock_movements(
    product_id,warehouse_id,qty_change,movement_type,
    reference_table,reference_id,company_id,
    base_uom_id,base_uom_name_snapshot,balance_after_base_qty,
    actor_id,posted_at,movement_status,source_line_id,notes
) VALUES (
    '00000000-0000-0000-0000-000000070061',
    '00000000-0000-0000-0000-000000070031',
    10,'PURCHASE'::public.stock_movement_type,
    'G4_PHASE12_TEST',
    '00000000-0000-0000-0000-000000070083',
    '00000000-0000-0000-0000-000000070001',
    '00000000-0000-0000-0000-000000070051','Piece',10,
    '00000000-0000-0000-0000-000000070091',
    clock_timestamp(),'POSTED',
    '00000000-0000-0000-0000-000000070084',
    'Rollback-only stock fixture'
);

INSERT INTO public.company_features(
    company_id,feature_code,is_enabled,config
) VALUES (
    '00000000-0000-0000-0000-000000070001',
    'offline_pos_enabled',TRUE,'{}'::JSONB
)
ON CONFLICT(company_id,feature_code) DO UPDATE
SET is_enabled = TRUE;

INSERT INTO public.pos_offline_allowance_policies(
    id,company_id,scope_type,allocation_percent,is_enabled
) VALUES (
    '00000000-0000-0000-0000-000000070085',
    '00000000-0000-0000-0000-000000070001',
    'COMPANY',0.2,TRUE
);

INSERT INTO public.pos_offline_allowance_policies(
    id,company_id,scope_type,store_id,terminal_id,is_enabled
) VALUES (
    '00000000-0000-0000-0000-000000070086',
    '00000000-0000-0000-0000-000000070001',
    'TERMINAL',
    '00000000-0000-0000-0000-000000070011',
    '00000000-0000-0000-0000-000000070021',TRUE
);

DO $test$
DECLARE
    v_result JSONB;
    v_session UUID;
    v_allowance UUID;
    v_cash_method UUID;
    v_customer UUID;
    v_sale_payload JSONB;
    v_envelope JSONB;
    v_hash TEXT;
    v_submission UUID;
    v_sale UUID;
    v_count BIGINT;
    v_value NUMERIC;
    v_rejected BOOLEAN;
BEGIN
    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000070091","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000070001',
        'G4_PHASE12_TEST'
    );

    SELECT id INTO v_cash_method
    FROM public.payment_methods
    WHERE company_id = '00000000-0000-0000-0000-000000070001'
      AND method_type = 'CASH' AND is_active
    ORDER BY is_default DESC,id LIMIT 1;
    SELECT id INTO v_customer
    FROM public.customers
    WHERE company_id = '00000000-0000-0000-0000-000000070001'
      AND is_system_customer AND is_active
    ORDER BY id LIMIT 1;
    IF v_cash_method IS NULL OR v_customer IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: provisioned Cash/Walk-In missing';
    END IF;

    v_result := public.open_cashier_session(
        '00000000-0000-0000-0000-000000070021',
        '00000000-0000-0000-0000-000000070031',100
    );
    v_session := (v_result->>'cashierSessionId')::UUID;
    v_result := public.issue_pos_offline_stock_allowance(
        v_session,'00000000-0000-0000-0000-000000070061'
    );
    v_allowance := (v_result->>'allowanceId')::UUID;
    IF (v_result->>'allocatedBaseQty')::NUMERIC <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: expected allowance 2';
    END IF;

    v_sale_payload := jsonb_build_object(
        'clientTransactionId',
            '00000000-0000-0000-0000-000000070101',
        'cashierSessionId',v_session,
        'customerId',v_customer,
        'isTempo',FALSE,
        'globalDiscount',0,
        'roundingDirection','NONE',
        'roundingIncrement',100,
        'lines',jsonb_build_array(jsonb_build_object(
            'lineKey','offline-line-1',
            'productUomId',
                '00000000-0000-0000-0000-000000070071',
            'quantity',1,
            'snapshotUnitPrice',90,
            'lineDiscountInput',0
        )),
        'payments',jsonb_build_array(jsonb_build_object(
            'clientPaymentKey',
                '00000000-0000-0000-0000-000000070111',
            'paymentMethodId',v_cash_method,
            'amount',90,
            'tenderedAmount',100
        ))
    );
    v_hash := encode(extensions.digest(
        convert_to(v_sale_payload::TEXT,'UTF8'),'sha256'
    ),'hex');
    v_envelope := jsonb_build_object(
        'clientTransactionId',
            '00000000-0000-0000-0000-000000070101',
        'postingIdempotencyKey',
            '00000000-0000-0000-0000-000000070102',
        'cashierSessionId',v_session,
        'localMasterVersion',1,
        'payloadVersion',1,
        'localTransactionAt',clock_timestamp() - interval '2 minutes',
        'payloadHash',v_hash,
        'salePayload',v_sale_payload
    );

    v_result := public.submit_pos_offline_sale(v_envelope);
    v_submission := (v_result->>'submissionId')::UUID;
    IF v_result->>'status' <> 'QUEUED'
       OR (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: first submission not queued';
    END IF;
    v_result := public.submit_pos_offline_sale(v_envelope);
    IF NOT (v_result->>'idempotentReplay')::BOOLEAN
       OR (v_result->>'submissionId')::UUID <> v_submission THEN
        RAISE EXCEPTION 'TEST_FAILED: submit retry not idempotent';
    END IF;

    v_result := public.process_pos_offline_sale_submission(v_submission);
    IF v_result->>'status' <> 'POSTED'
       OR (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: Offline Sale did not post';
    END IF;
    v_sale := (v_result->>'salesId')::UUID;

    SELECT count(*) INTO v_count
    FROM public.sales_headers sh
    WHERE sh.company_id =
            '00000000-0000-0000-0000-000000070001'
      AND sh.id = v_sale
      AND sh.document_status = 'POSTED'
      AND sh.source_channel = 'OFFLINE'
      AND sh.offline_submission_id = v_submission
      AND sh.grand_total_after_rounding = 90
      AND sh.offline_price_variance_total = -10;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Offline Sale snapshot invalid';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.sales_details sd
    WHERE sd.company_id =
            '00000000-0000-0000-0000-000000070001'
      AND sd.sales_id = v_sale
      AND sd.resolved_unit_price = 90
      AND sd.offline_snapshot_unit_price = 90
      AND sd.offline_resolved_unit_price = 100
      AND sd.offline_price_variance = -10;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Offline line price not honored';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.sales_payments sp
    WHERE sp.company_id =
            '00000000-0000-0000-0000-000000070001'
      AND sp.sales_id = v_sale
      AND sp.client_payment_key =
            '00000000-0000-0000-0000-000000070111'
      AND sp.offline_verification_status = 'VERIFIED'
      AND sp.offline_reference_snapshot IS NOT NULL;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Offline Cash snapshot invalid';
    END IF;

    SELECT stock_qty INTO v_value
    FROM public.product_stocks
    WHERE company_id = '00000000-0000-0000-0000-000000070001'
      AND product_id = '00000000-0000-0000-0000-000000070061'
      AND warehouse_id = '00000000-0000-0000-0000-000000070031';
    IF v_value <> 9 THEN
        RAISE EXCEPTION 'TEST_FAILED: stock %, expected 9',v_value;
    END IF;
    SELECT sum(qty_remaining) INTO v_value
    FROM public.product_batches
    WHERE company_id = '00000000-0000-0000-0000-000000070001'
      AND product_id = '00000000-0000-0000-0000-000000070061'
      AND warehouse_id = '00000000-0000-0000-0000-000000070031';
    IF v_value <> 9 THEN
        RAISE EXCEPTION 'TEST_FAILED: FIFO %, expected 9',v_value;
    END IF;
    SELECT consumed_base_qty INTO v_value
    FROM public.pos_offline_stock_allowances
    WHERE id = v_allowance;
    IF v_value <> 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: allowance consumed %, expected 1',v_value;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.pos_offline_sale_allowance_consumptions
    WHERE submission_id = v_submission
      AND sales_id = v_sale
      AND consumed_base_qty = 1;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: consumption ledger missing';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.pos_offline_sync_exceptions
    WHERE submission_id = v_submission
      AND exception_type = 'PRICE_VARIANCE';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: price variance audit missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.offline_payment_exceptions
        WHERE submission_id = v_submission
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Cash created payment exception';
    END IF;

    v_result := public.process_pos_offline_sale_submission(v_submission);
    IF NOT (v_result->>'idempotentReplay')::BOOLEAN
       OR (v_result->>'salesId')::UUID <> v_sale THEN
        RAISE EXCEPTION 'TEST_FAILED: process retry not idempotent';
    END IF;
    v_result := public.get_pos_offline_submission_status(
        '00000000-0000-0000-0000-000000070101'
    );
    IF v_result->>'status' <> 'POSTED'
       OR (v_result->'acknowledgement'->>'salesId')::UUID <> v_sale THEN
        RAISE EXCEPTION 'TEST_FAILED: acknowledgement lookup invalid';
    END IF;

    -- The remaining allowance is one. A physical Offline Sale requiring two
    -- must fail atomically without a second Sale/Movement/consumption.
    v_sale_payload := jsonb_build_object(
        'clientTransactionId',
            '00000000-0000-0000-0000-000000070121',
        'cashierSessionId',v_session,
        'customerId',v_customer,
        'isTempo',FALSE,
        'globalDiscount',0,
        'roundingDirection','NONE',
        'roundingIncrement',100,
        'lines',jsonb_build_array(jsonb_build_object(
            'lineKey','offline-line-2',
            'productUomId',
                '00000000-0000-0000-0000-000000070071',
            'quantity',2,
            'snapshotUnitPrice',100,
            'lineDiscountInput',0
        )),
        'payments',jsonb_build_array(jsonb_build_object(
            'clientPaymentKey',
                '00000000-0000-0000-0000-000000070122',
            'paymentMethodId',v_cash_method,
            'amount',200,
            'tenderedAmount',200
        ))
    );
    v_hash := encode(extensions.digest(
        convert_to(v_sale_payload::TEXT,'UTF8'),'sha256'
    ),'hex');
    v_envelope := jsonb_build_object(
        'clientTransactionId',
            '00000000-0000-0000-0000-000000070121',
        'postingIdempotencyKey',
            '00000000-0000-0000-0000-000000070123',
        'cashierSessionId',v_session,
        'localMasterVersion',1,
        'payloadVersion',1,
        'localTransactionAt',clock_timestamp() - interval '1 minute',
        'payloadHash',v_hash,
        'salePayload',v_sale_payload
    );
    v_result := public.submit_pos_offline_sale(v_envelope);
    v_submission := (v_result->>'submissionId')::UUID;
    v_result := public.process_pos_offline_sale_submission(v_submission);
    IF v_result->>'status' <> 'FAILED'
       OR v_result->>'errorCode' <>
            'OFFLINE_ALLOWANCE_INSUFFICIENT' THEN
        RAISE EXCEPTION
            'TEST_FAILED: insufficient allowance not failed safely';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.sales_headers
    WHERE company_id = '00000000-0000-0000-0000-000000070001';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: failed sync persisted a Sale';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.pos_offline_sale_allowance_consumptions;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: failed sync consumed allowance';
    END IF;
    SELECT stock_qty INTO v_value
    FROM public.product_stocks
    WHERE company_id = '00000000-0000-0000-0000-000000070001'
      AND product_id = '00000000-0000-0000-0000-000000070061'
      AND warehouse_id = '00000000-0000-0000-0000-000000070031';
    IF v_value <> 9 THEN
        RAISE EXCEPTION 'TEST_FAILED: failed sync changed stock';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.submit_pos_offline_sale(
            jsonb_set(
                v_envelope,'{payloadHash}',
                to_jsonb(repeat('0',64)),TRUE
            )
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM IN (
            'OFFLINE_PAYLOAD_HASH_MISMATCH',
            'OFFLINE_SUBMISSION_IDEMPOTENCY_CONFLICT'
        ) THEN
            v_rejected := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: hash tampering accepted';
    END IF;

    IF has_table_privilege(
        'authenticated',
        'public.pos_offline_sale_allowance_consumptions',
        'INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.pos_offline_sync_exceptions',
        'INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.offline_payment_exceptions',
        'INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated','public.submit_pos_offline_sale(jsonb)','EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.process_pos_offline_sale_submission(uuid)','EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Offline sync privilege boundary invalid';
    END IF;

    RAISE NOTICE
        'TEST PASSED: Offline hash/idempotency, snapshot price, canonical Post, allowance consumption, failure rollback, and acknowledgement are safe.';
END
$test$;

ROLLBACK;
