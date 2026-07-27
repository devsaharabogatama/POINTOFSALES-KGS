# Runbook G1 Fase 5B - Catalog dan Inventory RLS

**Migration:** `supabase/migrations/20260720230000_g1_phase5b_catalog_inventory_rls.sql`  
**Requirement:** TEN-001, TEN-002  
**Scope:** Product, Bundle Item, UOM, Product UOM Conversion, Customer, Product Stock, dan Product Batch.

## Perubahan Keamanan

- Semua SELECT katalog/inventory wajib mengikuti active Company.
- Product/UOM/Bundle/Conversion dapat dibuat atau diperbarui oleh Company Admin, Store Manager, dan Warehouse Admin sesuai hierarchy.
- Customer dapat dikelola Manager/Finance, tetapi `current_balance` tidak dapat diedit langsung dari browser.
- Cashier hanya membaca Customer; quick-create tetap menunggu RPC/API terkontrol.
- Product Stock dan FIFO Batch read-only dari browser. Mutation harus melalui workflow transaksi atomik.
- Pricelist tidak dibuat pada fase ini. Tabel legacy tidak ada di database live dan model canonical Pricelist dibuat pada G2.
- Product import lama tetap tersedia sementara, tetapi dibungkus guard active Company. Implementasinya akan diganti pada G2.
- DELETE tidak diberikan kepada browser.

## Urutan Manual

1. Pastikan seluruh preflight/postflight/behavioral test Phase 5A sudah aman.
2. Jalankan `supabase/diagnostics/g1_phase5b_catalog_inventory_rls_preflight.sql`.
3. Semua 4 baris wajib `PASS` dengan `violation_rows = 0`.
4. Ambil backup/export, lalu jalankan migration `20260720230000...sql` sebagai satu batch.
5. Jalankan `supabase/diagnostics/g1_phase5b_catalog_inventory_rls_postflight.sql`; harus 19 baris dan semuanya `PASS`.
6. Jalankan `supabase/tests/g1_phase5b_catalog_inventory_rls_tests.sql`.
7. Reload Backoffice lokal sebagai Super Admin. Product, total stock, lokasi Warehouse, dan Customer harus tetap terbaca.
8. Coba impor satu CSV test hanya jika diperlukan; Company pada request harus sama dengan Company aktif.

Expected behavioral notice:

```text
TEST PASSED: catalog and inventory reads are tenant-safe; direct balance mutation is blocked.
```

## Stop Condition

- Jangan migration bila preflight menemukan stock negatif, batch invalid, atau tenant mismatch.
- Jangan menjalankan `customer_pricelist_migration.sql`; struktur tersebut legacy dan bukan target G2.
- Jika Product/Customer hilang dari Backoffice, kirim request/error PostgREST dan active Company ID.
- Jika behavioral fixture Auth gagal, kirim exact error; jangan mengubah schema Auth manual.
- Jangan lanjut ke transaction RLS sebelum seluruh postflight dan smoke lokal PASS.

## Forward Fix

Policy lama diganti hanya pada tujuh tabel scope ini. Jangan mengembalikan broad policy `FOR ALL`. Runtime tetap lokal + Supabase dan belum memerlukan Vercel.
