# G3 Phase 1 - Opening Stock Preflight

## Tujuan

Mengaudit kesiapan live database sebelum membuat dokumen dan posting service
Opening Stock canonical. Preflight tidak mengisi atau mengubah stok.

## Menjalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

```text
supabase/diagnostics/g3_phase1_opening_stock_preflight.sql
```

Kirim seluruh hasil `check_name,status,details`.

## Expected

- seluruh check yang dapat berstatus `BLOCKER` harus bernilai `PASS`;
- `stock_balance_movement_mismatch` dan
  `fifo_remaining_balance_mismatch` idealnya `PASS`; status `REVIEW` harus
  dianalisis sebelum migration;
- schema dan enum Opening Stock masih boleh `INFO` atau belum tersedia;
- `pairs_without_movement` menunjukkan pasangan yang masih sah menerima
  Opening Stock.

## Boundary Rollout Berikutnya

Jika preflight bersih, migration berikutnya baru boleh menambahkan:

- header dan line Opening Stock berstatus Draft/Posted;
- enum/event canonical Opening Stock;
- guarded Company Admin/Super Admin posting RPC;
- atomic insert movement, upsert balance, FIFO batch, financial event, dan
  audit;
- unique idempotency/source contract;
- hard guard: pasangan yang sudah memiliki movement ditolak;
- postflight, behavior, concurrency/idempotency, serta reconciliation test.

Upload/preview Draft tidak boleh mengubah saldo. `product_stocks` tidak boleh
ditulis langsung oleh browser. Nilai HPP nol hanya boleh dengan warning dan
alasan eksplisit.

## Rollback

File preflight ini `SELECT`-only sehingga tidak membutuhkan rollback.
