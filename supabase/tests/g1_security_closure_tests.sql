-- G1 integrated negative-access closure test.
-- SAFETY: every Auth/business/feature/context mutation is rolled back.

BEGIN;

INSERT INTO auth.users(
    id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at
) VALUES
    (
        '00000000-0000-0000-0000-000000010091',
        'g1close-super@example.invalid',
        '00000000-0000-0000-0000-000000000000',
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{"name":"G1 Closure Super"}'::jsonb,
        FALSE,'authenticated','authenticated',now()
    ),
    (
        '00000000-0000-0000-0000-000000010092',
        'g1close-admin@example.invalid',
        '00000000-0000-0000-0000-000000000000',
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{"name":"G1 Closure Admin"}'::jsonb,
        FALSE,'authenticated','authenticated',now()
    ),
    (
        '00000000-0000-0000-0000-000000010093',
        'g1close-cashier@example.invalid',
        '00000000-0000-0000-0000-000000000000',
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{"name":"G1 Closure Cashier"}'::jsonb,
        FALSE,'authenticated','authenticated',now()
    );

INSERT INTO public.profiles(id,email,name,role) VALUES
    (
        '00000000-0000-0000-0000-000000010091',
        'g1close-super@example.invalid','G1 Closure Super',
        'super_admin'::user_role
    ),
    (
        '00000000-0000-0000-0000-000000010092',
        'g1close-admin@example.invalid','G1 Closure Admin',
        'cashier'::user_role
    ),
    (
        '00000000-0000-0000-0000-000000010093',
        'g1close-cashier@example.invalid','G1 Closure Cashier',
        'cashier'::user_role
    )
ON CONFLICT(id) DO UPDATE SET
    name = EXCLUDED.name,
    role = EXCLUDED.role;

INSERT INTO public.companies(
    id,company_code,company_name,company_slug,status
) VALUES
    (
        '00000000-0000-0000-0000-000000010001',
        'G10A','G10 Company A','g10-company-a','ACTIVE'
    ),
    (
        '00000000-0000-0000-0000-000000010002',
        'G10B','G10 Company B','g10-company-b','ACTIVE'
    );

INSERT INTO public.stores(id,company_id,store_code,store_name,status) VALUES
    (
        '00000000-0000-0000-0000-000000010011',
        '00000000-0000-0000-0000-000000010001',
        'A1','G10 Store A','ACTIVE'
    ),
    (
        '00000000-0000-0000-0000-000000010012',
        '00000000-0000-0000-0000-000000010002',
        'B1','G10 Store B','ACTIVE'
    );

INSERT INTO public.pos_terminals(
    id,company_id,store_id,pos_code,pos_name,status
) VALUES
    (
        '00000000-0000-0000-0000-000000010021',
        '00000000-0000-0000-0000-000000010001',
        '00000000-0000-0000-0000-000000010011',
        'PA','G10 POS A','ACTIVE'
    ),
    (
        '00000000-0000-0000-0000-000000010022',
        '00000000-0000-0000-0000-000000010002',
        '00000000-0000-0000-0000-000000010012',
        'PB','G10 POS B','ACTIVE'
    );

INSERT INTO public.warehouses(id,company_id,code,name,is_active) VALUES
    (
        '00000000-0000-0000-0000-000000010031',
        '00000000-0000-0000-0000-000000010001',
        'WA','G10 Warehouse A',TRUE
    ),
    (
        '00000000-0000-0000-0000-000000010032',
        '00000000-0000-0000-0000-000000010002',
        'WB','G10 Warehouse B',TRUE
    );

INSERT INTO public.products(
    id,company_id,sku,name,price,cogs,uom,is_active,is_bundle
) VALUES
    (
        '00000000-0000-0000-0000-000000010041',
        '00000000-0000-0000-0000-000000010001',
        'G10PA','G10 Product A',100,50,'PCS',TRUE,FALSE
    ),
    (
        '00000000-0000-0000-0000-000000010042',
        '00000000-0000-0000-0000-000000010002',
        'G10PB','G10 Product B',100,50,'PCS',TRUE,FALSE
    );

INSERT INTO public.company_memberships(
    company_id,user_id,role_code,status,is_default_company
) VALUES
    (
        '00000000-0000-0000-0000-000000010001',
        '00000000-0000-0000-0000-000000010092',
        'COMPANY_ADMIN','ACTIVE',TRUE
    ),
    (
        '00000000-0000-0000-0000-000000010001',
        '00000000-0000-0000-0000-000000010093',
        'CASHIER','ACTIVE',TRUE
    );

INSERT INTO public.store_memberships(
    company_id,store_id,user_id,role_code,status
) VALUES (
    '00000000-0000-0000-0000-000000010001',
    '00000000-0000-0000-0000-000000010011',
    '00000000-0000-0000-0000-000000010093',
    'CASHIER','ACTIVE'
);

