# Runbook G2 Fase 13 - Pricelist Default Guard Forward Fix

**Status:** READY FOR MANUAL DATABASE ROLLOUT  
**Dependency:** `20260722070000` complete

## Alasan Forward Fix

Phase 12 sudah applied dan immutable. Review API/UI menemukan partial unique
index hanya mencegah dua default Global, tetapi belum mencegah default terakhir
dinonaktifkan. Karena ini invariant server-side, UI tidak boleh menjadi pagar
satu-satunya.

Forward migration ini:

- mewajibkan tepat satu active default Global untuk setiap active Company;
- menolak penghapusan/nonaktif default terakhir pada akhir transaksi;
- memungkinkan pemindahan default secara atomic ketika default baru disimpan;
- mencatat audit untuk default lama yang dilepas;
- menjaga RPC public tetap satu-satunya jalur authenticated mutation.

## Urutan Manual

1. Jalankan
   `supabase/migrations/20260722080000_g2_phase13_pricelist_default_guard.sql`
   tepat satu kali.
2. Jalankan
   `supabase/diagnostics/g2_phase13_pricelist_default_guard_postflight.sql`.
   Expected: **6 PASS**.
3. Jalankan
   `supabase/tests/g2_phase13_pricelist_default_guard_tests.sql`.
   Expected notice:
   `TEST PASSED: every active Company retains exactly one active default Global Pricelist.`
4. Setelah seluruh database gate PASS, restart Backoffice dan lanjutkan smoke
   `G2_PHASE13_PRICELIST_API_UI_ROLLOUT.md`.

## Stop Conditions

- Jika migration menghasilkan `G2_PHASE13_STATE_CHANGED`, kirim hasil query
  default Pricelist; jangan memperbaiki row secara manual tanpa review.
- Jika postflight/test gagal, jangan smoke mutation UI terlebih dahulu.
- Migration Phase 12 tidak boleh diedit; seluruh koreksi tetap forward-only.
