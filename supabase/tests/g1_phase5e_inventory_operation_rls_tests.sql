-- G1 phase 5E behavioral test: inventory-operation visibility and boundary.
-- SAFETY: every Auth/business fixture is rolled back.

BEGIN;

INSERT INTO auth.users(
    id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at
) VALUES
    (
        '00000000-0000-0000-0000-000000009091',
        'g1p5e-admin@example.invalid',
        '00000000-0000-0000-0000-000000000000',
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{"name":"G1 P5E Admin"}'::jsonb,
        FALSE,'authenticated','authenticated',now()
    ),
    (
        '00000000-0000-0000-0000-000000009092',
        'g1p5e-cashier@example.invalid',
        '00000000-0000-0000-0000-000000000000',
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{"name":"G1 P5E Cashier"}'::jsonb,
        FALSE,'authenticated','authenticated',now()
    );

INSERT INTO public.profiles(id,email,name,role) VALUES
    (
        '00000000-0000-0000-0000-000000009091',
        'g1p5e-admin@example.invalid','G1 P5E Admin','cashier'::user_role
    ),
    (
        '00000000-0000-0000-0000-000000009092',
        'g1p5e-cashier@example.invalid','G1 P5E Cashier','cashier'::user_role
    )
ON CONFLICT(id) DO UPDATE SET name = EXCLUDED.name;

INSERT INTO public.companies(
    id,company_code,company_name,company_slug,status
) VALUES
    (
        '00000000-0000-0000-0000-000000009001',
        'G9A','G9 Company A','g9-company-a','ACTIVE'
    ),
    (
        '00000000-0000-0000-0000-000000009002',
        'G9B','G9 Company B','g9-company-b','ACTIVE'
    );

INSERT INTO public.stores(id,company_id,store_code,store_name,status) VALUES
    (
        '00000000-0000-0000-0000-000000009011',
        '00000000-0000-0000-0000-000000009001',
        'A1','G9 Store A','ACTIVE'
    ),
    (
        '00000000-0000-0000-0000-000000009012',
        '00000000-0000-0000-0000-000000009002',
        'B1','G9 Store B','ACTIVE'
    );

INSERT INTO public.pos_terminals(
    id,company_id,store_id,pos_code,pos_name,status
) VALUES
    (
        '00000000-0000-0000-0000-000000009021',
        '00000000-0000-0000-0000-000000009001',
        '00000000-0000-0000-0000-000000009011',
        'PA','G9 POS A','ACTIVE'
    ),
    (
        '00000000-0000-0000-0000-000000009022',
        '00000000-0000-0000-0000-000000009002',
        '00000000-0000-0000-0000-000000009012',
        'PB','G9 POS B','ACTIVE'
    );

INSERT INTO public.warehouses(id,company_id,code,name,is_active) VALUES
    (
        '00000000-0000-0000-0000-000000009031',
        '00000000-0000-0000-0000-000000009001',
        'WA','G9 Warehouse A',TRUE
    ),
    (
        '00000000-0000-0000-0000-000000009032',
        '00000000-0000-0000-0000-000000009002',
        'WB','G9 Warehouse B',TRUE
    );

INSERT INTO public.products(
    id,company_id,sku,name,price,cogs,uom,is_active,is_bundle
) VALUES
    (
        '00000000-0000-0000-0000-000000009041',
        '00000000-0000-0000-0000-000000009001',
        'G9PA','G9 Product A',100,50,'PCS',TRUE,FALSE
    ),
    (
        '00000000-0000-0000-0000-000000009042',
        '00000000-0000-0000-0000-000000009002',
        'G9PB','G9 Product B',100,50,'PCS',TRUE,FALSE
    );

INSERT INTO public.company_memberships(
    company_id,user_id,role_code,status,is_default_company
) VALUES
    (
        '00000000-0000-0000-0000-000000009001',
        '00000000-0000-0000-0000-000000009091',
        'COMPANY_ADMIN','ACTIVE',TRUE
    ),
    (
        '00000000-0000-0000-0000-000000009001',
        '00000000-0000-0000-0000-000000009092',
        'CASHIER','ACTIVE',TRUE
    );

INSERT INTO public.store_memberships(
    company_id,store_id,user_id,role_code,status
) VALUES (
    '00000000-0000-0000-0000-000000009001',
    '00000000-0000-0000-0000-000000009011',
    '00000000-0000-0000-0000-000000009092',
    'CASHIER','ACTIVE'
);

