-- -----------------------------------------------------
-- RLS Helper Functions & Auth Signup Trigger (Multi-Tenant Aware)
-- -----------------------------------------------------

-- Helper to check role in company context
CREATE OR REPLACE FUNCTION get_user_role_in_company(p_company_id UUID) 
RETURNS TEXT AS $$
    SELECT role_code FROM company_memberships 
    WHERE company_id = p_company_id AND user_id = auth.uid() AND status = 'ACTIVE';
$$ LANGUAGE sql SECURITY DEFINER;

-- Trigger to automatically create profile on Auth signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
BEGIN
    INSERT INTO public.profiles (id, email, name)
    VALUES (
        new.id, 
        new.email, 
        COALESCE(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1))
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- -----------------------------------------------------
-- ROW LEVEL SECURITY POLICIES WITH MULTI-TENANT ISOLATION
-- -----------------------------------------------------

-- Profiles
DROP POLICY IF EXISTS "Profiles are viewable by owner, manager, or self" ON profiles;
CREATE POLICY "Profiles are viewable by owner, manager, or self" ON profiles
    FOR SELECT TO authenticated USING (auth.uid() = id OR EXISTS (
        SELECT 1 FROM company_memberships WHERE user_id = auth.uid() AND role_code IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
    ));

DROP POLICY IF EXISTS "Profiles can be updated by owners or self" ON profiles;
CREATE POLICY "Profiles can be updated by owners or self" ON profiles
    FOR UPDATE TO authenticated USING (auth.uid() = id);

-- Warehouses
DROP POLICY IF EXISTS "Warehouses viewable by authenticated users" ON warehouses;
CREATE POLICY "Warehouses viewable by company members" ON warehouses
    FOR SELECT TO authenticated USING (private_user_has_company_access(company_id));

DROP POLICY IF EXISTS "Warehouses manageable by owner/manager" ON warehouses;
CREATE POLICY "Warehouses manageable by company owner/admin" ON warehouses
    FOR ALL TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
    );

-- Products
DROP POLICY IF EXISTS "Products viewable by authenticated users" ON products;
CREATE POLICY "Products viewable by company members" ON products
    FOR SELECT TO authenticated USING (private_user_has_company_access(company_id));

DROP POLICY IF EXISTS "Products manageable by owner/manager" ON products;
CREATE POLICY "Products manageable by company owner/admin" ON products
    FOR ALL TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
    );

-- Product Bundle Items
DROP POLICY IF EXISTS "Bundle items viewable by authenticated users" ON product_bundle_items;
CREATE POLICY "Bundle items viewable by company members" ON product_bundle_items
    FOR SELECT TO authenticated USING (private_user_has_company_access(company_id));

DROP POLICY IF EXISTS "Bundle items manageable by owner/manager" ON product_bundle_items;
CREATE POLICY "Bundle items manageable by company owner/admin" ON product_bundle_items
    FOR ALL TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
    );

-- Product Stocks
DROP POLICY IF EXISTS "Stocks viewable by authenticated users" ON product_stocks;
CREATE POLICY "Stocks viewable by company members" ON product_stocks
    FOR SELECT TO authenticated USING (private_user_has_company_access(company_id));

DROP POLICY IF EXISTS "Stocks manageable by owner/manager" ON product_stocks;
CREATE POLICY "Stocks manageable by company owner/admin/warehouse" ON product_stocks
    FOR ALL TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN', 'WAREHOUSE_ADMIN')
    );

-- Customers
DROP POLICY IF EXISTS "Customers viewable by authenticated users" ON customers;
CREATE POLICY "Customers viewable by company members" ON customers
    FOR SELECT TO authenticated USING (private_user_has_company_access(company_id));

DROP POLICY IF EXISTS "Customers manageable by cashier, manager, owner" ON customers;
CREATE POLICY "Customers manageable by company staff" ON customers
    FOR ALL TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN', 'CASHIER', 'STORE_MANAGER')
    );

-- Cashier Sessions
DROP POLICY IF EXISTS "Sessions viewable by owner, manager, or self" ON cashier_sessions;
CREATE POLICY "Sessions viewable by authorized company/store staff" ON cashier_sessions
    FOR SELECT TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND (cashier_id = auth.uid() OR private_user_has_store_access(store_id))
    );

