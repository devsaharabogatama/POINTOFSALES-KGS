# G4 Phase 60 — Negative Stock Online Runtime Rollout

Phase ini menambahkan jalur STK-006 yang tetap default OFF dan hanya berlaku
untuk Sale online Product stok biasa. Bundle dan Offline tetap fail-closed.

Runtime mewajibkan entitlement Company, policy aktif, Gudang sale-source opt-in,
permission user aktif, batas saldo negatif, dan alasan. Kekurangan FIFO dicatat
sebagai allocation provisional, bukan batch FIFO palsu. Setiap batch masuk akan
menutup outstanding shortage paling lama terlebih dahulu; hanya sisanya menjadi
FIFO tersedia. Selisih HPP aktual terhadap provisional disimpan untuk G6.

## Urutan Eksekusi

1. `supabase/migrations/20260805220000_g4_phase60_negative_stock_online_runtime.sql`
2. bila Phase-60 sudah applied, jalankan forward fix
   `supabase/migrations/20260805230000_g4_phase60_offline_reservation_guard_fix.sql`;
   jangan menjalankan ulang atau mengedit migration Phase-60;
3. bila behavior dari fix pertama masih ditolak guard, jalankan forward fix 2
   `supabase/migrations/20260805233000_g4_phase60_authorization_transaction_marker_fix.sql`;
4. jalankan final responsibility fix
   `supabase/migrations/20260805234500_g4_phase60_offline_guard_responsibility_fix.sql`;
5. `supabase/diagnostics/g4_phase60_offline_guard_responsibility_fix_postflight.sql`
6. `supabase/diagnostics/g4_phase60_negative_stock_online_runtime_postflight.sql`
7. `supabase/tests/g4_phase60_negative_stock_online_runtime_tests.sql`
8. regression:
   - `supabase/tests/g4_phase11_offline_stock_allowance_tests.sql`
   - `supabase/tests/g4_phase56_customer_balance_tender_tests.sql`
   - `supabase/tests/g4_phase4_atomic_sale_runtime_tests.sql`
   - `supabase/diagnostics/g4_phase4_atomic_sale_runtime_postflight.sql`
   - `supabase/diagnostics/g3_phase14_inventory_core_exit_preflight.sql`
   - `supabase/tests/g1_security_closure_tests.sql`
9. jalankan kembali seluruh postflight Phase 60.

Hash migration:

```text
7e2b56db7b54e901831b961691883535bd6a29418f3e452724e7f294afe6dd9c
6fbd6f8e745b3e3fa2b317c27bb754ef6254803f245070c17f7da84090f26ac7
76a628711ad3dba60f632d687233dbd3fef3ea2fb2fc716a23966ceae4b7034b
55b6b82e2ae63443a07750a59e49d933befb15000248c250f19396a453cb0d92
```

## Kriteria Lulus

- seluruh postflight `PASS` dengan `violation_rows = 0`;
- behavior mencetak `TEST PASSED` dan rollback;
- Sale berizin menghasilkan satu authorization, satu outstanding allocation,
  saldo/Movement negatif yang sama, serta HPP provisional;
- batch masuk otomatis menutup shortage, mencatat actual/variance cost, dan
  menyisakan FIFO yang sama dengan saldo aktual;
- Sale tanpa seluruh konfigurasi tetap menjadi Draft `STOCK_SHORTAGE`;
- tidak ada direct browser write dan Offline tidak menerima alasan stok minus.
- reservasi Offline aktif tetap tidak dapat dikonsumsi Sale online, sedangkan
  saldo negatif yang telah diotorisasi dan replenishment menuju nol tidak
  lagi salah ditolak guard Offline.

## Operasional

Jangan menyalakan fitur live sebelum Backoffice konfigurasi dan POS reason UX
Phase berikutnya selesai diuji. Migration ini tidak menyalakan entitlement,
policy, Gudang, atau permission existing.

Jika migration rollback, kirim error lengkap lalu gunakan file terkoreksi. Jika
ledger `20260805220000` sudah tersimpan, jangan edit migration; gunakan
forward-fix baru.
