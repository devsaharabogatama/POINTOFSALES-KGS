-- -----------------------------------------------------
-- RLS Helper Functions & Auth Signup Trigger
-- -----------------------------------------------------

-- Helper to check role
CREATE OR REPLACE FUNCTION get_my_role() 
RETURNS user_role AS $$
    SELECT role FROM profiles WHERE id = auth.uid();
$$ LANGUAGE sql SECURITY DEFINER;

-- Trigger to automatically create profile on Auth signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
BEGIN
    INSERT INTO public.profiles (id, email, name, role)
    VALUES (
        new.id, 
        new.email, 
        COALESCE(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)), 
        'cashier'::user_role
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- -----------------------------------------------------
-- ROW LEVEL SECURITY POLICIES
-- -----------------------------------------------------

-- Profiles
CREATE POLICY "Profiles are viewable by owner, manager, or self" ON profiles
    FOR SELECT TO authenticated USING (auth.uid() = id OR get_my_role() IN ('owner', 'manager'));

CREATE POLICY "Profiles can be updated by owners or self" ON profiles
    FOR UPDATE TO authenticated USING (auth.uid() = id OR get_my_role() = 'owner');

-- Warehouses
CREATE POLICY "Warehouses viewable by authenticated users" ON warehouses
    FOR SELECT TO authenticated USING (true);

CREATE POLICY "Warehouses manageable by owner/manager" ON warehouses
    FOR ALL TO authenticated USING (get_my_role() IN ('owner', 'manager'));

-- Products
CREATE POLICY "Products viewable by authenticated users" ON products
    FOR SELECT TO authenticated USING (true);

CREATE POLICY "Products manageable by owner/manager" ON products
    FOR ALL TO authenticated USING (get_my_role() IN ('owner', 'manager'));

-- Product Bundle Items
CREATE POLICY "Bundle items viewable by authenticated users" ON product_bundle_items
    FOR SELECT TO authenticated USING (true);

CREATE POLICY "Bundle items manageable by owner/manager" ON product_bundle_items
    FOR ALL TO authenticated USING (get_my_role() IN ('owner', 'manager'));

-- Product Stocks
CREATE POLICY "Stocks viewable by authenticated users" ON product_stocks
    FOR SELECT TO authenticated USING (true);

CREATE POLICY "Stocks manageable by owner/manager" ON product_stocks
    FOR ALL TO authenticated USING (get_my_role() IN ('owner', 'manager'));

-- Customers
CREATE POLICY "Customers viewable by authenticated users" ON customers
    FOR SELECT TO authenticated USING (true);

CREATE POLICY "Customers manageable by cashier, manager, owner" ON customers
    FOR ALL TO authenticated USING (get_my_role() IN ('cashier', 'manager', 'owner'));

-- Cashier Sessions
CREATE POLICY "Sessions viewable by owner, manager, or self" ON cashier_sessions
    FOR SELECT TO authenticated USING (cashier_id = auth.uid() OR get_my_role() IN ('owner', 'manager'));

CREATE POLICY "Sessions insertable by authenticated cashiers" ON cashier_sessions
    FOR INSERT TO authenticated WITH CHECK (cashier_id = auth.uid());

CREATE POLICY "Sessions updateable by owner, manager, or self" ON cashier_sessions
    FOR UPDATE TO authenticated USING (cashier_id = auth.uid() OR get_my_role() IN ('owner', 'manager'));

-- Sales Headers
CREATE POLICY "Sales headers viewable by owner, manager, or self" ON sales_headers
    FOR SELECT TO authenticated USING (created_by = auth.uid() OR get_my_role() IN ('owner', 'manager'));

CREATE POLICY "Sales headers insertable by authenticated users" ON sales_headers
    FOR INSERT TO authenticated WITH CHECK (created_by = auth.uid());

-- Sales Details
CREATE POLICY "Sales details viewable by authenticated users" ON sales_details
    FOR SELECT TO authenticated USING (true);

CREATE POLICY "Sales details insertable by authenticated users" ON sales_details
    FOR INSERT TO authenticated WITH CHECK (true);

-- Sales Payments
CREATE POLICY "Sales payments viewable by authenticated users" ON sales_payments
    FOR SELECT TO authenticated USING (true);

CREATE POLICY "Sales payments insertable by authenticated users" ON sales_payments
    FOR INSERT TO authenticated WITH CHECK (true);

-- Purchases Headers
CREATE POLICY "Purchases viewable by owner/manager" ON purchases_headers
    FOR ALL TO authenticated USING (get_my_role() IN ('owner', 'manager'));

-- Purchases Details
CREATE POLICY "Purchases details viewable by owner/manager" ON purchases_details
    FOR ALL TO authenticated USING (get_my_role() IN ('owner', 'manager'));

-- Cash Advances
CREATE POLICY "Cash advances viewable by owner, manager, or self" ON cash_advances
    FOR SELECT TO authenticated USING (created_by = auth.uid() OR get_my_role() IN ('owner', 'manager'));

CREATE POLICY "Cash advances insertable by cashiers/managers" ON cash_advances
    FOR INSERT TO authenticated WITH CHECK (created_by = auth.uid());

CREATE POLICY "Cash advances manageable by owner/manager" ON cash_advances
    FOR UPDATE TO authenticated USING (get_my_role() IN ('owner', 'manager'));

-- Bank Deposits
CREATE POLICY "Bank deposits viewable by owner, manager, or self" ON bank_deposits
    FOR SELECT TO authenticated USING (created_by = auth.uid() OR get_my_role() IN ('owner', 'manager'));

CREATE POLICY "Bank deposits insertable by cashiers" ON bank_deposits
    FOR INSERT TO authenticated WITH CHECK (created_by = auth.uid());

-- Financial Events, Journal Entries, POS Reconciliations (Owner & Manager Only)
CREATE POLICY "Accounting tables viewable by owner/manager" ON financial_events
    FOR SELECT TO authenticated USING (get_my_role() IN ('owner', 'manager'));

CREATE POLICY "Accounting entries viewable by owner/manager" ON journal_entries
    FOR SELECT TO authenticated USING (get_my_role() IN ('owner', 'manager'));

CREATE POLICY "Reconciliation viewable by owner/manager" ON pos_reconciliations
    FOR SELECT TO authenticated USING (get_my_role() IN ('owner', 'manager'));
