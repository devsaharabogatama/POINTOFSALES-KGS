# KGS Multi-Company Data Architecture Specification

## 1. Tujuan Dokumen

Dokumen ini adalah instruksi kerja untuk agent yang akan menyiapkan struktur data KGS agar siap digunakan sebagai platform POS multi-company dan multi-store.

Target akhirnya:

- Satu Supabase project.
- Satu PostgreSQL database fisik.
- Banyak perusahaan di dalam database yang sama.
- Setiap perusahaan memiliki master data, transaksi, stok, pembelian, kasir, jurnal, dan laporan sendiri.
- Data antarperusahaan tidak boleh saling terlihat atau saling berubah.
- Satu perusahaan dapat memiliki banyak toko, gudang, POS, user, dan sesi kasir.
- Flow existing KGS tidak boleh dirombak tanpa dasar teknis yang jelas.
- Migrasi harus additive dan aman terhadap data yang sudah ada.

Dokumen ini bukan izin untuk membuat ulang seluruh sistem dari nol.

---

# 2. Peran Agent

Bertindak sebagai:

- Senior PostgreSQL Architect.
- Supabase Database Engineer.
- Multi-Tenant SaaS Architect.
- Accounting System Engineer.
- Migration Engineer.
- Security Reviewer.

Agent harus membaca seluruh struktur project existing sebelum menulis perubahan.

Prioritas utama:

1. Menjaga flow existing tetap berjalan.
2. Menambahkan kesiapan multi-company secara bertahap.
3. Menghindari perubahan besar yang tidak diperlukan.
4. Menjaga transaksi POS tetap cepat.
5. Menjaga jurnal tidak ganda.
6. Menjaga isolasi data antarcompany.
7. Menghasilkan migration yang dapat diaudit dan diulang.

---

# 3. Konteks Existing KGS yang Wajib Dipertahankan

Project saat ini memiliki atau direncanakan memiliki struktur utama:

```text
pwa/
backoffice/
supabase/
```

Berkas SQL existing atau target existing:

```text
supabase/
├── schema.sql
├── checkout_rpc.sql
├── worker_rpc.sql
├── transfer_rpc.sql
└── triggers.sql
```

Flow utama POS:

```text
POS Checkout
    ↓
Sales
Sales Detail
Payment
Stock Movement
Financial Event
Journal Queue
    ↓
Journal Worker
    ↓
Journal Entries
Reconciliation
```

Struktur queue existing secara konsep memiliki field:

```text
QUEUE_ID
SOURCE_SYSTEM
SOURCE_TYPE
SOURCE_ID
ACTION
STATUS
RETRY_COUNT
CREATED_AT
```

Contoh:

```text
SOURCE_TYPE = PURCHASE_RECEIVE
ACTION = UPSERT_JOURNAL
STATUS = PENDING | PROCESSING | DONE | FAILED
```

Flow checkout harus tetap transactional.

Artinya:

- Penjualan tidak boleh tercatat setengah.
- Detail penjualan tidak boleh masuk tanpa header.
- Payment tidak boleh masuk tanpa sales.
- Stock movement harus konsisten.
- Journal queue harus terbentuk dalam transaksi yang sama.
- Jurnal dapat diproses asynchronous setelah checkout berhasil.
- Kasir tidak perlu menunggu seluruh jurnal selesai.

Flow existing tidak boleh dipecah menjadi banyak request frontend bila satu RPC masih dapat menangani semuanya.

---

# 4. Aturan Non-Negotiable

Agent tidak boleh:

- Menghapus tabel existing tanpa audit.
- Mengganti nama tabel existing tanpa migration plan.
- Mengganti nama kolom existing secara langsung tanpa compatibility layer.
- Menghapus data existing.
- Membuat schema baru yang menduplikasi fungsi existing tanpa alasan.
- Membuat database terpisah per company di dalam satu Supabase project.
- Menaruh `service_role` di frontend.
- Mengizinkan frontend memilih `company_id` secara bebas.
- Mengandalkan filter frontend sebagai keamanan.
- Menonaktifkan RLS untuk mempermudah development.
- Membuat jurnal langsung dari frontend.
- Membuat journal worker yang tidak idempotent.
- Membuat trigger berat yang memperlambat checkout.
- Membuat perubahan ke production tanpa migration file.
- Menggunakan hard delete untuk transaksi finansial final.
- Membuat asumsi nama tabel atau flow tanpa membaca kode existing.

Jika informasi tidak tersedia, agent harus menuliskan:

```text
BELUM ADA BUKTI DI REPOSITORY
```

Lalu membuat rekomendasi terpisah, bukan menganggap rekomendasi sebagai fakta existing.

---

# 5. Prinsip Arsitektur Multi-Tenant

Model yang digunakan:

```text
Single Database
Single Schema Set
Shared Tables
Tenant Isolation by company_id
```

Hierarki utama:

