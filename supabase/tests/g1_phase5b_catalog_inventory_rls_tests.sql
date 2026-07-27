-- G1 phase 5B behavioral test: catalog/inventory role and tenant boundary.
-- SAFETY: all Auth and business fixtures are rolled back.

BEGIN;

INSERT INTO auth.users (
    id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at
) VALUES
    (
        '00000000-0000-0000-0000-000000006091','g1p5b-admin@example.invalid',
        '00000000-0000-0000-0000-000000000000',
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{"name":"G1 P5B Admin"}'::jsonb,FALSE,'authenticated','authenticated',now()
    ),
    (
        '00000000-0000-0000-0000-000000006092','g1p5b-cashier@example.invalid',
        '00000000-0000-0000-0000-000000000000',
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{"name":"G1 P5B Cashier"}'::jsonb,FALSE,'authenticated','authenticated',now()
    ),
    (
        '00000000-0000-0000-0000-000000006093','g1p5b-warehouse@example.invalid',
        '00000000-0000-0000-0000-000000000000',
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{"name":"G1 P5B Warehouse"}'::jsonb,FALSE,'authenticated','authenticated',now()
    );

INSERT INTO public.profiles (id,email,name,role) VALUES
    ('00000000-0000-0000-0000-000000006091','g1p5b-admin@example.invalid','G1 P5B Admin','cashier'::user_role),
    ('00000000-0000-0000-0000-000000006092','g1p5b-cashier@example.invalid','G1 P5B Cashier','cashier'::user_role),
    ('00000000-0000-0000-0000-000000006093','g1p5b-warehouse@example.invalid','G1 P5B Warehouse','cashier'::user_role)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

INSERT INTO public.companies (id,company_code,company_name,company_slug,status) VALUES
    ('00000000-0000-0000-0000-000000006001','G6A','G6 Company A','g6-company-a','ACTIVE'),
    ('00000000-0000-0000-0000-000000006002','G6B','G6 Company B','g6-company-b','ACTIVE');

INSERT INTO public.stores (id,company_id,store_code,store_name,status) VALUES
    ('00000000-0000-0000-0000-000000006011','00000000-0000-0000-0000-000000006001','A1','G6 Store A','ACTIVE'),
    ('00000000-0000-0000-0000-000000006012','00000000-0000-0000-0000-000000006002','B1','G6 Store B','ACTIVE');

INSERT INTO public.warehouses (id,company_id,code,name,is_active) VALUES
    ('00000000-0000-0000-0000-000000006021','00000000-0000-0000-0000-000000006001','WA','G6 Warehouse A',TRUE),
    ('00000000-0000-0000-0000-000000006022','00000000-0000-0000-0000-000000006002','WB','G6 Warehouse B',TRUE);

INSERT INTO public.products (id,company_id,sku,name,price,cogs,uom,is_active,is_bundle) VALUES
    ('00000000-0000-0000-0000-000000006031','00000000-0000-0000-0000-000000006001','G6PA','G6 Product A',100,50,'PCS',TRUE,FALSE),
    ('00000000-0000-0000-0000-000000006032','00000000-0000-0000-0000-000000006002','G6PB','G6 Product B',100,50,'PCS',TRUE,FALSE);

INSERT INTO public.product_stocks (company_id,product_id,warehouse_id,stock_qty) VALUES
    ('00000000-0000-0000-0000-000000006001','00000000-0000-0000-0000-000000006031','00000000-0000-0000-0000-000000006021',5),
    ('00000000-0000-0000-0000-000000006002','00000000-0000-0000-0000-000000006032','00000000-0000-0000-0000-000000006022',7);

INSERT INTO public.customers (id,company_id,code,name) VALUES
    ('00000000-0000-0000-0000-000000006041','00000000-0000-0000-0000-000000006001','G6CA','G6 Customer A'),
    ('00000000-0000-0000-0000-000000006042','00000000-0000-0000-0000-000000006002','G6CB','G6 Customer B');

