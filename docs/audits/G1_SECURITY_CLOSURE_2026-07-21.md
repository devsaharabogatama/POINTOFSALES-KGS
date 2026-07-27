# Evidence Penutupan G1 - Tenant dan Security

**Tanggal konfirmasi:** 2026-07-21
**Gate:** G1 - Tenant, Security, Role, dan Feature Entitlement
**Status:** COMPLETE

## Evidence yang Dikonfirmasi

- `supabase/diagnostics/g1_security_closure_preflight.sql` menghasilkan 15 baris `PASS` tanpa violation.
- `supabase/tests/g1_security_closure_tests.sql` berhasil sebagai satu batch dan seluruh fixture diakhiri dengan `ROLLBACK`.
- Integrated negative-access test membuktikan isolasi Company, pembatasan role, active Company context, feature entitlement, serta boundary RPC, Finance, dan Inventory.
- Setelah Backoffice lokal direstart, seluruh menu existing dapat dibuka tanpa notifikasi error pemuatan.
- Fase 1, 2, 3, 4, 5A, 5B, 5C, 5D, dan 5E telah memiliki evidence rollout masing-masing.

## Exit Criteria G1

| Kriteria | Evidence | Status |
|---|---|---|
| Tenant-bearing table memiliki policy/constraint yang terdokumentasi | Closure preflight dan migration G1 phase 1-5E | PASS |
| Tidak ada service-role key pada route client/browser | Audit lokal pada `backoffice/src/lib/server-auth.ts` dan Route Handler server | PASS |
| Negative access test lulus 100% | Integrated closure test Supabase | PASS |
| Aplikasi existing tidak regresi setelah security closure | Restart dan pemeriksaan seluruh menu Backoffice lokal | PASS |

## Keputusan Lanjutan

G1 ditutup. Pekerjaan berikutnya masuk G2 dan dimulai dengan preflight canonical
master Product, Product Category, UOM, Product-UOM, dan Warehouse. Schema G2
tidak boleh menebak backfill dari field teks legacy dan UI belum dihubungkan
sebelum contract database/import stabil.

Vercel belum dipasang pada tahap ini. Sesuai gate delivery, Vercel Preview baru
disiapkan setelah seluruh exit criteria G2 lulus.
