# G3 Phase 15 — Inventory Core Stress Behavior

## Outcome

Integrated rollback-safe test untuk menutup risiko inventory core yang belum
terlihat pada data live karena:

- belum ada Bundle aktif;
- dua FIFO layer live berada pada pasangan berbeda;
- belum ada Adjustment/Opname posted live.

Test membuat Company dan fixture sendiri, menjalankan guarded RPC, lalu
`ROLLBACK`.

## Cakupan

File:

`supabase/tests/g3_phase15_inventory_core_stress_behavior_tests.sql`

Behavior yang diuji:

1. satu Product memiliki dua FIFO layer dengan cost berbeda;
2. Transfer delapan unit mengonsumsi kedua layer secara FIFO;
3. retry key yang sama tidak menggandakan Movement;
4. Adjustment gain menambah saldo dan layer melalui RPC canonical;
5. dua puluh dokumen Transfer bersaing atas lima unit tersisa:
   tepat lima POSTED dan lima belas ditolak tanpa partial write;
6. saldo akhir sama dengan agregat Movement dan remaining FIFO;
7. Bundle availability berubah mengikuti komponen pembatas per Gudang;
8. Bundle tidak pernah mempunyai saldo, batch, atau Movement sendiri;
9. browser direct-write stock tetap tertutup.

## Batas Klaim

Dua puluh attempt di SQL Editor diproses serial dalam satu transaction.
Pengujian ini membuktikan atomic rejection, idempotency, dan konsistensi ketika
request berulang memperebutkan saldo yang sama. Ini **bukan** bukti true
multi-session concurrency.

True parallel concurrency membutuhkan runner eksternal/API dengan beberapa
connection dan data UAT yang dapat dibersihkan. Runner tersebut dilakukan pada
Preview/local integration gate setelah execution path transaksi yang relevan
tersedia; jangan mengklaimnya dari test SQL ini.

Sale checkout, Bundle component deduction saat Sale, Sales Return, Goods
Receipt, dan Purchase Return tetap berada di G4/G5.

## Cara Menjalankan

1. Jalankan seluruh file test di Supabase SQL Editor.
2. Expected notice:

```text
TEST PASSED: inventory core preserves two-layer FIFO, idempotent retry,
atomic contention rejection, three-way reconciliation, and virtual Bundle
availability.
```

3. Pastikan hasil akhir `ROLLBACK`.
4. Setelah PASS, rerun:

   - `g3_phase14_inventory_core_exit_preflight.sql`;
   - `g1_security_closure_tests.sql`.

Live row count harus kembali ke kondisi sebelum test.

## Failure dan Rollback

- Setiap exception membatalkan transaction test; jalankan `ROLLBACK` bila SQL
  Editor belum menutup transaction otomatis.
- Jangan mengubah data live untuk memenuhi fixture test.
- Jika contention menghasilkan lebih dari lima success, saldo negatif, partial
  document, duplicate Movement, atau reconciliation mismatch, hentikan G3.

## Next Safe Step

Setelah integrated test, Phase-14 preflight, dan G1 closure PASS:

1. catat G3 inventory core sebagai complete pada boundary non-transaction;
2. pertahankan cross-gate coverage sebagai deferred, bukan PASS;
3. lanjut ke G4 POS readiness preflight, bukan langsung mengaktifkan checkout.
