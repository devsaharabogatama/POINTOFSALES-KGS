-- G1 phase 5D behavioral test: Finance visibility and immutable ledger boundary.
-- SAFETY: every Auth/business fixture is rolled back.

BEGIN;

INSERT INTO auth.users(
    id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at
) VALUES
    ('00000000-0000-0000-0000-000000008091','g1p5d-admin@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::jsonb,'{"name":"G1 P5D Admin"}'::jsonb,FALSE,'authenticated','authenticated',now()),
    ('00000000-0000-0000-0000-000000008092','g1p5d-cashier@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::jsonb,'{"name":"G1 P5D Cashier"}'::jsonb,FALSE,'authenticated','authenticated',now());

INSERT INTO public.profiles(id,email,name,role) VALUES
    ('00000000-0000-0000-0000-000000008091','g1p5d-admin@example.invalid','G1 P5D Admin','cashier'::user_role),
    ('00000000-0000-0000-0000-000000008092','g1p5d-cashier@example.invalid','G1 P5D Cashier','cashier'::user_role)
ON CONFLICT(id) DO UPDATE SET name = EXCLUDED.name;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status) VALUES
    ('00000000-0000-0000-0000-000000008001','G8A','G8 Company A','g8-company-a','ACTIVE'),
    ('00000000-0000-0000-0000-000000008002','G8B','G8 Company B','g8-company-b','ACTIVE');
INSERT INTO public.stores(id,company_id,store_code,store_name,status) VALUES
    ('00000000-0000-0000-0000-000000008011','00000000-0000-0000-0000-000000008001','A1','G8 Store A','ACTIVE'),
    ('00000000-0000-0000-0000-000000008012','00000000-0000-0000-0000-000000008002','B1','G8 Store B','ACTIVE');
INSERT INTO public.pos_terminals(id,company_id,store_id,pos_code,pos_name,status) VALUES
    ('00000000-0000-0000-0000-000000008021','00000000-0000-0000-0000-000000008001','00000000-0000-0000-0000-000000008011','PA','G8 POS A','ACTIVE'),
    ('00000000-0000-0000-0000-000000008022','00000000-0000-0000-0000-000000008002','00000000-0000-0000-0000-000000008012','PB','G8 POS B','ACTIVE');

INSERT INTO public.company_memberships(company_id,user_id,role_code,status,is_default_company) VALUES
    ('00000000-0000-0000-0000-000000008001','00000000-0000-0000-0000-000000008091','COMPANY_ADMIN','ACTIVE',TRUE),
    ('00000000-0000-0000-0000-000000008001','00000000-0000-0000-0000-000000008092','CASHIER','ACTIVE',TRUE);
INSERT INTO public.store_memberships(company_id,store_id,user_id,role_code,status) VALUES
    ('00000000-0000-0000-0000-000000008001','00000000-0000-0000-0000-000000008011','00000000-0000-0000-0000-000000008092','CASHIER','ACTIVE');

INSERT INTO public.cashier_sessions(id,session_code,cashier_id,company_id,store_id,pos_id) VALUES
    ('00000000-0000-0000-0000-000000008031','G8-SA','00000000-0000-0000-0000-000000008092','00000000-0000-0000-0000-000000008001','00000000-0000-0000-0000-000000008011','00000000-0000-0000-0000-000000008021'),
    ('00000000-0000-0000-0000-000000008032','G8-SB','00000000-0000-0000-0000-000000008092','00000000-0000-0000-0000-000000008002','00000000-0000-0000-0000-000000008012','00000000-0000-0000-0000-000000008022');
INSERT INTO public.sales_headers(id,invoice_no,session_id,company_id,store_id,pos_id,created_by) VALUES
    ('00000000-0000-0000-0000-000000008041','G8-INV-A','00000000-0000-0000-0000-000000008031','00000000-0000-0000-0000-000000008001','00000000-0000-0000-0000-000000008011','00000000-0000-0000-0000-000000008021','00000000-0000-0000-0000-000000008092'),
    ('00000000-0000-0000-0000-000000008042','G8-INV-B','00000000-0000-0000-0000-000000008032','00000000-0000-0000-0000-000000008002','00000000-0000-0000-0000-000000008012','00000000-0000-0000-0000-000000008022','00000000-0000-0000-0000-000000008092');

INSERT INTO public.cash_advances(id,ca_no,session_id,category,amount,created_by,company_id,store_id) VALUES
    ('00000000-0000-0000-0000-000000008051','G8-CA-A-C','00000000-0000-0000-0000-000000008031','TEST',10,'00000000-0000-0000-0000-000000008092','00000000-0000-0000-0000-000000008001','00000000-0000-0000-0000-000000008011'),
    ('00000000-0000-0000-0000-000000008052','G8-CA-A-A','00000000-0000-0000-0000-000000008031','TEST',20,'00000000-0000-0000-0000-000000008091','00000000-0000-0000-0000-000000008001','00000000-0000-0000-0000-000000008011'),
    ('00000000-0000-0000-0000-000000008053','G8-CA-B','00000000-0000-0000-0000-000000008032','TEST',30,'00000000-0000-0000-0000-000000008092','00000000-0000-0000-0000-000000008002','00000000-0000-0000-0000-000000008012');

INSERT INTO public.bank_deposits(id,deposit_no,session_id,amount,bank_account_info,created_by,company_id,store_id) VALUES
    ('00000000-0000-0000-0000-000000008061','G8-BD-A-C','00000000-0000-0000-0000-000000008031',10,'TEST','00000000-0000-0000-0000-000000008092','00000000-0000-0000-0000-000000008001','00000000-0000-0000-0000-000000008011'),
    ('00000000-0000-0000-0000-000000008062','G8-BD-A-A','00000000-0000-0000-0000-000000008031',20,'TEST','00000000-0000-0000-0000-000000008091','00000000-0000-0000-0000-000000008001','00000000-0000-0000-0000-000000008011'),
    ('00000000-0000-0000-0000-000000008063','G8-BD-B','00000000-0000-0000-0000-000000008032',30,'TEST','00000000-0000-0000-0000-000000008092','00000000-0000-0000-0000-000000008002','00000000-0000-0000-0000-000000008012');

INSERT INTO public.financial_events(id,event_code,event_type,source_table,source_id,root_sales_id,idempotency_key,amounts,company_id,store_id) VALUES
    ('00000000-0000-0000-0000-000000008071','G8-E-A','SALE_POSTED'::event_type,'G1_PHASE5D_TEST','00000000-0000-0000-0000-000000008041','00000000-0000-0000-0000-000000008041','G8|E|A','{}'::jsonb,'00000000-0000-0000-0000-000000008001','00000000-0000-0000-0000-000000008011'),
    ('00000000-0000-0000-0000-000000008072','G8-E-B','SALE_POSTED'::event_type,'G1_PHASE5D_TEST','00000000-0000-0000-0000-000000008042','00000000-0000-0000-0000-000000008042','G8|E|B','{}'::jsonb,'00000000-0000-0000-0000-000000008002','00000000-0000-0000-0000-000000008012');

INSERT INTO public.journal_entries(journal_no,entry_group_id,transaction_date,financial_event_id,coa_code,coa_name,debit,kredit,company_id,store_id) VALUES
    ('G8-J-A-1','G8-J-A',now(),'00000000-0000-0000-0000-000000008071','1000','Cash',100,0,'00000000-0000-0000-0000-000000008001','00000000-0000-0000-0000-000000008011'),
    ('G8-J-A-2','G8-J-A',now(),'00000000-0000-0000-0000-000000008071','4000','Sales',0,100,'00000000-0000-0000-0000-000000008001','00000000-0000-0000-0000-000000008011'),
    ('G8-J-B-1','G8-J-B',now(),'00000000-0000-0000-0000-000000008072','1000','Cash',100,0,'00000000-0000-0000-0000-000000008002','00000000-0000-0000-0000-000000008012'),
    ('G8-J-B-2','G8-J-B',now(),'00000000-0000-0000-0000-000000008072','4000','Sales',0,100,'00000000-0000-0000-0000-000000008002','00000000-0000-0000-0000-000000008012');

INSERT INTO public.pos_reconciliations(id,sales_id,company_id) VALUES
    ('00000000-0000-0000-0000-000000008081','00000000-0000-0000-0000-000000008041','00000000-0000-0000-0000-000000008001'),
    ('00000000-0000-0000-0000-000000008082','00000000-0000-0000-0000-000000008042','00000000-0000-0000-0000-000000008002');

DO $constraint_test$
DECLARE
    v_constraint TEXT;
BEGIN
    BEGIN
        INSERT INTO public.cash_advances(
            ca_no,session_id,category,amount,created_by,company_id,store_id
        ) VALUES (
            'G8-CA-FORGED','00000000-0000-0000-0000-000000008032',
            'TEST',1,'00000000-0000-0000-0000-000000008091',
            '00000000-0000-0000-0000-000000008001',
            '00000000-0000-0000-0000-000000008011'
        );
        RAISE EXCEPTION 'TEST_FAILED: forged cross-Company Expense accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_cash_advances_company_store_session' THEN
            RAISE EXCEPTION 'TEST_FAILED: unexpected Expense constraint %',v_constraint;
        END IF;
    END;
END
$constraint_test$;

SET LOCAL ROLE authenticated;

DO $test$
DECLARE
    v_count BIGINT;
BEGIN
    PERFORM set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000008091","role":"authenticated"}',TRUE);
    PERFORM public.set_active_company_context('00000000-0000-0000-0000-000000008001','G1_PHASE5D_TEST');

    SELECT count(*) INTO v_count FROM public.cash_advances WHERE ca_no LIKE 'G8-CA-%';
    IF v_count <> 2 THEN RAISE EXCEPTION 'TEST_FAILED: Admin saw % Company Expenses, expected 2',v_count; END IF;
    SELECT count(*) INTO v_count FROM public.bank_deposits WHERE deposit_no LIKE 'G8-BD-%';
    IF v_count <> 2 THEN RAISE EXCEPTION 'TEST_FAILED: Admin saw % Company Deposits, expected 2',v_count; END IF;
    SELECT count(*) INTO v_count FROM public.financial_events WHERE source_table = 'G1_PHASE5D_TEST';
    IF v_count <> 1 THEN RAISE EXCEPTION 'TEST_FAILED: Admin saw % test Events, expected 1',v_count; END IF;
    SELECT count(*) INTO v_count FROM public.journal_entries WHERE entry_group_id = 'G8-J-A';
    IF v_count <> 2 THEN RAISE EXCEPTION 'TEST_FAILED: Admin saw % Journal lines, expected 2',v_count; END IF;
    SELECT count(*) INTO v_count FROM public.pos_reconciliations;
    IF v_count <> 1 THEN RAISE EXCEPTION 'TEST_FAILED: Admin saw % Reconciliations, expected 1',v_count; END IF;

    PERFORM set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000008092","role":"authenticated"}',TRUE);
    PERFORM public.set_active_company_context('00000000-0000-0000-0000-000000008001','G1_PHASE5D_TEST');

    SELECT count(*) INTO v_count FROM public.cash_advances WHERE ca_no LIKE 'G8-CA-%';
    IF v_count <> 1 THEN RAISE EXCEPTION 'TEST_FAILED: Cashier saw % Expenses, expected own only',v_count; END IF;
    SELECT count(*) INTO v_count FROM public.bank_deposits WHERE deposit_no LIKE 'G8-BD-%';
    IF v_count <> 1 THEN RAISE EXCEPTION 'TEST_FAILED: Cashier saw % Deposits, expected own only',v_count; END IF;
    SELECT count(*) INTO v_count FROM public.financial_events WHERE source_table = 'G1_PHASE5D_TEST';
    IF v_count <> 0 THEN RAISE EXCEPTION 'TEST_FAILED: Cashier saw Finance Events'; END IF;
    SELECT count(*) INTO v_count FROM public.journal_entries WHERE entry_group_id LIKE 'G8-J-%';
    IF v_count <> 0 THEN RAISE EXCEPTION 'TEST_FAILED: Cashier saw Journal Entries'; END IF;
    SELECT count(*) INTO v_count FROM public.pos_reconciliations;
    IF v_count <> 0 THEN RAISE EXCEPTION 'TEST_FAILED: Cashier saw Reconciliation'; END IF;

    IF has_table_privilege('authenticated','public.cash_advances','INSERT')
       OR has_table_privilege('authenticated','public.bank_deposits','UPDATE')
       OR has_table_privilege('authenticated','public.journal_entries','INSERT')
       OR has_function_privilege('authenticated','public.process_financial_events_queue()','EXECUTE') THEN
        RAISE EXCEPTION 'TEST_FAILED: unsafe Finance mutation privilege remains';
    END IF;

    RAISE NOTICE 'TEST PASSED: Finance reads are scoped, Cashier cannot see ledger, and worker remains service-role-only.';
END
$test$;

RESET ROLE;
ROLLBACK;