INSERT INTO public.company_memberships (
    company_id,user_id,role_code,status,is_default_company
) VALUES
    ('00000000-0000-0000-0000-000000006001','00000000-0000-0000-0000-000000006091','COMPANY_ADMIN','ACTIVE',TRUE),
    ('00000000-0000-0000-0000-000000006001','00000000-0000-0000-0000-000000006092','CASHIER','ACTIVE',TRUE),
    ('00000000-0000-0000-0000-000000006001','00000000-0000-0000-0000-000000006093','WAREHOUSE_ADMIN','ACTIVE',TRUE);

INSERT INTO public.store_memberships (
    company_id,store_id,user_id,role_code,status
) VALUES
    ('00000000-0000-0000-0000-000000006001','00000000-0000-0000-0000-000000006011','00000000-0000-0000-0000-000000006092','CASHIER','ACTIVE'),
    ('00000000-0000-0000-0000-000000006001','00000000-0000-0000-0000-000000006011','00000000-0000-0000-0000-000000006093','WAREHOUSE_ADMIN','ACTIVE');

SET LOCAL ROLE authenticated;

DO $test$
DECLARE
    v_count BIGINT;
    v_blocked BOOLEAN;
BEGIN
    -- Company Admin sees/mutates only the active Company.
    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000006091","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000006001','G1_PHASE5B_TEST'
    );

    SELECT count(*) INTO v_count FROM public.products;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Company Admin saw % Products, expected 1',v_count;
    END IF;

    INSERT INTO public.products (company_id,sku,name,price,cogs,uom)
    VALUES ('00000000-0000-0000-0000-000000006001','G6PA2','G6 Product A2',10,5,'PCS');

    v_blocked := FALSE;
    BEGIN
        INSERT INTO public.products (company_id,sku,name,price,cogs,uom)
        VALUES ('00000000-0000-0000-0000-000000006002','G6PX','Forged Product',10,5,'PCS');
    EXCEPTION WHEN insufficient_privilege THEN
        v_blocked := TRUE;
    END;
    IF NOT v_blocked THEN
        RAISE EXCEPTION 'TEST_FAILED: Company Admin inserted cross-Company Product';
    END IF;

    v_blocked := FALSE;
    BEGIN
        PERFORM public.import_products_for_company(
            '00000000-0000-0000-0000-000000006002','[]'::jsonb
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_COMPANY_MISMATCH' THEN
            v_blocked := TRUE;
        ELSE
            RAISE EXCEPTION 'TEST_FAILED with unexpected import error: %',SQLERRM;
        END IF;
    END;
    IF NOT v_blocked THEN
        RAISE EXCEPTION 'TEST_FAILED: Product import ignored active Company';
    END IF;

    -- Cashier reads the active Company catalog but cannot mutate masters.
    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000006092","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000006001','G1_PHASE5B_TEST'
    );

    SELECT count(*) INTO v_count FROM public.product_stocks;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier saw % Stock rows, expected 1',v_count;
    END IF;

    v_blocked := FALSE;
    BEGIN
        INSERT INTO public.customers (company_id,code,name)
        VALUES ('00000000-0000-0000-0000-000000006001','G6CX','Cashier Customer');
    EXCEPTION WHEN insufficient_privilege THEN
        v_blocked := TRUE;
    END;
    IF NOT v_blocked THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier directly inserted Customer';
    END IF;

    -- Warehouse Admin can manage reusable Product/UOM master.
    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000006093","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000006001','G1_PHASE5B_TEST'
    );
    INSERT INTO public.uoms (company_id,code,name)
    VALUES ('00000000-0000-0000-0000-000000006001','BOX','Box');

    IF has_table_privilege('authenticated','public.product_stocks','INSERT')
       OR has_table_privilege('authenticated','public.product_batches','UPDATE')
       OR has_column_privilege(
            'authenticated','public.customers','current_balance','UPDATE'
       )
       OR has_function_privilege(
            'authenticated',
            'public.private_import_products_for_company_g1_legacy(uuid,jsonb)',
            'EXECUTE'
       ) THEN
        RAISE EXCEPTION 'TEST_FAILED: unsafe catalog/inventory privilege remains';
    END IF;

    RAISE NOTICE 'TEST PASSED: catalog and inventory reads are tenant-safe; direct balance mutation is blocked.';
END
$test$;

RESET ROLE;
ROLLBACK;
