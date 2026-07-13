-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- -----------------------------------------------------
-- CREATE ENUMS
-- -----------------------------------------------------
CREATE TYPE user_role AS ENUM ('cashier', 'manager', 'owner');
CREATE TYPE session_status AS ENUM ('OPEN', 'CLOSED');
CREATE TYPE sj_status AS ENUM ('NONE', 'PENDING', 'SHIPPED');
CREATE TYPE so_confirm_status AS ENUM ('DRAFT', 'CONFIRMED');
CREATE TYPE invoice_status AS ENUM ('DRAFT', 'READY', 'NOT_READY', 'GENERATED');
CREATE TYPE payment_status AS ENUM ('DRAFT', 'UNPAID', 'PARTIAL', 'PAID');
CREATE TYPE financial_status AS ENUM ('PENDING', 'POSTED', 'PARTIALLY_POSTED', 'ERROR');
CREATE TYPE recon_status AS ENUM ('UNRECONCILED', 'MATCH', 'UNMATCH');
CREATE TYPE payment_method AS ENUM ('Cash', 'Transfer', 'QRIS', 'Customer_Balance');
CREATE TYPE ca_status AS ENUM ('APPROVED', 'REJECTED');
CREATE TYPE event_type AS ENUM (
    'SALE_POSTED', 
    'SALE_REVISED', 
    'SALE_VOIDED', 
    'PAYMENT_RECEIVED', 
    'SALES_REFUND', 
    'SALES_RETURN_STOCK', 
    'PURCHASE_POSTED', 
    'EXPENSE_POSTED', 
    'BANK_DEPOSIT'
);
CREATE TYPE event_status AS ENUM ('READY', 'PROCESSING', 'DONE', 'ERROR', 'CANCELED');

-- -----------------------------------------------------
-- TABLE DEFINITIONS
-- -----------------------------------------------------

-- 3.1. General & Authentication
CREATE TABLE profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    role user_role NOT NULL DEFAULT 'cashier',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE warehouses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 3.2. Master Data
CREATE TABLE products (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sku TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    category TEXT,
    vendor TEXT,
    merk TEXT,
    price NUMERIC NOT NULL DEFAULT 0,
    cogs NUMERIC NOT NULL DEFAULT 0,
    uom TEXT NOT NULL DEFAULT 'pcs',
    is_bundle BOOLEAN NOT NULL DEFAULT FALSE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE product_bundle_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    bundle_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    item_id UUID NOT NULL REFERENCES products(id),
    qty NUMERIC NOT NULL DEFAULT 1,
    CONSTRAINT chk_qty_positive CHECK (qty > 0)
);

CREATE TABLE product_stocks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    stock_qty NUMERIC NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_product_warehouse UNIQUE (product_id, warehouse_id)
);

CREATE TABLE customers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    phone TEXT,
    address TEXT,
    current_balance NUMERIC NOT NULL DEFAULT 0,
    credit_limit NUMERIC NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 3.3. POS & Sales Operations
CREATE TABLE cashier_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_code TEXT UNIQUE NOT NULL,
    cashier_id UUID NOT NULL REFERENCES profiles(id),
    opened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at TIMESTAMPTZ,
    opening_balance NUMERIC NOT NULL DEFAULT 0,
    expected_cash NUMERIC NOT NULL DEFAULT 0,
    actual_cash NUMERIC NOT NULL DEFAULT 0,
    difference NUMERIC NOT NULL DEFAULT 0,
    note_open TEXT,
    note_close TEXT,
    status session_status NOT NULL DEFAULT 'OPEN'
);

