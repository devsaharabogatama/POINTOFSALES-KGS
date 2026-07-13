-- -----------------------------------------------------
-- 1. CREATE CORE MULTI-TENANT TABLES
-- -----------------------------------------------------

-- Companies table
CREATE TABLE IF NOT EXISTS companies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_code TEXT UNIQUE NOT NULL,
    company_name TEXT NOT NULL,
    company_slug TEXT UNIQUE NOT NULL,
    legal_name TEXT,
    tax_id TEXT,
    timezone TEXT NOT NULL DEFAULT 'Asia/Jakarta',
    currency_code TEXT NOT NULL DEFAULT 'IDR',
    status TEXT NOT NULL DEFAULT 'ACTIVE',
    subscription_plan TEXT NOT NULL DEFAULT 'FREE',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Stores table
CREATE TABLE IF NOT EXISTS stores (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    store_code TEXT NOT NULL,
    store_name TEXT NOT NULL,
    address TEXT,
    timezone TEXT NOT NULL DEFAULT 'Asia/Jakarta',
    status TEXT NOT NULL DEFAULT 'ACTIVE',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_company_store UNIQUE (company_id, store_code)
);

-- POS Terminals table
CREATE TABLE IF NOT EXISTS pos_terminals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    store_id UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    pos_code TEXT NOT NULL,
    pos_name TEXT NOT NULL,
    device_identifier TEXT,
    status TEXT NOT NULL DEFAULT 'ACTIVE',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_company_store_pos UNIQUE (company_id, store_id, pos_code)
);

-- Memberships tables
CREATE TABLE IF NOT EXISTS company_memberships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    role_code TEXT NOT NULL DEFAULT 'CASHIER',
    status TEXT NOT NULL DEFAULT 'ACTIVE',
    is_default_company BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_company_user UNIQUE (company_id, user_id)
);

CREATE TABLE IF NOT EXISTS store_memberships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    store_id UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    role_code TEXT NOT NULL DEFAULT 'CASHIER',
    status TEXT NOT NULL DEFAULT 'ACTIVE',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_company_store_user UNIQUE (company_id, store_id, user_id)
);

-- -----------------------------------------------------
-- 2. SEED DEFAULT INITIAL TENANT DATA (KGS)
-- -----------------------------------------------------
INSERT INTO companies (id, company_code, company_name, company_slug, status)
VALUES ('d290f1ee-6c54-4b01-90e6-d701748f0851', 'KGS', 'KGS Company', 'kgs-company', 'ACTIVE')
ON CONFLICT (company_code) DO UPDATE SET company_name = EXCLUDED.company_name;

INSERT INTO stores (id, company_id, store_code, store_name, status)
VALUES ('e290f1ee-6c54-4b01-90e6-d701748f0852', 'd290f1ee-6c54-4b01-90e6-d701748f0851', 'KGS-STORE-1', 'Toko Utama KGS', 'ACTIVE')
ON CONFLICT (company_id, store_code) DO UPDATE SET store_name = EXCLUDED.store_name;

INSERT INTO pos_terminals (id, company_id, store_id, pos_code, pos_name, status)
VALUES ('f290f1ee-6c54-4b01-90e6-d701748f0853', 'd290f1ee-6c54-4b01-90e6-d701748f0851', 'e290f1ee-6c54-4b01-90e6-d701748f0852', 'POS-1', 'Kasir Utama POS-1', 'ACTIVE')
ON CONFLICT (company_id, store_id, pos_code) DO UPDATE SET pos_name = EXCLUDED.pos_name;

-- -----------------------------------------------------
-- 3. ADD TENANT ID COLUMNS (NULLABLE FOR SAFETY FIRST)
-- -----------------------------------------------------
ALTER TABLE warehouses ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);

ALTER TABLE products ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE product_bundle_items ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE product_stocks ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);

ALTER TABLE customers ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);

