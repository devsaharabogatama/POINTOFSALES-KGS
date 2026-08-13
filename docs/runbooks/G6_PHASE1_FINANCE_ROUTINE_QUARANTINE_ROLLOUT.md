# G6 Corrective Phase 1 Finance Routine Quarantine

## Tujuan

Menutup akses browser terhadap routine Finance dari draft G6 yang ditolak,
tanpa menghapus routine, mengubah jurnal/event, atau membuka posting Finance.

## Urutan manual

1. Jalankan migration
   `supabase/migrations/20260810170000_g6_phase1_unsafe_finance_routine_quarantine.sql`.
2. Jalankan
   `supabase/diagnostics/g6_phase1_finance_routine_quarantine_postflight.sql`.
   Seluruh status non-INFO harus `PASS`.
3. Jalankan
   `supabase/tests/g6_phase1_finance_routine_quarantine_tests.sql`.
   Harus muncul notice `TEST PASSED` dan seluruh fixture di-rollback.
4. Rerun
   `supabase/diagnostics/g6_phase1_posting_engine_preflight.sql`.
   Seluruh status `BLOCKER` harus nol.

## Compatibility dan rollback

- Routine tidak di-drop agar dependency/forensic history tetap tersedia.
- `service_role` tetap memiliki `EXECUTE` untuk compatibility server-only.
- `PUBLIC`, `anon`, dan `authenticated` tidak dapat mengeksekusi routine.
- Finance posting tetap tertutup; migration ini tidak memproses 26 event HOLD.
- Jika aplikasi lama ternyata memanggil salah satu routine langsung dari
  browser, jangan membuka grant kembali. Migrasikan call site ke guarded RPC
  Corrective Phase 2 setelah active-Company, role, idempotency, dan audit guard
  tersedia.
