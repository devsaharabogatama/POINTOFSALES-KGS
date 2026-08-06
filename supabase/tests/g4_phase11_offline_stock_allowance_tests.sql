-- G4 phase 11 behavior: guarded Offline Stock Allowance reservation.
-- SAFETY: every Auth/master/stock/Session/policy/allowance fixture rolls back.

BEGIN;

INSERT INTO auth.users(
    id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at
) VALUES (
    '00000000-0000-0000-0000-000000060091',
    'g4-offline-cashier@example.invalid',
    '00000000-0000-0000-0000-000000000000',
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"name":"G4 Offline Cashier"}'::jsonb,
    FALSE,'authenticated','authenticated',clock_timestamp()
);

INSERT INTO public.profiles(id,email,name,role)
VALUES (
    '00000000-0000-0000-0000-000000060091',
    'g4-offline-cashier@example.invalid',
    'G4 Offline Cashier','cashier'::public.user_role
)
ON CONFLICT(id) DO UPDATE SET
    email = EXCLUDED.email,
    name = EXCLUDED.name,
    role = EXCLUDED.role;

INSERT INTO public.companies(
    id,company_code,company_name,company_slug,status
) VALUES
    (
        '00000000-0000-0000-0000-000000060001',
        'G60A','G60 Company A','g60-company-a','ACTIVE'
    ),
    (
        '00000000-0000-0000-0000-000000060002',
        'G60B','G60 Company B','g60-company-b','ACTIVE'
    );

INSERT INTO public.stores(id,company_id,store_code,store_name,status)
VALUES (
    '00000000-0000-0000-0000-000000060011',
    '00000000-0000-0000-0000-000000060001',
    'S1','G60 Store','ACTIVE'
);

INSERT INTO public.pos_terminals(
    id,company_id,store_id,pos_code,pos_name,status
) VALUES (
    '00000000-0000-0000-0000-000000060021',
    '00000000-0000-0000-0000-000000060001',
    '00000000-0000-0000-0000-000000060011',
    'POS1','G60 POS','ACTIVE'
);

INSERT INTO public.company_memberships(
    company_id,user_id,role_code,status,is_default_company
) VALUES (
    '00000000-0000-0000-0000-000000060001',
    '00000000-0000-0000-0000-000000060091',
    'CASHIER','ACTIVE',TRUE
);

INSERT INTO public.store_memberships(
    company_id,store_id,user_id,role_code,status
) VALUES (
    '00000000-0000-0000-0000-000000060001',
    '00000000-0000-0000-0000-000000060011',
    '00000000-0000-0000-0000-000000060091',
    'CASHIER','ACTIVE'
);

INSERT INTO public.warehouses(
    id,company_id,code,name,warehouse_type,store_id,
    is_sale_source,is_purchase_destination,is_active
) VALUES (
    '00000000-0000-0000-0000-000000060031',
    '00000000-0000-0000-0000-000000060001',
    'SWA','G60 Sales Warehouse','STORE',
    '00000000-0000-0000-0000-000000060011',
    TRUE,FALSE,TRUE
);

INSERT INTO public.product_categories(
    id,company_id,category_code,category_name
) VALUES
    (
        '00000000-0000-0000-0000-000000060041',
        '00000000-0000-0000-0000-000000060001',
        'TEST','Test'
    ),
    (
        '00000000-0000-0000-0000-000000060042',
        '00000000-0000-0000-0000-000000060002',
        'TEST','Test'
    );

INSERT INTO public.uoms(
    id,company_id,code,name,uom_type,allow_decimal,decimal_precision
) VALUES
    (
        '00000000-0000-0000-0000-000000060051',
        '00000000-0000-0000-0000-000000060001',
        'PCS','Piece','UNIT',FALSE,0
    ),
    (
        '00000000-0000-0000-0000-000000060052',
        '00000000-0000-0000-0000-000000060002',
        'PCS','Piece','UNIT',FALSE,0
    );

INSERT INTO public.products(
    id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
    weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
) VALUES
    (
        '00000000-0000-0000-0000-000000060061',
        '00000000-0000-0000-0000-000000060001',
        'G60-P','G60 Product','Test',
        '00000000-0000-0000-0000-000000060041',
        100,50,'PCS',
        '00000000-0000-0000-0000-000000060051',
        '00000000-0000-0000-0000-000000060051',
        1,TRUE,FALSE
    ),
    (
        '00000000-0000-0000-0000-000000060062',
        '00000000-0000-0000-0000-000000060002',
        'G60-X','G60 Cross Product','Test',
        '00000000-0000-0000-0000-000000060042',
        100,50,'PCS',
        '00000000-0000-0000-0000-000000060052',
        '00000000-0000-0000-0000-000000060052',
        1,TRUE,FALSE
    );