ALTER TABLE cashier_sessions ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE cashier_sessions ADD COLUMN IF NOT EXISTS store_id UUID REFERENCES stores(id);
ALTER TABLE cashier_sessions ADD COLUMN IF NOT EXISTS pos_id UUID REFERENCES pos_terminals(id);

ALTER TABLE sales_headers ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE sales_headers ADD COLUMN IF NOT EXISTS store_id UUID REFERENCES stores(id);
ALTER TABLE sales_headers ADD COLUMN IF NOT EXISTS pos_id UUID REFERENCES pos_terminals(id);

ALTER TABLE sales_details ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE sales_payments ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);

ALTER TABLE purchases_headers ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE purchases_headers ADD COLUMN IF NOT EXISTS store_id UUID REFERENCES stores(id);
ALTER TABLE purchases_details ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);

ALTER TABLE cash_advances ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE cash_advances ADD COLUMN IF NOT EXISTS store_id UUID REFERENCES stores(id);

ALTER TABLE bank_deposits ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE bank_deposits ADD COLUMN IF NOT EXISTS store_id UUID REFERENCES stores(id);

ALTER TABLE financial_events ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE financial_events ADD COLUMN IF NOT EXISTS store_id UUID REFERENCES stores(id);

ALTER TABLE journal_entries ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE journal_entries ADD COLUMN IF NOT EXISTS store_id UUID REFERENCES stores(id);

ALTER TABLE pos_reconciliations ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);

-- Optional/New module tables from inventory migration
ALTER TABLE uoms ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE product_uom_conversions ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE product_batches ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE sales_fifo_allocations ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE stock_opnames ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE stock_opname_details ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE stock_adjustments ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE stock_movements ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES companies(id);
ALTER TABLE stock_movements ADD COLUMN IF NOT EXISTS store_id UUID REFERENCES stores(id);

-- -----------------------------------------------------
-- 4. BACKFILL DATA LAMA KE TENANT KGS
-- -----------------------------------------------------
UPDATE warehouses SET company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851' WHERE company_id IS NULL;

UPDATE products SET company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851' WHERE company_id IS NULL;
UPDATE product_bundle_items SET company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851' WHERE company_id IS NULL;
UPDATE product_stocks SET company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851' WHERE company_id IS NULL;

UPDATE customers SET company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851' WHERE company_id IS NULL;

UPDATE cashier_sessions SET 
    company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851',
    store_id = 'e290f1ee-6c54-4b01-90e6-d701748f0852',
    pos_id = 'f290f1ee-6c54-4b01-90e6-d701748f0853'
WHERE company_id IS NULL;

UPDATE sales_headers SET 
    company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851',
    store_id = 'e290f1ee-6c54-4b01-90e6-d701748f0852',
    pos_id = 'f290f1ee-6c54-4b01-90e6-d701748f0853'
WHERE company_id IS NULL;

UPDATE sales_details SET company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851' WHERE company_id IS NULL;
UPDATE sales_payments SET company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851' WHERE company_id IS NULL;

UPDATE purchases_headers SET 
    company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851',
    store_id = 'e290f1ee-6c54-4b01-90e6-d701748f0852'
WHERE company_id IS NULL;

UPDATE purchases_details SET company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851' WHERE company_id IS NULL;

UPDATE cash_advances SET 
    company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851',
    store_id = 'e290f1ee-6c54-4b01-90e6-d701748f0852'
WHERE company_id IS NULL;

UPDATE bank_deposits SET 
    company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851',
    store_id = 'e290f1ee-6c54-4b01-90e6-d701748f0852'
WHERE company_id IS NULL;

UPDATE financial_events SET 
    company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851',
    store_id = 'e290f1ee-6c54-4b01-90e6-d701748f0852'
WHERE company_id IS NULL;

UPDATE journal_entries SET 
    company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851',
    store_id = 'e290f1ee-6c54-4b01-90e6-d701748f0852'
