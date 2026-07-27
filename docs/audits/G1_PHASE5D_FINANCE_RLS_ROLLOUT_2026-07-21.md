# Evidence Rollout G1 Fase 5D - Finance RLS

**Tanggal konfirmasi:** 2026-07-21  
**Migration:** `20260721120000_g1_phase5d_finance_rls.sql`  
**Status:** COMPLETE

## Evidence yang Dikonfirmasi

- Preflight Finance berhasil tanpa blocker.
- Migration berhasil diterapkan sebagai satu batch.
- Postflight berhasil dan seluruh pemeriksaan aman.
- Behavioral Finance RLS test berhasil.
- POS dan Backoffice lokal tetap berjalan tanpa regresi yang dilaporkan.

## Boundary yang Aktif

- Expense/Setoran hanya terlihat sesuai actor dan reviewer scope.
- Financial Event, Journal, dan Reconciliation tidak terlihat oleh Cashier.
- Lima tabel Finance tidak dapat dimutasi langsung oleh browser.
- Worker Finance tetap eksklusif `service_role`.
- Tenant topology Finance diperkuat dengan composite foreign key.

## Keputusan Lanjutan

Phase 5D ditutup. Phase 5E inventory-operation RLS boleh dimulai. Nama legacy
`cash_advances` tetap dipertahankan sampai canonical Expense contract dibangun.
