-- G4 phase 2 behavioral test: guarded Cashier Session lifecycle.
-- SAFETY: every Auth, Company, master, Session, snapshot, and audit fixture is
-- rolled back.

BEGIN;

INSERT INTO auth.users(
    id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at
) VALUES (
    '00000000-0000-0000-0000-000000050091',
    'g4-session-cashier@example.invalid',
    '00000000-0000-0000-0000-000000000000',
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"name":"G4 Session Cashier"}'::jsonb,
    FALSE,'authenticated','authenticated',clock_timestamp()
);

INSERT INTO public.profiles(id,email,name,role)
VALUES (
    '00000000-0000-0000-0000-000000050091',
    'g4-session-cashier@example.invalid',
    'G4 Session Cashier',
    'cashier'::public.user_role
)
ON CONFLICT(id) DO UPDATE SET
    name = EXCLUDED.name,
    role = EXCLUDED.role;

INSERT INTO public.companies(
    id,company_code,company_name,company_slug,status
) VALUES
    (
        '00000000-0000-0000-0000-000000050001',
        'G50A','G50 Company A','g50-company-a','ACTIVE'
    ),
    (
        '00000000-0000-0000-0000-000000050002',
        'G50B','G50 Company B','g50-company-b','ACTIVE'
    );

INSERT INTO public.stores(
    id,company_id,store_code,store_name,status
) VALUES (
    '00000000-0000-0000-0000-000000050011',
    '00000000-0000-0000-0000-000000050001',
    'A1','G50 Store A','ACTIVE'
);

INSERT INTO public.pos_terminals(
    id,company_id,store_id,pos_code,pos_name,status
) VALUES (
    '00000000-0000-0000-0000-000000050021',
    '00000000-0000-0000-0000-000000050001',
    '00000000-0000-0000-0000-000000050011',
    'POS1','G50 POS 1','ACTIVE'
);

INSERT INTO public.company_memberships(
    company_id,user_id,role_code,status,is_default_company
) VALUES (
    '00000000-0000-0000-0000-000000050001',
    '00000000-0000-0000-0000-000000050091',
    'CASHIER','ACTIVE',TRUE
);

INSERT INTO public.store_memberships(
    company_id,store_id,user_id,role_code,status
) VALUES (
    '00000000-0000-0000-0000-000000050001',
    '00000000-0000-0000-0000-000000050011',
    '00000000-0000-0000-0000-000000050091',
    'CASHIER','ACTIVE'
);

INSERT INTO public.warehouses(
    id,company_id,code,name,warehouse_type,store_id,
    is_sale_source,is_purchase_destination,is_active
) VALUES
    (
        '00000000-0000-0000-0000-000000050031',
        '00000000-0000-0000-0000-000000050001',
        'SWA','G50 Sales Warehouse A','STORE',
        '00000000-0000-0000-0000-000000050011',
        TRUE,FALSE,TRUE
    ),
    (
        '00000000-0000-0000-0000-000000050032',
        '00000000-0000-0000-0000-000000050002',
        'SWB','G50 Sales Warehouse B','CENTRAL',
        NULL,TRUE,FALSE,TRUE
    );

INSERT INTO public.product_categories(
    id,company_id,category_code,category_name
) VALUES (
    '00000000-0000-0000-0000-000000050041',
    '00000000-0000-0000-0000-000000050001',
    'TEST','Test Product'
);

INSERT INTO public.uoms(
    id,company_id,code,name,uom_type,allow_decimal,decimal_precision
) VALUES (
    '00000000-0000-0000-0000-000000050051',
    '00000000-0000-0000-0000-000000050001',
    'PCS','Piece','UNIT',FALSE,0
);

INSERT INTO public.products(
    id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
    weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
) VALUES (
    '00000000-0000-0000-0000-000000050061',
    '00000000-0000-0000-0000-000000050001',
    'G50-PROD','G50 Product','Test Product',
    '00000000-0000-0000-0000-000000050041',
    100,50,'PCS',
    '00000000-0000-0000-0000-000000050051',
    '00000000-0000-0000-0000-000000050051',
    1,TRUE,FALSE
);

INSERT INTO public.product_uoms(
    company_id,product_id,uom_id,factor_to_base,
    purchase_allowed,sales_allowed,purchase_price,sale_price,is_active
) VALUES (
    '00000000-0000-0000-0000-000000050001',
    '00000000-0000-0000-0000-000000050061',
    '00000000-0000-0000-0000-000000050051',
    1,TRUE,TRUE,50,100,TRUE
);

INSERT INTO public.product_stocks(
    company_id,product_id,warehouse_id,stock_qty
) VALUES (
    '00000000-0000-0000-0000-000000050001',
    '00000000-0000-0000-0000-000000050061',
    '00000000-0000-0000-0000-000000050031',
    5
);

