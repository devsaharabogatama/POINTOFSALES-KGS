# Multi-Company Gap Analysis

Analisis kesenjangan antara arsitektur database saat ini dengan target spesifikasi Multi-Company / Multi-Tenant.

---

## 1. Tabel Tambahan yang Diperlukan (BELUM ADA)
* **`companies`**: Dibutuhkan sebagai jangkar utama kepemilikan tenant.
* **`stores`**: Dibutuhkan untuk membagi lokasi penjualan di dalam satu perusahaan.
* **`pos_terminals`**: Dibutuhkan untuk melacak register/pos mesin kasir per toko.
* **`company_memberships`**: Menghubungkan user/profile ke company beserta level otoritasnya (`role_code`).
* **`store_memberships`**: Membatasi kasir/manager hanya pada toko tertentu.

---

## 2. Kolom Tambahan yang Diperlukan (PERLU TAMBAH KOLOM)
Hampir seluruh tabel transaksi dan master data saat ini belum memiliki kolom `company_id`.

* **Master Data**: `products`, `customers`, `warehouses`, `uoms` harus ditambahkan kolom `company_id` (UUID).
* **Transaksi POS**: `sales_headers`, `sales_payments`, `purchases_headers`, `cashier_sessions`, `cash_advances`, `bank_deposits` harus ditambahkan kolom `company_id` dan `store_id` (atau references).
* **Jurnal & Ledger**: `financial_events`, `journal_entries` (dan detail `journal_lines` bila dipisah) harus memuat `company_id`.

---

## 3. Strategi Backfill (PERLU BACKFILL & SEEDING)
* Seluruh data existing harus dimigrasikan ke company default awal: **`KGS`** (company_code).
* Kode default store awal akan di-seed sebagai **`KGS-STORE-1`** dan POS terminal default sebagai **`POS-1`**.
* Migrasi kolom `company_id` harus diatur `NULLABLE` terlebih dahulu, dilanjutkan proses *backfill*, barulah diberi batasan `NOT NULL` agar tidak memicu error data rusak.

---

## 4. Keamanan RLS & Penyesuaian RPC (PERLU RLS & REFACTOR RPC)
* RLS saat ini hanya mendeteksi role secara string (`user_role`). Harus disesuaikan dengan fungsi pembantu `private.user_has_company_access` dan `private.user_has_store_access`.
* RPC `create_sales_transaction` harus memverifikasi kesamaan `company_id` antara kasir, produk, customer, dan gudang dalam satu transaksi ACID.
