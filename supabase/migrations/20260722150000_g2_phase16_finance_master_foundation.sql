-- KGS POS G2 phase 16: Transaction Category and minimum COA foundation.
-- Dependency: 20260722120000_g2_phase14_payment_method_foundation.sql
--
-- EXPAND-ONLY:
-- - legacy journal COA text remains authoritative for existing compatibility;
-- - new Event/Journal canonical references are nullable;
-- - Finance worker, resolver, automatic posting, and period enforcement stay off.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260722120000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G2 phase 14 is incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260722150000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260722150000';
    END IF;
END
$migration_guard$;

DO $empty_history_guard$
DECLARE
    v_expenses BIGINT;
    v_events BIGINT;
    v_journals BIGINT;
BEGIN
    SELECT count(*) INTO v_expenses FROM public.cash_advances;
    SELECT count(*) INTO v_events FROM public.financial_events;
    SELECT count(*) INTO v_journals FROM public.journal_entries;
    IF v_expenses <> 0 OR v_events <> 0 OR v_journals <> 0 THEN
        RAISE EXCEPTION
            'G2_PHASE16_STATE_CHANGED: expenses %, events %, journals %; rerun preflight and design explicit backfill',
            v_expenses,v_events,v_journals;
    END IF;
END
$empty_history_guard$;

CREATE TABLE public.account_functions (
    function_key TEXT PRIMARY KEY,
    function_name TEXT NOT NULL,
    compatible_account_types TEXT[] NOT NULL,
    default_normal_balance TEXT,
    allow_reconciliation BOOLEAN NOT NULL DEFAULT FALSE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT account_functions_key_format CHECK (
        function_key ~ '^[A-Z][A-Z0-9_]*$'
    ),
    CONSTRAINT account_functions_name_not_blank CHECK (
        btrim(function_name) <> ''
    ),
    CONSTRAINT account_functions_types_not_empty CHECK (
        cardinality(compatible_account_types) > 0
        AND compatible_account_types <@ ARRAY[
            'ASSET','LIABILITY','EQUITY','REVENUE','COGS','EXPENSE',
            'OTHER_INCOME','OTHER_EXPENSE'
        ]::TEXT[]
    ),
    CONSTRAINT account_functions_normal_balance_check CHECK (
        default_normal_balance IS NULL
        OR default_normal_balance IN ('DEBIT','CREDIT')
    )
);

CREATE TABLE public.system_events (
    system_key TEXT PRIMARY KEY,
    event_group TEXT NOT NULL,
    event_name TEXT NOT NULL,
    required_account_functions TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    conditional_account_functions TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    optional_account_functions TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT system_events_key_format CHECK (
        system_key ~ '^[A-Z][A-Z0-9_]*$'
    ),
    CONSTRAINT system_events_group_format CHECK (
        event_group ~ '^[A-Z][A-Z0-9_]*$'
    ),
    CONSTRAINT system_events_name_not_blank CHECK (btrim(event_name) <> '')
);

CREATE TABLE public.chart_of_accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    account_code TEXT NOT NULL,
    account_name TEXT NOT NULL,
    account_type TEXT NOT NULL,
    normal_balance TEXT NOT NULL,
    parent_account_id UUID,
    system_function_key TEXT REFERENCES public.account_functions(function_key),
    is_system_account BOOLEAN NOT NULL DEFAULT FALSE,
    is_postable BOOLEAN NOT NULL DEFAULT TRUE,
    allow_manual_posting BOOLEAN NOT NULL DEFAULT FALSE,
    allow_reconciliation BOOLEAN NOT NULL DEFAULT FALSE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT chart_of_accounts_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT chart_of_accounts_code_not_blank
        CHECK (btrim(account_code) <> ''),
    CONSTRAINT chart_of_accounts_name_not_blank
        CHECK (btrim(account_name) <> ''),
    CONSTRAINT chart_of_accounts_type_check CHECK (
        account_type IN (
            'ASSET','LIABILITY','EQUITY','REVENUE','COGS','EXPENSE',
            'OTHER_INCOME','OTHER_EXPENSE'
        )
    ),
    CONSTRAINT chart_of_accounts_normal_balance_check
        CHECK (normal_balance IN ('DEBIT','CREDIT')),
    CONSTRAINT chart_of_accounts_version_positive CHECK(master_version > 0),
    CONSTRAINT chart_of_accounts_manual_leaf_check
        CHECK (NOT allow_manual_posting OR is_postable),
    CONSTRAINT fk_chart_of_accounts_company_parent
        FOREIGN KEY(company_id,parent_account_id)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX uq_chart_of_accounts_company_normalized_code
    ON public.chart_of_accounts(
        company_id,
        upper(regexp_replace(btrim(account_code),'\s+',' ','g'))
    );
CREATE UNIQUE INDEX uq_chart_of_accounts_company_normalized_name
    ON public.chart_of_accounts(
        company_id,
        lower(regexp_replace(btrim(account_name),'\s+',' ','g'))
    );
CREATE INDEX idx_chart_of_accounts_company_parent
    ON public.chart_of_accounts(company_id,parent_account_id);
CREATE INDEX idx_chart_of_accounts_company_function
    ON public.chart_of_accounts(company_id,system_function_key)
    WHERE system_function_key IS NOT NULL;

CREATE TABLE public.transaction_categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    category_code TEXT NOT NULL,
    category_name TEXT NOT NULL,
    system_key TEXT NOT NULL REFERENCES public.system_events(system_key),
    description TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT transaction_categories_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT transaction_categories_code_not_blank
        CHECK(btrim(category_code) <> ''),
    CONSTRAINT transaction_categories_name_not_blank
        CHECK(btrim(category_name) <> ''),
    CONSTRAINT transaction_categories_version_positive
        CHECK(master_version > 0)
);