```text
Platform
└── Company
    ├── Store
    │   ├── POS Terminal
    │   ├── Cashier Session
    │   └── Store Users
    ├── Warehouse
    ├── Master Data
    ├── Transactions
    ├── Accounting
    └── Reports
```

Kolom pemisah utama:

```text
company_id
store_id
warehouse_id
pos_id
session_id
```

Definisi:

- `company_id`: pemilik data secara bisnis dan finansial.
- `store_id`: lokasi operasional penjualan.
- `warehouse_id`: lokasi stok.
- `pos_id`: terminal atau register kasir.
- `session_id`: sesi buka-tutup kasir.

Semua data tenant wajib dapat ditelusuri ke `company_id`.

---

# 6. Keputusan Penting: Satu Project Bukan Banyak Database

Dalam satu Supabase project:

- Hanya ada satu PostgreSQL database fisik.
- Banyak company berada di database yang sama.
- Pemisahan dilakukan secara logis.
- Isolasi dilakukan dengan foreign key, RLS, role, membership, dan RPC validation.

Jangan membuat:

```text
database_kgs
database_company_b
database_company_c
```

di dalam satu Supabase project.

Yang dibuat adalah:

```text
companies
stores
warehouses
products
sales
journal_entries
```

dengan setiap row membawa `company_id`.

---

# 7. Strategi Schema

Gunakan struktur sederhana yang mudah dirawat solo developer.

Rekomendasi:

```text
public
├── tables yang dibaca aplikasi
├── views aman untuk aplikasi
└── RPC yang dipanggil frontend/backend

private
├── helper function internal
├── worker function
├── audit helper
└── function yang tidak boleh diekspos langsung
```

Jika repository existing hanya memakai schema `public`, jangan memindahkan semuanya sekaligus.

Lakukan bertahap:

1. Pertahankan tabel existing di `public`.
2. Tambahkan RLS.
3. Tambahkan helper function internal.
4. Pindahkan logic sensitif ke schema private bila memang diperlukan.
5. Hindari refactor besar hanya demi estetika schema.

---

# 8. Tipe Primary Key

Gunakan UUID untuk entitas utama baru.

Contoh:

```sql
id uuid primary key default gen_random_uuid()
```

Untuk tabel existing dengan key text atau bigint:

- Jangan langsung diganti.
- Tambahkan UUID bila dibutuhkan.
- Buat mapping/backfill.
- Pertahankan key existing sebagai `legacy_id` atau business identifier.

Pisahkan:

- Primary key teknis.
- Kode bisnis.
- Nomor dokumen.

Contoh:

```text
id              = UUID internal
company_code    = KGS
store_code      = PWT01
invoice_number  = INV/KGS/PWT01/2026/000001
```

---

# 9. Tabel Inti Multi-Company

## 9.1 companies

Wajib tersedia.

Kolom minimum:

```text
id
company_code
company_name
company_slug
legal_name
tax_id
timezone
currency_code
status
subscription_plan
created_at
created_by
updated_at
updated_by
```

Ketentuan:

- `company_code` unique.
- `company_slug` unique.
- Default timezone KGS: `Asia/Jakarta`.
- Status minimal: `ACTIVE`, `SUSPENDED`, `CLOSED`.

Contoh unique:

```sql
unique (company_code)
unique (company_slug)
```

---

## 9.2 stores

Kolom minimum:

```text
id
company_id
store_code
store_name
address
timezone
status
created_at
created_by
updated_at
updated_by
```

Unique wajib:

```sql
unique (company_id, store_code)
```

Satu company dapat memiliki banyak store.

---

## 9.3 warehouses

Kolom minimum:

```text
id
company_id
store_id nullable
warehouse_code
warehouse_name
warehouse_type
status
created_at
updated_at
```

Ketentuan:

- Warehouse dapat terkait store.
- Warehouse pusat boleh `store_id` null.
- Existing KGS/GDS harus dimapping, bukan dibuat ulang tanpa audit.

Unique:

```sql
unique (company_id, warehouse_code)
```

---

## 9.4 pos_terminals

Kolom minimum:

```text
id
company_id
store_id
pos_code
pos_name
device_identifier
status
created_at
updated_at
```

Unique:

```sql
unique (company_id, store_id, pos_code)
```

Existing default `POS-1` harus dimigrasikan sebagai terminal existing, bukan dihapus.

---

# 10. User, Membership, dan Role

Jangan menaruh satu `company_id` permanen langsung pada user bila user berpotensi mengakses lebih dari satu company.

Gunakan:

## 10.1 profiles

```text
user_id
full_name
email
phone
status
created_at
updated_at
```

`user_id` mereferensikan `auth.users.id`.

---

## 10.2 company_memberships

```text
id
company_id
user_id
role_code
status
is_default_company
created_at
created_by
```

Unique:

```sql
unique (company_id, user_id)
```

---