INSERT INTO public.product_uoms(
    company_id,product_id,uom_id,factor_to_base,
    purchase_allowed,sales_allowed,purchase_price,sale_price,is_active
) VALUES
    (
        '00000000-0000-0000-0000-000000060001',
        '00000000-0000-0000-0000-000000060061',
        '00000000-0000-0000-0000-000000060051',
        1,TRUE,TRUE,50,100,TRUE
    ),
    (
        '00000000-0000-0000-0000-000000060002',
        '00000000-0000-0000-0000-000000060062',
        '00000000-0000-0000-0000-000000060052',
        1,TRUE,TRUE,50,100,TRUE
    );

INSERT INTO public.product_stocks(
    company_id,product_id,warehouse_id,stock_qty
) VALUES (
    '00000000-0000-0000-0000-000000060001',
    '00000000-0000-0000-0000-000000060061',
    '00000000-0000-0000-0000-000000060031',10
);

INSERT INTO public.company_features(
    company_id,feature_code,is_enabled,config
) VALUES (
    '00000000-0000-0000-0000-000000060001',
    'offline_pos_enabled',TRUE,'{}'::jsonb
);

DO $test$
DECLARE
    v_admin UUID;
    v_result JSONB;
    v_company_policy UUID;
    v_terminal_policy UUID;
    v_store_policy UUID;
    v_session UUID;
    v_allowance UUID;
    v_second_allowance UUID;
    v_version BIGINT;
    v_count BIGINT;
    v_rejected BOOLEAN;
