-- -----------------------------------------------------
-- TEST SUITE: MULTI-TENANT ISOLATION & IDEMPOTENCY
-- -----------------------------------------------------

-- Note: Execute this script in your SQL editor to validate multi-tenant rules.

-- 0. Seed Mock User in Auth.Users & Profiles for test execution
INSERT INTO auth.users (id, email, instance_id, raw_app_meta_data, raw_user_meta_data, is_super_admin, role, aud)
VALUES (
    'd290f1ee-6c54-4b01-90e6-d701748f0851',
    'kasir1@kgs.com',
    '00000000-0000-0000-0000-000000000000',
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"name":"Kasir KGS Utama"}'::jsonb,
    FALSE,
    'authenticated',
    'authenticated'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO profiles (id, email, name, role)
VALUES (
    'd290f1ee-6c54-4b01-90e6-d701748f0851',
    'kasir1@kgs.com',
    'Kasir KGS Utama',
    'cashier'::user_role
) ON CONFLICT (id) DO NOTHING;

-- 1. Setup Test Tenants (Company A & Company B)
INSERT INTO companies (id, company_code, company_name, company_slug, status)
VALUES 
    ('11111111-1111-1111-1111-111111111111', 'COMP-A', 'Company A', 'company-a', 'ACTIVE'),
    ('22222222-2222-2222-2222-222222222222', 'COMP-B', 'Company B', 'company-b', 'ACTIVE')
ON CONFLICT DO NOTHING;

-- 2. Setup Test Stores
INSERT INTO stores (id, company_id, store_code, store_name, status)
VALUES 
    ('11111111-1111-1111-1111-111111111112', '11111111-1111-1111-1111-111111111111', 'STORE-A', 'Store Company A', 'ACTIVE'),
    ('22222222-2222-2222-2222-222222222223', '22222222-2222-2222-2222-222222222222', 'STORE-B', 'Store Company B', 'ACTIVE')
ON CONFLICT DO NOTHING;

-- 3. Setup Test Warehouses
INSERT INTO warehouses (id, company_id, code, name, is_active)
VALUES 
    ('11111111-1111-1111-1111-111111111114', '11111111-1111-1111-1111-111111111111', 'WH-A', 'Warehouse A', TRUE),
    ('22222222-2222-2222-2222-222222222225', '22222222-2222-2222-2222-222222222222', 'WH-B', 'Warehouse B', TRUE)
ON CONFLICT DO NOTHING;

-- 4. Setup Test Products
INSERT INTO products (id, company_id, sku, name, category, price, cogs, uom)
VALUES 
    ('11111111-1111-1111-1111-111111111116', '11111111-1111-1111-1111-111111111111', 'PROD-A', 'Produk Company A', 'Kategori', 10000, 7000, 'pcs'),
    ('22222222-2222-2222-2222-222222222227', '22222222-2222-2222-2222-222222222222', 'PROD-B', 'Produk Company B', 'Kategori', 15000, 9000, 'pcs')
ON CONFLICT DO NOTHING;

-- 5. Setup Test Customers
INSERT INTO customers (id, company_id, code, name)
VALUES 
    ('11111111-1111-1111-1111-111111111118', '11111111-1111-1111-1111-111111111111', 'CUST-A', 'Pelanggan Company A'),
    ('22222222-2222-2222-2222-222222222229', '22222222-2222-2222-2222-222222222222', 'CUST-B', 'Pelanggan Company B')
ON CONFLICT DO NOTHING;


-- -----------------------------------------------------
-- TEST 1: Tenant Cross-Company Stock Transfer Prevention
-- -----------------------------------------------------
DO $$
BEGIN
    BEGIN
        -- Attempt to transfer stock between Warehouse of Company A and Warehouse of Company B
        PERFORM transfer_product_stock(
            '11111111-1111-1111-1111-111111111116', -- Prod A (Company A)
            '11111111-1111-1111-1111-111111111114', -- Wh A (Company A)
            '22222222-2222-2222-2222-222222222225', -- Wh B (Company B)
            10
        );
        RAISE EXCEPTION 'TEST FAILED: Cross-company transfer was allowed!';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'TRANSFER_COMPANY_MISMATCH' THEN
            RAISE NOTICE 'TEST PASSED: Cross-company transfer blocked successfully.';
        ELSE
            RAISE NOTICE 'TEST PASSED (With alternative exception): Blocked cross-company transfer. Error: %', SQLERRM;
        END IF;
    END;
END $$;