INSERT INTO public.cashier_sessions(
    id,session_code,cashier_id,company_id,store_id,pos_id,status
) VALUES
    (
        '00000000-0000-0000-0000-000000010051','G10-SA',
        '00000000-0000-0000-0000-000000010093',
        '00000000-0000-0000-0000-000000010001',
        '00000000-0000-0000-0000-000000010011',
        '00000000-0000-0000-0000-000000010021',
        'CLOSED'::session_status
    ),
    (
        '00000000-0000-0000-0000-000000010052','G10-SB',
        '00000000-0000-0000-0000-000000010093',
        '00000000-0000-0000-0000-000000010002',
        '00000000-0000-0000-0000-000000010012',
        '00000000-0000-0000-0000-000000010022',
        'CLOSED'::session_status
    );

INSERT INTO public.sales_headers(
    id,invoice_no,session_id,company_id,store_id,pos_id,created_by
) VALUES
    (
        '00000000-0000-0000-0000-000000010061','G10-INV-A',
        '00000000-0000-0000-0000-000000010051',
        '00000000-0000-0000-0000-000000010001',
        '00000000-0000-0000-0000-000000010011',
        '00000000-0000-0000-0000-000000010021',
        '00000000-0000-0000-0000-000000010093'
    ),
    (
        '00000000-0000-0000-0000-000000010062','G10-INV-B',
        '00000000-0000-0000-0000-000000010052',
        '00000000-0000-0000-0000-000000010002',
        '00000000-0000-0000-0000-000000010012',
        '00000000-0000-0000-0000-000000010022',
        '00000000-0000-0000-0000-000000010093'
    );

INSERT INTO public.financial_events(
    event_code,event_type,source_table,source_id,root_sales_id,
    idempotency_key,amounts,company_id,store_id
) VALUES
    (
        'G10-E-A','SALE_POSTED'::event_type,'G1_CLOSURE_TEST',
        '00000000-0000-0000-0000-000000010061',
        '00000000-0000-0000-0000-000000010061',
        'G10|E|A','{}'::jsonb,
        '00000000-0000-0000-0000-000000010001',
        '00000000-0000-0000-0000-000000010011'
    ),
    (
        'G10-E-B','SALE_POSTED'::event_type,'G1_CLOSURE_TEST',
        '00000000-0000-0000-0000-000000010062',
        '00000000-0000-0000-0000-000000010062',
        'G10|E|B','{}'::jsonb,
        '00000000-0000-0000-0000-000000010002',
        '00000000-0000-0000-0000-000000010012'
    );

INSERT INTO public.stock_movements(
    product_id,warehouse_id,qty_change,movement_type,
    reference_table,reference_id,company_id
) VALUES
    -- These are rollback-only tenant-visibility fixtures, not canonical
    -- Adjustment documents. PURCHASE keeps the positive movement semantically
    -- valid without bypassing the G3 Adjustment snapshot/source constraint.
    (
        '00000000-0000-0000-0000-000000010041',
        '00000000-0000-0000-0000-000000010031',1,
        'PURCHASE'::stock_movement_type,'G1_CLOSURE_TEST',
        '00000000-0000-0000-0000-000000010061',
        '00000000-0000-0000-0000-000000010001'
    ),
    (
        '00000000-0000-0000-0000-000000010042',
        '00000000-0000-0000-0000-000000010032',1,
        'PURCHASE'::stock_movement_type,'G1_CLOSURE_TEST',
        '00000000-0000-0000-0000-000000010062',
        '00000000-0000-0000-0000-000000010002'
    );

INSERT INTO public.stock_opnames(
    opname_no,warehouse_id,status,created_by,company_id
) VALUES
    (
        'G10-OP-A','00000000-0000-0000-0000-000000010031',
        'DRAFT'::opname_status,
        '00000000-0000-0000-0000-000000010093',
        '00000000-0000-0000-0000-000000010001'
    ),
    (
        'G10-OP-B','00000000-0000-0000-0000-000000010032',
        'DRAFT'::opname_status,
        '00000000-0000-0000-0000-000000010093',
        '00000000-0000-0000-0000-000000010002'
    );

-- Anonymous callers have neither table access nor executable public RPC.
SET LOCAL ROLE anon;

DO $anon_test$
DECLARE
    v_blocked BOOLEAN := FALSE;
