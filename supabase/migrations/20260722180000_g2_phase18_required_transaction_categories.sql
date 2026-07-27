-- KGS POS G2 phase 18: required default Transaction Categories.
-- Additive provisioning only; Finance resolver and journal posting remain off.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260722150000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 16 Finance master is required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260722180000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260722180000';
    END IF;
END
$migration_guard$;

ALTER TABLE public.transaction_categories
    ADD COLUMN is_system_default BOOLEAN NOT NULL DEFAULT FALSE,
    ADD CONSTRAINT transaction_categories_required_default_active_check
        CHECK (NOT is_system_default OR is_active);

CREATE UNIQUE INDEX uq_transaction_categories_company_default_system
    ON public.transaction_categories(company_id,system_key)
    WHERE is_system_default;

CREATE FUNCTION private.provision_g2_required_transaction_categories(
    p_company_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.companies c WHERE c.id = p_company_id
    ) THEN
        RAISE EXCEPTION 'COMPANY_NOT_FOUND';
    END IF;

    INSERT INTO public.transaction_categories(
        company_id,category_code,category_name,system_key,description,
        is_active,is_system_default
    )
    SELECT p_company_id,v.category_code,v.category_name,v.system_key,
           v.description,TRUE,TRUE
    FROM (VALUES
        ('DEFAULT-SALE-POSTED','Penjualan','SALE_POSTED','Dipakai saat transaksi penjualan selesai dan siap dicatat.'),
        ('DEFAULT-SALE-PAYMENT','Pembayaran Penjualan','SALE_PAYMENT','Dipakai saat pembayaran atas penjualan diterima.'),
        ('DEFAULT-SALES-RETURN','Retur Penjualan','SALES_RETURN','Dipakai saat barang dari customer dikembalikan.'),
        ('DEFAULT-CUSTOMER-CREDIT-NOTE','Credit Note Customer','CUSTOMER_CREDIT_NOTE','Dipakai untuk mengurangi tagihan atau kewajiban customer tanpa retur biasa.'),
        ('DEFAULT-CUSTOMER-DEBIT-NOTE','Debit Note Customer','CUSTOMER_DEBIT_NOTE','Dipakai untuk menambah tagihan customer melalui dokumen koreksi.'),
        ('DEFAULT-GOODS-RECEIPT','Penerimaan Barang','GOODS_RECEIPT','Dipakai saat barang dari supplier benar-benar diterima.'),
        ('DEFAULT-SUPPLIER-INVOICE','Invoice Supplier','SUPPLIER_INVOICE','Dipakai saat invoice supplier diakui sebagai tagihan.'),
        ('DEFAULT-SUPPLIER-PAYMENT','Pembayaran Supplier','SUPPLIER_PAYMENT','Dipakai saat utang kepada supplier dibayar.'),
        ('DEFAULT-PURCHASE-RETURN','Retur Pembelian','PURCHASE_RETURN','Dipakai saat barang dikembalikan kepada supplier.'),
        ('DEFAULT-SUPPLIER-CREDIT-NOTE','Credit Note Supplier','SUPPLIER_CREDIT_NOTE','Dipakai saat supplier mengurangi nilai tagihan.'),
        ('DEFAULT-SUPPLIER-DEBIT-NOTE','Debit Note Supplier','SUPPLIER_DEBIT_NOTE','Dipakai saat koreksi menambah nilai klaim atau tagihan supplier.'),
        ('DEFAULT-STOCK-OPENING','Stok Awal','STOCK_OPENING','Dipakai untuk saldo persediaan pada awal penggunaan sistem.'),
        ('DEFAULT-STOCK-GAIN','Stok Lebih','STOCK_GAIN','Dipakai ketika stok fisik lebih besar daripada stok sistem.'),
        ('DEFAULT-STOCK-LOSS','Stok Kurang atau Rusak','STOCK_LOSS','Dipakai untuk kehilangan, kerusakan, atau stok fisik kurang.'),
        ('DEFAULT-STOCK-TRANSFER','Transfer Stok','STOCK_TRANSFER','Dipakai saat stok berpindah antar-gudang dalam Company.'),
        ('DEFAULT-EXPENSE-DISBURSEMENT','Uang Muka Operasional','EXPENSE_DISBURSEMENT','Dipakai saat uang operasional dicairkan sebelum bukti final diselesaikan.'),
        ('DEFAULT-EXPENSE-SETTLEMENT','Beban Operasional Umum','EXPENSE_SETTLEMENT','Dipakai saat bukti pengeluaran diselesaikan menjadi beban.'),
        ('DEFAULT-CASH-IN','Kas Masuk Lainnya','CASH_IN','Dipakai untuk penerimaan kas non-penjualan yang sah.'),
        ('DEFAULT-CASH-DEPOSIT','Setoran Kas','CASH_DEPOSIT','Dipakai saat kas toko disetor ke kas transit atau bank.'),
        ('DEFAULT-CASH-VARIANCE','Selisih Kas','CASH_VARIANCE','Dipakai saat hasil hitung kas berbeda dari nilai sistem.'),
        ('DEFAULT-CUSTOMER-BALANCE-RECEIPT','Top Up Saldo Customer','CUSTOMER_BALANCE_RECEIPT','Dipakai ketika customer menitipkan atau menambah saldo.'),
        ('DEFAULT-CUSTOMER-BALANCE-USAGE','Pemakaian Saldo Customer','CUSTOMER_BALANCE_USAGE','Dipakai ketika saldo customer digunakan untuk transaksi.'),
        ('DEFAULT-KETUL-CUSTOMER-INTAKE','Penerimaan Ketul Customer','KETUL_CUSTOMER_INTAKE','Dipakai saat ketul milik customer diterima untuk diproses.'),
        ('DEFAULT-KETUL-VENDOR-RESULT','Hasil Pengolahan Ketul','KETUL_VENDOR_RESULT','Dipakai saat hasil proses ketul dari vendor diterima.'),
        ('DEFAULT-KETUL-VENDOR-PAYMENT','Pembayaran Vendor Ketul','KETUL_VENDOR_PAYMENT','Dipakai saat biaya vendor pengolahan ketul dibayar.'),
        ('DEFAULT-MANUAL-JOURNAL','Jurnal Penyesuaian Manual','MANUAL_JOURNAL','Dipakai Finance untuk koreksi yang tidak berasal dari modul operasional.')
    ) AS v(category_code,category_name,system_key,description)
    WHERE NOT EXISTS (
        SELECT 1 FROM public.transaction_categories tc
        WHERE tc.company_id = p_company_id
          AND tc.is_system_default
          AND tc.system_key = v.system_key
    );
