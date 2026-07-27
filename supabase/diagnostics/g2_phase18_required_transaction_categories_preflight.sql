-- G2 phase 18 preflight: required default Transaction Category readiness.
-- SAFETY: SELECT-only; returns aggregate counts and no business row values.

WITH defaults(category_code,category_name,system_key) AS (
    VALUES
        ('DEFAULT-SALE-POSTED','Penjualan','SALE_POSTED'),
        ('DEFAULT-SALE-PAYMENT','Pembayaran Penjualan','SALE_PAYMENT'),
        ('DEFAULT-SALES-RETURN','Retur Penjualan','SALES_RETURN'),
        ('DEFAULT-CUSTOMER-CREDIT-NOTE','Credit Note Customer','CUSTOMER_CREDIT_NOTE'),
        ('DEFAULT-CUSTOMER-DEBIT-NOTE','Debit Note Customer','CUSTOMER_DEBIT_NOTE'),
        ('DEFAULT-GOODS-RECEIPT','Penerimaan Barang','GOODS_RECEIPT'),
        ('DEFAULT-SUPPLIER-INVOICE','Invoice Supplier','SUPPLIER_INVOICE'),
        ('DEFAULT-SUPPLIER-PAYMENT','Pembayaran Supplier','SUPPLIER_PAYMENT'),
        ('DEFAULT-PURCHASE-RETURN','Retur Pembelian','PURCHASE_RETURN'),
        ('DEFAULT-SUPPLIER-CREDIT-NOTE','Credit Note Supplier','SUPPLIER_CREDIT_NOTE'),
        ('DEFAULT-SUPPLIER-DEBIT-NOTE','Debit Note Supplier','SUPPLIER_DEBIT_NOTE'),
        ('DEFAULT-STOCK-OPENING','Stok Awal','STOCK_OPENING'),
        ('DEFAULT-STOCK-GAIN','Stok Lebih','STOCK_GAIN'),
        ('DEFAULT-STOCK-LOSS','Stok Kurang atau Rusak','STOCK_LOSS'),
        ('DEFAULT-STOCK-TRANSFER','Transfer Stok','STOCK_TRANSFER'),
        ('DEFAULT-EXPENSE-DISBURSEMENT','Uang Muka Operasional','EXPENSE_DISBURSEMENT'),
        ('DEFAULT-EXPENSE-SETTLEMENT','Beban Operasional Umum','EXPENSE_SETTLEMENT'),
        ('DEFAULT-CASH-IN','Kas Masuk Lainnya','CASH_IN'),
        ('DEFAULT-CASH-DEPOSIT','Setoran Kas','CASH_DEPOSIT'),
        ('DEFAULT-CASH-VARIANCE','Selisih Kas','CASH_VARIANCE'),
        ('DEFAULT-CUSTOMER-BALANCE-RECEIPT','Top Up Saldo Customer','CUSTOMER_BALANCE_RECEIPT'),
        ('DEFAULT-CUSTOMER-BALANCE-USAGE','Pemakaian Saldo Customer','CUSTOMER_BALANCE_USAGE'),
        ('DEFAULT-KETUL-CUSTOMER-INTAKE','Penerimaan Ketul Customer','KETUL_CUSTOMER_INTAKE'),
        ('DEFAULT-KETUL-VENDOR-RESULT','Hasil Pengolahan Ketul','KETUL_VENDOR_RESULT'),
        ('DEFAULT-KETUL-VENDOR-PAYMENT','Pembayaran Vendor Ketul','KETUL_VENDOR_PAYMENT'),
        ('DEFAULT-MANUAL-JOURNAL','Jurnal Penyesuaian Manual','MANUAL_JOURNAL')
), active_companies AS (
    SELECT id FROM public.companies WHERE status = 'ACTIVE'
), checks AS (
    SELECT
        'g2_phase16_dependency'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260722150000'

    UNION ALL

    SELECT
        'required_category_schema_state','INFO',
        jsonb_build_object(
            'is_system_default_exists',EXISTS(
                SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = 'transaction_categories'
                  AND column_name = 'is_system_default'
            )
        )

    UNION ALL

    SELECT
        'default_catalog_system_event_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('missing_system_events',count(*))
    FROM defaults d
    LEFT JOIN public.system_events se ON se.system_key = d.system_key
    WHERE se.system_key IS NULL OR NOT se.is_active

    UNION ALL

    SELECT
        'default_category_code_collisions',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('collision_rows',count(*))
    FROM active_companies c
    CROSS JOIN defaults d
    JOIN public.transaction_categories tc
      ON tc.company_id = c.id
     AND upper(regexp_replace(btrim(tc.category_code),'\s+',' ','g')) =
         upper(regexp_replace(btrim(d.category_code),'\s+',' ','g'))

    UNION ALL

    SELECT
        'default_category_name_collisions',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('collision_rows',count(*))
    FROM active_companies c
    CROSS JOIN defaults d
    JOIN public.transaction_categories tc
      ON tc.company_id = c.id
     AND lower(regexp_replace(btrim(tc.category_name),'\s+',' ','g')) =
         lower(regexp_replace(btrim(d.category_name),'\s+',' ','g'))

    UNION ALL

    SELECT
        'existing_transaction_category_inventory','INFO',
        jsonb_build_object(
            'active_companies',(SELECT count(*) FROM active_companies),
            'categories',count(*),
            'active_categories',count(*) FILTER(WHERE is_active),
            'system_events_in_use',count(DISTINCT system_key)
        )
    FROM public.transaction_categories

    UNION ALL

    SELECT
        'required_category_provision_scope','BACKFILL',
        jsonb_build_object(
            'categories_per_company',(SELECT count(*) FROM defaults),
            'active_companies',(SELECT count(*) FROM active_companies),
            'rows_to_insert',
                (SELECT count(*) FROM defaults) *
                (SELECT count(*) FROM active_companies)
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2
                WHEN 'BACKFILL' THEN 3 ELSE 4 END,
    check_name;
