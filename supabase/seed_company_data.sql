-- Safe development seed. Run after migration 002.
-- User accounts must be created through Supabase Auth / the authorized backoffice API.
-- This file intentionally does not create credentials or reset passwords.

INSERT INTO public.companies (
    id, company_code, company_name, company_slug, status
) VALUES (
    'd290f1ee-6c54-4b01-90e6-d701748f0851',
    'KGS',
    'KGS Company',
    'kgs-company',
    'ACTIVE'
)
ON CONFLICT (company_code) DO UPDATE
SET company_name = EXCLUDED.company_name,
    status = EXCLUDED.status;

INSERT INTO public.stores (
    id, company_id, store_code, store_name, status
) VALUES (
    'e290f1ee-6c54-4b01-90e6-d701748f0852',
    'd290f1ee-6c54-4b01-90e6-d701748f0851',
    'KGS-STORE-1',
    'Toko Utama KGS',
    'ACTIVE'
)
ON CONFLICT (company_id, store_code) DO UPDATE
SET store_name = EXCLUDED.store_name,
    status = EXCLUDED.status;

INSERT INTO public.warehouses (company_id, code, name, is_active)
VALUES
    ('d290f1ee-6c54-4b01-90e6-d701748f0851', 'GDS', 'Gudang Utama', TRUE),
    ('d290f1ee-6c54-4b01-90e6-d701748f0851', 'KGS', 'Gudang Toko', TRUE)
ON CONFLICT (company_id, code) DO UPDATE
SET name = EXCLUDED.name,
    is_active = EXCLUDED.is_active;
