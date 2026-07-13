# Multi-Company Entity Relationship Diagram (ERD)

Rancangan ERD Multi-Company KGS menggunakan representasi diagram Mermaid.

```mermaid
erDiagram
    companies ||--o{ stores : "has"
    companies ||--o{ company_memberships : "has members"
    companies ||--o{ warehouses : "owns"
    companies ||--o{ products : "owns"
    companies ||--o{ customers : "owns"
    companies ||--o{ sales_headers : "owns"
    companies ||--o{ financial_events : "tracks"
    companies ||--o{ journal_entries : "ledger"

    stores ||--o{ store_memberships : "has staff"
    stores ||--o{ pos_terminals : "has terminals"
    stores ||--o{ cashier_sessions : "hosts"
    stores ||--o{ sales_headers : "routes sales"

    profiles ||--o{ company_memberships : "belongs to"
    profiles ||--o{ store_memberships : "assigned to"

    products ||--o{ product_stocks : "has stock levels"
    warehouses ||--o{ product_stocks : "stores stock"

    cashier_sessions ||--o{ sales_headers : "groups sales"
    sales_headers ||--o{ sales_details : "contains"
    sales_headers ||--o{ sales_payments : "has payments"

    financial_events ||--o{ journal_entries : "generates journals"
```

---

## Penjelasan Relasi Utama:
1. **`companies`** adalah pusat tenant. Semua data bisnis (seperti produk, pelanggan, gudang) harus terikat ke satu ID perusahaan (`company_id`).
2. **`stores`** terikat ke perusahaan, memisahkan wilayah penjualan operasional.
3. **`company_memberships`** menghubungkan tabel global `profiles` (yang mereferensikan akun otentikasi Supabase `auth.users`) ke perusahaan tertentu dengan memegang `role_code` (Owner, Manager, Finance, dll).
4. **`store_memberships`** digunakan untuk membatasi kasir agar hanya dapat mengakses terminal POS di toko tempat mereka ditugaskan.