## 10.3 store_memberships

Gunakan bila akses user dibatasi per toko.

```text
id
company_id
store_id
user_id
role_code
status
```

Unique:

```sql
unique (company_id, store_id, user_id)
```

Role awal yang disarankan:

```text
PLATFORM_SUPERADMIN
COMPANY_OWNER
COMPANY_ADMIN
FINANCE
ACCOUNTING
WAREHOUSE_ADMIN
STORE_MANAGER
SUPERVISOR
CASHIER
VIEWER
```

Jangan menjadikan role hanya sebagai string di frontend.

Akses harus divalidasi di database.

---

# 11. Pembagian Data Global dan Tenant

## 11.1 Data global platform

Contoh:

```text
subscription_plans
platform_features
system_permissions
countries
currencies
global_status_codes
```

Data global tidak memakai `company_id`.

---

## 11.2 Data milik company

Wajib memakai `company_id`.

Contoh:

```text
customers
vendors
products
product_categories
bundles
price_lists
payment_methods
chart_of_accounts
expense_categories
tax_settings
employees
```

---

## 11.3 Data milik store

Wajib memakai:

```text
company_id
store_id
```

Contoh:

```text
cashier_sessions
sales
store_expenses
cash_advances
daily_closings
store_stock
```

---

## 11.4 Data milik warehouse

Wajib memakai:

```text
company_id
warehouse_id
```

Contoh:

```text
warehouse_stock
stock_movements
stock_adjustments
stock_transfers
purchase_receipts
```

---

# 12. Master Data Company

Agent harus mengaudit tabel master existing dan menambahkan tenant key secara minimal.

## 12.1 customers

Kolom minimum:

```text
id
company_id
customer_code
customer_name
customer_type
phone
email
address
credit_limit
status
created_at
updated_at
```

Unique:

```sql
unique (company_id, customer_code)
```

Existing default customer KGS seperti `K000` harus dimapping ke company KGS.

Jangan menjadikannya global untuk semua company.

Setiap company boleh memiliki `K000` sendiri.

---

## 12.2 vendors

```text
id
company_id
vendor_code
vendor_name
phone
email
address
payment_terms
status
created_at
updated_at
```

Unique:

```sql
unique (company_id, vendor_code)
```

---

## 12.3 products

```text
id
company_id
product_code
product_name
category_id
unit_id
cost_price
selling_price
is_stock_item
status
created_at
updated_at
```

Unique:

```sql
unique (company_id, product_code)
```

Harga tidak boleh dianggap satu nilai global jika existing memiliki harga per customer atau price list.

Agent harus memeriksa flow harga existing sebelum memutuskan struktur akhir.

---

## 12.4 bundles

```text
id
company_id
bundle_code
bundle_name
selling_price
status
```

## 12.5 bundle_items

```text
id
company_id
bundle_id
product_id
qty
```

---

## 12.6 chart_of_accounts

```text
id
company_id
account_code
account_name
account_type
parent_account_id
normal_balance
is_postable
status
```

Unique:

```sql
unique (company_id, account_code)
```

Chart of accounts tidak boleh global karena setiap company dapat memiliki struktur akun berbeda.

---

# 13. Struktur Transaksi Penjualan

Agent harus menyesuaikan dengan tabel existing.

Jangan membuat `sales_v2` bila tabel `sales` existing masih dapat diperluas dengan migration.

## 13.1 sales

Kolom minimum multi-company:

```text
id
company_id
store_id
warehouse_id
pos_id
session_id
customer_id
invoice_number
transaction_date
subtotal
discount_amount
tax_amount
grand_total
payment_status
sales_status
created_by
created_at
updated_at
voided_at
voided_by
void_reason
```

Unique:

```sql
unique (company_id, invoice_number)
```

Index minimum:

```sql
(company_id, transaction_date)
(company_id, store_id, transaction_date)
(company_id, session_id)
(company_id, customer_id)
```

---

## 13.2 sales_details

```text
id
company_id
sales_id
product_id
bundle_id nullable
qty
unit_price
discount_amount
subtotal
cost_amount
created_at
```

Foreign key harus memastikan data detail tidak berasal dari company berbeda.

Jika PostgreSQL FK komposit dibutuhkan untuk menjaga tenant consistency, agent harus mengevaluasi implementasinya.

Minimal, RPC checkout wajib memvalidasi bahwa:

```text
sales.company_id
product.company_id
customer.company_id
warehouse.company_id
store.company_id
```

semuanya sama.

---

## 13.3 payments

```text
id
company_id
sales_id
payment_method_id
amount
reference_number
proof_storage_path
payment_status
paid_at
created_by
created_at
```

Bukti transfer harus disimpan dengan path:

```text
{company_id}/{store_id}/{yyyy}/{mm}/{sales_id}/{filename}
```

Jangan gunakan bucket publik untuk bukti pembayaran sensitif.

