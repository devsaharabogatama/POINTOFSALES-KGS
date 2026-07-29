# G3 Phase 8 — Canonical Stock Adjustment Foundation Rollout

## Status

`READY_FOR_MANUAL_ROLLOUT`

Preflight live telah dikonfirmasi user:

- seluruh blocker `PASS`;
- tidak ada legacy Adjustment atau Movement Adjustment yang perlu backfill;
- dua pasangan saldo positif memiliki dua FIFO layer valid dan tidak ada
  positive layer bernilai nol;
- saldo, Movement, FIFO, Base UOM, tenant reference, category, dan Finance
  function siap;
- direct browser write tetap tertutup.

## Urutan eksekusi

1. Jalankan migration:
   `supabase/migrations/20260728210000_g3_phase8_stock_adjustment_foundation.sql`
2. Jalankan postflight:
   `supabase/diagnostics/g3_phase8_stock_adjustment_postflight.sql`
3. Expected: seluruh **16 checks PASS** dengan `violation_rows = 0`.
4. Jalankan behavioral test:
   `supabase/tests/g3_phase8_stock_adjustment_foundation_tests.sql`
5. Expected notice:
   `TEST PASSED: Adjustment derives final-stock delta, consumes/adds FIFO, posts immutable Movement and HOLD Finance events atomically.`
6. Jalankan regression:
   - `supabase/tests/g3_phase6_stock_transfer_tests.sql`
   - `supabase/tests/g3_phase4_canonical_stock_movement_tests.sql`
   - `supabase/tests/g3_phase1_opening_stock_tests.sql`
   - `supabase/tests/g2_phase46_product_warehouse_minimum_stock_tests.sql`
   - `supabase/tests/g1_security_closure_tests.sql`

Hentikan rollout pada kegagalan pertama dan kirim error lengkap. Jangan masuk
API/UI Adjustment sebelum migration, postflight, behavior, dan regression lulus.

## Kontrak yang dibangun

- operator memasukkan **stok fisik akhir**, bukan angka plus/minus;
- server menyimpan snapshot stok sistem lalu menghitung
  `final physical - system snapshot`;
- Draft tidak menyentuh stok; final state hanya `POSTED` atau `CANCELED`;
- Store Manager hanya dapat memproses gudang Store dalam assignment;
- Company Owner/Admin dan Super Admin dapat memproses dalam Company aktif;
- Warehouse Admin tidak memperoleh hak posting Adjustment;
- reason reusable, tenant-scoped, bernama unik, berkode otomatis, memiliki arah
  `INCREASE/DECREASE/BOTH`, treatment Finance, status, version, dan audit;
- gain membuat FIFO layer baru; loss mengonsumsi FIFO aktual paling lama;
- perubahan stok, FIFO, immutable Movement, Finance event `HOLD`, state, dan
  audit berada dalam satu transaksi;
- perubahan stok setelah Draft membuat posting ditolak dengan
  `STOCK_ADJUSTMENT_STOCK_CHANGED`;
- cost gain memakai suggested cost terbaru; override wajib memiliki alasan;
- satu dokumen campuran dapat membuat satu event `STOCK_GAIN` dan satu event
  `STOCK_LOSS`, masing-masing idempotent dan tetap `HOLD_UNTIL_G6`;
- browser hanya mendapat `SELECT`; mutation melalui guarded RPC.

## Compatibility dan boundary

- tabel legacy `stock_adjustments` tidak dihapus atau diubah;
- Opening Stock, Kartu Stok, Minimum Stock, dan Transfer tetap kompatibel;
- Finance Journal posting belum dibuka; event Adjustment tetap `HOLD`;
- linkage `opname_detail_id` sudah tersedia agar Stock Opname nanti memakai
  workflow Adjustment yang sama;
- reversal UI/API, Adjustment UI/API, Opname, Notification, dan Purchasing tidak
  dibuka pada gate database ini.

## Forward-fix

Setelah migration applied, jangan edit migration ini. Temuan postflight/test
harus ditangani dengan migration forward-only versi berikutnya.