CREATE UNIQUE INDEX uq_transaction_categories_company_normalized_code
    ON public.transaction_categories(
        company_id,
        upper(regexp_replace(btrim(category_code),'\s+',' ','g'))
    );
CREATE UNIQUE INDEX uq_transaction_categories_company_normalized_name
    ON public.transaction_categories(
        company_id,
        lower(regexp_replace(btrim(category_name),'\s+',' ','g'))
    );
CREATE INDEX idx_transaction_categories_company_system_active
    ON public.transaction_categories(company_id,system_key,is_active);

CREATE TABLE public.transaction_account_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    transaction_category_id UUID NOT NULL,
    system_key TEXT NOT NULL REFERENCES public.system_events(system_key),
    account_function_key TEXT NOT NULL
        REFERENCES public.account_functions(function_key),
    account_id UUID NOT NULL,
    effective_from TIMESTAMPTZ NOT NULL,
    effective_to TIMESTAMPTZ,
    rule_version BIGINT NOT NULL DEFAULT 1,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    approved_by UUID REFERENCES public.profiles(id),
    approved_at TIMESTAMPTZ,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT transaction_account_rules_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT transaction_account_rules_identity_unique UNIQUE(
        company_id,transaction_category_id,account_function_key,rule_version
    ),
    CONSTRAINT transaction_account_rules_period_check
        CHECK(effective_to IS NULL OR effective_to > effective_from),
    CONSTRAINT transaction_account_rules_version_positive
        CHECK(rule_version > 0),
    CONSTRAINT transaction_account_rules_status_check
        CHECK(status IN ('DRAFT','ACTIVE','INACTIVE')),
    CONSTRAINT transaction_account_rules_approval_check CHECK (
        status <> 'ACTIVE' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)
    ),
    CONSTRAINT fk_transaction_rules_company_category
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_transaction_rules_company_account
        FOREIGN KEY(company_id,account_id)
        REFERENCES public.chart_of_accounts(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_transaction_rules_resolver
    ON public.transaction_account_rules(
        company_id,transaction_category_id,account_function_key,
        status,effective_from
    );

CREATE TABLE public.company_account_function_fallbacks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    account_function_key TEXT NOT NULL
        REFERENCES public.account_functions(function_key),
    account_id UUID NOT NULL,
    effective_from TIMESTAMPTZ NOT NULL,
    effective_to TIMESTAMPTZ,
    fallback_version BIGINT NOT NULL DEFAULT 1,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    approved_by UUID REFERENCES public.profiles(id),
    approved_at TIMESTAMPTZ,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT company_account_fallbacks_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT company_account_fallbacks_identity_unique UNIQUE(
        company_id,account_function_key,fallback_version
    ),
    CONSTRAINT company_account_fallbacks_period_check
        CHECK(effective_to IS NULL OR effective_to > effective_from),
    CONSTRAINT company_account_fallbacks_version_positive
        CHECK(fallback_version > 0),
    CONSTRAINT company_account_fallbacks_status_check
        CHECK(status IN ('DRAFT','ACTIVE','INACTIVE')),
    CONSTRAINT company_account_fallbacks_approval_check CHECK (
        status <> 'ACTIVE' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)
    ),
    CONSTRAINT fk_company_account_fallbacks_company_account
        FOREIGN KEY(company_id,account_id)
        REFERENCES public.chart_of_accounts(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_company_account_fallbacks_resolver
    ON public.company_account_function_fallbacks(
        company_id,account_function_key,status,effective_from
    );

CREATE TABLE public.finance_posting_exceptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    financial_event_id UUID,
    source_table TEXT NOT NULL,
    source_id UUID NOT NULL,
    system_key TEXT REFERENCES public.system_events(system_key),
    transaction_category_id UUID,
    account_function_key TEXT
        REFERENCES public.account_functions(function_key),
    reason_code TEXT NOT NULL,
    resolver_level TEXT,
    status TEXT NOT NULL DEFAULT 'PENDING_MAPPING',
    retry_count INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    resolved_by UUID REFERENCES public.profiles(id),
    resolved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT finance_posting_exceptions_reason_check CHECK (
        reason_code IN (
            'MISSING_REQUIRED_FUNCTION','INACTIVE_ACCOUNT',
            'INCOMPATIBLE_ACCOUNT_TYPE','INVALID_COMPANY_SCOPE',
            'INVALID_DIMENSION','LOCKED_PERIOD','UNBALANCED_JOURNAL',
            'RULE_VERSION_CONFLICT'
        )
    ),
    CONSTRAINT finance_posting_exceptions_status_check CHECK (
        status IN ('PENDING_MAPPING','POSTING_ERROR','RESOLVED')
    ),
    CONSTRAINT finance_posting_exceptions_retry_nonnegative
        CHECK(retry_count >= 0),
    CONSTRAINT fk_finance_exception_company_event
        FOREIGN KEY(company_id,financial_event_id)
        REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_finance_exception_company_category
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_finance_posting_exceptions_queue
    ON public.finance_posting_exceptions(company_id,status,created_at);

CREATE TABLE public.finance_master_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    entity_type TEXT NOT NULL,
    entity_id UUID NOT NULL,
    action TEXT NOT NULL CHECK(action IN ('CREATE','UPDATE','APPROVE')),
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT finance_master_audit_entity_check CHECK (
        entity_type IN ('ACCOUNT','CATEGORY','RULE','FALLBACK')
    )
);

CREATE INDEX idx_finance_master_audit_entity_created
    ON public.finance_master_audit(company_id,entity_type,entity_id,created_at DESC);

