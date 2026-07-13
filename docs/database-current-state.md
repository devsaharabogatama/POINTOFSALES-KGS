# Database Current State Audit

Dokumen ini mendokumentasikan kondisi skema database KGS saat ini sebelum dilakukan migrasi multi-company.

---

## 1. Daftar Tabel Existing & Kolom Utama
Berdasarkan berkas [schema.sql](file:///C:/Users/sbi_l/OneDrive/Documents/POINT%20OF%2520SALES/supabase/schema.sql) dan [inventory_migration.sql](file:///C:/Users/sbi_l/OneDrive/Documents/POINT%20OF%2520SALES/supabase/inventory_migration.sql):

### 1.1 Tabel Inti & Master
* **`profiles`**: `id` (UUID, primary key), `email` (TEXT), `name` (TEXT), `role` (user_role enum).
* **`warehouses`**: `id` (UUID), `code` (TEXT), `name` (TEXT), `is_active` (BOOLEAN).
* **`products`**: `id` (UUID), `sku` (TEXT), `name` (TEXT), `category` (TEXT), `price` (NUMERIC), `cogs` (NUMERIC), `uom` (TEXT), `is_bundle` (BOOLEAN).
* **`product_bundle_items`**: `id` (UUID), `bundle_id` (UUID), `item_id` (UUID), `qty` (NUMERIC).
* **`product_stocks`**: `id` (UUID), `product_id` (UUID), `warehouse_id` (UUID), `stock_qty` (NUMERIC).
* **`customers`**: `id` (UUID), `code` (TEXT), `name` (TEXT), `current_balance` (NUMERIC), `credit_limit` (NUMERIC).
* **`uoms`**: `id` (UUID), `code` (TEXT), `name` (TEXT).
* **`product_uom_conversions`**: `id` (UUID), `product_id` (UUID), `from_uom_id` (UUID), `to_uom_id` (UUID), `conversion_factor` (NUMERIC).

### 1.2 Tabel Transaksi & Keuangan
* **`cashier_sessions`**: `id` (UUID), `session_code` (TEXT), `cashier_id` (UUID), `opening_balance` (NUMERIC), `status` (session_status).
* **`sales_headers`**: `id` (UUID), `invoice_no` (TEXT), `session_id` (UUID), `customer_id` (UUID), `grand_total` (NUMERIC), `paid_amount` (NUMERIC).
* **`sales_details`**: `id` (UUID), `sales_id` (UUID), `product_id` (UUID), `warehouse_id` (UUID), `qty` (NUMERIC), `price` (NUMERIC), `cogs_total` (NUMERIC).
* **`sales_payments`**: `id` (UUID), `payment_no` (TEXT), `sales_id` (UUID), `payment_method` (payment_method), `amount` (NUMERIC).
* **`purchases_headers`**: `id` (UUID), `purchase_no` (TEXT), `supplier_name` (TEXT), `warehouse_id` (UUID), `grand_total` (NUMERIC).
* **`purchases_details`**: `id` (UUID), `purchase_id` (UUID), `product_id` (UUID), `qty` (NUMERIC), `purchase_price` (NUMERIC).
* **`cash_advances`**: `id` (UUID), `ca_no` (TEXT), `session_id` (UUID), `amount` (NUMERIC).
* **`bank_deposits`**: `id` (UUID), `deposit_no` (TEXT), `session_id` (UUID), `amount` (NUMERIC).
* **`financial_events`**: `id` (UUID), `event_code` (TEXT), `event_type` (event_type), `status` (event_status), `amounts` (JSONB).
* **`journal_entries`**: `id` (UUID), `journal_no` (TEXT), `debit` (NUMERIC), `kredit` (NUMERIC).
* **`pos_reconciliations`**: `id` (UUID), `sales_id` (UUID), `status` (recon_status).

---

## 2. Hardcoded Default / Asumsi KGS Existing
* **Gudang Utama**: Berkode `GDS` dan Toko kasir berkode `KGS` (terdapat di triggers, API backend, dan inisiasi seed).
* **Kasir Awal**: Memiliki user default `CASHIER` di profiles yang diasumsikan login di PWA.
* **Mata Uang & Jam**: Jam menggunakan UTC (`Asia/Jakarta` secara lokal), mata uang diasumsikan Rupiah (`id-ID`).
