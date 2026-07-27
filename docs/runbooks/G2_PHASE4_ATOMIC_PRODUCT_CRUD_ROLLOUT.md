# Runbook G2 Fase 4 - Atomic Product CRUD

**Scope:** guarded database write untuk STOCK Product dan seluruh Product-UOM  
**Requirement:** MST-001, MST-002  
**Dependency:** G2 fase 1-3 complete; live preflight clean  
**Status:** COMPLETE - DATABASE POSTFLIGHT + BEHAVIORAL TEST PASS

## Perubahan

- Satu RPC `save_product_with_uoms` membuat/mengubah Product dan seluruh UOM
  dalam satu transaksi database.
- Active Company dan role pengelola ditentukan server-side.
- Category, base UOM, UOM acuan berat, serta seluruh Product-UOM wajib aktif dan
  berasal dari Company yang sama.
- Base UOM wajib faktor `1`; UOM lain wajib lebih besar dari `1` dan selalu
  dikonversi langsung ke base.
- UOM acuan berat wajib merupakan UOM dengan faktor terbesar.
- Harga beli/jual wajib tersedia ketika UOM diaktifkan untuk fungsi tersebut.
- Update memakai `masterVersion` untuk mencegah lost update.
- Create/update dicatat pada `product_master_audit` dengan before/after snapshot.
- Legacy Product columns tetap disinkronkan agar reader lama tidak langsung rusak.
- Direct browser writes ke `products` dan `product_uoms` dicabut.
- Import Product lama ditutup untuk authenticated karena tidak membuat
  Product-UOM canonical.
- Bundle ditolak sampai komposisi atomic dibangun pada G3.

## Urutan Manual

1. Jalankan migration:
   `supabase/migrations/20260721210000_g2_phase4_atomic_product_crud.sql`.
2. Jalankan postflight:
   `supabase/diagnostics/g2_phase4_atomic_product_postflight.sql`.
3. Expected: seluruh baris postflight `PASS`.
4. Jalankan behavioral test:
   `supabase/tests/g2_phase4_atomic_product_crud_tests.sql`.
5. Expected: query sukses dan notice terakhir menyatakan `TEST PASSED`.
6. Restart Backoffice lalu pastikan seluruh menu lama masih dapat dibuka.

## Stop Condition

- Jangan menjalankan migration dua kali.
- Jika migration gagal, kirim error persis dan jangan menjalankan postflight/test.
- Jika ada satu postflight `FAIL`, jangan lanjut ke API/UI Product.
- Jika behavioral test gagal, semua fixture tetap rollback; kirim error persis.
- Jangan memakai import Product lama setelah migration.
- Jangan membuat Bundle sebelum G3 membuka kontrak komponennya.

## Evidence 2026-07-21

- Migration berhasil diterapkan satu kali.
- Seluruh postflight `PASS`.
- Behavioral test atomic Product + Product-UOM berhasil.
- Menu POS dan Backoffice existing tetap dapat dibuka setelah restart.

## Belum Termasuk

- Route API dan form Product canonical.
- Import/export staging dan dry-run.
- Opening Stock.
- Bundle composition.
- POS selected-UOM checkout cutover.
