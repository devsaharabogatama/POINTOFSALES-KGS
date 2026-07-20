# G0 Live Schema Baseline — 2026-07-20

**Environment:** Supabase database `postgres`, PostgreSQL 17.6  
**Captured at:** 2026-07-20 07:50:06 UTC  
**Evidence:** hasil manual `supabase/diagnostics/g0_schema_baseline.sql` dan `supabase/diagnostics/g0_schema_fingerprint.sql`  
**Status:** CLOSED / PASS WITH FORWARD-FIX ITEMS

---

## 1. Ringkasan Hasil

Diagnostic menghasilkan 114 check:

| Status | Jumlah |
|---|---:|
| PASS | 91 |
| WARN | 15 |
| MISSING | 3 |
| SKIP | 1 |
| INFO | 4 |
| FAIL | 0 |

Tidak adanya `FAIL` berarti data-quality minimum yang diperiksa tidak menemukan kerusakan. Ini belum membuktikan bahwa schema live identik dengan file lokal atau seluruh authorization benar.

---

## 2. Temuan Positif yang Terbukti Live

### Data quality

Seluruh check berikut bernilai nol dan PASS:

- negative `product_stocks`;
- tenant mismatch `product_stocks` terhadap Product/Warehouse;
- tenant mismatch `sales_details` terhadap header/Product/Warehouse;
- tenant mismatch `purchases_details` terhadap header/Product;
- unbalanced journal group;
- duplicate tenant key untuk Product SKU, Warehouse code, Customer code, dan UOM code.

### Tenant columns

- 20 tenant-bearing table yang sudah `NOT NULL` tidak memiliki `company_id` kosong.
- Delapan optional inventory table memiliki `company_id` nullable, tetapi saat diagnostic tidak memiliki row NULL.

### RLS

- Semua expected table yang ditemukan memiliki RLS aktif dan minimal satu policy.
- `customer_pricelists` tidak dinilai karena table tidak ditemukan.

### Function hardening yang sudah terlihat

- `create_sales_transaction(...)` ada, `SECURITY DEFINER`, fixed `search_path`, dan tidak executable oleh `PUBLIC`.
- `import_products_for_company(uuid, jsonb)` ada, `SECURITY DEFINER`, fixed `search_path`, dan tidak executable oleh `PUBLIC`.
- helper tenant/super-admin live memiliki fixed `search_path`.

---

## 3. Missing Object

| Object | Hasil | Implikasi |
|---|---|---|
| `supabase_migrations.schema_migrations` | MISSING | SQL kemungkinan diterapkan manual melalui SQL Editor; applied version tidak dapat dibuktikan dari registry. |
| `public.customer_pricelists` | MISSING | `customer_pricelist_migration.sql` tidak terbukti applied. Jangan menjalankan file legacy itu karena target Pricelist G2 sudah berubah. |
| `public.confirm_purchase_order(...)` | MISSING | `confirm_purchase_rpc.sql` tidak terbukti applied. Ini tidak memblokir target karena direct-confirm flow memang legacy dan akan diganti pada G5. |

Tidak ada alasan untuk “mengejar kelengkapan” dengan menjalankan dua file missing tersebut. Keduanya harus mengikuti target schema/gate baru, bukan dipasang sebagai legacy patch.

---

## 4. Security Warning

### Function executable oleh `PUBLIC`

Function berikut dapat dieksekusi oleh pseudo-role PostgreSQL `PUBLIC`, yang berarti scope lebih luas dari `authenticated`:

- `get_user_role_in_company(uuid)`;
- `handle_new_user()`;
- `private_is_super_admin(uuid)`;
- `private_user_has_company_access(uuid)`;
- `private_user_has_store_access(uuid)`;
- `process_financial_events_queue()`;
- `transfer_product_stock(uuid, uuid, uuid, numeric)`.

Catatan:

- helper RLS memang membutuhkan execute untuk role yang memakai policy, tetapi tidak harus diberikan ke `PUBLIC`/anon;
- trigger function `handle_new_user()` tidak memerlukan public API execute;
- worker dan transfer merupakan mutation surface dan harus memakai explicit revoke/grant;
- transfer juga memiliki blocker qty negatif/concurrency dari audit sebelumnya.

Tindakan masuk G1/G3:

1. inventory exact ACL/default privilege;
2. revoke `PUBLIC`/anon sesuai function contract;
3. grant hanya role yang perlu;
4. pastikan setiap SECURITY DEFINER fixed search path dan actor/tenant check;
5. test direct RPC sebagai anon, authenticated role berbeda, dan service role.

### Function tanpa fixed config

`process_financial_events_queue()` dan `transfer_product_stock(...)` adalah invoker function pada live state dan tidak memiliki function config. Ini tetap perlu explicit schema qualification/search path hardening pada replacement migration.

---

## 5. Nullable Tenant Columns

Table berikut mempunyai `company_id` nullable dan nol row NULL saat diagnostic:

- `product_batches`;
- `product_uom_conversions`;
- `sales_fifo_allocations`;
- `stock_adjustments`;
- `stock_movements`;
- `stock_opname_details`;
- `stock_opnames`;
- `uoms`.

G1 harus menggunakan urutan:

```text
preflight row count
-> backfill/ambiguous-row report
-> tenant-parent consistency check
-> SET NOT NULL
-> composite/constraint protection
-> postflight
```