INSERT INTO public.cashier_sessions(
    id,session_code,cashier_id,company_id,store_id,pos_id,status
) VALUES
    (
        '00000000-0000-0000-0000-000000009051','G9-SA',
        '00000000-0000-0000-0000-000000009092',
        '00000000-0000-0000-0000-000000009001',
        '00000000-0000-0000-0000-000000009011',
        '00000000-0000-0000-0000-000000009021',
        'CLOSED'::session_status
    ),
    (
        '00000000-0000-0000-0000-000000009052','G9-SB',
        '00000000-0000-0000-0000-000000009092',
        '00000000-0000-0000-0000-000000009002',
        '00000000-0000-0000-0000-000000009012',
        '00000000-0000-0000-0000-000000009022',
        'CLOSED'::session_status
    );

INSERT INTO public.sales_headers(
    id,invoice_no,session_id,company_id,store_id,pos_id,created_by
) VALUES
    (
        '00000000-0000-0000-0000-000000009061','G9-INV-A',
        '00000000-0000-0000-0000-000000009051',
        '00000000-0000-0000-0000-000000009001',
        '00000000-0000-0000-0000-000000009011',
        '00000000-0000-0000-0000-000000009021',
        '00000000-0000-0000-0000-000000009092'
    ),
    (
        '00000000-0000-0000-0000-000000009062','G9-INV-B',
        '00000000-0000-0000-0000-000000009052',
        '00000000-0000-0000-0000-000000009002',
        '00000000-0000-0000-0000-000000009012',
        '00000000-0000-0000-0000-000000009022',
        '00000000-0000-0000-0000-000000009092'
    );

INSERT INTO public.sales_details(
    id,company_id,sales_id,product_id,warehouse_id,qty,price,subtotal
) VALUES
    (
        '00000000-0000-0000-0000-000000009071',
        '00000000-0000-0000-0000-000000009001',
        '00000000-0000-0000-0000-000000009061',
        '00000000-0000-0000-0000-000000009041',
        '00000000-0000-0000-0000-000000009031',1,100,100
    ),
    (
        '00000000-0000-0000-0000-000000009072',
        '00000000-0000-0000-0000-000000009002',
        '00000000-0000-0000-0000-000000009062',
        '00000000-0000-0000-0000-000000009042',
        '00000000-0000-0000-0000-000000009032',1,100,100
    );

INSERT INTO public.product_batches(
    id,company_id,product_id,warehouse_id,
    qty_purchased,qty_remaining,cogs_unit
) VALUES
    (
        '00000000-0000-0000-0000-000000009081',
        '00000000-0000-0000-0000-000000009001',
        '00000000-0000-0000-0000-000000009041',
        '00000000-0000-0000-0000-000000009031',10,9,50
    ),
    (
        '00000000-0000-0000-0000-000000009082',
        '00000000-0000-0000-0000-000000009002',
        '00000000-0000-0000-0000-000000009042',
        '00000000-0000-0000-0000-000000009032',10,9,50
    );

INSERT INTO public.sales_fifo_allocations(
    company_id,sales_detail_id,product_batch_id,qty_allocated,cogs_unit
) VALUES
    (
        '00000000-0000-0000-0000-000000009001',
        '00000000-0000-0000-0000-000000009071',
        '00000000-0000-0000-0000-000000009081',1,50
    ),
    (
        '00000000-0000-0000-0000-000000009002',
        '00000000-0000-0000-0000-000000009072',
        '00000000-0000-0000-0000-000000009082',1,50
    );

INSERT INTO public.stock_opnames(
    id,opname_no,warehouse_id,status,created_by,company_id
) VALUES
    (
        '00000000-0000-0000-0000-000000009101','G9-OP-A-C',
        '00000000-0000-0000-0000-000000009031','DRAFT'::opname_status,
        '00000000-0000-0000-0000-000000009092',
        '00000000-0000-0000-0000-000000009001'
    ),
    (
        '00000000-0000-0000-0000-000000009102','G9-OP-A-A',
        '00000000-0000-0000-0000-000000009031','DRAFT'::opname_status,
        '00000000-0000-0000-0000-000000009091',
        '00000000-0000-0000-0000-000000009001'
    ),
    (
        '00000000-0000-0000-0000-000000009103','G9-OP-B',
        '00000000-0000-0000-0000-000000009032','DRAFT'::opname_status,
        '00000000-0000-0000-0000-000000009092',
        '00000000-0000-0000-0000-000000009002'
    );

INSERT INTO public.stock_opname_details(
    id,opname_id,product_id,system_qty,physical_qty,difference,company_id
) VALUES
    (
        '00000000-0000-0000-0000-000000009111',
        '00000000-0000-0000-0000-000000009101',
        '00000000-0000-0000-0000-000000009041',100,98,-2,
        '00000000-0000-0000-0000-000000009001'
    ),
    (
        '00000000-0000-0000-0000-000000009112',
        '00000000-0000-0000-0000-000000009102',
        '00000000-0000-0000-0000-000000009041',100,99,-1,
        '00000000-0000-0000-0000-000000009001'
    ),
    (
        '00000000-0000-0000-0000-000000009113',
        '00000000-0000-0000-0000-000000009103',
        '00000000-0000-0000-0000-000000009042',100,97,-3,
        '00000000-0000-0000-0000-000000009002'
    );

