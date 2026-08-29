# ODR-4D — Foundation Delta/Amendment Purchasing

## Outcome

Menambahkan relation immutable untuk notice delta/amendment ketika perubahan
demand tidak aman diterapkan ke Draft PO. Foundation ini zero-backfill dan belum
menjalankan sinkronisasi quantity.

## Urutan manual

1. Migration:
   `supabase/migrations/20260828180000_odr_phase4d_amendment_foundation.sql`.
2. Postflight:
   `supabase/tests/odr_phase4d_amendment_foundation_postflight.sql`.
3. Behavioral:
   `supabase/tests/odr_phase4d_amendment_foundation_behavior.sql`.
4. Postflight ulang.

Semua hasil selain `INFO` wajib `PASS`.

## Boundary

- Tidak membuat atau mengubah Stock Request maupun PO.
- Tidak menyentuh Stock, FIFO, Movement, AP, event, atau Journal.
- Runtime sinkronisasi Draft PO baru dibuka setelah foundation terverifikasi.
- Migration transactional; kegagalan sebelum `COMMIT` tidak meninggalkan
  schema parsial. Setelah berhasil gunakan forward-fix, bukan drop history.
