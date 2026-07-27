# G2 Phase 16 — Transaction Category dan Minimum COA Foundation

## Outcome

Migration ini menambahkan registry System Event/Account Function, minimum COA
per Company, Transaction Category, versioned account mapping, explicit Company
fallback storage, exception queue, audit, serta snapshot nullable pada Event dan
Journal.

Finance worker, automatic journal, period lock, resolver, dan production posting
tetap tidak diaktifkan.

## Urutan rollout

Jalankan satu per satu di Supabase SQL Editor:

1. `supabase/migrations/20260722150000_g2_phase16_finance_master_foundation.sql`;
2. `supabase/diagnostics/g2_phase16_finance_master_postflight.sql`;
3. pastikan seluruh **14 baris** postflight berstatus `PASS` dan
   `violation_rows = 0`;
4. `supabase/tests/g2_phase16_finance_master_foundation_tests.sql`;
5. pastikan notice terakhir menyatakan `TEST PASSED`;
6. restart Backoffice dan buka menu existing untuk compatibility smoke.

Jangan menjalankan ulang migration bila ledger version `20260722150000` sudah
ada. Postflight dan behavioral test aman dijalankan ulang; behavioral test
melakukan `ROLLBACK`.

## Expected backfill

Preflight live menyatakan:

- satu Company aktif perlu template COA;
- tidak ada Expense, Financial Event, atau Journal historis;
- tidak ada collision Category/COA;
- browser tidak mempunyai direct Finance write privilege.

Migration berhenti bila histori Finance muncul setelah preflight. Template COA
dibuat untuk Company aktif existing dan otomatis untuk Company baru.

## Compatibility

- `journal_entries.coa_code` dan `coa_name` lama tidak dihapus atau diubah;
- canonical `account_id` dan snapshot baru nullable;
- `financial_events` lama tetap dapat dibuat tanpa Category/Rule selama resolver
  belum dicutover;
- Payment Method, Pricelist, Customer, Product, Supplier, dan menu existing tidak
  dipindahkan ke Finance resolver pada fase ini.

## Forward-fix policy

Migration transactional. Error sebelum `COMMIT` me-roll back seluruh perubahan.
Setelah applied, jangan edit file migration; koreksi memakai migration baru.
Jangan mengaktifkan worker lama dengan kode COA hard-coded.