---

# 14. Cashier Session

## cashier_sessions

```text
id
company_id
store_id
pos_id
cashier_user_id
opened_at
opening_cash
closed_at
closing_cash
expected_cash
cash_difference
status
created_at
updated_at
```

Status minimal:

```text
OPEN
CLOSING
CLOSED
CANCELLED
```

Semua transaksi POS harus terkait `session_id` bila memang dibuat pada sesi kasir.

Satu POS tidak boleh memiliki dua sesi aktif untuk konteks yang sama kecuali business rule existing menyatakan lain.

---

# 15. Stock Architecture

Gunakan ledger movement sebagai sumber audit utama.

## 15.1 stock_movements

```text
id
company_id
store_id nullable
warehouse_id
product_id
movement_type
direction
qty
unit_cost
source_system
source_type
source_id
reference_number
occurred_at
created_by
created_at
```

Contoh:

```text
movement_type = SALE
direction = OUT

movement_type = PURCHASE_RECEIVE
direction = IN

movement_type = TRANSFER_OUT
direction = OUT

movement_type = TRANSFER_IN
direction = IN

movement_type = ADJUSTMENT
direction = IN | OUT
```

Index minimum:

```sql
(company_id, warehouse_id, product_id, occurred_at)
(company_id, source_type, source_id)
```

---

## 15.2 stock_balances

Boleh digunakan sebagai cached balance.

```text
company_id
warehouse_id
product_id
qty_on_hand
updated_at
```

Unique:

```sql
unique (company_id, warehouse_id, product_id)
```

`stock_balances` bukan satu-satunya audit source.

Jika terjadi mismatch, `stock_movements` tetap menjadi sumber rekonstruksi.

---

## 15.3 stock_transfers

```text
id
company_id
from_warehouse_id
to_warehouse_id
transfer_number
status
requested_at
approved_at
shipped_at
received_at
created_by
```

## stock_transfer_items

```text
id
company_id
transfer_id
product_id
qty_requested
qty_shipped
qty_received
```

Existing `transfer_rpc.sql` harus diaudit dan diperluas, bukan diganti tanpa alasan.

---

# 16. Purchasing

## purchases

```text
id
company_id
store_id nullable
vendor_id
purchase_number
purchase_date
status
subtotal
discount_amount
tax_amount
grand_total
created_by
created_at
updated_at
```

## purchase_items

```text
id
company_id
purchase_id
product_id
qty
unit_cost
subtotal
```

## purchase_receipts

```text
id
company_id
purchase_id
warehouse_id
receipt_number
received_at
received_by
status
```

## purchase_receipt_items

```text
id
company_id
receipt_id
purchase_item_id
product_id
qty_received
unit_cost
```

Receive harus menghasilkan:

```text
stock movement IN
financial event
journal queue
```

---

# 17. Financial Event dan Journal Queue

Gunakan event-driven accounting.

## 17.1 financial_events

```text
id
company_id
store_id nullable
source_system
source_type
source_id
event_type
event_date
amount
currency_code
payload jsonb
status
created_at
created_by
```

Unique minimum:

```sql
unique (company_id, source_system, source_type, source_id, event_type)
```

Tujuan:

- Satu sumber bisnis menghasilkan event finansial yang dapat ditelusuri.
- Tidak boleh menghasilkan event sama dua kali.

---

## 17.2 journal_queue

Pertahankan konsep existing.

Kolom minimum:

```text
id
company_id
source_system
source_type
source_id
action
status
retry_count
max_retry
priority
locked_at
locked_by
last_error
created_at
processed_at
```

Unique minimum:

```sql
unique (company_id, source_system, source_type, source_id, action)
```

Status:

```text
PENDING
PROCESSING
DONE
FAILED
CANCELLED
```

Worker harus:

- Mengambil queue secara batch.
- Mengunci row.
- Aman terhadap concurrent worker.
- Idempotent.
- Menyimpan `last_error`.
- Tidak membuat jurnal ganda.
- Dapat retry.
- Tidak memblokir checkout.

Gunakan pola yang setara dengan:

```sql
for update skip locked
```

jika sesuai.

---

# 18. Journal Structure

## 18.1 journal_entries

```text
id
company_id
store_id nullable
journal_number
journal_date
source_system
source_type
source_id
description
status
posted_at
created_at
created_by
reversal_of_entry_id nullable
```

Status minimal:

```text
DRAFT
POSTED
REVERSED
VOID
```

Unique:

```sql
unique (company_id, journal_number)
unique (company_id, source_system, source_type, source_id)
```

Unique kedua harus dievaluasi bila satu source dapat menghasilkan lebih dari satu jenis jurnal.

Jika demikian, tambahkan `journal_type`.

---

## 18.2 journal_lines

```text
id
company_id
journal_entry_id
account_id
debit
credit
description
store_id nullable
warehouse_id nullable
created_at
```

