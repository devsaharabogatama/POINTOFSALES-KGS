# G2 Phase 46 — Product-Warehouse Minimum Stock Rollout

## Status

`READY FOR MANUAL DATABASE ROLLOUT`

Live preflight pada 2026-07-28 bersih:

- seluruh invariant operasional `PASS`;
- satu Product stock aktif dan tiga Gudang aktif menghasilkan tiga eligible
  pair;
- belum ada balance atau movement;
- tidak ada reference ambigu, orphan, duplicate, negative stock, atau import
  job nonterminal;
- schema settings, guarded RPC, dan import type belum ada sesuai expected
  pre-migration state.

## Outcome

Migration menambahkan:

```text
product_warehouse_stock_settings
product_warehouse_stock_setting_audit
```

Satu row mewakili satu pasangan Product–Gudang. Threshold disimpan dalam base
UOM, nullable saat alert nonaktif, wajib nonnegatif, wajib terisi saat alert
aktif, versioned, audited, dan tidak bergantung pada keberadaan
`product_stocks`.

Semua write memakai guarded RPC:

```text
save_product_warehouse_stock_setting(...)
```

Fixed import type:

```text
PRODUCT_WAREHOUSE_MINIMUM_STOCK
```

Template database contract:

```text
product_sku,warehouse_name,minimum_stock_base_qty,low_stock_alert_enabled
```

Import mempunyai preview, update confirmation, partial commit, audit, terminal
retry idempotent, dan tidak membuat master referensi.

## File

1. Migration:
   `supabase/migrations/20260728090000_g2_phase46_product_warehouse_minimum_stock.sql`
2. Postflight:
   `supabase/diagnostics/g2_phase46_product_warehouse_minimum_stock_postflight.sql`
3. Behavioral test:
   `supabase/tests/g2_phase46_product_warehouse_minimum_stock_tests.sql`

## Urutan manual

### 1. Migration

Jalankan seluruh migration `20260728090000`.

Expected:

```text
Success. No rows returned
```

Migration berada dalam satu transaction. Jika gagal, simpan error lengkap dan
jangan mengedit/rerun migration Phase 44.

### 2. Postflight

Jalankan seluruh postflight.

Expected: **12 row `PASS`**, seluruh `violation_rows = 0`.

### 3. Behavioral test

Jalankan seluruh test.

Expected notice:

```text
TEST PASSED: Product-Warehouse minimum stock is tenant-safe, versioned, audited, importable, idempotent, and stock/request neutral.
```

Test berakhir dengan `ROLLBACK`.

### 4. Compatibility regression

Jalankan ulang:

1. `supabase/tests/g2_phase44_product_supplier_import_tests.sql`;
2. `supabase/tests/g2_phase42_grouped_product_import_tests.sql`;
3. `supabase/tests/g2_phase40_remaining_simple_master_import_tests.sql`;
4. `supabase/tests/g2_phase38_codeless_master_import_tests.sql`.

Semua harus tetap PASS karena public create/validate/commit signature tidak
berubah dan import lama didelegasikan ke dispatcher Phase 44.

### 5. Existing-menu smoke

Restart Backoffice lalu buka Produk, Gudang, Supplier, dan Import & Export.
Belum ada menu Minimum Stock pada phase database ini; menu tersebut baru
ditambahkan setelah semua database gate PASS.

## Invariant utama

- setting lintas Company ditolak;
- Product wajib aktif, non-bundle, dan mempunyai base UOM aktif faktor `1`;
- Gudang wajib aktif dalam Company yang sama;
- satu pasangan hanya mempunyai satu setting;
- stale update ditolak;
- alert tanpa threshold dan threshold negatif ditolak;
- direct browser insert/update/delete ditutup;
- private validator/commit tidak executable oleh authenticated;
- satu row import invalid tidak membatalkan row valid;
- retry commit terminal tidak menggandakan write;
- setting/import tidak membuat atau mengubah `product_stocks`;
- setting/import tidak membuat `stock_movements`, Stock Request, atau Supplier
  Order.

## Rollback / forward fix

- jika migration belum commit, transaction rollback penuh;
- setelah applied, migration menjadi immutable;
- defect setelah applied diperbaiki dengan migration version baru;
- jangan menghapus audit/import job untuk “membersihkan” kegagalan;
- bila behavioral/regression gagal, hentikan sebelum membuka Backoffice UI.

## Setelah database gate PASS

Next safe step adalah Phase 47 Backoffice:

- menu konfigurasi Minimum Stock per Product–Gudang;
- user memilih SKU/nama Product dan nama Gudang;
- threshold diberi label base UOM Produk;
- enable/disable alert jelas;
- template/export fixed tanpa kode Gudang/UUID pada create;
- preview dan error memakai nama user-facing;
- belum ada notice Cashier sampai POS/Stock Request gate terkait dibuka.

Opening Stock tetap menunggu G3.
