-- Reproducible baseline for a fresh Supabase project.
--
-- The original project created this schema from supabase/schema.sql before the
-- numbered migration ledger existed. Keep every statement idempotent so this
-- migration is a no-op when backfilled to the established Production project,
-- while a new staging project receives the exact legacy objects expected by
-- 001_multi_company_setup.sql and the later canonical migrations.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Hosted Supabase installs uuid-ossp in `extensions`, while the original
-- baseline used uuid_generate_v4() without a schema qualifier. Scope this to
-- this migration session and reset it at the end; the database-wide setting is
-- never changed.
SET search_path = public, extensions;

DO $baseline_types$
BEGIN
    IF to_regtype('public.user_role') IS NULL THEN
        CREATE TYPE public.user_role AS ENUM (
            'cashier', 'manager', 'owner', 'super_admin'
        );
    ELSIF NOT EXISTS (
        SELECT 1
        FROM pg_enum enum_value
        JOIN pg_type enum_type ON enum_type.oid=enum_value.enumtypid
        JOIN pg_namespace enum_schema ON enum_schema.oid=enum_type.typnamespace
        WHERE enum_schema.nspname='public'
          AND enum_type.typname='user_role'
          AND enum_value.enumlabel='super_admin'
    ) THEN
        ALTER TYPE public.user_role ADD VALUE 'super_admin';
    END IF;
    IF to_regtype('public.session_status') IS NULL THEN
        CREATE TYPE public.session_status AS ENUM ('OPEN', 'CLOSED');
    END IF;
    IF to_regtype('public.sj_status') IS NULL THEN
        CREATE TYPE public.sj_status AS ENUM ('NONE', 'PENDING', 'SHIPPED');
    END IF;
    IF to_regtype('public.so_confirm_status') IS NULL THEN
        CREATE TYPE public.so_confirm_status AS ENUM ('DRAFT', 'CONFIRMED');
    END IF;
    IF to_regtype('public.invoice_status') IS NULL THEN
        CREATE TYPE public.invoice_status AS ENUM (
            'DRAFT', 'READY', 'NOT_READY', 'GENERATED'
        );
    END IF;
    IF to_regtype('public.payment_status') IS NULL THEN
        CREATE TYPE public.payment_status AS ENUM (
            'DRAFT', 'UNPAID', 'PARTIAL', 'PAID'
        );
    END IF;
    IF to_regtype('public.financial_status') IS NULL THEN
        CREATE TYPE public.financial_status AS ENUM (
            'PENDING', 'POSTED', 'PARTIALLY_POSTED', 'ERROR'
        );
    END IF;
    IF to_regtype('public.recon_status') IS NULL THEN
        CREATE TYPE public.recon_status AS ENUM (
            'UNRECONCILED', 'MATCH', 'UNMATCH'
        );
    END IF;
    IF to_regtype('public.payment_method') IS NULL THEN
        CREATE TYPE public.payment_method AS ENUM (
            'Cash', 'Transfer', 'QRIS', 'Customer_Balance'
        );
    END IF;
    IF to_regtype('public.ca_status') IS NULL THEN
        CREATE TYPE public.ca_status AS ENUM ('APPROVED', 'REJECTED');
    END IF;
    IF to_regtype('public.event_type') IS NULL THEN
        CREATE TYPE public.event_type AS ENUM (
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
    END IF;
    IF to_regtype('public.event_status') IS NULL THEN
        CREATE TYPE public.event_status AS ENUM (
            'READY', 'PROCESSING', 'DONE', 'ERROR', 'CANCELED'
        );
    END IF;
    IF to_regtype('public.opname_status') IS NULL THEN
        CREATE TYPE public.opname_status AS ENUM (
            'DRAFT', 'SUBMITTED', 'APPROVED'
        );
    END IF;
    IF to_regtype('public.stock_movement_type') IS NULL THEN
        CREATE TYPE public.stock_movement_type AS ENUM (
            'SALE', 'PURCHASE', 'ADJUSTMENT', 'TRANSFER_IN', 'TRANSFER_OUT'
        );
    END IF;
END
$baseline_types$;

CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    role public.user_role NOT NULL DEFAULT 'cashier',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.warehouses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.products (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sku TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    category TEXT,
    vendor TEXT,
    merk TEXT,
    price NUMERIC NOT NULL DEFAULT 0,
    cogs NUMERIC NOT NULL DEFAULT 0,
    uom TEXT NOT NULL DEFAULT 'pcs',
    weight_per_uom_kg NUMERIC(14,3) NOT NULL DEFAULT 0
        CHECK (weight_per_uom_kg >= 0),
    is_bundle BOOLEAN NOT NULL DEFAULT FALSE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.product_bundle_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    bundle_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    item_id UUID NOT NULL REFERENCES public.products(id),
    qty NUMERIC NOT NULL DEFAULT 1,
    CONSTRAINT chk_qty_positive CHECK (qty > 0)
);

CREATE TABLE IF NOT EXISTS public.product_stocks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL
        REFERENCES public.products(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL
        REFERENCES public.warehouses(id) ON DELETE CASCADE,
    stock_qty NUMERIC NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_product_warehouse UNIQUE (product_id, warehouse_id)
);

CREATE TABLE IF NOT EXISTS public.customers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    phone TEXT,
    address TEXT,
    current_balance NUMERIC NOT NULL DEFAULT 0,
    credit_limit NUMERIC NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.cashier_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_code TEXT UNIQUE NOT NULL,
    cashier_id UUID NOT NULL REFERENCES public.profiles(id),
    opened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at TIMESTAMPTZ,
    opening_balance NUMERIC NOT NULL DEFAULT 0,
    expected_cash NUMERIC NOT NULL DEFAULT 0,
    actual_cash NUMERIC NOT NULL DEFAULT 0,
    difference NUMERIC NOT NULL DEFAULT 0,
    note_open TEXT,
    note_close TEXT,
    status public.session_status NOT NULL DEFAULT 'OPEN'
);