Constraint wajib:

```text
debit >= 0
credit >= 0
tidak boleh debit dan credit terisi bersamaan
```

Validasi posting:

```text
total debit = total credit
```

Jurnal yang sudah `POSTED` tidak boleh diedit langsung.

Gunakan:

- reversal,
- adjustment,
- correcting entry.

---

# 19. Checkout RPC

Agent harus memeriksa `checkout_rpc.sql`.

Target akhirnya satu RPC transactional.

Contoh alur:

```text
validate authenticated user
validate company membership
validate store access
validate active cashier session
validate product belongs to company
validate customer belongs to company
validate warehouse belongs to company
validate stock/business rule
insert sales
insert sales details
insert payments
insert stock movements
insert financial event
insert journal queue
return checkout result
```

Frontend tidak boleh menentukan `company_id` final tanpa validasi.

Pilihan yang lebih aman:

- Frontend mengirim `store_id`, `pos_id`, `session_id`.
- RPC mengambil company dari membership/store.
- RPC memastikan user memiliki akses ke store.
- RPC mengisi `company_id` dari hasil validasi database.

RPC harus mengembalikan:

```text
success
sales_id
invoice_number
queue_id
created_at
```

Error harus eksplisit dan dapat dibaca aplikasi.

Contoh:

```text
COMPANY_ACCESS_DENIED
STORE_ACCESS_DENIED
SESSION_NOT_ACTIVE
PRODUCT_COMPANY_MISMATCH
CUSTOMER_COMPANY_MISMATCH
INSUFFICIENT_STOCK
DUPLICATE_CHECKOUT_REQUEST
```

Tambahkan idempotency key untuk mencegah double submit.

Contoh:

```text
client_request_id
```

Unique:

```sql
unique (company_id, client_request_id)
```

---

# 20. Idempotency

Wajib pada proses:

- Checkout.
- Purchase receive.
- Stock transfer.
- Journal worker.
- Payment callback.
- Retry offline PWA.

Setiap request penting harus memiliki:

```text
client_request_id
source_id
event_id
```

Jangan hanya mengandalkan timestamp.

Jika request yang sama dikirim ulang:

- Jangan membuat transaksi baru.
- Kembalikan hasil transaksi existing.

---

# 21. Row Level Security

RLS wajib aktif pada semua tabel yang dapat diakses melalui Supabase API.

Minimum policy concept:

```text
User hanya dapat SELECT row jika user memiliki active membership pada company tersebut.
```

Untuk store-scoped role:

```text
User hanya dapat melihat store yang ada pada store_memberships.
```

Contoh helper concept:

```sql
private.user_has_company_access(target_company_id uuid)
private.user_has_store_access(target_store_id uuid)
private.user_has_role(target_company_id uuid, allowed_roles text[])
```

Policy jangan menulis subquery kompleks berulang di semua tabel bila dapat dibuat helper yang aman dan terindeks.

Perhatian:

- Function `SECURITY DEFINER` harus memiliki `search_path` aman.
- Hak `EXECUTE` harus dibatasi.
- Jangan membuat helper yang dapat dipakai user untuk menaikkan hak akses.
- Service role bypass RLS, jadi hanya backend aman yang boleh memakainya.

---

# 22. RLS Minimum per Kategori

## Company master

SELECT:

```text
active company membership
```

INSERT/UPDATE:

```text
COMPANY_OWNER atau COMPANY_ADMIN
```

---

## Store data

SELECT:

```text
company membership
dan bila store-limited, harus punya store membership
```

INSERT/UPDATE:

```text
COMPANY_ADMIN atau STORE_MANAGER sesuai rule
```

---

## Sales

Kasir:

- Boleh membuat transaksi melalui RPC.
- Tidak diberi akses insert langsung ke semua tabel sales.
- Boleh melihat transaksi store dan session yang diizinkan.
- Tidak boleh mengubah transaksi final secara langsung.

Finance/owner:

- Dapat melihat seluruh transaksi company.
- Void/refund melalui RPC khusus.

---

## Accounting

Kasir:

- Tidak dapat mengubah journal entries.

Accounting:

- Dapat melihat dan melakukan proses yang diizinkan.

Worker:

- Menggunakan function internal atau service backend terkontrol.

---

# 23. Indexing Multi-Tenant

Index harus mempertimbangkan `company_id` sebagai prefix pada query tenant.

Contoh:

```sql
create index on sales (company_id, transaction_date desc);
create index on sales (company_id, store_id, transaction_date desc);
create index on sales_details (company_id, sales_id);
create index on stock_movements (company_id, warehouse_id, product_id, occurred_at desc);
create index on journal_queue (company_id, status, created_at);
create index on journal_entries (company_id, journal_date desc);
```

Jangan membuat index tanpa melihat query existing.

Agent harus menghasilkan:

```text
QUERY → INDEX JUSTIFICATION
```