BEGIN
    SELECT p.id INTO v_admin
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::public.user_role
    ORDER BY p.id LIMIT 1;
    IF v_admin IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object(
            'sub',v_admin,'role','authenticated'
        )::text,
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000060001',
        'G4_PHASE11_TEST_ADMIN'
    );

    v_result := public.save_pos_offline_allowance_policy(
        NULL,NULL,'COMPANY',NULL,NULL,0.2,TRUE
    );
    v_company_policy := (v_result->>'policyId')::UUID;
    v_result := public.save_pos_offline_allowance_policy(
        NULL,NULL,'STORE',
        '00000000-0000-0000-0000-000000060011',
        NULL,0.1,TRUE
    );
    v_store_policy := (v_result->>'policyId')::UUID;
    v_result := public.save_pos_offline_allowance_policy(
        NULL,NULL,'TERMINAL',
        '00000000-0000-0000-0000-000000060011',
        '00000000-0000-0000-0000-000000060021',
        NULL,TRUE
    );
    v_terminal_policy := (v_result->>'policyId')::UUID;

    IF v_company_policy IS NULL OR v_store_policy IS NULL
       OR v_terminal_policy IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: policy creation missing';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000060091","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000060001',
        'G4_PHASE11_TEST_CASHIER'
    );
    v_result := public.open_cashier_session(
        '00000000-0000-0000-0000-000000060021',
        '00000000-0000-0000-0000-000000060031',100
    );
    v_session := (v_result->>'cashierSessionId')::UUID;

    v_result := public.issue_pos_offline_stock_allowance(
        v_session,'00000000-0000-0000-0000-000000060061'
    );
    v_allowance := (v_result->>'allowanceId')::UUID;
    v_version := (v_result->>'masterVersion')::BIGINT;
    IF (v_result->>'allocatedBaseQty')::NUMERIC <> 1
       OR COALESCE((v_result->>'replayed')::BOOLEAN,TRUE) THEN
        RAISE EXCEPTION
            'TEST_FAILED: Store 10 percent allowance should equal 1';
    END IF;

    v_result := public.issue_pos_offline_stock_allowance(
        v_session,'00000000-0000-0000-0000-000000060061'
    );
    IF (v_result->>'allowanceId')::UUID <> v_allowance
       OR NOT COALESCE((v_result->>'replayed')::BOOLEAN,FALSE) THEN
        RAISE EXCEPTION 'TEST_FAILED: allowance retry not idempotent';
    END IF;

    v_rejected := FALSE;
    BEGIN
        UPDATE public.product_stocks
        SET stock_qty = 0
        WHERE company_id = '00000000-0000-0000-0000-000000060001'
          AND product_id = '00000000-0000-0000-0000-000000060061'
          AND warehouse_id = '00000000-0000-0000-0000-000000060031';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'STOCK_RESERVED_FOR_OFFLINE_ALLOWANCE' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: reserved stock could be consumed';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.close_cashier_session(v_session,1,100);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'OFFLINE_ALLOWANCE_RELEASE_REQUIRED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: Session closed with active allowance';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.issue_pos_offline_stock_allowance(
            v_session,'00000000-0000-0000-0000-000000060062'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company Product accepted';
    END IF;

    v_result := public.release_pos_offline_stock_allowance(
        v_allowance,v_version,FALSE,NULL
    );
    IF v_result->>'status' <> 'RELEASED' THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier release failed';
    END IF;

    UPDATE public.product_stocks
    SET stock_qty = 0
    WHERE company_id = '00000000-0000-0000-0000-000000060001'
      AND product_id = '00000000-0000-0000-0000-000000060061'
      AND warehouse_id = '00000000-0000-0000-0000-000000060031';

    UPDATE public.product_stocks
    SET stock_qty = 10
    WHERE company_id = '00000000-0000-0000-0000-000000060001'
      AND product_id = '00000000-0000-0000-0000-000000060061'
      AND warehouse_id = '00000000-0000-0000-0000-000000060031';

    UPDATE public.company_features
    SET is_enabled = FALSE
    WHERE company_id = '00000000-0000-0000-0000-000000060001'
      AND feature_code = 'offline_pos_enabled';
    v_rejected := FALSE;
    BEGIN
        PERFORM public.issue_pos_offline_stock_allowance(
            v_session,'00000000-0000-0000-0000-000000060061'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'OFFLINE_POS_FEATURE_DISABLED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: disabled Offline entitlement accepted';
    END IF;
    UPDATE public.company_features
    SET is_enabled = TRUE
    WHERE company_id = '00000000-0000-0000-0000-000000060001'
      AND feature_code = 'offline_pos_enabled';

    v_result := public.issue_pos_offline_stock_allowance(
        v_session,'00000000-0000-0000-0000-000000060061'
    );
    v_second_allowance := (v_result->>'allowanceId')::UUID;
    v_version := (v_result->>'masterVersion')::BIGINT;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object(
            'sub',v_admin,'role','authenticated'
        )::text,
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000060001',
        'G4_PHASE11_TEST_REVOKE'
    );
    v_result := public.release_pos_offline_stock_allowance(
        v_second_allowance,v_version,TRUE,'Terminal lost test'
    );
    IF v_result->>'status' <> 'REVOKED' THEN
        RAISE EXCEPTION 'TEST_FAILED: Manager force revoke failed';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000060091","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000060001',
        'G4_PHASE11_TEST_CLOSE'
    );
    PERFORM public.close_cashier_session(v_session,1,100);

    SELECT count(*) INTO v_count
    FROM public.pos_offline_stock_allowance_audit
    WHERE company_id = '00000000-0000-0000-0000-000000060001'
      AND (
          policy_id IN (
              v_company_policy,v_store_policy,v_terminal_policy
          )
          OR allowance_id IN (v_allowance,v_second_allowance)
      );
    IF v_count <> 7 THEN
        RAISE EXCEPTION
            'TEST_FAILED: expected 7 policy/allowance audit rows, got %',
            v_count;
    END IF;

    v_rejected := FALSE;
    BEGIN
        DELETE FROM public.pos_offline_stock_allowances
        WHERE id = v_allowance;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'OFFLINE_HISTORY_MUTATION_FORBIDDEN' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: Offline allowance history could be deleted';
    END IF;

    IF has_table_privilege(
        'authenticated',
        'public.pos_offline_stock_allowances','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated',
        'public.pos_offline_sale_submissions','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.issue_pos_offline_stock_allowance(uuid,uuid)','EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: Offline allowance privilege boundary invalid';
    END IF;

    RAISE NOTICE
        'TEST PASSED: Offline allowance is policy-scoped, idempotent, reserved, tenant-safe, releasable, audited, and blocks Session close.';
END
$test$;

ROLLBACK;
