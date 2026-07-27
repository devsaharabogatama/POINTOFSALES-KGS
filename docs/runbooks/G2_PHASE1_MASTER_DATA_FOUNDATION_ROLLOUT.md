# Runbook G2 Fase 1 - Master Data Foundation

**Migration:** `supabase/migrations/20260721180000_g2_phase1_master_data_foundation.sql`
**Requirement:** MST-001, MST-002, MST-003, MST-004
**Gate:** G2 expand phase

## Outcome

- Menambah master `product_categories` dan `product_uoms` yang tenant-scoped.
- Menambah precision/lifecycle/version metadata pada UOM.
- Menambah tipe, Store scope, lokasi, dan version metadata pada Warehouse.
- Menambah Category, weight reference UOM, external image URL, serta version metadata pada Product.
- Mencegah perubahan base UOM dan conversion factor setelah Product memiliki Stock Movement.
- Mempertahankan kolom/tabel legacy agar Backoffice dan import existing belum terputus.

## Boundary Expand

- `products.category` dan `products.uom` belum dihapus.
- `product_uom_conversions` belum dihapus.
- `products.category_id`, `weight_reference_uom_id`, dan `warehouses.warehouse_type` belum `NOT NULL` sampai API/form/provisioning baru siap.
- Import lama belum menjadi import framework G2 dan belum boleh dianggap memenuhi MST-005.
- COA fallback Category ditunda sampai contract Finance final diterapkan.
- Tidak ada UI baru dalam fase ini.

## Urutan Manual

1. Simpan/export hasil `g2_phase1_master_data_preflight.sql` yang menunjukkan seluruh master legacy masih nol row.
2. Ambil backup/export Supabase sebelum migration.
3. Jalankan migration `20260721180000_g2_phase1_master_data_foundation.sql` sebagai satu batch.
4. Jalankan `supabase/diagnostics/g2_phase1_master_data_postflight.sql`; seluruh baris wajib `PASS`.
5. Jalankan `supabase/tests/g2_phase1_master_data_foundation_tests.sql` sebagai satu batch.
6. Pastikan test berakhir `ROLLBACK` dan menampilkan:

```text
TEST PASSED: G2 master foundation is tenant-scoped, versioned, and protects historical UOM conversion.
```

7. Restart Backoffice lokal dan buka seluruh menu existing. Pastikan Company aktif tetap KGS dan tidak muncul notifikasi pemuatan.
8. Jangan mencoba membuat Product canonical melalui UI pada fase ini karena form/API cutover belum dibangun.

## Stop Condition

- Jika migration menghasilkan `G2_PHASE1_STATE_CHANGED`, hentikan. Jalankan ulang preflight dan kirim hasil; jangan menghapus row baru.
- Jika postflight memiliki satu `FAIL`, jangan lanjut behavioral test atau UI work.
- Jika fixture `G11*` tersisa, test tidak rollback dengan benar; hentikan dan audit transaction SQL Editor.
- Jangan drop kolom/tabel legacy atau mengubah import agar memaksa migration lolos.
- Jangan menurunkan RLS/constraint/history guard.

## Forward Fix

Migration ini additive dan tidak memiliki down migration destructive. Bila runtime
bermasalah, jangan drop object baru; pertahankan legacy reader/writer lalu buat
forward fix. Cutover hanya dilakukan setelah canonical API, form, import dry-run,
dan compatibility test tersedia.