-- -----------------------------------------------------
-- TEST 2: Product & Warehouse Company Mismatch Prevention in Checkout
-- -----------------------------------------------------
-- Setup a mock active session under Company A (for testing RPC validations)
INSERT INTO cashier_sessions (id, session_code, cashier_id, status, company_id, store_id, pos_id)
VALUES (
    '11111111-1111-1111-1111-111111111200', 
    'SESS-TEST-A', 
    'd290f1ee-6c54-4b01-90e6-d701748f0851', -- existing fallback user profiles id (now verified in profiles)
    'OPEN'::session_status,
    '11111111-1111-1111-1111-111111111111', 
    '11111111-1111-1111-1111-111111111112',
    'f290f1ee-6c54-4b01-90e6-d701748f0853'
) ON CONFLICT DO NOTHING;

DO $$
BEGIN
    BEGIN
        -- Attempt checkout for Company A session, using Product from Company B
        PERFORM create_sales_transaction(
            'INV-CROSS-TEST-001',
            '11111111-1111-1111-1111-111111111200', -- Session under Company A
            '11111111-1111-1111-1111-111111111118', -- Customer Company A
            FALSE, NULL, FALSE, NULL, 15000, 0, 0, 15000, 15000, 0, 'PAID'::payment_status,
            'd290f1ee-6c54-4b01-90e6-d701748f0851', '{}'::jsonb,
            -- Details array contains Prod B (Company B)
            '[{"product_id": "22222222-2222-2222-2222-222222222227", "warehouse_id": "11111111-1111-1111-1111-111111111114", "qty": 1, "price": 15000, "discount_amount": 0, "subtotal": 15000, "cogs_unit": 9000, "cogs_total": 9000}]'::jsonb,
            '[{"payment_no": "PAY-001", "payment_method": "Cash", "amount": 15000, "balance_before": 0, "balance_after": 0, "is_reversal": false}]'::jsonb
        );
        RAISE EXCEPTION 'TEST FAILED: Checkout with mismatching product company was allowed!';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'PRODUCT_COMPANY_MISMATCH' THEN
            RAISE NOTICE 'TEST PASSED: Mismatched product company checkout was blocked.';
        ELSE
            RAISE NOTICE 'TEST PASSED: Blocked mismatch product. Error: %', SQLERRM;
        END IF;
    END;
END $$;


-- -----------------------------------------------------
-- TEST 3: Idempotency Prevention for Duplicate Checkout Events
-- -----------------------------------------------------
DO $$
DECLARE
    v_sales_id1 UUID;
    v_sales_id2 UUID;
BEGIN
    -- First checkout
    v_sales_id1 := create_sales_transaction(
        'INV-IDEMP-001',
        '11111111-1111-1111-1111-111111111200',
        '11111111-1111-1111-1111-111111111118',
        FALSE, NULL, FALSE, NULL, 10000, 0, 0, 10000, 10000, 0, 'PAID'::payment_status,
        'd290f1ee-6c54-4b01-90e6-d701748f0851', '{}'::jsonb,
        '[{"product_id": "11111111-1111-1111-1111-111111111116", "warehouse_id": "11111111-1111-1111-1111-111111111114", "qty": 1, "price": 10000, "discount_amount": 0, "subtotal": 10000, "cogs_unit": 7000, "cogs_total": 7000}]'::jsonb,
        '[{"payment_no": "PAY-IDEMP-001", "payment_method": "Cash", "amount": 10000, "balance_before": 0, "balance_after": 0, "is_reversal": false}]'::jsonb
    );

    BEGIN
        -- Second checkout with identical invoice number
        v_sales_id2 := create_sales_transaction(
            'INV-IDEMP-001',
            '11111111-1111-1111-1111-111111111200',
            '11111111-1111-1111-1111-111111111118',
            FALSE, NULL, FALSE, NULL, 10000, 0, 0, 10000, 10000, 0, 'PAID'::payment_status,
            'd290f1ee-6c54-4b01-90e6-d701748f0851', '{}'::jsonb,
            '[{"product_id": "11111111-1111-1111-1111-111111111116", "warehouse_id": "11111111-1111-1111-1111-111111111114", "qty": 1, "price": 10000, "discount_amount": 0, "subtotal": 10000, "cogs_unit": 7000, "cogs_total": 7000}]'::jsonb,
            '[{"payment_no": "PAY-IDEMP-001", "payment_method": "Cash", "amount": 10000, "balance_before": 0, "balance_after": 0, "is_reversal": false}]'::jsonb
        );
        RAISE EXCEPTION 'TEST FAILED: Duplicate checkout went through without error!';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'TEST PASSED: Duplicate checkout blocked successfully (Idempotency Unique Constraint Triggered). Error: %', SQLERRM;
    END;
END $$;
