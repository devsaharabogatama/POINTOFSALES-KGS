-- G1 phase 5C behavioral test: transaction visibility and mutation boundary.
-- SAFETY: every Auth/business fixture is rolled back.

BEGIN;

INSERT INTO auth.users (
    id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at
) VALUES
    (
        '00000000-0000-0000-0000-000000007091','g1p5c-admin@example.invalid',
        '00000000-0000-0000-0000-000000000000',
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{"name":"G1 P5C Admin"}'::jsonb,FALSE,'authenticated','authenticated',now()
    ),
    (
        '00000000-0000-0000-0000-000000007092','g1p5c-cashier@example.invalid',
        '00000000-0000-0000-0000-000000000000',
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{"name":"G1 P5C Cashier"}'::jsonb,FALSE,'authenticated','authenticated',now()
    );

INSERT INTO public.profiles(id,email,name,role) VALUES
    ('00000000-0000-0000-0000-000000007091','g1p5c-admin@example.invalid','G1 P5C Admin','cashier'::user_role),
    ('00000000-0000-0000-0000-000000007092','g1p5c-cashier@example.invalid','G1 P5C Cashier','cashier'::user_role)
ON CONFLICT(id) DO UPDATE SET name = EXCLUDED.name;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status) VALUES
    ('00000000-0000-0000-0000-000000007001','G7A','G7 Company A','g7-company-a','ACTIVE'),
    ('00000000-0000-0000-0000-000000007002','G7B','G7 Company B','g7-company-b','ACTIVE');

INSERT INTO public.stores(id,company_id,store_code,store_name,status) VALUES
    ('00000000-0000-0000-0000-000000007011','00000000-0000-0000-0000-000000007001','A1','G7 Store A','ACTIVE'),
    ('00000000-0000-0000-0000-000000007012','00000000-0000-0000-0000-000000007002','B1','G7 Store B','ACTIVE');

INSERT INTO public.pos_terminals(id,company_id,store_id,pos_code,pos_name,status) VALUES
    ('00000000-0000-0000-0000-000000007021','00000000-0000-0000-0000-000000007001','00000000-0000-0000-0000-000000007011','PA','G7 POS A','ACTIVE'),
    ('00000000-0000-0000-0000-000000007022','00000000-0000-0000-0000-000000007002','00000000-0000-0000-0000-000000007012','PB','G7 POS B','ACTIVE');

INSERT INTO public.warehouses(id,company_id,code,name,is_active) VALUES
    ('00000000-0000-0000-0000-000000007031','00000000-0000-0000-0000-000000007001','WA','G7 Warehouse A',TRUE),
    ('00000000-0000-0000-0000-000000007032','00000000-0000-0000-0000-000000007002','WB','G7 Warehouse B',TRUE);

INSERT INTO public.products(id,company_id,sku,name,price,cogs,uom,is_active,is_bundle) VALUES
    ('00000000-0000-0000-0000-000000007041','00000000-0000-0000-0000-000000007001','G7PA','G7 Product A',100,50,'PCS',TRUE,FALSE),
    ('00000000-0000-0000-0000-000000007042','00000000-0000-0000-0000-000000007002','G7PB','G7 Product B',100,50,'PCS',TRUE,FALSE);

INSERT INTO public.company_memberships(company_id,user_id,role_code,status,is_default_company) VALUES
    ('00000000-0000-0000-0000-000000007001','00000000-0000-0000-0000-000000007091','COMPANY_ADMIN','ACTIVE',TRUE),
    ('00000000-0000-0000-0000-000000007001','00000000-0000-0000-0000-000000007092','CASHIER','ACTIVE',TRUE);

INSERT INTO public.store_memberships(company_id,store_id,user_id,role_code,status) VALUES
    ('00000000-0000-0000-0000-000000007001','00000000-0000-0000-0000-000000007011','00000000-0000-0000-0000-000000007092','CASHIER','ACTIVE');

INSERT INTO public.cashier_sessions(id,session_code,cashier_id,company_id,store_id,pos_id) VALUES
    ('00000000-0000-0000-0000-000000007051','G7-SA','00000000-0000-0000-0000-000000007092','00000000-0000-0000-0000-000000007001','00000000-0000-0000-0000-000000007011','00000000-0000-0000-0000-000000007021'),
    ('00000000-0000-0000-0000-000000007052','G7-SB','00000000-0000-0000-0000-000000007092','00000000-0000-0000-0000-000000007002','00000000-0000-0000-0000-000000007012','00000000-0000-0000-0000-000000007022');

INSERT INTO public.sales_headers(id,invoice_no,session_id,company_id,store_id,pos_id,created_by) VALUES
    ('00000000-0000-0000-0000-000000007061','G7-INV-A-C','00000000-0000-0000-0000-000000007051','00000000-0000-0000-0000-000000007001','00000000-0000-0000-0000-000000007011','00000000-0000-0000-0000-000000007021','00000000-0000-0000-0000-000000007092'),
    ('00000000-0000-0000-0000-000000007062','G7-INV-A-A','00000000-0000-0000-0000-000000007051','00000000-0000-0000-0000-000000007001','00000000-0000-0000-0000-000000007011','00000000-0000-0000-0000-000000007021','00000000-0000-0000-0000-000000007091'),
    ('00000000-0000-0000-0000-000000007063','G7-INV-B','00000000-0000-0000-0000-000000007052','00000000-0000-0000-0000-000000007002','00000000-0000-0000-0000-000000007012','00000000-0000-0000-0000-000000007022','00000000-0000-0000-0000-000000007092');