END;
$$;

REVOKE ALL ON FUNCTION
    private.provision_g2_required_transaction_categories(UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.provision_g2_required_transaction_categories(UUID)
TO service_role;

CREATE FUNCTION private.trg_g2_provision_required_transaction_categories()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM private.provision_g2_required_transaction_categories(NEW.id);
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION
    private.trg_g2_provision_required_transaction_categories()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.trg_g2_provision_required_transaction_categories()
TO service_role;

CREATE TRIGGER g2_provision_required_transaction_categories
AFTER INSERT ON public.companies
FOR EACH ROW
EXECUTE FUNCTION private.trg_g2_provision_required_transaction_categories();

CREATE FUNCTION private.trg_g2_guard_required_transaction_category()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_OP = 'DELETE' AND OLD.is_system_default THEN
        RAISE EXCEPTION 'REQUIRED_TRANSACTION_CATEGORY_CANNOT_BE_DELETED';
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.is_system_default THEN
        IF NOT NEW.is_system_default THEN
            RAISE EXCEPTION 'REQUIRED_TRANSACTION_CATEGORY_FLAG_LOCKED';
        END IF;
        IF NEW.system_key IS DISTINCT FROM OLD.system_key THEN
            RAISE EXCEPTION 'REQUIRED_TRANSACTION_CATEGORY_SYSTEM_EVENT_LOCKED';
        END IF;
        IF NOT NEW.is_active THEN
            RAISE EXCEPTION 'REQUIRED_TRANSACTION_CATEGORY_CANNOT_BE_DISABLED';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_guard_required_transaction_category()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_guard_required_transaction_category()
TO service_role;

CREATE TRIGGER g2_guard_required_transaction_category
BEFORE UPDATE OR DELETE ON public.transaction_categories
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_guard_required_transaction_category();

SELECT private.provision_g2_required_transaction_categories(c.id)
FROM public.companies c
WHERE c.status = 'ACTIVE';

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260722180000',
    'g2_phase18_required_transaction_categories',
    'Provision one protected, editable-label default category for each system event per Company; no account rule, resolver, worker, or journal activation'
);

COMMIT;