ALTER TABLE public.financial_events
    ADD COLUMN system_event_key TEXT REFERENCES public.system_events(system_key),
    ADD COLUMN transaction_category_id UUID,
    ADD COLUMN transaction_rule_version BIGINT,
    ADD CONSTRAINT fk_financial_events_company_transaction_category
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id)
        ON DELETE RESTRICT;

ALTER TABLE public.journal_entries
    ADD COLUMN account_id UUID,
    ADD COLUMN account_code_snapshot TEXT,
    ADD COLUMN account_name_snapshot TEXT,
    ADD COLUMN system_event_key TEXT REFERENCES public.system_events(system_key),
    ADD COLUMN transaction_category_id UUID,
    ADD COLUMN transaction_rule_version BIGINT,
    ADD CONSTRAINT fk_journal_entries_company_account
        FOREIGN KEY(company_id,account_id)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_journal_entries_company_transaction_category
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT journal_entries_account_snapshot_check CHECK (
        (account_id IS NULL
         AND account_code_snapshot IS NULL
         AND account_name_snapshot IS NULL)
        OR
        (account_id IS NOT NULL
         AND btrim(COALESCE(account_code_snapshot,'')) <> ''
         AND btrim(COALESCE(account_name_snapshot,'')) <> '')
    );

CREATE INDEX idx_financial_events_category
    ON public.financial_events(company_id,transaction_category_id)
    WHERE transaction_category_id IS NOT NULL;
CREATE INDEX idx_journal_entries_account_id
    ON public.journal_entries(company_id,account_id)
    WHERE account_id IS NOT NULL;

INSERT INTO public.account_functions(
    function_key,function_name,compatible_account_types,
    default_normal_balance,allow_reconciliation
) VALUES
    ('CASH_DRAWER','Kas Laci',ARRAY['ASSET'],'DEBIT',TRUE),
    ('MAIN_CASH','Kas Besar',ARRAY['ASSET'],'DEBIT',TRUE),
    ('BANK','Bank',ARRAY['ASSET'],'DEBIT',TRUE),
    ('BANK_RECEIPT','Penerimaan Bank',ARRAY['ASSET'],'DEBIT',TRUE),
    ('PAYMENT_CLEARING','Payment Clearing',ARRAY['ASSET'],'DEBIT',TRUE),
    ('CASH_IN_TRANSIT','Kas dalam Perjalanan',ARRAY['ASSET'],'DEBIT',TRUE),
    ('CUSTOMER_RECEIVABLE','Piutang Customer',ARRAY['ASSET'],'DEBIT',TRUE),
    ('SUPPLIER_REFUND_RECEIVABLE','Piutang Refund Supplier',ARRAY['ASSET'],'DEBIT',TRUE),
    ('SUPPLIER_ADVANCE','Uang Muka Supplier',ARRAY['ASSET'],'DEBIT',TRUE),
    ('OFFLINE_PAYMENT_RECEIVABLE','Piutang Pembayaran Offline',ARRAY['ASSET'],'DEBIT',TRUE),
    ('UNDER_DEPOSIT_CONTROL','Kontrol Setoran Kurang',ARRAY['ASSET'],'DEBIT',TRUE),
    ('INVENTORY_ASSET','Persediaan',ARRAY['ASSET'],'DEBIT',FALSE),
    ('SUPPLIER_AP_PROVISIONAL','Utang Supplier Provisional',ARRAY['LIABILITY'],'CREDIT',TRUE),
    ('SUPPLIER_AP_FINAL','Utang Supplier Final',ARRAY['LIABILITY'],'CREDIT',TRUE),
    ('CUSTOMER_BALANCE_LIABILITY','Customer Balance',ARRAY['LIABILITY'],'CREDIT',TRUE),
    ('CUSTOMER_REFUND_LIABILITY','Utang Refund Customer',ARRAY['LIABILITY'],'CREDIT',TRUE),
    ('CASH_OVERAGE_LIABILITY','Selisih Kas Lebih',ARRAY['LIABILITY'],'CREDIT',TRUE),
    ('INPUT_TAX','Pajak Masukan',ARRAY['ASSET'],'DEBIT',FALSE),
    ('OUTPUT_TAX','Pajak Keluaran',ARRAY['LIABILITY'],'CREDIT',FALSE),
    ('OWNER_CAPITAL','Modal Pemilik',ARRAY['EQUITY'],'CREDIT',FALSE),
    ('RETAINED_EARNINGS','Laba Ditahan',ARRAY['EQUITY'],'CREDIT',FALSE),
    ('OPENING_BALANCE_CLEARING','Opening Balance Clearing',ARRAY['EQUITY'],'CREDIT',FALSE),
    ('SALES_REVENUE','Pendapatan Penjualan',ARRAY['REVENUE'],'CREDIT',FALSE),
    ('SALES_RETURN_DISCOUNT','Retur dan Potongan Penjualan',ARRAY['REVENUE'],'DEBIT',FALSE),
    ('COGS','Harga Pokok Penjualan',ARRAY['COGS'],'DEBIT',FALSE),
    ('PURCHASE_PRICE_VARIANCE','Selisih Harga Beli',ARRAY['COGS','EXPENSE'],'DEBIT',FALSE),
    ('EXPENSE','Beban',ARRAY['EXPENSE','OTHER_EXPENSE'],'DEBIT',FALSE),
    ('OUTSTANDING_EXPENSE','Outstanding Expense',ARRAY['ASSET'],'DEBIT',TRUE),
    ('ROUNDING_GAIN','Selisih Pembulatan Untung',ARRAY['OTHER_INCOME'],'CREDIT',FALSE),
    ('ROUNDING_LOSS','Selisih Pembulatan Rugi',ARRAY['EXPENSE','OTHER_EXPENSE'],'DEBIT',FALSE),
    ('CASH_SHORTAGE_CONTROL','Piutang Kekurangan Kasir',ARRAY['ASSET'],'DEBIT',TRUE),
    ('STOCK_GAIN_INCOME','Pendapatan Selisih Stok',ARRAY['OTHER_INCOME'],'CREDIT',FALSE),
    ('STOCK_LOSS_EXPENSE','Beban Selisih Stok',ARRAY['EXPENSE'],'DEBIT',FALSE),
    ('BAD_DEBT_EXPENSE','Beban Piutang Tak Tertagih',ARRAY['EXPENSE'],'DEBIT',FALSE),
    ('BAD_DEBT_RECOVERY','Recovery Piutang',ARRAY['OTHER_INCOME'],'CREDIT',FALSE),
    ('OTHER_INCOME','Pendapatan Lain',ARRAY['OTHER_INCOME'],'CREDIT',FALSE),
    ('PAYMENT_SURCHARGE_INCOME','Penggantian Biaya Pembayaran',ARRAY['OTHER_INCOME'],'CREDIT',FALSE);