INSERT INTO public.sales_details(company_id,sales_id,product_id,warehouse_id,qty,price,subtotal) VALUES
    ('00000000-0000-0000-0000-000000007001','00000000-0000-0000-0000-000000007061','00000000-0000-0000-0000-000000007041','00000000-0000-0000-0000-000000007031',1,100,100),
    ('00000000-0000-0000-0000-000000007001','00000000-0000-0000-0000-000000007062','00000000-0000-0000-0000-000000007041','00000000-0000-0000-0000-000000007031',1,100,100),
    ('00000000-0000-0000-0000-000000007002','00000000-0000-0000-0000-000000007063','00000000-0000-0000-0000-000000007042','00000000-0000-0000-0000-000000007032',1,100,100);

INSERT INTO public.sales_payments(company_id,sales_id,session_id,payment_no,payment_method,amount) VALUES
    ('00000000-0000-0000-0000-000000007001','00000000-0000-0000-0000-000000007061','00000000-0000-0000-0000-000000007051','G7-PAY-A-C','Cash'::payment_method,100),
    ('00000000-0000-0000-0000-000000007001','00000000-0000-0000-0000-000000007062','00000000-0000-0000-0000-000000007051','G7-PAY-A-A','Cash'::payment_method,100),
    ('00000000-0000-0000-0000-000000007002','00000000-0000-0000-0000-000000007063','00000000-0000-0000-0000-000000007052','G7-PAY-B','Cash'::payment_method,100);

INSERT INTO public.purchases_headers(id,purchase_no,supplier_name,warehouse_id,company_id,store_id,created_by) VALUES
    ('00000000-0000-0000-0000-000000007071','G7-PO-A','Supplier A','00000000-0000-0000-0000-000000007031','00000000-0000-0000-0000-000000007001','00000000-0000-0000-0000-000000007011','00000000-0000-0000-0000-000000007091'),
    ('00000000-0000-0000-0000-000000007072','G7-PO-B','Supplier B','00000000-0000-0000-0000-000000007032','00000000-0000-0000-0000-000000007002','00000000-0000-0000-0000-000000007012','00000000-0000-0000-0000-000000007091');

INSERT INTO public.purchases_details(company_id,purchase_id,product_id,qty,purchase_price,subtotal) VALUES
    ('00000000-0000-0000-0000-000000007001','00000000-0000-0000-0000-000000007071','00000000-0000-0000-0000-000000007041',1,50,50),
    ('00000000-0000-0000-0000-000000007002','00000000-0000-0000-0000-000000007072','00000000-0000-0000-0000-000000007042',1,50,50);

SET LOCAL ROLE authenticated;

DO $test$
DECLARE
    v_count BIGINT;
    v_blocked BOOLEAN := FALSE;
BEGIN
    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000007091","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000007001','G1_PHASE5C_TEST'
    );

    SELECT count(*) INTO v_count FROM public.sales_headers;
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Company Admin saw % Sales, expected 2',v_count;
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000007092","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000007001','G1_PHASE5C_TEST'
    );

    SELECT count(*) INTO v_count FROM public.cashier_sessions;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier saw % Sessions, expected own active-Company session',v_count;
    END IF;

    SELECT count(*) INTO v_count FROM public.sales_headers;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier saw % Sales, expected own Sale only',v_count;
    END IF;

    SELECT count(*) INTO v_count FROM public.sales_details;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier saw % Sale details, expected 1',v_count;
    END IF;

    SELECT count(*) INTO v_count FROM public.sales_payments;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier saw % Payments, expected 1',v_count;
    END IF;

    SELECT count(*) INTO v_count FROM public.purchases_details;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier saw % Purchase details, expected assigned Store only',v_count;
    END IF;

    IF has_table_privilege('authenticated','public.sales_headers','INSERT')
       OR has_table_privilege('authenticated','public.cashier_sessions','UPDATE')
       OR has_table_privilege('authenticated','public.purchases_headers','DELETE') THEN
        RAISE EXCEPTION 'TEST_FAILED: direct transaction mutation privilege remains';
    END IF;

    BEGIN
        PERFORM public.create_sales_transaction(
            'G7-CROSS-CHECKOUT','00000000-0000-0000-0000-000000007052',
            NULL,FALSE,NULL,FALSE,NULL,0,0,0,0,0,0,
            'DRAFT'::payment_status,'00000000-0000-0000-0000-000000007092',
            '{}'::jsonb,'[]'::jsonb,'[]'::jsonb
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_COMPANY_MISMATCH' THEN
            v_blocked := TRUE;
        ELSE
            RAISE EXCEPTION 'TEST_FAILED with unexpected checkout error: %',SQLERRM;
        END IF;
    END;

    IF NOT v_blocked THEN
        RAISE EXCEPTION 'TEST_FAILED: checkout ignored active Company';
    END IF;

    IF has_function_privilege(
        'authenticated',
        'public.private_create_sales_transaction_g1_legacy(text,uuid,uuid,boolean,timestamp with time zone,boolean,text,numeric,numeric,numeric,numeric,numeric,numeric,payment_status,uuid,jsonb,jsonb,jsonb)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: legacy checkout remains API executable';
    END IF;

    RAISE NOTICE 'TEST PASSED: transaction reads follow actor/Store/Company scope and direct writes are blocked.';
END
$test$;

RESET ROLE;
ROLLBACK;
