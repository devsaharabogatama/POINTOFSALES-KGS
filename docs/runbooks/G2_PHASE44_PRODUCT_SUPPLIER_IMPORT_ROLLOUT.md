# G2 Phase 44 — Product-Supplier Import Rollout

## Status

`READY FOR MANUAL DATABASE ROLLOUT`

Live preflight dikonfirmasi user bersih pada 2026-07-27: seluruh blocker
`PASS`, tidak ada job nonterminal, ambiguity, orphan/cross-Company relation,
invalid UOM pembelian, preferred Supplier ganda, atau nilai existing invalid.
Satu Product-Supplier existing aman menjadi fixture compatibility.

## Outcome

Phase ini menambahkan import fixed `product_supplier_v1`:

```text
product_sku,supplier_name,purchase_uom_name,supplier_product_code,reference_purchase_price,is_preferred_supplier,is_active
```

Aturannya:

- satu baris mewakili satu relasi Product–Supplier;
- Product wajib aktif, bertipe stock, dan ditemukan dari SKU dalam Company;
- Supplier wajib aktif dan ditemukan dari nama dalam Company;
- UOM wajib aktif, dimiliki Product, dan diizinkan untuk pembelian;
- reference price boleh kosong, tetapi tidak boleh negatif;
- preferred Supplier wajib aktif dan maksimal satu per Product;
- pergantian preferred dalam satu file memakai baris lama `false` dan baris
  baru `true`; commit selalu memproses pelepasan preferred lebih dahulu;
- update memakai optimistic `master_version` dan warning/konfirmasi existing;
- commit hanya melalui `save_product_supplier(...)`;
- `last_purchase_price`, Purchase, stock, FIFO, movement, dan Opening Stock
  tidak pernah diubah oleh import ini.

## File

1. Migration:
   `supabase/migrations/20260727160000_g2_phase44_product_supplier_import.sql`
2. Postflight:
   `supabase/diagnostics/g2_phase44_product_supplier_import_postflight.sql`
3. Behavioral test:
   `supabase/tests/g2_phase44_product_supplier_import_tests.sql`

## Urutan manual

### 1. Migration

Jalankan seluruh migration `20260727160000`.

Expected:

```text
Success. No rows returned
```

Jika migration gagal, transaction harus rollback penuh. Simpan error lengkap
dan jangan mengedit migration Phase 42 yang sudah applied.

### 2. Postflight

Jalankan seluruh postflight.

Expected: **11 baris `PASS`**, seluruh `violation_rows = 0`.

Jika `nonterminal_import_jobs` gagal, selesaikan atau batalkan job secara
eksplisit. Jangan menghapus job/row/event audit secara manual.

### 3. Behavioral test

Jalankan seluruh behavioral test.

Expected notice:

```text
TEST PASSED: Product-Supplier import is tenant-safe, previewed, preferred-switch safe, partially committed, audited, idempotent, and stock-neutral.
```

Test berakhir dengan `ROLLBACK`; fixture tidak menetap.

### 4. Compatibility regression

Jalankan ulang:

1. `supabase/tests/g2_phase42_grouped_product_import_tests.sql`;
2. `supabase/tests/g2_phase40_remaining_simple_master_import_tests.sql`;
3. `supabase/tests/g2_phase38_codeless_master_import_tests.sql`.

Ketiganya harus tetap PASS. Public create/validate/commit RPC mempertahankan
signature lama dan mendelegasikan tipe existing ke dispatcher Phase 42.

## Invariant yang diuji

- Supplier dari Company lain tidak dapat direferensikan;
- satu row invalid tidak membatalkan create/update valid;
- old preferred dapat dilepas sebelum preferred baru dibuat;
- create dan update menulis audit dari guarded CRUD;
- terminal retry tidak menggandakan write;
- direct table write dan private routine tetap tertutup bagi browser;
- import tidak menambah stock movement.

## Rollback / forward fix

Migration bersifat forward-only setelah applied:

- jangan hapus ledger atau rename function kembali secara manual;
- bila migration belum commit, perbaiki file yang sama lalu jalankan ulang;
- bila migration sudah commit dan ditemukan defect, buat migration
  forward-fix dengan version baru;
- bila behavioral/regression test gagal, hentikan sebelum membuka UI.

## Setelah database gate

Next safe step adalah Phase 45 Backoffice Product-Supplier Import UI:

- tambah tipe **Relasi Produk–Supplier**;
- template fixed dan export-for-update;
- user melihat SKU Product, nama Supplier, dan nama UOM pembelian;
- preview menjelaskan preferred switch serta harga referensi;
- `internal_id` hanya tampil pada export/update, bukan create template.

Opening Stock dan Minimum Stock tetap workflow terpisah.
