# G6 Corrective Phase 1 — Posting Engine Preflight

**Status:** READY FOR MANUAL SELECT-ONLY RUN  
**Target:** `supabase/diagnostics/g6_phase1_posting_engine_preflight.sql`

Diagnostic ini wajib dijalankan sebelum membuat atau menjalankan migration
Finance posting. Draft G6 tanggal 20260807/20260810 sudah dikeluarkan dari jalur
rollout karena tidak memenuhi tenant, immutability, mapping, dan migration gate.

## Langkah

1. Buka target SQL di Supabase SQL Editor.
2. Jalankan seluruh file sebagai satu statement.
3. Kirim seluruh output `check_name,status,details`.
4. Jangan lanjut jika ada `BLOCKER`.

## Interpretasi khusus

- `rejected_g6_migration_ledger=BLOCKER`: draft G6 mungkin sudah applied;
  jangan rerun/hapus object, siapkan forward fix dari live-state.
- `unsafe_authenticated_finance_routine_execution=BLOCKER`: browser masih dapat
  menjalankan routine Finance yang belum guarded. Untuk live result 2026-08-10
  dengan 10 routine dan seluruh invariant lain PASS, ikuti forward-fix
  `G6_PHASE1_FINANCE_ROUTINE_QUARANTINE_ROLLOUT.md`; jangan membuka grant atau
  menjalankan routine tersebut.
- `canonical_transaction_rule_requiredness` atau `history_guard=BLOCKER`:
  schema canonical pernah dilonggarkan atau trigger dilepas.
- `finance_runtime_schema_state=INFO`: object boleh belum ada; Phase 1 memang
  preflight dan tidak membuat schema.

Setelah seluruh blocker ditutup, next step hanya Corrective Phase 2 sesuai
`docs/G6_FINANCE_CORRECTIVE_RECOVERY_PLAN.md`.