BEGIN
    BEGIN
        PERFORM count(*) FROM public.companies;
    EXCEPTION WHEN insufficient_privilege THEN
        v_blocked := TRUE;
    END;

    IF NOT v_blocked THEN
        RAISE EXCEPTION 'TEST_FAILED: anon read public Company table';
    END IF;

    IF has_function_privilege(
        'anon','public.set_active_company_context(uuid,text)','EXECUTE'
    ) OR has_function_privilege(
        'anon','public.import_products_for_company(uuid,jsonb)','EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: anon can execute authenticated RPC';
    END IF;
END
$anon_test$;

RESET ROLE;
SET LOCAL ROLE authenticated;

DO $authenticated_test$
DECLARE
    v_count BIGINT;
    v_blocked BOOLEAN;
BEGIN
    -- Company Admin: own active Company only.
    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000010092","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000010001','G1_CLOSURE_TEST'
    );

    SELECT count(*) INTO v_count FROM public.companies;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Company Admin saw % Companies',v_count;
    END IF;
    SELECT count(*) INTO v_count FROM public.products
    WHERE sku LIKE 'G10P%';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Company Admin saw % Products',v_count;
    END IF;
    SELECT count(*) INTO v_count FROM public.sales_headers
    WHERE invoice_no LIKE 'G10-INV-%';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Company Admin saw % Sales',v_count;
    END IF;
    SELECT count(*) INTO v_count FROM public.financial_events
    WHERE source_table = 'G1_CLOSURE_TEST';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Company Admin saw % Events',v_count;
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_movements
    WHERE reference_table = 'G1_CLOSURE_TEST';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Company Admin saw % Movements',v_count;
    END IF;

    v_blocked := FALSE;
    BEGIN
        PERFORM public.set_active_company_context(
            '00000000-0000-0000-0000-000000010002','G1_CLOSURE_TEST'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'COMPANY_ACCESS_DENIED' THEN
            v_blocked := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_blocked THEN
        RAISE EXCEPTION 'TEST_FAILED: Company Admin selected foreign Company';
    END IF;

    v_blocked := FALSE;
    BEGIN
        PERFORM public.set_company_feature(
            '00000000-0000-0000-0000-000000010001',
            'tax_sales_enabled',TRUE,'{}'::jsonb
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'SUPER_ADMIN_REQUIRED' THEN
            v_blocked := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_blocked THEN
        RAISE EXCEPTION 'TEST_FAILED: Company Admin changed entitlement';
    END IF;

    v_blocked := FALSE;
    BEGIN
        UPDATE public.profiles
        SET role = 'super_admin'::user_role
        WHERE id = '00000000-0000-0000-0000-000000010092';
    EXCEPTION WHEN insufficient_privilege THEN
        v_blocked := TRUE;
    END;
    IF NOT v_blocked THEN
        RAISE EXCEPTION 'TEST_FAILED: Company Admin escalated profile role';
    END IF;

    -- Cashier: operational own rows, no Finance/Movement ledger.
    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000010093","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000010001','G1_CLOSURE_TEST'
    );

    SELECT count(*) INTO v_count FROM public.sales_headers
    WHERE invoice_no LIKE 'G10-INV-%';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier saw % own Sales',v_count;
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_opnames
    WHERE opname_no LIKE 'G10-OP-%';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier saw % own Opnames',v_count;
    END IF;
    SELECT count(*) INTO v_count FROM public.financial_events
    WHERE source_table = 'G1_CLOSURE_TEST';
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier saw Financial Event';
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_movements
    WHERE reference_table = 'G1_CLOSURE_TEST';
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier saw Stock Movement';
    END IF;

    IF has_table_privilege(
        'authenticated','public.sales_headers','INSERT'
    ) OR has_table_privilege(
        'authenticated','public.financial_events','UPDATE'
    ) OR has_table_privilege(
        'authenticated','public.stock_movements','DELETE'
    ) OR has_function_privilege(
        'authenticated',
        'public.process_financial_events_queue()','EXECUTE'
    ) OR has_function_privilege(
        'authenticated',
        'public.transfer_product_stock(uuid,uuid,uuid,numeric)','EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: authenticated unsafe mutation remains';
    END IF;

    -- Super Admin: explicit active Company enables cross-Company operation.
    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000010091","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000010002','G1_CLOSURE_TEST'
    );

    SELECT count(*) INTO v_count FROM public.products
    WHERE sku LIKE 'G10P%';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Super Admin active Company scope invalid';
    END IF;
    SELECT count(*) INTO v_count FROM public.financial_events
    WHERE source_table = 'G1_CLOSURE_TEST';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Super Admin Finance scope invalid';
    END IF;

    PERFORM public.set_company_feature(
        '00000000-0000-0000-0000-000000010002',
        'tax_sales_enabled',TRUE,'{"closure_test":true}'::jsonb
    );
    IF NOT public.private_company_feature_enabled(
        '00000000-0000-0000-0000-000000010002','tax_sales_enabled'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Super Admin entitlement mutation failed';
    END IF;

    RAISE NOTICE 'TEST PASSED: G1 integrated tenant, role, feature, RPC, Finance, and Inventory boundaries are closed.';
END
$authenticated_test$;

RESET ROLE;
ROLLBACK;