INSERT INTO public.system_events(
    system_key,event_group,event_name,required_account_functions,
    conditional_account_functions
) VALUES
    ('SALE_POSTED','SALES','Penjualan Diposting',ARRAY['SALES_REVENUE','INVENTORY_ASSET','COGS'],ARRAY['CASH_DRAWER','BANK','PAYMENT_CLEARING','CUSTOMER_RECEIVABLE','CUSTOMER_BALANCE_LIABILITY','OUTPUT_TAX']),
    ('SALE_PAYMENT','SALES','Pembayaran Penjualan',ARRAY[]::TEXT[],ARRAY['CASH_DRAWER','BANK','PAYMENT_CLEARING','CUSTOMER_RECEIVABLE']),
    ('SALES_RETURN','SALES','Retur Penjualan',ARRAY['SALES_RETURN_DISCOUNT'],ARRAY['INVENTORY_ASSET','COGS','CUSTOMER_REFUND_LIABILITY']),
    ('CUSTOMER_CREDIT_NOTE','SALES','Credit Note Customer',ARRAY['CUSTOMER_RECEIVABLE'],ARRAY['SALES_RETURN_DISCOUNT','OUTPUT_TAX']),
    ('CUSTOMER_DEBIT_NOTE','SALES','Debit Note Customer',ARRAY['CUSTOMER_RECEIVABLE'],ARRAY['SALES_REVENUE','OUTPUT_TAX']),
    ('GOODS_RECEIPT','PURCHASE','Penerimaan Barang',ARRAY['INVENTORY_ASSET','SUPPLIER_AP_PROVISIONAL'],ARRAY[]::TEXT[]),
    ('SUPPLIER_INVOICE','PURCHASE','Invoice Supplier',ARRAY['SUPPLIER_AP_FINAL'],ARRAY['SUPPLIER_AP_PROVISIONAL','PURCHASE_PRICE_VARIANCE','INPUT_TAX']),
    ('SUPPLIER_PAYMENT','PURCHASE','Pembayaran Supplier',ARRAY['SUPPLIER_AP_FINAL'],ARRAY['BANK','MAIN_CASH']),
    ('PURCHASE_RETURN','PURCHASE','Retur Pembelian',ARRAY['INVENTORY_ASSET'],ARRAY['SUPPLIER_AP_FINAL','SUPPLIER_REFUND_RECEIVABLE']),
    ('SUPPLIER_CREDIT_NOTE','PURCHASE','Credit Note Supplier',ARRAY['SUPPLIER_AP_FINAL'],ARRAY['PURCHASE_PRICE_VARIANCE','INPUT_TAX']),
    ('SUPPLIER_DEBIT_NOTE','PURCHASE','Debit Note Supplier',ARRAY['SUPPLIER_AP_FINAL'],ARRAY['PURCHASE_PRICE_VARIANCE','INPUT_TAX']),
    ('STOCK_OPENING','INVENTORY','Stok Awal',ARRAY['INVENTORY_ASSET','OPENING_BALANCE_CLEARING'],ARRAY[]::TEXT[]),
    ('STOCK_GAIN','INVENTORY','Stok Lebih',ARRAY['INVENTORY_ASSET','STOCK_GAIN_INCOME'],ARRAY[]::TEXT[]),
    ('STOCK_LOSS','INVENTORY','Stok Kurang',ARRAY['STOCK_LOSS_EXPENSE','INVENTORY_ASSET'],ARRAY[]::TEXT[]),
    ('STOCK_TRANSFER','INVENTORY','Transfer Stok',ARRAY['INVENTORY_ASSET'],ARRAY[]::TEXT[]),
    ('EXPENSE_DISBURSEMENT','EXPENSE','Pencairan Expense',ARRAY['OUTSTANDING_EXPENSE'],ARRAY['CASH_DRAWER','MAIN_CASH','BANK']),
    ('EXPENSE_SETTLEMENT','EXPENSE','Settlement Expense',ARRAY['EXPENSE','OUTSTANDING_EXPENSE'],ARRAY['INPUT_TAX']),
    ('CASH_IN','CASH','Kas Masuk',ARRAY['CASH_DRAWER'],ARRAY['OTHER_INCOME']),
    ('CASH_DEPOSIT','CASH','Setor Kas',ARRAY['CASH_IN_TRANSIT','CASH_DRAWER'],ARRAY['BANK','UNDER_DEPOSIT_CONTROL','CASH_OVERAGE_LIABILITY']),
    ('CASH_VARIANCE','CASH','Selisih Kas',ARRAY['CASH_DRAWER'],ARRAY['CASH_SHORTAGE_CONTROL','CASH_OVERAGE_LIABILITY']),
    ('CUSTOMER_BALANCE_RECEIPT','CUSTOMER','Penerimaan Customer Balance',ARRAY['CUSTOMER_BALANCE_LIABILITY'],ARRAY['CASH_DRAWER','BANK','PAYMENT_CLEARING']),
    ('CUSTOMER_BALANCE_USAGE','CUSTOMER','Penggunaan Customer Balance',ARRAY['CUSTOMER_BALANCE_LIABILITY'],ARRAY['CUSTOMER_RECEIVABLE']),
    ('KETUL_CUSTOMER_INTAKE','KETUL','Penerimaan Ketul Customer',ARRAY['INVENTORY_ASSET'],ARRAY[]::TEXT[]),
    ('KETUL_VENDOR_RESULT','KETUL','Hasil Vendor Ketul',ARRAY['INVENTORY_ASSET','COGS'],ARRAY['SALES_REVENUE']),
    ('KETUL_VENDOR_PAYMENT','KETUL','Pembayaran Vendor Ketul',ARRAY['BANK'],ARRAY[]::TEXT[]),
    ('MANUAL_JOURNAL','FINANCE','Jurnal Manual',ARRAY[]::TEXT[],ARRAY[]::TEXT[]);

