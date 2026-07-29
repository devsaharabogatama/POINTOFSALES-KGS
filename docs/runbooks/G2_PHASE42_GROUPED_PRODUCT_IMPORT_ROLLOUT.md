# G2 Phase 42 — Grouped Product Import Rollout

## Status

`COMPLETE`

Preflight live sudah dikonfirmasi user seluruhnya aman pada 2026-07-27.

Percobaan rollout pertama berhenti pada
`MIGRATION_PRECONDITION_FAILED: create job whitelist changed`. Transaction
rollback penuh, sehingga migration belum applied dan tidak memerlukan cleanup.
File terbaru mengganti text rewrite tersebut dengan definisi RPC lengkap yang
mempertahankan signature/behavior lama serta menambah `PRODUCT`.

Migration terbaru kemudian berhasil applied. Behavioral test menemukan audit
event `COMMIT` tidak termasuk vocabulary canonical. Gunakan forward fix
`G2_PHASE42_PRODUCT_IMPORT_COMPLETE_EVENT_FIX.md`; jangan menjalankan ulang
migration utama ini.

User kemudian mengonfirmasi forward migration, 4-check postflight, behavioral
test Phase 42, serta regression Phase 40/38 seluruhnya PASS.

## Outcome

Phase ini menambahkan import Product canonical dengan kontrak:

- satu `product_key` = satu Product;
- satu baris CSV = satu UOM milik Product tersebut;
- seluruh baris dalam satu group divalidasi dan disimpan secara atomic;
- tepat satu UOM memiliki faktor `1` dan menjadi Base UOM;
- UOM dengan faktor aktif terbesar menjadi acuan berat;
- minimal satu UOM jual dan satu UOM beli wajib tersedia;
- Category, UOM, dan Tax Rule hanya direferensikan berdasarkan nama existing;
- commit memakai guarded `save_product_with_uoms(...)`;
- import tidak membuat stock, Opening Stock, movement, FIFO, atau master referensi.

Product Bundle tetap export-only sampai kontrak komponen Bundle G3 tersedia.

## File

1. Migration:
   `supabase/migrations/20260727130000_g2_phase42_grouped_product_import.sql`
2. Postflight:
   `supabase/diagnostics/g2_phase42_grouped_product_import_postflight.sql`
3. Behavioral test:
   `supabase/tests/g2_phase42_grouped_product_import_tests.sql`

## Urutan manual

### 1. Migration

Migration `20260727130000` sudah applied. Jangan jalankan ulang.

Expected: `Success. No rows returned`.

Lanjutkan melalui forward migration `20260727140000` pada runbook fix.

### 2. Postflight

Jalankan seluruh postflight.

Expected: **11 baris `PASS`**, seluruh `violation_rows = 0`.

Jika `nonterminal_import_jobs` gagal, selesaikan atau batalkan job tersebut
secara eksplisit. Jangan menghapus job/row audit secara manual.

### 3. Behavioral test

Jalankan seluruh behavioral test.

Expected notice:

```text
TEST PASSED: grouped Product import is atomic, partial-commit safe, history guarded, audited, and stock-neutral.
```

Test diakhiri `ROLLBACK`; fixture tidak menetap.

### 4. Compatibility regression

Jalankan ulang:

1. `supabase/tests/g2_phase40_remaining_simple_master_import_tests.sql`;
2. `supabase/tests/g2_phase38_codeless_master_import_tests.sql`.

Keduanya harus tetap PASS karena public RPC lama mendelegasikan tujuh tipe
simple master ke implementation Phase 40.

## Invariant yang diuji

- satu group valid dengan dua UOM membuat tepat satu Product;
- group invalid tidak meninggalkan Product/UOM parsial;
- error pada satu group tidak membatalkan group valid lain;
- Product audit tetap ditulis oleh guarded RPC;
- perubahan faktor setelah histori movement ditolak saat preview;
- optimistic master version dicek lagi saat commit;
- direct write Product/Product-UOM tetap tertutup;
- private validator/commit tidak executable oleh browser;
- legacy Product import tetap dikarantina;
- tidak ada stock mutation dari Product import.

## Rollback / forward fix

Migration bersifat forward-only. Setelah applied:

- jangan menghapus ledger atau mengembalikan function lama secara manual;
- bila ada error DDL/function, buat migration forward-fix baru;
- bila behavioral test gagal, simpan error PostgreSQL lengkap dan hentikan
  sebelum membuka UI Product import.

## Setelah database gate

Next safe step adalah Phase 43 Backoffice Product Import UI:

- tambahkan tipe `PRODUCT`;
- template fixed `product_v1`;
- preview dikelompokkan berdasarkan `product_key`;
- user melihat nama Category/UOM/Tax, bukan UUID/kode teknis;
- UI menjelaskan bahwa import Product tidak mengisi stock.

Opening Stock, Product Bundle, Product-Supplier, Pricelist group, dan Payment
Method group tidak dibuka dalam phase ini.
