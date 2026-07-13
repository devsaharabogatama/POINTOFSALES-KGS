-- ======================================================================
-- SQL SCRIPT: seed_company_data.sql
-- Seed the default Company, Store, and Warehouses, and link your
-- authenticated user account to Company A.
-- ======================================================================

-- 1. Create Default Company A
INSERT INTO companies (id, company_code, company_name, company_slug, status)
VALUES ('11111111-1111-1111-1111-111111111111', 'COMP-A', 'Company A', 'company-a', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

-- 2. Create Default Store A
INSERT INTO stores (id, company_id, store_code, store_name, status)
VALUES ('11111111-1111-1111-1111-111111111112', '11111111-1111-1111-1111-111111111111', 'STORE-A', 'Store A', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

-- 3. Create Default Warehouses (KGS and GDS) linked to Company A
INSERT INTO warehouses (company_id, code, name, is_active)
VALUES 
    ('11111111-1111-1111-1111-111111111111', 'GDS', 'Gudang Utama GDS', true),
    ('11111111-1111-1111-1111-111111111111', 'KGS', 'Toko Kasir KGS', true)
ON CONFLICT DO NOTHING;

-- 4. LINK YOUR LOGGED-IN ACCOUNT TO COMPANY A
-- INSTRUCTIONS: 
-- A. Run this query first to find your user ID: 
--    SELECT id, email FROM auth.users;
-- B. Replace 'PASTE_YOUR_USER_ID_HERE' below with your user ID and run this section:

INSERT INTO company_memberships (company_id, user_id, role_code, status)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    'PASTE_YOUR_USER_ID_HERE', -- <-- GANTI DENGAN USER ID ANDA
    'COMPANY_OWNER',
    'ACTIVE'
) ON CONFLICT DO NOTHING;

INSERT INTO store_memberships (company_id, store_id, user_id, status)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    '11111111-1111-1111-1111-111111111112',
    'PASTE_YOUR_USER_ID_HERE', -- <-- GANTI DENGAN USER ID ANDA
    'ACTIVE'
) ON CONFLICT DO NOTHING;