DROP POLICY IF EXISTS "Sessions insertable by authenticated cashiers" ON cashier_sessions;
CREATE POLICY "Sessions insertable by cashiers" ON cashier_sessions
    FOR INSERT TO authenticated WITH CHECK (
        private_user_has_company_access(company_id) 
        AND cashier_id = auth.uid()
    );

DROP POLICY IF EXISTS "Sessions updateable by owner, manager, or self" ON cashier_sessions;
CREATE POLICY "Sessions updateable by cashiers or managers" ON cashier_sessions
    FOR UPDATE TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND (cashier_id = auth.uid() OR private_user_has_store_access(store_id))
    );

-- Sales Headers
DROP POLICY IF EXISTS "Sales headers viewable by owner, manager, or self" ON sales_headers;
CREATE POLICY "Sales headers viewable by company/store members" ON sales_headers
    FOR SELECT TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND (created_by = auth.uid() OR private_user_has_store_access(store_id))
    );

DROP POLICY IF EXISTS "Sales headers insertable by authenticated users" ON sales_headers;
CREATE POLICY "Sales headers insertable by cashier staff" ON sales_headers
    FOR INSERT TO authenticated WITH CHECK (
        private_user_has_company_access(company_id) 
        AND created_by = auth.uid()
    );

-- Sales Details
DROP POLICY IF EXISTS "Sales details viewable by authenticated users" ON sales_details;
CREATE POLICY "Sales details viewable by company members" ON sales_details
    FOR SELECT TO authenticated USING (private_user_has_company_access(company_id));

DROP POLICY IF EXISTS "Sales details insertable by authenticated users" ON sales_details;
CREATE POLICY "Sales details insertable by company members" ON sales_details
    FOR INSERT TO authenticated WITH CHECK (private_user_has_company_access(company_id));

-- Sales Payments
DROP POLICY IF EXISTS "Sales payments viewable by authenticated users" ON sales_payments;
CREATE POLICY "Sales payments viewable by company members" ON sales_payments
    FOR SELECT TO authenticated USING (private_user_has_company_access(company_id));

DROP POLICY IF EXISTS "Sales payments insertable by authenticated users" ON sales_payments;
CREATE POLICY "Sales payments insertable by company members" ON sales_payments
    FOR INSERT TO authenticated WITH CHECK (private_user_has_company_access(company_id));

-- Purchases Headers
DROP POLICY IF EXISTS "Purchases viewable by owner/manager" ON purchases_headers;
CREATE POLICY "Purchases headers viewable by company members" ON purchases_headers
    FOR ALL TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
    );

-- Purchases Details
DROP POLICY IF EXISTS "Purchases details viewable by owner/manager" ON purchases_details;
CREATE POLICY "Purchases details viewable by company members" ON purchases_details
    FOR ALL TO authenticated USING (private_user_has_company_access(company_id));

-- Cash Advances
DROP POLICY IF EXISTS "Cash advances viewable by owner, manager, or self" ON cash_advances;
CREATE POLICY "Cash advances viewable by company/store members" ON cash_advances
    FOR SELECT TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND (created_by = auth.uid() OR private_user_has_store_access(store_id))
    );

DROP POLICY IF EXISTS "Cash advances insertable by cashiers/managers" ON cash_advances;
CREATE POLICY "Cash advances insertable by cashiers" ON cash_advances
    FOR INSERT TO authenticated WITH CHECK (
        private_user_has_company_access(company_id) 
        AND created_by = auth.uid()
    );

DROP POLICY IF EXISTS "Cash advances manageable by owner/manager" ON cash_advances;
CREATE POLICY "Cash advances manageable by company owner/admin" ON cash_advances
    FOR UPDATE TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
    );

-- Bank Deposits
DROP POLICY IF EXISTS "Bank deposits viewable by owner, manager, or self" ON bank_deposits;
CREATE POLICY "Bank deposits viewable by company/store members" ON bank_deposits
    FOR SELECT TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND (created_by = auth.uid() OR private_user_has_store_access(store_id))
    );

