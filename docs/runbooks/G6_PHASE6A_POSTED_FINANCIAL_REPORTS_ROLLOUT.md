# G6 Corrective Phase 6A — POSTED Financial Reports Rollout

## Scope

Phase 6A membuka database contract untuk Trial Balance dan General Ledger saja:

- hanya canonical journal `POSTED`;
- active Company dan Finance-role server guard;
- Company timezone, accounting date, date range, Store/Gudang filter;
- normal-balance presentation tanpa mengubah nilai line;
- source/prior-period drill-down dan GL pagination;
- version metadata serta immutable report history;
- export metadata disiapkan, tetapi worker/export file belum dibuka.

P&L, Neraca, pending analysis, reconciliation mutation, cache, UI, dan 25 event
unsupported tetap tertutup.

## Urutan manual

1. Jalankan `supabase/migrations/20260810220000_g6_phase6a_posted_financial_reports.sql`.
2. Jalankan `supabase/diagnostics/g6_phase6a_posted_financial_reports_postflight.sql`.
3. Jalankan `supabase/tests/g6_phase6a_posted_financial_reports_tests.sql`.
4. Jika semua PASS, rerun Phase 6 preflight dan Phase 5/4/2/G1 regression.

Expected postflight: seluruh non-INFO `PASS`, `violation_rows = 0`.
Behavior fixture rollback dan wajib menghasilkan notice `TEST PASSED`.

## Live data warning

Trial Balance/GL live masih kosong sampai controlled `STOCK_OPENING` benar-benar
diposting. Jangan membuat jurnal manual untuk menutup difference Rp84,71 juta.
Historical live run tetap memakai Phase-5 preview/approval/process setelah
closing database gate direview.

## Forward fix

Migration transactional. Sebelum ledger tercatat, error rollback otomatis.
Setelah `20260810220000` applied, jangan edit/drop object atau report history;
perbaikan wajib migration baru. Report tidak pernah mengubah journal/event.