untuk setiap index baru yang signifikan.

---

# 24. Audit Trail

Tabel penting wajib memiliki:

```text
created_at
created_by
updated_at
updated_by
```

Untuk transaksi final:

```text
voided_at
voided_by
void_reason
```

Untuk perubahan sensitif:

```text
revision_number
previous_record_id
reversal_reference
```

Agent harus mengevaluasi apakah perlu tabel:

```text
audit_logs
```

Minimum:

```text
id
company_id
actor_user_id
action
table_name
record_id
old_data jsonb
new_data jsonb
created_at
```

Audit log tidak boleh menjadi trigger berat untuk semua tabel tanpa evaluasi performa.

Prioritaskan:

- sales,
- payments,
- stock,
- purchase,
- journal,
- company membership,
- chart of accounts.

---

# 25. Soft Delete

Gunakan soft delete untuk master data:

```text
status
deleted_at
deleted_by
```

Jangan hard delete jika record sudah direferensikan transaksi.

Untuk transaksi finansial:

- Gunakan void.
- Gunakan reversal.
- Jangan hapus row final.

---

# 26. Penomoran Dokumen

Nomor dokumen harus scoped per company, dan bila perlu per store.

Contoh:

```text
INV/KGS/PWT01/2026/000001
TRF/KGS/2026/000001
JRN/KGS/2026/000001
```

Jangan generate nomor hanya dengan:

```text
select max(number) + 1
```

Gunakan sequence/counter table transactional.

Contoh:

```text
document_sequences
- company_id
- store_id nullable
- document_type
- period_key
- last_number
```

Unique:

```sql
unique (company_id, store_id, document_type, period_key)
```

---

# 27. Storage

Bucket minimum:

```text
payment-proofs
product-images
company-assets
reports
```

Gunakan private bucket untuk:

```text
payment-proofs
reports finansial
dokumen sensitif
```

Path wajib membawa tenant context.

Contoh:

```text
payment-proofs/{company_id}/{store_id}/{yyyy}/{mm}/{sales_id}/proof.jpg
```

Storage policy harus memvalidasi membership company.

Jangan hanya menyembunyikan URL di frontend.

---

# 28. Cron dan Worker

Journal worker dapat memakai:

- Supabase Cron/pg_cron untuk memanggil SQL function.
- Edge Function bila membutuhkan integrasi eksternal.

Untuk proses internal database, prioritaskan SQL function agar:

- Tidak menambah network hop.
- Tidak memakan invocation Edge Function.
- Lebih mudah transactional.

Worker tiap 1–5 menit cukup untuk volume saat ini.

Jangan memproses satu queue per schedule jika dapat batch.

Contoh:

```text
ambil maksimal 50 queue PENDING
proses dengan lock
commit per event atau batch aman
```

---

# 29. Strategi Migrasi Existing KGS

Agent wajib melakukan audit dahulu.

## Fase 1 — Discovery

Hasilkan file:

```text
docs/database-current-state.md
```

Isi:

- Semua tabel existing.
- Semua kolom.
- Primary key.
- Foreign key.
- Index.
- Trigger.
- RPC.
- View.
- RLS.
- Storage bucket.
- Hubungan dengan frontend/backoffice.
- Tabel yang menyimpan company/store/gudang secara text.
- Hardcoded default seperti `KGS`, `GDS`, `POS-1`, `K000`.

---

## Fase 2 — Gap Analysis

Hasilkan:

```text
docs/multi-company-gap-analysis.md
```

Klasifikasi:

```text
SUDAH SIAP
PERLU TAMBAH KOLOM
PERLU BACKFILL
PERLU RLS
PERLU REFACTOR RPC
PERLU INDEX
PERLU DIPERTAHANKAN
RISIKO TINGGI
```

---

## Fase 3 — Migration Plan

Hasilkan migration berurutan.

Contoh:

```text
supabase/migrations/
001_create_tenant_core.sql
002_seed_kgs_company.sql
003_add_company_id_to_master.sql
004_backfill_master_company.sql
005_add_company_id_to_transactions.sql
006_backfill_transaction_company.sql
007_add_constraints.sql
008_add_indexes.sql
009_create_memberships.sql
010_create_rls_helpers.sql
011_enable_rls.sql
012_update_checkout_rpc.sql
013_update_worker_rpc.sql
014_update_transfer_rpc.sql
015_update_triggers.sql
016_add_validation_tests.sql
```

Nama aktual mengikuti timestamp convention project bila sudah ada.

---

## Fase 4 — Backfill

Existing data KGS harus dimapping ke satu company awal.

Contoh:

```text
company_code = KGS
company_name = KGS
timezone = Asia/Jakarta
```

Existing store, warehouse, POS, customer, product, transaction, stock, dan journal harus mendapat `company_id` KGS.

Jangan mengaktifkan `NOT NULL` sebelum backfill tervalidasi.

