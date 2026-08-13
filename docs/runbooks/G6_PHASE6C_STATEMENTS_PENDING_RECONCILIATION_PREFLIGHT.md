# G6 Corrective Phase 6C - Statements and Pending Reconciliation Preflight

## Tujuan

Mengaudit kesiapan P&L, Neraca, pending-event analysis, dan reconciliation
summary setelah satu canonical journal live tersedia. Diagnostic tetap
SELECT-only dan tidak memproses 25 event HOLD.

## Jalankan

Jalankan seluruh:

`supabase/diagnostics/g6_phase6c_statements_pending_reconciliation_preflight.sql`

Kirim seluruh output untuk review sebelum migration Phase 6C dibuat.

## Expected

- `BLOCKER` dan `REVIEW` wajib nol;
- report definition/RPC dan reconciliation relation dapat `SETUP`;
- P&L fixture dapat `SETUP` karena jurnal live saat ini hanya Opening Stock;
- seluruh remaining HOLD dan FIFO–GL mismatch tetap `DEFERRED`;
- posted journal fixture, trial balance, Neraca equation, timezone, privilege,
  dan legacy report quarantine wajib `PASS`.

## Boundary

Phase 6C tidak menambah dukungan posting untuk event baru. Pending analysis
harus menampilkan exposure secara agregat dan tidak boleh mengubah status event.
Reconciliation summary adalah read model; adjustment/correction tetap workflow
terpisah dan tidak boleh dibuat otomatis.