INSERT INTO public.stock_adjustments(
    adjustment_no,product_id,warehouse_id,opname_detail_id,
    qty_adjusted,cogs_unit,reason,created_by,company_id
) VALUES
    (
        'G9-ADJ-A','00000000-0000-0000-0000-000000009041',
        '00000000-0000-0000-0000-000000009031',
        '00000000-0000-0000-0000-000000009111',-2,50,'TEST',
        '00000000-0000-0000-0000-000000009091',
        '00000000-0000-0000-0000-000000009001'
    ),
    (
        'G9-ADJ-B','00000000-0000-0000-0000-000000009042',
        '00000000-0000-0000-0000-000000009032',
        '00000000-0000-0000-0000-000000009113',-3,50,'TEST',
        '00000000-0000-0000-0000-000000009091',
        '00000000-0000-0000-0000-000000009002'
    );

INSERT INTO public.stock_movements(
    product_id,warehouse_id,qty_change,movement_type,
    reference_table,reference_id,company_id
) VALUES
    (
        '00000000-0000-0000-0000-000000009041',
        '00000000-0000-0000-0000-000000009031',-2,
        'PURCHASE_RETURN'::stock_movement_type,'stock_adjustments',
        '00000000-0000-0000-0000-000000009111',
        '00000000-0000-0000-0000-000000009001'
    ),
    (
        '00000000-0000-0000-0000-000000009042',
        '00000000-0000-0000-0000-000000009032',-3,
        'PURCHASE_RETURN'::stock_movement_type,'stock_adjustments',
        '00000000-0000-0000-0000-000000009113',
        '00000000-0000-0000-0000-000000009002'
    );

DO $constraint_test$
DECLARE
    v_constraint TEXT;
BEGIN
    BEGIN
        INSERT INTO public.stock_movements(
            product_id,warehouse_id,qty_change,movement_type,
            reference_table,reference_id,company_id
        ) VALUES (
            '00000000-0000-0000-0000-000000009042',
            '00000000-0000-0000-0000-000000009031',1,
            'PURCHASE'::stock_movement_type,'G1_PHASE5E_TEST',
            '00000000-0000-0000-0000-000000009111',
            '00000000-0000-0000-0000-000000009001'
        );
        RAISE EXCEPTION 'TEST_FAILED: forged cross-Company Movement accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_stock_movements_company_product' THEN
            RAISE EXCEPTION
                'TEST_FAILED: unexpected Movement constraint %',v_constraint;
        END IF;
    END;
END
$constraint_test$;

SET LOCAL ROLE authenticated;

DO $test$
DECLARE
    v_count BIGINT;
BEGIN
    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000009091","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000009001','G1_PHASE5E_TEST'
    );

    SELECT count(*) INTO v_count FROM public.sales_fifo_allocations;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Admin saw % FIFO rows, expected 1',v_count;
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_opnames
    WHERE opname_no LIKE 'G9-OP-%';
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Admin saw % Opnames, expected 2',v_count;
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_opname_details;
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Admin saw % Opname details, expected 2',v_count;
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_adjustments
    WHERE adjustment_no LIKE 'G9-ADJ-%';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Admin saw % Adjustments, expected 1',v_count;
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_movements
    WHERE reference_table = 'stock_adjustments';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Admin saw % Movements, expected 1',v_count;
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000009092","role":"authenticated"}',
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000009001','G1_PHASE5E_TEST'
    );

    SELECT count(*) INTO v_count FROM public.stock_opnames
    WHERE opname_no LIKE 'G9-OP-%';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier saw % Opnames, expected own only',v_count;
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_opname_details;
    IF v_count <> 0 THEN
        RAISE EXCEPTION
            'TEST_FAILED: Cashier saw blind-count protected Opname details';
    END IF;
    SELECT count(*) INTO v_count FROM public.sales_fifo_allocations;
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier saw FIFO allocation';
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_adjustments;
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier saw Stock Adjustment';
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_movements;
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier saw Stock Movement';
    END IF;

    IF has_table_privilege(
        'authenticated','public.stock_opnames','INSERT'
    ) OR has_table_privilege(
        'authenticated','public.stock_adjustments','UPDATE'
    ) OR has_table_privilege(
        'authenticated','public.stock_movements','DELETE'
    ) OR has_function_privilege(
        'authenticated',
        'public.transfer_product_stock(uuid,uuid,uuid,numeric)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: unsafe inventory mutation privilege remains';
    END IF;

    RAISE NOTICE 'TEST PASSED: inventory operation reads are scoped and browser mutations remain blocked.';
END
$test$;

RESET ROLE;
ROLLBACK;