Urutan aman:

```text
add nullable column
create company KGS
backfill
validate missing rows
add foreign key
add index
set not null
add unique constraint
enable RLS
```

---

## Fase 5 — Compatibility

Jika frontend existing masih mengirim store code/gudang code berbentuk text:

- Buat compatibility mapping sementara.
- Jangan memaksa seluruh frontend berubah sekaligus.
- RPC dapat menerima kode lama lalu resolve ke UUID.
- Tandai compatibility layer sebagai sementara.

---

# 30. Testing Wajib

Agent harus menghasilkan SQL test atau automated test.

Minimum test:

## Tenant isolation

```text
User Company A tidak dapat melihat Company B.
User Company A tidak dapat insert product untuk Company B.
User Company A tidak dapat checkout di Store B.
User Company A tidak dapat membaca payment proof Company B.
```

## Membership

```text
Owner dapat melihat semua store dalam company.
Cashier hanya dapat mengakses store yang ditugaskan.
Finance dapat melihat jurnal company.
User suspended tidak dapat mengakses data.
```

## Checkout

```text
Checkout sukses membuat sales, details, payment, stock movement, event, queue.
Double submit dengan client_request_id sama tidak membuat sales baru.
Product beda company ditolak.
Customer beda company ditolak.
Warehouse beda company ditolak.
Session tidak aktif ditolak.
```

## Journal

```text
Queue DONE tidak diproses ulang.
Retry tidak menghasilkan jurnal ganda.
Debit = credit.
Source yang sama tidak menghasilkan duplicate journal.
Reversal tidak menghapus jurnal asli.
```

## Stock

```text
Transfer antarwarehouse beda company ditolak.
Stock movement selalu memiliki company_id.
Balance dapat direkonstruksi dari movement.
```

## RLS

Test harus dijalankan menggunakan JWT/user context berbeda, bukan hanya role postgres admin.

---

# 31. Performance Requirements

Volume saat ini kurang dari 50 transaksi per hari per POS/toko.

Namun schema harus siap bertumbuh.

Target awal:

- Checkout normal tidak menunggu proses laporan.
- Checkout tidak menjalankan query agregasi besar.
- Journal worker asynchronous.
- Index mendukung company/store/date.
- Dashboard memakai query terfilter.
- Hindari scan seluruh tenant.
- Gunakan pagination.
- Jangan mengirim seluruh master data tanpa batas.

Agent harus menyediakan query audit untuk:

```text
slow query
missing index
queue backlog
failed queue
database growth
stock mismatch
journal imbalance
```

---

# 32. Observability Minimum

Tambahkan mekanisme untuk memantau:

```text
journal_queue PENDING count
journal_queue FAILED count
oldest pending queue age
checkout error count
duplicate request count
stock negative count
unbalanced journal count
database size
storage usage
```

Boleh melalui:

- SQL view.
- Admin dashboard.
- Scheduled report.
- Supabase logs.

Jangan membuat sistem monitoring kompleks sebelum core stabil.

---

# 33. Environment

Minimum:

```text
Production
Staging
Local
```

Jika saat ini hanya ada production:

- Siapkan migration agar dapat dijalankan lokal.
- Jangan membuat staging project sebelum benar-benar diperlukan bila biaya menjadi pertimbangan.
- Namun jangan menguji migration berisiko langsung di production.

Environment variable minimum:

```text
NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_ANON_KEY
SUPABASE_SERVICE_ROLE_KEY
SUPABASE_DB_URL
APP_ENV
```

`SUPABASE_SERVICE_ROLE_KEY` tidak boleh memiliki prefix public dan tidak boleh masuk bundle frontend.

---

# 34. Output Wajib dari Agent

Agent harus menghasilkan:

## A. Audit

```text
docs/database-current-state.md
docs/multi-company-gap-analysis.md
```

## B. ERD

```text
docs/multi-company-erd.md
```

Boleh memakai Mermaid.

## C. Migration

```text
supabase/migrations/*.sql
```

## D. RLS Matrix

```text
docs/rls-access-matrix.md
```

Isi:

```text
role
table
select
insert
update
delete
rpc
scope
```

## E. Migration Runbook

```text
docs/multi-company-migration-runbook.md
```

Harus berisi:

- Backup sebelum migrasi.
- Urutan deployment.
- Cara validasi.
- Cara rollback.
- Cara backfill.
- Cara memastikan tidak ada row tanpa company.
- Cara mengaktifkan RLS tanpa memutus aplikasi.

## F. Tests

```text
supabase/tests/
```

Minimal:

- tenant isolation,
- checkout idempotency,
- journal idempotency,
- stock company validation,
- RLS access.

## G. Final Summary

Agent harus menjelaskan:

```text
apa yang ditemukan
apa yang diubah
apa yang tidak diubah
risiko tersisa
langkah deployment
langkah rollback
```

---