DO $test$
DECLARE
    v_result JSONB;
    v_session UUID;
    v_count BIGINT;
    v_rejected BOOLEAN;
BEGIN
    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000050091","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000050001',
        'G4_PHASE2_TEST'
    );

    v_rejected := FALSE;
    BEGIN
        PERFORM public.open_cashier_session(
            '00000000-0000-0000-0000-000000050021',
            '00000000-0000-0000-0000-000000050032',
            100
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_SALES_WAREHOUSE_NOT_FOUND' THEN
            v_rejected := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: cross-Company sales Warehouse accepted';
    END IF;

    v_result := public.open_cashier_session(
        '00000000-0000-0000-0000-000000050021',
        '00000000-0000-0000-0000-000000050031',
        100
    );
    v_session := (v_result->>'cashierSessionId')::UUID;

    IF COALESCE((v_result->>'idempotentReplay')::BOOLEAN,TRUE) THEN
        RAISE EXCEPTION 'TEST_FAILED: first Session open marked replay';
    END IF;
    IF (v_result->>'masterVersion')::BIGINT <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: initial Session version invalid';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.cashier_sessions cs
    WHERE cs.id = v_session
      AND cs.company_id = '00000000-0000-0000-0000-000000050001'
      AND cs.store_id = '00000000-0000-0000-0000-000000050011'
      AND cs.pos_id = '00000000-0000-0000-0000-000000050021'
      AND cs.sales_warehouse_id =
          '00000000-0000-0000-0000-000000050031'
      AND cs.cashier_id = '00000000-0000-0000-0000-000000050091'
      AND cs.opening_cash_actual = 100
      AND cs.opening_balance = 100
      AND cs.status = 'OPEN'::public.session_status
      AND cs.opening_stock_snapshot_at IS NOT NULL;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: canonical OPEN Session row invalid';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.cashier_session_stock_snapshots s
    WHERE s.cashier_session_id = v_session
      AND s.snapshot_stage = 'OPENING'
      AND s.product_id = '00000000-0000-0000-0000-000000050061'
      AND s.stock_qty_base = 5
      AND s.base_uom_name_snapshot = 'Piece';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: opening stock snapshot invalid';
    END IF;

    v_result := public.open_cashier_session(
        '00000000-0000-0000-0000-000000050021',
        '00000000-0000-0000-0000-000000050031',
        100
    );
    IF (v_result->>'cashierSessionId')::UUID <> v_session
       OR NOT (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: Session open retry was not idempotent';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.open_cashier_session(
            '00000000-0000-0000-0000-000000050021',
            '00000000-0000-0000-0000-000000050031',
            101
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'CASHIER_SESSION_ALREADY_OPEN' THEN
            v_rejected := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: second OPEN Session accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.close_cashier_session(v_session,2,90);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'MASTER_VERSION_CONFLICT' THEN
            v_rejected := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale Session close accepted';
    END IF;

    v_result := public.close_cashier_session(v_session,1,90);
    IF (v_result->>'masterVersion')::BIGINT <> 2
       OR (v_result->>'expectedCash')::NUMERIC <> 100
       OR (v_result->>'closingCashActual')::NUMERIC <> 90
       OR (v_result->>'difference')::NUMERIC <> -10
       OR (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: Session close result invalid: %',v_result;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.cashier_sessions cs
    WHERE cs.id = v_session
      AND cs.status = 'CLOSED'::public.session_status
      AND cs.expected_cash = 100
      AND cs.actual_cash = 90
      AND cs.closing_cash_actual = 90
      AND cs.difference = -10
      AND cs.master_version = 2
      AND cs.closing_stock_snapshot_at IS NOT NULL;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: canonical CLOSED Session row invalid';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.cashier_session_stock_snapshots
    WHERE cashier_session_id = v_session;
    IF v_count <> 2 THEN
        RAISE EXCEPTION
            'TEST_FAILED: expected opening and closing snapshots, got %',
            v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.cashier_session_audit
    WHERE cashier_session_id = v_session
      AND action IN ('OPEN','CLOSE');
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Session lifecycle audit incomplete';
    END IF;

    v_result := public.close_cashier_session(v_session,1,90);
    IF NOT (v_result->>'idempotentReplay')::BOOLEAN
       OR (v_result->>'masterVersion')::BIGINT <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Session close retry was not idempotent';
    END IF;

    IF has_table_privilege(
        'authenticated','public.cashier_sessions','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated',
        'public.cashier_session_stock_snapshots',
        'INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.cashier_session_audit','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.open_cashier_session(uuid,uuid,numeric)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.close_cashier_session(uuid,bigint,numeric)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier Session privilege boundary invalid';
    END IF;

    RAISE NOTICE
        'TEST PASSED: Cashier Session open/close is tenant-safe, one-open, cash-counted, stock-snapshotted, versioned, idempotent, and audited.';
END
$test$;

ROLLBACK;