Jangan langsung menjalankan `SET NOT NULL` hanya karena hasil sekarang menunjukkan nol row NULL. Concurrent writer dan cross-parent mismatch tetap harus ditutup.

---

## 6. Applied-State yang Dapat dan Tidak Dapat Disimpulkan

### Dapat disimpulkan

- core schema, inventory tables, dan multi-company tables ada;
- sebagian besar effect migration 001/002 terlihat pada object live;
- product import dan checkout RPC versi hardened pernah dipasang atau direkonstruksi setara;
- transfer, Finance worker, Cash Advance trigger, dan Bank Deposit trigger ada;
- policy bundle untuk expected tables telah dipasang;
- legacy Customer Pricelist dan confirm-purchase RPC tidak ada.

### Belum dapat disimpulkan

- file/urutan SQL mana yang persis pernah dijalankan;
- apakah live function/policy definition identik dengan file lokal;
- exact columns/defaults/check constraints/foreign keys/indexes;
- global versus tenant-scoped unique constraint yang masih aktif;
- exact table/function/default privileges;
- extension dan enum labels live;
- keberadaan cross-table tenant constraints.

Karena migration registry tidak ada, applied-state harus ditentukan melalui schema fingerprint, bukan berdasarkan nama migration.

---

## 7. Hasil Catalog Fingerprint

Fingerprint final berisi 1.100 object/property row:

| Object | Jumlah |
|---|---:|
| Column | 318 |
| Constraint | 141 |
| Index | 81 |
| Policy | 54 |
| Function target | 11 |
| Trigger | 2 |
| Table privilege | 419 |
| Routine privilege | 31 |
| Default privilege | 24 |
| Enum | 14 |
| Extension | 5 |

Temuan catalog yang menentukan desain G1:

1. Tidak ditemukan composite foreign key `(company_id, parent_id)`. Child memang memiliki `company_id`, tetapi foreign key legacy hanya memvalidasi UUID parent secara global. Cross-tenant consistency masih bergantung pada RPC/policy dan harus ditutup oleh forward migration.
2. Tenant-scoped unique index untuk Product SKU, Warehouse code, Customer code, dan UOM code sudah ada. Sejumlah nomor dokumen masih global unique; perubahan scope nomor dokumen ditunda sampai contract modulnya dibangun agar tidak memecahkan kompatibilitas.
3. Delapan `company_id` nullable dari baseline dikonfirmasi catalog dan siap masuk preflight + `SET NOT NULL`.
4. `create_sales_transaction` dan `import_products_for_company` sudah hardened: `SECURITY DEFINER`, fixed `search_path`, dan tidak executable oleh `PUBLIC`.
5. Helper RLS, trigger Auth, worker Finance, dan transfer legacy masih mempunyai ACL terlalu luas. Worker dan transfer juga belum memiliki function-level `search_path`.
6. `authenticated` memiliki privilege `TRUNCATE`, `REFERENCES`, dan `TRIGGER` pada table public. RLS tidak melindungi `TRUNCATE`, sehingga privilege tersebut harus dicabut.
7. Default privilege owner `postgres`/`supabase_admin` memberi akses luas pada object public baru. Canonical migration harus memakai default-deny untuk owner migration dan explicit grant per object.
8. Terdapat policy Profile duplikat dengan expression setara. Ini bukan kerusakan data, tetapi perlu dikonsolidasikan saat matrix RLS penuh ditulis.
9. Hanya dua trigger bisnis live: Cash Advance dan Bank Deposit menuju financial event. Legacy flow tersebut dipertahankan sampai replacement Finance gate.
10. Enum/flow live masih model legacy. Tidak ada bukti schema future module telah diterapkan secara prematur.

## 8. Rekonsiliasi terhadap Repository

- Effect utama `001_multi_company_setup.sql` dan `002_secure_tenant_product_weight_import.sql` terbukti live, tetapi tidak dapat diklaim byte-identical karena registry/checksum applied tidak tersedia.
- `customer_pricelists` dan `confirm_purchase_order(...)` tetap tidak ada; legacy file terkait tidak boleh direplay.
- Standalone `policies.sql`, `fix_permissions.sql`, `transfer_rpc.sql`, dan `worker_rpc.sql` tetap evidence historis, bukan deployment unit canonical.
- Forward migration pertama ditetapkan sebagai `20260720090000_g1_phase1_security_feature_foundation.sql`.
- Karena deployment dilakukan manual melalui SQL Editor, migration tersebut membuat ledger aplikasi `private.kgs_schema_migrations`. Registry internal Supabase tidak dimodifikasi manual.

## 9. Keputusan G0

**G0 ditutup.** Applied-state live sudah cukup terbukti melalui data-quality baseline dan catalog fingerprint. Tidak ditemukan orphan/mismatch/negative stock/unbalanced journal yang memblokir forward migration.

Forward-fix item berikut dialihkan ke G1 secara eksplisit:

1. tenant `NOT NULL` dan composite cross-table consistency;
2. feature entitlement hanya Super Admin;
3. function/table/default privilege hardening;
4. active Company context dan actor audit;
5. matrix RLS/API/RPC per role/action;
6. konsolidasi policy duplikat.

G1 dijalankan bertahap. Fase 1 menangani nullability, feature registry/audit, ledger migration, serta privilege dasar. Composite tenant constraints dan role matrix penuh baru dilanjutkan setelah postflight fase 1 lulus.