# 35. Deliverable Tahap Pertama

Pada tahap pertama, jangan langsung melakukan refactor besar.

Tahap pertama hanya:

1. Audit project existing.
2. Buat ERD current state.
3. Buat gap analysis.
4. Buat target ERD.
5. Susun migration plan.
6. Identifikasi breaking change.
7. Tunjukkan tabel/kolom yang akan disentuh.
8. Tunggu approval sebelum migration destructive.

Agent boleh langsung membuat migration additive yang aman, tetapi harus menjelaskan dampaknya.

---

# 36. Acceptance Criteria

Pekerjaan dianggap selesai bila:

- Existing KGS berhasil dimapping menjadi company awal.
- Semua master tenant memiliki `company_id`.
- Semua transaksi tenant dapat ditelusuri ke `company_id`.
- Company dapat memiliki banyak store.
- Store dapat memiliki banyak POS.
- Company dapat memiliki banyak warehouse.
- User dapat memiliki membership di company.
- User dapat dibatasi ke store.
- RLS mencegah kebocoran antarcompany.
- Checkout tetap transactional.
- Checkout idempotent.
- Journal queue idempotent.
- Worker tidak membuat jurnal ganda.
- Stock transfer beda company ditolak.
- Nomor dokumen unique per company.
- Existing flow tidak rusak.
- Migration dapat dijalankan ulang secara aman atau gagal dengan jelas.
- Rollback plan tersedia.
- Semua perubahan terdokumentasi.

---

# 37. Rekomendasi Implementasi Awal untuk KGS

Untuk kondisi sekarang, gunakan:

```text
1 Supabase Production Project
1 PostgreSQL Database
1 Company awal: KGS
1 atau lebih Store
Warehouse existing: KGS/GDS sesuai data aktual
POS existing: POS-1
Customer default existing: K000
```

Struktur aplikasi:

```text
Vercel
├── POS PWA
├── Backoffice
└── Super Admin
```

Semua aplikasi menggunakan Supabase project yang sama.

Jangan membuat project Vercel per company kecuali:

- white-label penuh,
- codebase berbeda,
- domain/release cycle berbeda,
- kontrak enterprise membutuhkan isolasi aplikasi.

Jangan membuat Supabase project per company kecuali:

- wajib dedicated database,
- customer enterprise meminta isolasi fisik,
- tenant sangat besar,
- compliance mengharuskan pemisahan,
- performa tenant besar mengganggu tenant lain.

---

# 38. Instruksi Eksekusi untuk Agent

Gunakan urutan kerja berikut:

```text
STEP 1
Baca seluruh repository.

STEP 2
Petakan tabel, function, trigger, RPC, view, RLS, storage, dan hubungan frontend.

STEP 3
Buat current state documentation.

STEP 4
Bandingkan dengan target multi-company di dokumen ini.

STEP 5
Tentukan patch minimal.

STEP 6
Buat migration additive.

STEP 7
Buat backfill KGS.

STEP 8
Tambahkan constraint dan index.

STEP 9
Tambahkan RLS dan membership.

STEP 10
Update checkout_rpc, worker_rpc, transfer_rpc, dan triggers tanpa mengubah flow existing yang masih benar.

STEP 11
Buat test tenant isolation dan idempotency.

STEP 12
Buat runbook deployment dan rollback.

STEP 13
Laporkan semua asumsi yang tidak terbukti oleh repository.
```

---

# 39. Format Laporan Agent

Gunakan format:

```text
## Temuan Existing
- Fakta dari file:
- Lokasi file:
- Fungsi existing:

## Gap Multi-Company
- Masalah:
- Dampak:
- Bukti:

## Perubahan yang Diusulkan
- File:
- Tabel/function:
- Perubahan:
- Alasan:

## Risiko
- Risiko:
- Mitigasi:

## Breaking Change
- Ada/Tidak:
- Detail:

## Test
- Test case:
- Expected result:

## Deployment
- Urutan:
- Validasi:
- Rollback:
```

Agent tidak boleh menulis:

```text
seharusnya ada
kemungkinan ada
mungkin flow-nya
```

tanpa membedakan antara fakta dan rekomendasi.

---

# 40. Final Direction

Tujuan utama bukan sekadar menambahkan `company_id`.

Tujuan utamanya adalah memastikan:

```text
identity
authorization
tenant isolation
transaction integrity
journal integrity
stock integrity
auditability
migration safety
```

seluruhnya siap digunakan oleh banyak perusahaan dalam satu database.

Gunakan pendekatan:

```text
minimal patch
additive migration
backward compatible
testable
auditable
portable PostgreSQL
```

Jangan over-engineering.

Jangan membuat microservices.

Jangan membuat database per company pada tahap awal.

Jangan mengorbankan flow checkout existing yang sudah berjalan.

Fokus pada fondasi data yang benar sebelum melanjutkan build fitur berikutnya.
