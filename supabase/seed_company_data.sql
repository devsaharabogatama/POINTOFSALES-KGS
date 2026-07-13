-- ======================================================================
-- SQL SCRIPT: seed_company_data.sql
-- AUTOMATICALLY CREATES A TEST USER AND TENANT DATA
-- Run this in your Supabase SQL Editor once to set up everything.
-- ======================================================================

-- 1. Enable pgcrypto for password hashing
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 2. Create Test User Account (kasir1@kgs.com / password123) in auth.users
INSERT INTO auth.users (
  id, 
  instance_id, 
  email, 
  encrypted_password, 
  email_confirmed_at, 
  raw_app_meta_data, 
  raw_user_meta_data, 
  created_at, 
  updated_at, 
  role, 
  aud
)
VALUES (
  'd290f1ee-6c54-4b01-90e6-d701748f0851', -- Fixed User UUID
  '00000000-0000-0000-0000-000000000000',
  'kasir1@kgs.com',
  crypt('password123', gen_salt('bf', 10)), -- Valid bcrypt hash for password 'password123'
  NOW(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"Kasir KGS Utama"}'::jsonb,
  NOW(),
  NOW(),
  'authenticated',
  'authenticated'
)
ON CONFLICT (id) DO UPDATE 
SET encrypted_password = crypt('password123', gen_salt('bf', 10));

-- 3. Create Profile in public.profiles (automatic via trigger, but we ensure it exists)
INSERT INTO public.profiles (id, email, name, role)
VALUES (
  'd290f1ee-6c54-4b01-90e6-d701748f0851',
  'kasir1@kgs.com',
  'Kasir KGS Utama',
  'cashier'::user_role
)
ON CONFLICT (id) DO NOTHING;

-- 4. Create Default Company A
INSERT INTO companies (id, company_code, company_name, company_slug, status)
VALUES ('11111111-1111-1111-1111-111111111111', 'COMP-A', 'Company A', 'company-a', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

-- 5. Create Default Store A
INSERT INTO stores (id, company_id, store_code, store_name, status)
VALUES ('11111111-1111-1111-1111-111111111112', '11111111-1111-1111-1111-111111111111', 'STORE-A', 'Store A', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

-- 6. Create Default Warehouses (KGS and GDS)
INSERT INTO warehouses (company_id, code, name, is_active)
VALUES 
    ('11111111-1111-1111-1111-111111111111', 'GDS', 'Gudang Utama GDS', true),
    ('11111111-1111-1111-1111-111111111111', 'KGS', 'Toko Kasir KGS', true)
ON CONFLICT DO NOTHING;

-- 7. Link User Account to Company A as OWNER
INSERT INTO company_memberships (company_id, user_id, role_code, status)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    'd290f1ee-6c54-4b01-90e6-d701748f0851',
    'COMPANY_OWNER',
    'ACTIVE'
) ON CONFLICT DO NOTHING;

-- 8. Link User Account to Store A
INSERT INTO store_memberships (company_id, store_id, user_id, status)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    '11111111-1111-1111-1111-111111111112',
    'd290f1ee-6c54-4b01-90e6-d701748f0851',
    'ACTIVE'
) ON CONFLICT DO NOTHING;