CREATE FUNCTION private.provision_g2_minimum_coa(p_company_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO public.chart_of_accounts(
        company_id,account_code,account_name,account_type,normal_balance,
        system_function_key,is_system_account,is_postable,
        allow_manual_posting,allow_reconciliation
    )
    SELECT p_company_id,v.code,v.name,v.account_type,v.normal_balance,
           v.function_key,TRUE,TRUE,FALSE,v.reconcile
    FROM (VALUES
        ('1110','Kas Laci','ASSET','DEBIT','CASH_DRAWER',TRUE),
        ('1120','Kas Besar/Brankas','ASSET','DEBIT','MAIN_CASH',TRUE),
        ('1130','Bank','ASSET','DEBIT','BANK',TRUE),
        ('1140','Payment Clearing','ASSET','DEBIT','PAYMENT_CLEARING',TRUE),
        ('1150','Kas dalam Perjalanan','ASSET','DEBIT','CASH_IN_TRANSIT',TRUE),
        ('1160','Pajak Masukan','ASSET','DEBIT','INPUT_TAX',FALSE),
        ('1210','Piutang Customer','ASSET','DEBIT','CUSTOMER_RECEIVABLE',TRUE),
        ('1230','Outstanding Expense Operasional','ASSET','DEBIT','OUTSTANDING_EXPENSE',TRUE),
        ('1240','Piutang Kekurangan Kasir','ASSET','DEBIT','CASH_SHORTAGE_CONTROL',TRUE),
        ('1250','Piutang Refund Supplier','ASSET','DEBIT','SUPPLIER_REFUND_RECEIVABLE',TRUE),
        ('1260','Uang Muka Supplier','ASSET','DEBIT','SUPPLIER_ADVANCE',TRUE),
        ('1270','Piutang Pembayaran Offline','ASSET','DEBIT','OFFLINE_PAYMENT_RECEIVABLE',TRUE),
        ('1280','Kontrol Setoran Kurang','ASSET','DEBIT','UNDER_DEPOSIT_CONTROL',TRUE),
        ('1310','Persediaan Barang','ASSET','DEBIT','INVENTORY_ASSET',FALSE),
        ('2110','Utang Supplier Provisional','LIABILITY','CREDIT','SUPPLIER_AP_PROVISIONAL',TRUE),
        ('2120','Utang Supplier Final','LIABILITY','CREDIT','SUPPLIER_AP_FINAL',TRUE),
        ('2130','Customer Balance','LIABILITY','CREDIT','CUSTOMER_BALANCE_LIABILITY',TRUE),
        ('2150','Pajak Keluaran','LIABILITY','CREDIT','OUTPUT_TAX',FALSE),
        ('2160','Utang Refund Customer','LIABILITY','CREDIT','CUSTOMER_REFUND_LIABILITY',TRUE),
        ('2170','Selisih Kas Lebih','LIABILITY','CREDIT','CASH_OVERAGE_LIABILITY',TRUE),
        ('3110','Modal Pemilik','EQUITY','CREDIT','OWNER_CAPITAL',FALSE),
        ('3210','Laba Ditahan','EQUITY','CREDIT','RETAINED_EARNINGS',FALSE),
        ('3310','Opening Balance Clearing','EQUITY','CREDIT','OPENING_BALANCE_CLEARING',FALSE),
        ('4110','Penjualan','REVENUE','CREDIT','SALES_REVENUE',FALSE),
        ('4120','Retur dan Potongan Penjualan','REVENUE','DEBIT','SALES_RETURN_DISCOUNT',FALSE),
        ('5110','HPP Penjualan','COGS','DEBIT','COGS',FALSE),
        ('5130','Selisih Harga Beli/HPP','COGS','DEBIT','PURCHASE_PRICE_VARIANCE',FALSE),
        ('6110','Beban Operasional Umum','EXPENSE','DEBIT','EXPENSE',FALSE),
        ('6130','Kerugian/Rusak/Selisih Stok','EXPENSE','DEBIT','STOCK_LOSS_EXPENSE',FALSE),
        ('6140','Beban Piutang Tak Tertagih','EXPENSE','DEBIT','BAD_DEBT_EXPENSE',FALSE),
        ('6150','Selisih Pembulatan Rugi','EXPENSE','DEBIT','ROUNDING_LOSS',FALSE),
        ('7110','Pendapatan Selisih Stok','OTHER_INCOME','CREDIT','STOCK_GAIN_INCOME',FALSE),
        ('7120','Selisih Pembulatan Untung','OTHER_INCOME','CREDIT','ROUNDING_GAIN',FALSE),
        ('7130','Recovery Piutang Write-off','OTHER_INCOME','CREDIT','BAD_DEBT_RECOVERY',FALSE),
        ('7140','Pendapatan Lain-lain','OTHER_INCOME','CREDIT','OTHER_INCOME',FALSE),
        ('7150','Penggantian Biaya Pembayaran','OTHER_INCOME','CREDIT','PAYMENT_SURCHARGE_INCOME',FALSE)
    ) AS v(code,name,account_type,normal_balance,function_key,reconcile)
    WHERE NOT EXISTS (
        SELECT 1 FROM public.chart_of_accounts coa
        WHERE coa.company_id = p_company_id
          AND upper(btrim(coa.account_code)) = v.code
    );
END;
$$;

REVOKE ALL ON FUNCTION private.provision_g2_minimum_coa(UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.provision_g2_minimum_coa(UUID)
TO service_role;

CREATE FUNCTION private.trg_g2_provision_minimum_coa()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM private.provision_g2_minimum_coa(NEW.id);
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_provision_minimum_coa()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_provision_minimum_coa()
TO service_role;

CREATE TRIGGER g2_provision_minimum_coa
AFTER INSERT ON public.companies
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_provision_minimum_coa();

SELECT private.provision_g2_minimum_coa(c.id)
FROM public.companies c
WHERE c.status = 'ACTIVE';

CREATE TRIGGER g2_touch_chart_of_accounts
BEFORE INSERT OR UPDATE ON public.chart_of_accounts
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();
CREATE TRIGGER g2_touch_transaction_categories
BEFORE INSERT OR UPDATE ON public.transaction_categories
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();

CREATE FUNCTION private.trg_g2_guard_finance_mapping()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_category_system_key TEXT;
    v_account_type TEXT;
    v_account_active BOOLEAN;
    v_account_postable BOOLEAN;
    v_compatible TEXT[];
BEGIN
    SELECT account_type,is_active,is_postable
    INTO v_account_type,v_account_active,v_account_postable
    FROM public.chart_of_accounts
    WHERE company_id = NEW.company_id AND id = NEW.account_id;
    SELECT compatible_account_types INTO v_compatible
    FROM public.account_functions
    WHERE function_key = NEW.account_function_key AND is_active;
    IF v_account_type IS NULL OR NOT v_account_active OR NOT v_account_postable THEN
        RAISE EXCEPTION 'ACTIVE_POSTABLE_ACCOUNT_REQUIRED';
    END IF;
    IF v_compatible IS NULL OR NOT (v_account_type = ANY(v_compatible)) THEN
        RAISE EXCEPTION 'INCOMPATIBLE_ACCOUNT_TYPE';
    END IF;
    IF TG_TABLE_NAME = 'transaction_account_rules' THEN
        SELECT system_key INTO v_category_system_key
        FROM public.transaction_categories
        WHERE company_id = NEW.company_id
          AND id = NEW.transaction_category_id;
        IF v_category_system_key IS DISTINCT FROM NEW.system_key THEN
            RAISE EXCEPTION 'CATEGORY_SYSTEM_EVENT_MISMATCH';
        END IF;
        IF NEW.status = 'ACTIVE' AND EXISTS (
            SELECT 1 FROM public.transaction_account_rules r
            WHERE r.company_id = NEW.company_id
              AND r.transaction_category_id = NEW.transaction_category_id
              AND r.account_function_key = NEW.account_function_key
              AND r.status = 'ACTIVE'
              AND r.id IS DISTINCT FROM NEW.id
              AND tstzrange(r.effective_from,r.effective_to,'[)')
                  && tstzrange(NEW.effective_from,NEW.effective_to,'[)')
        ) THEN RAISE EXCEPTION 'TRANSACTION_RULE_PERIOD_OVERLAP'; END IF;
    ELSE
        IF NEW.status = 'ACTIVE' AND EXISTS (
            SELECT 1 FROM public.company_account_function_fallbacks f
            WHERE f.company_id = NEW.company_id
              AND f.account_function_key = NEW.account_function_key
              AND f.status = 'ACTIVE'
              AND f.id IS DISTINCT FROM NEW.id
              AND tstzrange(f.effective_from,f.effective_to,'[)')
                  && tstzrange(NEW.effective_from,NEW.effective_to,'[)')
        ) THEN RAISE EXCEPTION 'COMPANY_FALLBACK_PERIOD_OVERLAP'; END IF;
    END IF;
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END;
$$;

CREATE TRIGGER g2_guard_transaction_account_rules
BEFORE INSERT OR UPDATE ON public.transaction_account_rules
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_guard_finance_mapping();
CREATE TRIGGER g2_guard_company_account_fallbacks
BEFORE INSERT OR UPDATE ON public.company_account_function_fallbacks
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_guard_finance_mapping();

CREATE FUNCTION private.trg_g2_guard_finance_master_history()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_TABLE_NAME = 'transaction_categories'
       AND NEW.system_key IS DISTINCT FROM OLD.system_key
       AND (
           EXISTS (
               SELECT 1 FROM public.transaction_account_rules r
               WHERE r.company_id = OLD.company_id
                 AND r.transaction_category_id = OLD.id
           ) OR EXISTS (
               SELECT 1 FROM public.financial_events e
               WHERE e.company_id = OLD.company_id
                 AND e.transaction_category_id = OLD.id
           )
       ) THEN RAISE EXCEPTION 'CATEGORY_SYSTEM_EVENT_LOCKED_BY_HISTORY'; END IF;
    IF TG_TABLE_NAME = 'chart_of_accounts'
       AND NEW.account_type IS DISTINCT FROM OLD.account_type
       AND EXISTS (
           SELECT 1 FROM public.journal_entries je
           WHERE je.company_id = OLD.company_id AND je.account_id = OLD.id
       ) THEN RAISE EXCEPTION 'ACCOUNT_TYPE_LOCKED_BY_HISTORY'; END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER g2_guard_transaction_category_history
BEFORE UPDATE ON public.transaction_categories
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_guard_finance_master_history();
CREATE TRIGGER g2_guard_chart_of_account_history
BEFORE UPDATE ON public.chart_of_accounts
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_guard_finance_master_history();

REVOKE ALL ON FUNCTION private.trg_g2_guard_finance_mapping(),
    private.trg_g2_guard_finance_master_history()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_guard_finance_mapping(),
    private.trg_g2_guard_finance_master_history()
TO service_role;

CREATE FUNCTION public.save_transaction_category(
    p_category_id UUID,
    p_master_version BIGINT,
    p_category_code TEXT,
    p_category_name TEXT,
    p_system_key TEXT,
    p_description TEXT,
    p_is_active BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_id UUID;
    v_version BIGINT;
    v_before JSONB;
    v_after JSONB;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
    ) THEN RAISE EXCEPTION 'FINANCE_MASTER_MANAGER_REQUIRED'; END IF;
    IF btrim(COALESCE(p_category_code,'')) = ''
       OR btrim(COALESCE(p_category_name,'')) = '' THEN
        RAISE EXCEPTION 'INVALID_TRANSACTION_CATEGORY_IDENTITY';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.system_events se
        WHERE se.system_key = upper(btrim(p_system_key)) AND se.is_active
    ) THEN RAISE EXCEPTION 'ACTIVE_SYSTEM_EVENT_NOT_FOUND'; END IF;
    IF p_category_id IS NULL THEN
        INSERT INTO public.transaction_categories(
            company_id,category_code,category_name,system_key,description,
            is_active,created_by,updated_by
        ) VALUES (
            v_company,upper(btrim(p_category_code)),btrim(p_category_name),
            upper(btrim(p_system_key)),NULLIF(btrim(p_description),''),
            COALESCE(p_is_active,TRUE),v_actor,v_actor
        ) RETURNING id,master_version INTO v_id,v_version;
    ELSE
        SELECT to_jsonb(tc),tc.master_version INTO v_before,v_version
        FROM public.transaction_categories tc
        WHERE tc.company_id = v_company AND tc.id = p_category_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'TRANSACTION_CATEGORY_NOT_FOUND'; END IF;
        IF p_master_version IS NULL OR p_master_version <> v_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        UPDATE public.transaction_categories SET
            category_code = upper(btrim(p_category_code)),
            category_name = btrim(p_category_name),
            system_key = upper(btrim(p_system_key)),
            description = NULLIF(btrim(p_description),''),
            is_active = COALESCE(p_is_active,TRUE),updated_by = v_actor
        WHERE company_id = v_company AND id = p_category_id
        RETURNING id,master_version INTO v_id,v_version;
    END IF;
    SELECT to_jsonb(tc) INTO v_after FROM public.transaction_categories tc
    WHERE tc.company_id = v_company AND tc.id = v_id;
    INSERT INTO public.finance_master_audit(
        company_id,entity_type,entity_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,'CATEGORY',v_id,
        CASE WHEN p_category_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
        v_actor,v_before,v_after
    );
    RETURN jsonb_build_object('categoryId',v_id,'masterVersion',v_version);
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'DUPLICATE_TRANSACTION_CATEGORY';
END;
$$;

CREATE FUNCTION public.save_transaction_account_rule(
    p_rule_id UUID,
    p_transaction_category_id UUID,
    p_account_function_key TEXT,
    p_account_id UUID,
    p_effective_from TIMESTAMPTZ,
    p_effective_to TIMESTAMPTZ,
    p_status TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_system_key TEXT;
    v_id UUID;
    v_version BIGINT;
    v_old_status TEXT;
    v_before JSONB;
    v_after JSONB;
    v_previous RECORD;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
    ) THEN RAISE EXCEPTION 'FINANCE_MASTER_MANAGER_REQUIRED'; END IF;
    SELECT system_key INTO v_system_key FROM public.transaction_categories
    WHERE company_id = v_company AND id = p_transaction_category_id
      AND is_active;
    IF v_system_key IS NULL THEN
        RAISE EXCEPTION 'ACTIVE_TRANSACTION_CATEGORY_NOT_FOUND';
    END IF;
    IF p_effective_from IS NULL THEN RAISE EXCEPTION 'EFFECTIVE_FROM_REQUIRED'; END IF;
    IF p_effective_to IS NOT NULL AND p_effective_to <= p_effective_from THEN
        RAISE EXCEPTION 'INVALID_EFFECTIVE_PERIOD';
    END IF;
    IF p_rule_id IS NULL THEN
        IF upper(p_status) = 'ACTIVE' THEN
            FOR v_previous IN
                SELECT r.id,r.effective_from,to_jsonb(r) AS before_state
                FROM public.transaction_account_rules r
                WHERE r.company_id = v_company
                  AND r.transaction_category_id = p_transaction_category_id
                  AND r.account_function_key =
                      upper(btrim(p_account_function_key))
                  AND r.status = 'ACTIVE'
                  AND (
                      r.effective_to IS NULL
                      OR r.effective_to > p_effective_from
                  )
                FOR UPDATE
            LOOP
                IF v_previous.effective_from >= p_effective_from THEN
                    RAISE EXCEPTION 'RULE_VERSION_CONFLICT';
                END IF;
                UPDATE public.transaction_account_rules
                SET effective_to = p_effective_from,updated_by = v_actor
                WHERE company_id = v_company AND id = v_previous.id;
                SELECT to_jsonb(r) INTO v_after
                FROM public.transaction_account_rules r
                WHERE r.company_id = v_company AND r.id = v_previous.id;
                INSERT INTO public.finance_master_audit(
                    company_id,entity_type,entity_id,action,actor_id,
                    before_state,after_state
                ) VALUES (
                    v_company,'RULE',v_previous.id,'UPDATE',v_actor,
                    v_previous.before_state,v_after
                );
            END LOOP;
        END IF;
        SELECT COALESCE(max(rule_version),0) + 1 INTO v_version
        FROM public.transaction_account_rules
        WHERE company_id = v_company
          AND transaction_category_id = p_transaction_category_id
          AND account_function_key = upper(btrim(p_account_function_key));
        INSERT INTO public.transaction_account_rules(
            company_id,transaction_category_id,system_key,
            account_function_key,account_id,effective_from,effective_to,
            rule_version,status,approved_by,approved_at,created_by,updated_by
        ) VALUES (
            v_company,p_transaction_category_id,v_system_key,
            upper(btrim(p_account_function_key)),p_account_id,
            p_effective_from,p_effective_to,v_version,upper(p_status),
            CASE WHEN upper(p_status) = 'ACTIVE' THEN v_actor END,
            CASE WHEN upper(p_status) = 'ACTIVE' THEN clock_timestamp() END,
            v_actor,v_actor
        ) RETURNING id INTO v_id;
    ELSE
        SELECT to_jsonb(r),r.rule_version,r.status
        INTO v_before,v_version,v_old_status
        FROM public.transaction_account_rules r
        WHERE r.company_id = v_company AND r.id = p_rule_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'TRANSACTION_RULE_NOT_FOUND'; END IF;
        IF v_old_status <> 'DRAFT' THEN
            RAISE EXCEPTION 'ACTIVE_TRANSACTION_RULE_IMMUTABLE';
        END IF;
        UPDATE public.transaction_account_rules SET
            account_id = p_account_id,effective_from = p_effective_from,
            effective_to = p_effective_to,status = upper(p_status),
            approved_by = CASE WHEN upper(p_status) = 'ACTIVE' THEN v_actor END,
            approved_at = CASE WHEN upper(p_status) = 'ACTIVE'
                               THEN clock_timestamp() END,
            updated_by = v_actor
        WHERE company_id = v_company AND id = p_rule_id
        RETURNING id INTO v_id;
    END IF;
    SELECT to_jsonb(r) INTO v_after FROM public.transaction_account_rules r
    WHERE r.company_id = v_company AND r.id = v_id;
    INSERT INTO public.finance_master_audit(
        company_id,entity_type,entity_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,'RULE',v_id,
        CASE WHEN p_rule_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
        v_actor,v_before,v_after
    );
    RETURN jsonb_build_object('ruleId',v_id,'ruleVersion',v_version);
END;
$$;

ALTER TABLE public.account_functions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chart_of_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transaction_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transaction_account_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_account_function_fallbacks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_posting_exceptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_master_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users read Account Functions"
ON public.account_functions FOR SELECT TO authenticated USING(TRUE);
CREATE POLICY "Authenticated users read System Events"
ON public.system_events FOR SELECT TO authenticated USING(TRUE);
CREATE POLICY "Finance roles read COA"
ON public.chart_of_accounts FOR SELECT TO authenticated
USING(public.private_finance_company_visible(company_id));
CREATE POLICY "Company users read Transaction Categories"
ON public.transaction_categories FOR SELECT TO authenticated
USING(
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);
CREATE POLICY "Finance roles read Transaction Rules"
ON public.transaction_account_rules FOR SELECT TO authenticated
USING(public.private_finance_company_visible(company_id));
CREATE POLICY "Finance roles read Company Account Fallbacks"
ON public.company_account_function_fallbacks FOR SELECT TO authenticated
USING(public.private_finance_company_visible(company_id));
CREATE POLICY "Finance roles read Posting Exceptions"
ON public.finance_posting_exceptions FOR SELECT TO authenticated
USING(public.private_finance_company_visible(company_id));
CREATE POLICY "Finance roles read Finance Master Audit"
ON public.finance_master_audit FOR SELECT TO authenticated
USING(public.private_finance_company_visible(company_id));

REVOKE ALL ON public.account_functions,public.system_events,
    public.chart_of_accounts,public.transaction_categories,
    public.transaction_account_rules,
    public.company_account_function_fallbacks,
    public.finance_posting_exceptions,public.finance_master_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.account_functions,public.system_events,
    public.chart_of_accounts,public.transaction_categories,
    public.transaction_account_rules,
    public.company_account_function_fallbacks,
    public.finance_posting_exceptions,public.finance_master_audit
TO authenticated;
GRANT ALL ON public.account_functions,public.system_events,
    public.chart_of_accounts,public.transaction_categories,
    public.transaction_account_rules,
    public.company_account_function_fallbacks,
    public.finance_posting_exceptions,public.finance_master_audit
TO service_role;

REVOKE ALL ON FUNCTION public.save_transaction_category(
    UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,BOOLEAN
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_transaction_category(
    UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,BOOLEAN
) TO authenticated,service_role;
REVOKE ALL ON FUNCTION public.save_transaction_account_rule(
    UUID,UUID,TEXT,UUID,TIMESTAMPTZ,TIMESTAMPTZ,TEXT
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_transaction_account_rule(
    UUID,UUID,TEXT,UUID,TIMESTAMPTZ,TIMESTAMPTZ,TEXT
) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260722150000',
    'g2_phase16_finance_master_foundation',
    'Additive system-event/account-function registry, minimum tenant COA, Transaction Category/versioned mapping, exception queue, and nullable Event/Journal snapshots; Finance posting remains disabled'
);

COMMIT;
