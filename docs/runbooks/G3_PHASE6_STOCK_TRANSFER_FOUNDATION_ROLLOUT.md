# G3 Phase 6 — Canonical Stock Transfer Foundation Rollout

## Status

`COMPLETE`

User mengonfirmasi migration, seluruh 15 postflight, behavioral test, dan
regression Phase-4/1/46/G1 sukses. Langkah berikutnya adalah authenticated UI
smoke pada `G3_PHASE7_STOCK_TRANSFER_API_UI.md`.

Preflight live dikonfirmasi:

- seluruh blocker `PASS`;
- satu Company aktif, tiga Gudang aktif, dan satu saldo sumber positif;
- saldo, movement, FIFO, tenant reference, dan Base UOM bersih;
- tidak ada histori Transfer yang memerlukan backfill;
- direct browser stock write seluruhnya `false`;
- RPC legacy masih ada tetapi `anon` dan `authenticated` tidak dapat execute;
- schema canonical Transfer belum ada sesuai ekspektasi.

## Urutan eksekusi

1. Jalankan migration:
   `supabase/migrations/20260728180000_g3_phase6_stock_transfer_foundation.sql`
2. Jalankan postflight:
   `supabase/diagnostics/g3_phase6_stock_transfer_postflight.sql`
3. Expected: **15 PASS**, seluruh `violation_rows = 0`.
4. Jalankan behavioral test:
   `supabase/tests/g3_phase6_stock_transfer_tests.sql`
5. Expected notice:
   `TEST PASSED: Stock Transfer is atomic, positive-only, tenant-safe, FIFO-preserving, paired, idempotent, and audited.`
6. Jalankan regression:
   - `supabase/tests/g3_phase4_canonical_stock_movement_tests.sql`
   - `supabase/tests/g3_phase1_opening_stock_tests.sql`
   - `supabase/tests/g2_phase46_product_warehouse_minimum_stock_tests.sql`
   - `supabase/tests/g1_security_closure_tests.sql`

Hentikan rollout bila satu gate gagal dan kirim error lengkap. Jangan lanjut ke
API/UI Transfer sebelum semua gate lulus.

## Isi migration

- dokumen `DRAFT -> POSTED` atau `DRAFT -> CANCELED`;
- nomor dokumen otomatis, optimistic version, actor/time, audit;
- Product hanya menggunakan Base UOM aktif dan quantity positif/precision-safe;
- source/destination wajib Gudang aktif berbeda dalam Company yang sama;
- posting memakai advisory lock, row lock, dan guarded source balance;
- FIFO source dikurangi berurutan dan layer destination dibuat dengan cost yang
  sama serta source-batch lineage;
- setiap line menghasilkan tepat satu `TRANSFER_OUT` dan satu `TRANSFER_IN`
  dengan snapshot Base UOM, saldo setelah movement, actor, waktu, dan source
  line;
- idempotency key mencegah duplicate posting;
- RPC legacy tetap ditemukan untuk compatibility tetapi execute dicabut juga
  dari `service_role`;
- browser hanya memperoleh `SELECT`; write melalui guarded RPC;
- operator posting saat ini: Super Admin, Company Owner/Admin, Warehouse Admin.

## Compatibility dan boundary

- `product_stocks`, `product_batches`, dan `stock_movements` existing tetap
  menjadi balance, FIFO layer, dan immutable ledger canonical;
- Opening Stock dan Kartu Stok tidak berubah;
- Transfer tidak membuat Finance event/jurnal karena nilai total persediaan
  Company tidak berubah; category `STOCK_TRANSFER` disimpan untuk audit;
- Store Manager mutation belum dibuka tanpa keputusan warehouse-scope granular;
- Adjustment, Opname, G4 notification, dan G5 Purchasing tetap deferred;
- concurrency harness multi-session tetap exit evidence G3 sebelum production,
  walaupun locking/guard sudah diterapkan di database.

## Forward-fix

Setelah migration applied, jangan edit file migration. Jika postflight atau test
menemukan masalah, buat migration forward-only dengan version lebih tinggi.