DROP POLICY IF EXISTS "Bank deposits insertable by cashiers" ON bank_deposits;
CREATE POLICY "Bank deposits insertable by cashiers" ON bank_deposits
    FOR INSERT TO authenticated WITH CHECK (
        private_user_has_company_access(company_id) 
        AND created_by = auth.uid()
    );

-- Financial Events, Journal Entries, POS Reconciliations (Owner, Admin & Finance Only)
DROP POLICY IF EXISTS "Accounting tables viewable by owner/manager" ON financial_events;
CREATE POLICY "Accounting events viewable by company owner/admin/finance" ON financial_events
    FOR SELECT TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN', 'FINANCE', 'ACCOUNTING')
    );

DROP POLICY IF EXISTS "Accounting entries viewable by owner/manager" ON journal_entries;
CREATE POLICY "Accounting entries viewable by company owner/admin/finance" ON journal_entries
    FOR SELECT TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN', 'FINANCE', 'ACCOUNTING')
    );

DROP POLICY IF EXISTS "Reconciliation viewable by owner/manager" ON pos_reconciliations;
CREATE POLICY "Reconciliation viewable by company owner/admin/finance" ON pos_reconciliations
    FOR SELECT TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN', 'FINANCE', 'ACCOUNTING')
    );

-- Uoms
DROP POLICY IF EXISTS "Uoms viewable by authenticated users" ON uoms;
CREATE POLICY "Uoms viewable by company members" ON uoms
    FOR SELECT TO authenticated USING (private_user_has_company_access(company_id));

CREATE POLICY "Uoms manageable by company owner/admin" ON uoms
    FOR ALL TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
    );

-- Product UOM Conversions
DROP POLICY IF EXISTS "Conversions viewable by authenticated users" ON product_uom_conversions;
CREATE POLICY "Conversions viewable by company members" ON product_uom_conversions
    FOR SELECT TO authenticated USING (private_user_has_company_access(company_id));

CREATE POLICY "Conversions manageable by company owner/admin" ON product_uom_conversions
    FOR ALL TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
    );

-- Product Batches (FIFO)
DROP POLICY IF EXISTS "Batches viewable by owner/manager" ON product_batches;
CREATE POLICY "Batches manageable by company owner/admin" ON product_batches
    FOR ALL TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
    );

-- Sales FIFO Allocations
DROP POLICY IF EXISTS "FIFO allocations viewable by owner/manager" ON sales_fifo_allocations;
CREATE POLICY "FIFO allocations viewable by company owner/admin/finance" ON sales_fifo_allocations
    FOR SELECT TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN', 'FINANCE', 'ACCOUNTING')
    );

-- Stock Opnames
DROP POLICY IF EXISTS "Opnames viewable by owner/manager" ON stock_opnames;
CREATE POLICY "Opnames viewable by company owner/admin" ON stock_opnames
    FOR SELECT TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
    );

CREATE POLICY "Opnames manageable by company owner/admin" ON stock_opnames
    FOR ALL TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
    );

-- Stock Opname Details
DROP POLICY IF EXISTS "Opname details viewable by owner/manager" ON stock_opname_details;
CREATE POLICY "Opname details viewable by company owner/admin" ON stock_opname_details
    FOR SELECT TO authenticated USING (private_user_has_company_access(company_id));

CREATE POLICY "Opname details manageable by company owner/admin" ON stock_opname_details
    FOR ALL TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
    );

-- Stock Adjustments
DROP POLICY IF EXISTS "Adjustments viewable by owner/manager" ON stock_adjustments;
CREATE POLICY "Adjustments viewable by company owner/admin" ON stock_adjustments
    FOR SELECT TO authenticated USING (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
    );

CREATE POLICY "Adjustments insertable by company owner/admin" ON stock_adjustments
    FOR INSERT TO authenticated WITH CHECK (
        private_user_has_company_access(company_id) 
        AND get_user_role_in_company(company_id) IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
    );

-- Stock Movements (Kartu Stok)
DROP POLICY IF EXISTS "Movements viewable by owner/manager" ON stock_movements;
CREATE POLICY "Movements viewable by company members" ON stock_movements
    FOR SELECT TO authenticated USING (private_user_has_company_access(company_id));
