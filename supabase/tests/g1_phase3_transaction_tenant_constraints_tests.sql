-- G1 phase 3 behavioral test: forged transaction topology must fail.
-- SAFETY: all fixtures and attempted mutations are rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_constraint TEXT;
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::user_role
    ORDER BY p.id LIMIT 1;

    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin is required';
    END IF;

    INSERT INTO public.companies (id, company_code, company_name, company_slug, status) VALUES
        ('00000000-0000-0000-0000-000000003001','G3A','G3 Company A','g3-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000003002','G3B','G3 Company B','g3-company-b','ACTIVE');

    INSERT INTO public.stores (id, company_id, store_code, store_name, status) VALUES
        ('00000000-0000-0000-0000-000000003011','00000000-0000-0000-0000-000000003001','A1','G3 Store A1','ACTIVE'),
        ('00000000-0000-0000-0000-000000003012','00000000-0000-0000-0000-000000003001','A2','G3 Store A2','ACTIVE'),
        ('00000000-0000-0000-0000-000000003013','00000000-0000-0000-0000-000000003002','B1','G3 Store B1','ACTIVE');

    INSERT INTO public.pos_terminals (id, company_id, store_id, pos_code, pos_name, status) VALUES
        ('00000000-0000-0000-0000-000000003021','00000000-0000-0000-0000-000000003001','00000000-0000-0000-0000-000000003011','PA1','G3 POS A1','ACTIVE'),
        ('00000000-0000-0000-0000-000000003022','00000000-0000-0000-0000-000000003001','00000000-0000-0000-0000-000000003012','PA2','G3 POS A2','ACTIVE'),
        ('00000000-0000-0000-0000-000000003023','00000000-0000-0000-0000-000000003002','00000000-0000-0000-0000-000000003013','PB1','G3 POS B1','ACTIVE');

    INSERT INTO public.warehouses (id, company_id, code, name, is_active) VALUES
        ('00000000-0000-0000-0000-000000003031','00000000-0000-0000-0000-000000003001','WA','G3 Warehouse A',TRUE),
        ('00000000-0000-0000-0000-000000003032','00000000-0000-0000-0000-000000003002','WB','G3 Warehouse B',TRUE);

    INSERT INTO public.products (id, company_id, sku, name, price, cogs, uom, is_active, is_bundle) VALUES
        ('00000000-0000-0000-0000-000000003041','00000000-0000-0000-0000-000000003001','G3PA','G3 Product A',100,50,'PCS',TRUE,FALSE),
        ('00000000-0000-0000-0000-000000003042','00000000-0000-0000-0000-000000003002','G3PB','G3 Product B',100,50,'PCS',TRUE,FALSE);

    INSERT INTO public.customers (id, company_id, code, name) VALUES
        ('00000000-0000-0000-0000-000000003051','00000000-0000-0000-0000-000000003001','G3CA','G3 Customer A'),
        ('00000000-0000-0000-0000-000000003052','00000000-0000-0000-0000-000000003002','G3CB','G3 Customer B');

    INSERT INTO public.cashier_sessions (id, session_code, cashier_id, company_id, store_id, pos_id) VALUES
        ('00000000-0000-0000-0000-000000003061','G3-SA1',v_actor,'00000000-0000-0000-0000-000000003001','00000000-0000-0000-0000-000000003011','00000000-0000-0000-0000-000000003021'),
        ('00000000-0000-0000-0000-000000003062','G3-SA2',v_actor,'00000000-0000-0000-0000-000000003001','00000000-0000-0000-0000-000000003012','00000000-0000-0000-0000-000000003022');

    INSERT INTO public.sales_headers (id, invoice_no, session_id, customer_id, company_id, store_id, pos_id, created_by) VALUES
        ('00000000-0000-0000-0000-000000003071','G3-INV-A','00000000-0000-0000-0000-000000003061','00000000-0000-0000-0000-000000003051','00000000-0000-0000-0000-000000003001','00000000-0000-0000-0000-000000003011','00000000-0000-0000-0000-000000003021',v_actor);

    INSERT INTO public.purchases_headers (id, purchase_no, supplier_name, warehouse_id, company_id, store_id, created_by) VALUES
        ('00000000-0000-0000-0000-000000003081','G3-PO-A','G3 Supplier','00000000-0000-0000-0000-000000003031','00000000-0000-0000-0000-000000003001','00000000-0000-0000-0000-000000003011',v_actor);

    BEGIN
        INSERT INTO public.cashier_sessions (session_code, cashier_id, company_id, store_id, pos_id)
        VALUES ('G3-FORGED-SESSION',v_actor,'00000000-0000-0000-0000-000000003001','00000000-0000-0000-0000-000000003011','00000000-0000-0000-0000-000000003022');
        RAISE EXCEPTION 'TEST_FAILED: mismatched session Store/POS accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_cashier_sessions_company_store_pos' THEN
            RAISE EXCEPTION 'TEST_FAILED: unexpected session constraint %', v_constraint;
        END IF;
    END;

    BEGIN
        INSERT INTO public.sales_headers (invoice_no, session_id, company_id, store_id, pos_id, created_by)
        VALUES ('G3-FORGED-SALE','00000000-0000-0000-0000-000000003061','00000000-0000-0000-0000-000000003001','00000000-0000-0000-0000-000000003012','00000000-0000-0000-0000-000000003022',v_actor);
        RAISE EXCEPTION 'TEST_FAILED: mismatched Sale session topology accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_sales_headers_company_store_pos_session' THEN
            RAISE EXCEPTION 'TEST_FAILED: unexpected Sale constraint %', v_constraint;
        END IF;
    END;

    BEGIN
        INSERT INTO public.sales_details (company_id, sales_id, product_id, warehouse_id, qty)
        VALUES ('00000000-0000-0000-0000-000000003001','00000000-0000-0000-0000-000000003071','00000000-0000-0000-0000-000000003042','00000000-0000-0000-0000-000000003031',1);
        RAISE EXCEPTION 'TEST_FAILED: cross-company Sale Product accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_sales_details_company_product' THEN
            RAISE EXCEPTION 'TEST_FAILED: unexpected Sale detail constraint %', v_constraint;
        END IF;
    END;

    BEGIN
        INSERT INTO public.sales_payments (company_id, sales_id, session_id, payment_no, payment_method, amount)
        VALUES ('00000000-0000-0000-0000-000000003001','00000000-0000-0000-0000-000000003071','00000000-0000-0000-0000-000000003062','G3-PAY-FORGED','Cash'::payment_method,100);
        RAISE EXCEPTION 'TEST_FAILED: payment with another session accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_sales_payments_company_session_sales' THEN
            RAISE EXCEPTION 'TEST_FAILED: unexpected Payment constraint %', v_constraint;
        END IF;
    END;

    BEGIN
        INSERT INTO public.purchases_headers (purchase_no, supplier_name, warehouse_id, company_id, store_id, created_by)
        VALUES ('G3-PO-FORGED','G3 Supplier','00000000-0000-0000-0000-000000003032','00000000-0000-0000-0000-000000003001','00000000-0000-0000-0000-000000003011',v_actor);
        RAISE EXCEPTION 'TEST_FAILED: cross-company Purchase Warehouse accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_purchases_headers_company_warehouse' THEN
            RAISE EXCEPTION 'TEST_FAILED: unexpected Purchase constraint %', v_constraint;
        END IF;
    END;

    BEGIN
        INSERT INTO public.purchases_details (company_id, purchase_id, product_id, qty)
        VALUES ('00000000-0000-0000-0000-000000003001','00000000-0000-0000-0000-000000003081','00000000-0000-0000-0000-000000003042',1);
        RAISE EXCEPTION 'TEST_FAILED: cross-company Purchase Product accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_purchases_details_company_product' THEN
            RAISE EXCEPTION 'TEST_FAILED: unexpected Purchase detail constraint %', v_constraint;
        END IF;
    END;

    RAISE NOTICE 'TEST PASSED: forged session, sales, payment, and purchase topology was rejected.';
END
$test$;

ROLLBACK;