CREATE TABLE IF NOT EXISTS public.sales_headers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    invoice_no TEXT UNIQUE NOT NULL,
    session_id UUID NOT NULL REFERENCES public.cashier_sessions(id),
    customer_id UUID REFERENCES public.customers(id),
    transaction_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_tempo BOOLEAN NOT NULL DEFAULT FALSE,
    due_date TIMESTAMPTZ,
    sj_required BOOLEAN NOT NULL DEFAULT FALSE,
    sj_no TEXT,
    sj_status public.sj_status NOT NULL DEFAULT 'NONE',
    so_confirm_status public.so_confirm_status NOT NULL DEFAULT 'DRAFT',
    invoice_status public.invoice_status NOT NULL DEFAULT 'DRAFT',
    subtotal NUMERIC NOT NULL DEFAULT 0,
    item_discount NUMERIC NOT NULL DEFAULT 0,
    global_discount NUMERIC NOT NULL DEFAULT 0,
    grand_total NUMERIC NOT NULL DEFAULT 0,
    paid_amount NUMERIC NOT NULL DEFAULT 0,
    sisa_piutang NUMERIC NOT NULL DEFAULT 0,
    payment_status public.payment_status NOT NULL DEFAULT 'DRAFT',
    financial_status public.financial_status NOT NULL DEFAULT 'PENDING',
    recon_status public.recon_status NOT NULL DEFAULT 'UNRECONCILED',
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    is_revision BOOLEAN NOT NULL DEFAULT FALSE,
    original_invoice_no TEXT,
    payload_snapshot JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.sales_details (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sales_id UUID NOT NULL
        REFERENCES public.sales_headers(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id),
    warehouse_id UUID NOT NULL REFERENCES public.warehouses(id),
    qty NUMERIC NOT NULL DEFAULT 0,
    price NUMERIC NOT NULL DEFAULT 0,
    discount_amount NUMERIC NOT NULL DEFAULT 0,
    subtotal NUMERIC NOT NULL DEFAULT 0,
    cogs_unit NUMERIC NOT NULL DEFAULT 0,
    cogs_total NUMERIC NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS public.sales_payments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    payment_no TEXT UNIQUE NOT NULL,
    sales_id UUID NOT NULL
        REFERENCES public.sales_headers(id) ON DELETE CASCADE,
    payment_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    session_id UUID NOT NULL REFERENCES public.cashier_sessions(id),
    payment_method public.payment_method NOT NULL,
    amount NUMERIC NOT NULL DEFAULT 0,
    balance_before NUMERIC NOT NULL DEFAULT 0,
    balance_after NUMERIC NOT NULL DEFAULT 0,
    is_reversal BOOLEAN NOT NULL DEFAULT FALSE,
    reversal_ref_id UUID REFERENCES public.sales_payments(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Legacy inventory objects were historically installed from
-- supabase/inventory_migration.sql before migration 001.
CREATE TABLE IF NOT EXISTS public.uoms (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.product_uom_conversions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL
        REFERENCES public.products(id) ON DELETE CASCADE,
    from_uom_id UUID NOT NULL
        REFERENCES public.uoms(id) ON DELETE CASCADE,
    to_uom_id UUID NOT NULL
        REFERENCES public.uoms(id) ON DELETE CASCADE,
    conversion_factor NUMERIC NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_product_uom_conversion
        UNIQUE (product_id, from_uom_id, to_uom_id)
);

ALTER TABLE public.products
    ADD COLUMN IF NOT EXISTS uom_id UUID REFERENCES public.uoms(id);

CREATE TABLE IF NOT EXISTS public.product_batches (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL
        REFERENCES public.products(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL
        REFERENCES public.warehouses(id) ON DELETE CASCADE,
    purchase_detail_id UUID,
    qty_purchased NUMERIC NOT NULL,
    qty_remaining NUMERIC NOT NULL,
    cogs_unit NUMERIC NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.sales_fifo_allocations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sales_detail_id UUID NOT NULL
        REFERENCES public.sales_details(id) ON DELETE CASCADE,
    product_batch_id UUID NOT NULL
        REFERENCES public.product_batches(id) ON DELETE CASCADE,
    qty_allocated NUMERIC NOT NULL,
    cogs_unit NUMERIC NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.stock_opnames (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    opname_no TEXT UNIQUE NOT NULL,
    warehouse_id UUID NOT NULL
        REFERENCES public.warehouses(id) ON DELETE CASCADE,
    status public.opname_status NOT NULL DEFAULT 'DRAFT',
    notes TEXT,
    created_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.stock_opname_details (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    opname_id UUID NOT NULL
        REFERENCES public.stock_opnames(id) ON DELETE CASCADE,
    product_id UUID NOT NULL
        REFERENCES public.products(id) ON DELETE CASCADE,
    system_qty NUMERIC NOT NULL,
    physical_qty NUMERIC NOT NULL,
    difference NUMERIC NOT NULL,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS public.stock_adjustments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    adjustment_no TEXT UNIQUE NOT NULL,
    product_id UUID NOT NULL
        REFERENCES public.products(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL
        REFERENCES public.warehouses(id) ON DELETE CASCADE,
    opname_detail_id UUID
        REFERENCES public.stock_opname_details(id) ON DELETE SET NULL,
    qty_adjusted NUMERIC NOT NULL,
    cogs_unit NUMERIC NOT NULL,
    reason TEXT NOT NULL,
    created_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.stock_movements (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL
        REFERENCES public.products(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL
        REFERENCES public.warehouses(id) ON DELETE CASCADE,
    qty_change NUMERIC NOT NULL,
    movement_type public.stock_movement_type NOT NULL,
    reference_table TEXT NOT NULL,
    reference_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION public.transfer_product_stock(
    p_product_id UUID,
    p_src_warehouse_id UUID,
    p_dest_warehouse_id UUID,
    p_qty NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'LEGACY_TRANSFER_ROUTINE_RETIRED';
END;
$$;

CREATE TABLE IF NOT EXISTS public.purchases_headers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    purchase_no TEXT UNIQUE NOT NULL,
    supplier_name TEXT NOT NULL,
    transaction_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    warehouse_id UUID NOT NULL REFERENCES public.warehouses(id),
    subtotal NUMERIC NOT NULL DEFAULT 0,
    grand_total NUMERIC NOT NULL DEFAULT 0,
    paid_amount NUMERIC NOT NULL DEFAULT 0,
    payment_status public.payment_status NOT NULL DEFAULT 'UNPAID',
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.purchases_details (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    purchase_id UUID NOT NULL
        REFERENCES public.purchases_headers(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id),
    qty NUMERIC NOT NULL DEFAULT 0,
    purchase_price NUMERIC NOT NULL DEFAULT 0,
    subtotal NUMERIC NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS public.cash_advances (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ca_no TEXT UNIQUE NOT NULL,
    session_id UUID NOT NULL REFERENCES public.cashier_sessions(id),
    transaction_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    category TEXT NOT NULL,
    description TEXT,
    amount NUMERIC NOT NULL DEFAULT 0,
    payment_method public.payment_method NOT NULL DEFAULT 'Cash',
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    status public.ca_status NOT NULL DEFAULT 'APPROVED',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.bank_deposits (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    deposit_no TEXT UNIQUE NOT NULL,
    session_id UUID NOT NULL REFERENCES public.cashier_sessions(id),
    transaction_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    amount NUMERIC NOT NULL DEFAULT 0,
    bank_account_info TEXT NOT NULL,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.financial_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_code TEXT UNIQUE NOT NULL,
    event_type public.event_type NOT NULL,
    source_table TEXT NOT NULL,
    source_id UUID NOT NULL,
    root_sales_id UUID
        REFERENCES public.sales_headers(id) ON DELETE SET NULL,
    event_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    event_version INT NOT NULL DEFAULT 1,
    idempotency_key TEXT UNIQUE NOT NULL,
    payment_method TEXT,
    amounts JSONB NOT NULL,
    status public.event_status NOT NULL DEFAULT 'READY',
    error_message TEXT,
    processed_at TIMESTAMPTZ,
    created_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.journal_entries (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    journal_no TEXT UNIQUE NOT NULL,
    entry_group_id TEXT NOT NULL,
    transaction_date TIMESTAMPTZ NOT NULL,
    financial_event_id UUID
        REFERENCES public.financial_events(id) ON DELETE CASCADE,
    coa_code TEXT NOT NULL,
    coa_name TEXT NOT NULL,
    debit NUMERIC NOT NULL DEFAULT 0,
    kredit NUMERIC NOT NULL DEFAULT 0,
    note TEXT,
    is_reversal BOOLEAN NOT NULL DEFAULT FALSE,
    reversal_of_event_id UUID
        REFERENCES public.financial_events(id) ON DELETE SET NULL,
    reversal_of_group_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.pos_reconciliations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sales_id UUID UNIQUE NOT NULL
        REFERENCES public.sales_headers(id) ON DELETE CASCADE,
    reconciled_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status public.recon_status NOT NULL DEFAULT 'UNRECONCILED',
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
    differences JSONB NOT NULL DEFAULT '{}'::JSONB
);

CREATE INDEX IF NOT EXISTS idx_products_sku
    ON public.products(sku);
CREATE INDEX IF NOT EXISTS idx_product_stocks_product
    ON public.product_stocks(product_id);
CREATE INDEX IF NOT EXISTS idx_product_stocks_warehouse
    ON public.product_stocks(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_sales_headers_invoice
    ON public.sales_headers(invoice_no);
CREATE INDEX IF NOT EXISTS idx_sales_headers_session
    ON public.sales_headers(session_id);
CREATE INDEX IF NOT EXISTS idx_sales_details_sales
    ON public.sales_details(sales_id);
CREATE INDEX IF NOT EXISTS idx_sales_payments_sales
    ON public.sales_payments(sales_id);
CREATE INDEX IF NOT EXISTS idx_sales_payments_session
    ON public.sales_payments(session_id);
CREATE INDEX IF NOT EXISTS idx_purchases_headers_no
    ON public.purchases_headers(purchase_no);
CREATE INDEX IF NOT EXISTS idx_purchases_details_purchase
    ON public.purchases_details(purchase_id);
CREATE INDEX IF NOT EXISTS idx_cash_advances_session
    ON public.cash_advances(session_id);
CREATE INDEX IF NOT EXISTS idx_bank_deposits_session
    ON public.bank_deposits(session_id);
CREATE INDEX IF NOT EXISTS idx_financial_events_status
    ON public.financial_events(status);
CREATE INDEX IF NOT EXISTS idx_financial_events_idempotency
    ON public.financial_events(idempotency_key);
CREATE INDEX IF NOT EXISTS idx_journal_entries_group
    ON public.journal_entries(entry_group_id);
CREATE INDEX IF NOT EXISTS idx_journal_entries_coa
    ON public.journal_entries(coa_code);
CREATE INDEX IF NOT EXISTS idx_journal_entries_event
    ON public.journal_entries(financial_event_id);
CREATE INDEX IF NOT EXISTS idx_pos_recon_sales
    ON public.pos_reconciliations(sales_id);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.warehouses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_bundle_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_stocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cashier_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_headers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uoms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_uom_conversions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_fifo_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_opnames ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_opname_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchases_headers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchases_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_advances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_deposits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.financial_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.journal_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_reconciliations ENABLE ROW LEVEL SECURITY;

RESET search_path;