WHERE company_id IS NULL;

UPDATE pos_reconciliations SET company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851' WHERE company_id IS NULL;

UPDATE uoms SET company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851' WHERE company_id IS NULL;
UPDATE product_uom_conversions SET company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851' WHERE company_id IS NULL;
UPDATE product_batches SET company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851' WHERE company_id IS NULL;
UPDATE sales_fifo_allocations SET company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851' WHERE company_id IS NULL;
UPDATE stock_opnames SET company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851' WHERE company_id IS NULL;
UPDATE stock_opname_details SET company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851' WHERE company_id IS NULL;
UPDATE stock_adjustments SET company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851' WHERE company_id IS NULL;

UPDATE stock_movements SET 
    company_id = 'd290f1ee-6c54-4b01-90e6-d701748f0851',
    store_id = 'e290f1ee-6c54-4b01-90e6-d701748f0852'
WHERE company_id IS NULL;

-- Profile membership seeding based on existing role
INSERT INTO company_memberships (company_id, user_id, role_code, status)
SELECT 'd290f1ee-6c54-4b01-90e6-d701748f0851', id, 
       CASE WHEN role = 'owner' THEN 'COMPANY_OWNER'
            WHEN role = 'manager' THEN 'COMPANY_ADMIN'
            ELSE 'CASHIER' END,
       'ACTIVE'
FROM profiles
ON CONFLICT (company_id, user_id) DO NOTHING;

-- -----------------------------------------------------
-- 5. SET NOT NULL ONCE DATA BACKFILL IS DONE
-- -----------------------------------------------------
ALTER TABLE warehouses ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE products ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE product_bundle_items ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE product_stocks ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE customers ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE cashier_sessions ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE sales_headers ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE sales_details ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE sales_payments ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE purchases_headers ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE purchases_details ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE cash_advances ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE bank_deposits ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE financial_events ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE journal_entries ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE pos_reconciliations ALTER COLUMN company_id SET NOT NULL;

-- -----------------------------------------------------
-- 6. SECURITY ACCESS HELPERS FOR RLS
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION private_user_has_company_access(p_company_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM company_memberships 
        WHERE company_id = p_company_id 
          AND user_id = auth.uid() 
          AND status = 'ACTIVE'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION private_user_has_store_access(p_store_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
    -- Owners/Admins of the company automatically have access to all stores
    RETURN EXISTS (
        SELECT 1 FROM company_memberships cm
        JOIN stores s ON s.company_id = cm.company_id
        WHERE s.id = p_store_id
          AND cm.user_id = auth.uid()
          AND cm.role_code IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
          AND cm.status = 'ACTIVE'
    ) OR EXISTS (
        SELECT 1 FROM store_memberships
        WHERE store_id = p_store_id
          AND user_id = auth.uid()
          AND status = 'ACTIVE'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- -----------------------------------------------------
-- 7. REBUILD INDEXES WITH COMPANY ID PREFIX
-- -----------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_products_company_sku ON products (company_id, sku);
CREATE INDEX IF NOT EXISTS idx_product_stocks_company_wh ON product_stocks (company_id, warehouse_id);
CREATE INDEX IF NOT EXISTS idx_sales_headers_company_inv ON sales_headers (company_id, invoice_no);
CREATE INDEX IF NOT EXISTS idx_sales_details_company_sales ON sales_details (company_id, sales_id);
CREATE INDEX IF NOT EXISTS idx_sales_payments_company_sales ON sales_payments (company_id, sales_id);
CREATE INDEX IF NOT EXISTS idx_financial_events_company_status ON financial_events (company_id, status);
CREATE INDEX IF NOT EXISTS idx_journal_entries_company_group ON journal_entries (company_id, entry_group_id);
CREATE INDEX IF NOT EXISTS idx_stock_movements_company_wh_prod ON stock_movements (company_id, warehouse_id, product_id);
