# ODR-4D — Rekonsiliasi Managed Stock Request

## Outcome

Perubahan Order setelah sesi ditutup memperbarui managed Stock Request dan
menghasilkan notice Purchasing. Runtime ini belum mengubah Draft maupun final
PO.

Baris kebutuhan yang kembali nol dinonaktifkan, bukan dihapus, agar lineage dan
audit tetap tersedia. Reader Purchasing hanya menampilkan baris aktif.

## Urutan manual

1. Migration:
   `supabase/migrations/20260828190000_odr_phase4d_managed_request_reconciliation.sql`.
2. Postflight:
   `supabase/tests/odr_phase4d_managed_request_reconciliation_postflight.sql`.
3. Behavioral:
   `supabase/tests/odr_phase4d_managed_request_reconciliation_behavior.sql`.
4. Postflight ulang.

Semua selain `INFO` wajib `PASS`.

## Boundary

- Tidak ada mutation Supplier Order/PO.
- Tidak ada Stock, FIFO, Movement, AP, event, atau Journal effect.
- `DRAFT_SYNC_PENDING` baru berarti eligible untuk fase sinkronisasi Draft PO;
  belum berarti PO sudah berubah.
- Migration transactional. Setelah berhasil, koreksi memakai forward-fix.
