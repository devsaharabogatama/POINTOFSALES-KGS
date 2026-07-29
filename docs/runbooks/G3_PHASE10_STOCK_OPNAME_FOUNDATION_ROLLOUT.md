# G3 Phase 10 — Canonical Stock Opname Foundation Rollout

## Status

`READY_FOR_MANUAL_ROLLOUT`

Live preflight telah dikonfirmasi user:

- seluruh invariant dan dependency `PASS`;
- legacy Opname/session/detail kosong;
- tidak ada overlap, backfill, atau linkage Adjustment bermasalah;
- saldo, Movement, FIFO, Base UOM, reason `Selisih Stok`, dan RPC Adjustment
  canonical siap;
- direct browser write tertutup;
- satu Store, POS terminal, dan Store Warehouse aktif tersedia;
- belum ada membership Cashier aktif; ini tidak memblokir schema rollout, tetapi
  diperlukan sebelum smoke POS dengan user Cashier.

## Urutan eksekusi

1. Jalankan migration:
   `supabase/migrations/20260728230000_g3_phase10_stock_opname_foundation.sql`
2. Jalankan postflight:
   `supabase/diagnostics/g3_phase10_stock_opname_postflight.sql`
3. Expected: seluruh **14 checks PASS** dengan `violation_rows = 0`.
4. Jalankan behavioral test:
   `supabase/tests/g3_phase10_stock_opname_foundation_tests.sql`
5. Expected notice:
   `TEST PASSED: blind count, movement-window recount, current-balance variance posting, Adjustment linkage, and idempotency are enforced.`
6. Jalankan regression:
   - `supabase/tests/g3_phase8_stock_adjustment_foundation_tests.sql`
   - `supabase/tests/g3_phase6_stock_transfer_tests.sql`
   - `supabase/tests/g3_phase4_canonical_stock_movement_tests.sql`
   - `supabase/tests/g3_phase1_opening_stock_tests.sql`
   - `supabase/tests/g2_phase46_product_warehouse_minimum_stock_tests.sql`
   - `supabase/tests/g1_security_closure_tests.sql`

Hentikan pada kegagalan pertama dan kirim error lengkap. Jangan membuat UI/API
Opname sebelum semua gate database dan regression lulus.

## Kontrak yang dibangun

- satu sesi hanya untuk satu Company dan satu Gudang;
- scope `ALL`, `CATEGORY`, atau `SELECTED`;
- kasir/creator menghitung melalui guarded RPC;
- detail direct-read tetap reviewer-only; payload kasir berasal dari
  `get_stock_opname_blind_session(...)` dan tidak membawa saldo, expected,
  variance, physical count lama, HPP, atau nilai rupiah;
- snapshot saldo dan movement watermark diambil saat sesi dimulai;
- movement dalam window `count_started_at..counted_at` menghasilkan
  `RECOUNT_REQUIRED`, tanpa membekukan transaksi;
- recount membuka time window baru dan menyimpan attempt lama untuk audit;
- hasil valid terbaru menandai line Product–Gudang lain yang belum final sebagai
  `SUPERSEDED`;
- completion menolak line `PENDING` atau `RECOUNT_REQUIRED`;
- reviewer tidak mengubah physical quantity; reviewer hanya meminta recount
  atau melakukan posting;
- posting menghitung `current stock + variance_at_count`, membuat satu canonical
  Adjustment untuk seluruh variance nonzero, lalu mem-posting Adjustment dalam
  transaksi yang sama;
- line zero variance tetap dapat menjadi `POSTED` tanpa Adjustment line;
- retry dengan idempotency key yang sama tidak menggandakan Adjustment,
  Movement, FIFO, atau Finance event;
- Store Manager mengikuti Store/Gudang assignment; Company Owner/Admin dan
  Super Admin mengikuti active Company;
- Finance tetap read-only dan bukan approval wajib.

## Compatibility dan boundary

- tabel legacy `stock_opnames` dan `stock_opname_details` diperluas, tidak
  diganti, karena kosong pada preflight;
- enum legacy `SUBMITTED` dan `APPROVED` dipertahankan untuk compatibility,
  tetapi guarded RPC hanya memakai flow canonical;
- Stock Adjustment, Stock Real, Kartu Stok, FIFO, Opening, Transfer, dan Minimum
  Stock tetap menjadi source yang sama;
- posting Finance tetap mengikuti canonical Adjustment dalam status
  `HOLD_UNTIL_G6`;
- UI POS blind count, Backoffice review/report, offline queue synchronization,
  abandoned-session retention, dan notification tetap gate berikutnya.

## Rollback dan forward-fix

Label enum adalah perubahan additive PostgreSQL yang tidak dapat dihapus aman.
Karena label baru harus committed sebelum digunakan, migration mempunyai commit
boundary sebelum transaksi schema utama. Jika transaksi utama gagal:

1. label enum yang sudah bertambah boleh dibiarkan;
2. perbaiki melalui migration forward-only;
3. rerun preflight/state audit;
4. jangan mengedit file ini setelah ledger `20260728230000` tercatat.

Seluruh tabel, kolom, RPC, privilege, dan ledger selain enum berada dalam
transaksi schema utama dan rollback bersama bila gagal.
