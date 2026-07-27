# Runbook G2 Fase 12 - Pricelist Foundation

**Status:** READY FOR MANUAL DATABASE ROLLOUT  
**Dependency:** `20260722040000` complete dan phase-11 preflight disetujui

## Evidence Preflight Live

- dependency phase 10: `PASS`;
- Product aktif tanpa Sales UOM valid: `0`;
- legacy Sales detail price invalid: `0`;
- Sales header/detail existing: `0`;
- satu Company aktif membutuhkan default Global Pricelist (`BACKFILL`, expected);
- tabel Pricelist dan kolom pricing snapshot belum ada (`INFO`, expected);
- direct mutation `sales_details` oleh authenticated tertutup.

## Scope Migration

- membuat Global dan Customer-exclusive Pricelist;
- membuat assignment Store dan versioned Product-UOM price rules;
- membuat satu `Harga Umum` default untuk setiap Company aktif dan otomatis
  saat Company baru dibuat;
- mutation melalui satu guarded RPC dengan active Company, role, optimistic
  version, transaction, dan audit;
- Customer-specific Pricelist hanya boleh menunjuk Customer biasa aktif dan
  tidak mempunyai quantity tier selain `min_qty = 1`;
- menambah pricing snapshot nullable pada `sales_details` untuk cutover
  berikutnya;
- menutup direct browser writes pada seluruh tabel Pricelist;
- mempertahankan Product-UOM `sale_price` dan checkout existing sebagai
  fallback. Resolver harga dan UI Pricelist belum diaktifkan pada fase ini.

## Urutan Manual

1. Pastikan hasil phase-11 preflight yang dikirim user masih state terbaru.
2. Jalankan seluruh file
   `supabase/migrations/20260722070000_g2_phase12_pricelist_foundation.sql`
   tepat satu kali di Supabase SQL Editor.
3. Jalankan seluruh file
   `supabase/diagnostics/g2_phase12_pricelist_foundation_postflight.sql`.
   Expected: **12 baris PASS**, seluruh `violation_rows = 0`.
4. Jalankan seluruh file
   `supabase/tests/g2_phase12_pricelist_foundation_tests.sql`.
   Expected notice:
   `TEST PASSED: Global/Customer Pricelist writes are atomic, tenant-safe, versioned, audited, and preserve historical rules.`
5. Restart Backoffice dan lakukan compatibility smoke:
   - menu Product, Customer, Supplier, dan menu existing tetap terbuka;
   - create/edit Product existing tetap bekerja;
   - tidak ada perubahan harga atau checkout karena resolver belum cutover.

## Stop Conditions

- Jika migration mengeluarkan `G2_PHASE12_STATE_CHANGED`, jangan menghapus
  Sales. Ulangi preflight dan desain backfill snapshot eksplisit.
- Jika salah satu postflight `FAIL`, jangan melanjutkan ke API/UI atau resolver.
- Jika behavioral test gagal, kirim error lengkap dan jangan menjalankan ulang
  migration yang sudah tercatat di ledger.
- Setelah applied, migration ini immutable; koreksi memakai forward migration.

## Compatibility dan Forward Fix

Migration additive. Checkout lama tetap memakai schema/flow existing dan
Product-UOM manual price. Kolom snapshot belum diwajibkan sehingga rollback
aplikasi tidak membutuhkan penghapusan schema. Jika ada defect sesudah applied,
buat forward-fix baru; jangan drop Pricelist yang sudah mungkin dipakai.

## Next Safe Step

Setelah database, test, dan compatibility smoke dikonfirmasi PASS, buat API/UI
master Pricelist. Resolver server-side dan checkout cutover menjadi gate
terpisah setelah master dapat diuji tanpa mengubah harga transaksi aktif.
