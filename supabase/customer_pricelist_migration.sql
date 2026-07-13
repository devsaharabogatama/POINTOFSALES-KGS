-- -----------------------------------------------------
-- TABLE: customer_pricelists (Multi-Company Enabled)
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS customer_pricelists (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    customer_id UUID NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    custom_price NUMERIC NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_customer_product_price UNIQUE (customer_id, product_id)
);

-- Enable RLS
ALTER TABLE customer_pricelists ENABLE ROW LEVEL SECURITY;

-- RLS Policies
DROP POLICY IF EXISTS "Pricelists viewable by company members" ON customer_pricelists;
CREATE POLICY "Pricelists viewable by company members" ON customer_pricelists
    FOR SELECT TO authenticated USING (private_user_has_company_access(company_id));

DROP POLICY IF EXISTS "Pricelists manageable by company staff" ON customer_pricelists;
CREATE POLICY "Pricelists manageable by company staff" ON customer_pricelists
    FOR ALL TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER')
    );

-- Refresh cache
NOTIFY pgrst, 'reload schema';