CREATE TABLE sales_headers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    invoice_no TEXT UNIQUE NOT NULL,
    session_id UUID NOT NULL REFERENCES cashier_sessions(id),
    customer_id UUID REFERENCES customers(id),
    transaction_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_tempo BOOLEAN NOT NULL DEFAULT FALSE,
    due_date TIMESTAMPTZ,
    sj_required BOOLEAN NOT NULL DEFAULT FALSE,
    sj_no TEXT,
    sj_status sj_status NOT NULL DEFAULT 'NONE',
    so_confirm_status so_confirm_status NOT NULL DEFAULT 'DRAFT',
    invoice_status invoice_status NOT NULL DEFAULT 'DRAFT',
    subtotal NUMERIC NOT NULL DEFAULT 0,
    item_discount NUMERIC NOT NULL DEFAULT 0,
    global_discount NUMERIC NOT NULL DEFAULT 0,
    grand_total NUMERIC NOT NULL DEFAULT 0,
    paid_amount NUMERIC NOT NULL DEFAULT 0,
    sisa_piutang NUMERIC NOT NULL DEFAULT 0,
    payment_status payment_status NOT NULL DEFAULT 'DRAFT',
    financial_status financial_status NOT NULL DEFAULT 'PENDING',
    recon_status recon_status NOT NULL DEFAULT 'UNRECONCILED',
    created_by UUID NOT NULL REFERENCES profiles(id),
    is_revision BOOLEAN NOT NULL DEFAULT FALSE,
    original_invoice_no TEXT,
    payload_snapshot JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE sales_details (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sales_id UUID NOT NULL REFERENCES sales_headers(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES products(id),
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    qty NUMERIC NOT NULL DEFAULT 0,
    price NUMERIC NOT NULL DEFAULT 0,
    discount_amount NUMERIC NOT NULL DEFAULT 0,
    subtotal NUMERIC NOT NULL DEFAULT 0,
    cogs_unit NUMERIC NOT NULL DEFAULT 0,
    cogs_total NUMERIC NOT NULL DEFAULT 0
);

CREATE TABLE sales_payments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    payment_no TEXT UNIQUE NOT NULL,
    sales_id UUID NOT NULL REFERENCES sales_headers(id) ON DELETE CASCADE,
    payment_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    session_id UUID NOT NULL REFERENCES cashier_sessions(id),
    payment_method payment_method NOT NULL,
    amount NUMERIC NOT NULL DEFAULT 0,
    balance_before NUMERIC NOT NULL DEFAULT 0,
    balance_after NUMERIC NOT NULL DEFAULT 0,
    is_reversal BOOLEAN NOT NULL DEFAULT FALSE,
    reversal_ref_id UUID REFERENCES sales_payments(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 3.4. Purchasing, Cash Advance & Bank Deposits
CREATE TABLE purchases_headers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    purchase_no TEXT UNIQUE NOT NULL,
    supplier_name TEXT NOT NULL,
    transaction_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    subtotal NUMERIC NOT NULL DEFAULT 0,
    grand_total NUMERIC NOT NULL DEFAULT 0,
    paid_amount NUMERIC NOT NULL DEFAULT 0,
    payment_status payment_status NOT NULL DEFAULT 'UNPAID',
    created_by UUID NOT NULL REFERENCES profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE purchases_details (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    purchase_id UUID NOT NULL REFERENCES purchases_headers(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES products(id),
    qty NUMERIC NOT NULL DEFAULT 0,
    purchase_price NUMERIC NOT NULL DEFAULT 0,
    subtotal NUMERIC NOT NULL DEFAULT 0
);

CREATE TABLE cash_advances (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ca_no TEXT UNIQUE NOT NULL,
    session_id UUID NOT NULL REFERENCES cashier_sessions(id),
    transaction_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    category TEXT NOT NULL,
    description TEXT,
    amount NUMERIC NOT NULL DEFAULT 0,
    payment_method payment_method NOT NULL DEFAULT 'Cash',
    created_by UUID NOT NULL REFERENCES profiles(id),
    status ca_status NOT NULL DEFAULT 'APPROVED',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Bank Deposits
CREATE TABLE bank_deposits (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    deposit_no TEXT UNIQUE NOT NULL,
    session_id UUID NOT NULL REFERENCES cashier_sessions(id),
    transaction_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    amount NUMERIC NOT NULL DEFAULT 0,
    bank_account_info TEXT NOT NULL,
    created_by UUID NOT NULL REFERENCES profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 4. Ledger & Accounting Schema (Event-Based)
CREATE TABLE financial_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_code TEXT UNIQUE NOT NULL,
    event_type event_type NOT NULL,
    source_table TEXT NOT NULL,
    source_id UUID NOT NULL,
    root_sales_id UUID REFERENCES sales_headers(id) ON DELETE SET NULL,
    event_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    event_version INT NOT NULL DEFAULT 1,
    idempotency_key TEXT UNIQUE NOT NULL,
    payment_method TEXT,
    amounts JSONB NOT NULL,
    status event_status NOT NULL DEFAULT 'READY',
    error_message TEXT,
    processed_at TIMESTAMPTZ,
    created_by UUID REFERENCES profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE journal_entries (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    journal_no TEXT UNIQUE NOT NULL,
    entry_group_id TEXT NOT NULL,
    transaction_date TIMESTAMPTZ NOT NULL,
    financial_event_id UUID REFERENCES financial_events(id) ON DELETE CASCADE,
    coa_code TEXT NOT NULL,
    coa_name TEXT NOT NULL,
    debit NUMERIC NOT NULL DEFAULT 0,
    kredit NUMERIC NOT NULL DEFAULT 0,
    note TEXT,
    is_reversal BOOLEAN NOT NULL DEFAULT FALSE,
    reversal_of_event_id UUID REFERENCES financial_events(id) ON DELETE SET NULL,
    reversal_of_group_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE pos_reconciliations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sales_id UUID UNIQUE NOT NULL REFERENCES sales_headers(id) ON DELETE CASCADE,
    reconciled_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status recon_status NOT NULL DEFAULT 'UNRECONCILED',
    pos_net_sales NUMERIC NOT NULL DEFAULT 0,
    journal_net_sales NUMERIC NOT NULL DEFAULT 0,
    pos_net_cash NUMERIC NOT NULL DEFAULT 0,
    journal_net_cash NUMERIC NOT NULL DEFAULT 0,
    pos_net_transfer NUMERIC NOT NULL DEFAULT 0,
    journal_net_transfer NUMERIC NOT NULL DEFAULT 0,
    pos_net_qris NUMERIC NOT NULL DEFAULT 0,
    journal_net_qris NUMERIC NOT NULL DEFAULT 0,
    pos_net_ar NUMERIC NOT NULL DEFAULT 0,
    journal_net_ar NUMERIC NOT NULL DEFAULT 0,
    pos_net_hpp NUMERIC NOT NULL DEFAULT 0,
    journal_net_hpp NUMERIC NOT NULL DEFAULT 0,
    differences JSONB NOT NULL DEFAULT '{}'::jsonb
);

-- -----------------------------------------------------
-- INDEXES
-- -----------------------------------------------------
CREATE INDEX idx_products_sku ON products(sku);
CREATE INDEX idx_product_stocks_product ON product_stocks(product_id);
CREATE INDEX idx_product_stocks_warehouse ON product_stocks(warehouse_id);
CREATE INDEX idx_sales_headers_invoice ON sales_headers(invoice_no);
CREATE INDEX idx_sales_headers_session ON sales_headers(session_id);
CREATE INDEX idx_sales_details_sales ON sales_details(sales_id);
CREATE INDEX idx_sales_payments_sales ON sales_payments(sales_id);
CREATE INDEX idx_sales_payments_session ON sales_payments(session_id);
CREATE INDEX idx_purchases_headers_no ON purchases_headers(purchase_no);
CREATE INDEX idx_purchases_details_purchase ON purchases_details(purchase_id);
CREATE INDEX idx_cash_advances_session ON cash_advances(session_id);
CREATE INDEX idx_bank_deposits_session ON bank_deposits(session_id);
CREATE INDEX idx_financial_events_status ON financial_events(status);
CREATE INDEX idx_financial_events_idempotency ON financial_events(idempotency_key);
CREATE INDEX idx_journal_entries_group ON journal_entries(entry_group_id);
CREATE INDEX idx_journal_entries_coa ON journal_entries(coa_code);
CREATE INDEX idx_journal_entries_event ON journal_entries(financial_event_id);
CREATE INDEX idx_pos_recon_sales ON pos_reconciliations(sales_id);

-- -----------------------------------------------------
-- ROW LEVEL SECURITY (RLS) SKELETON
-- -----------------------------------------------------
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE warehouses ENABLE ROW LEVEL SECURITY;
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_bundle_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_stocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE cashier_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales_headers ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchases_headers ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchases_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE cash_advances ENABLE ROW LEVEL SECURITY;
ALTER TABLE bank_deposits ENABLE ROW LEVEL SECURITY;
ALTER TABLE financial_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos_reconciliations ENABLE ROW LEVEL SECURITY;
