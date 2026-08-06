# G4 Phase 40 — Additional Expense Disbursement Rollout

## Outcome

Phase ini menutup eksekusi dana tambahan pada satu Expense yang sudah
`DISBURSED` atau `PARTIALLY_SETTLED`. Request dan approval tetap tidak mengubah
kas. Efek final baru dibuat oleh RPC pencairan setelah request `APPROVED`.

Requirement: `POS-007`.

## Boundary

- Cash wajib memakai Cashier Session `OPEN`, expected cash cukup, dan tepat
  satu immutable Cash Drawer Movement `OUT`.
- Transfer/non-Cash hanya dapat dieksekusi Finance/Company Admin/Owner dan
  tidak boleh menyentuh drawer.
- Retry dengan identitas dan payload sama mengembalikan hasil lama tanpa efek
  ganda; payload berbeda ditolak.
- Financial Event masih `HOLD`; posting jurnal G6 belum dibuka.
- Migration tidak otomatis menyetujui atau mencairkan request existing.
- UI Phase 40, Offline Expense, correction/reversal, Deposit, dan G5/G6 tetap
  di luar scope rollout database ini.

## Urutan Manual Supabase

Jalankan satu file penuh per langkah dan hentikan bila ada error.

1. Migration:
   `supabase/migrations/20260804100000_g4_phase40_additional_expense_disbursement.sql`
2. Postflight:
   `supabase/diagnostics/g4_phase40_additional_expense_disbursement_postflight.sql`
   Semua baris selain inventory `INFO` wajib `PASS`; `FAIL` harus nol.
3. Behavioral test rollback-safe:
   `supabase/tests/g4_phase40_additional_expense_disbursement_tests.sql`
   Harus menghasilkan notice `TEST PASSED` dan berakhir `ROLLBACK`.
4. Regression, berurutan:
   - `supabase/tests/g4_phase37_expense_settlement_tests.sql`
   - `supabase/tests/g4_phase34_expense_disbursement_tests.sql`
   - `supabase/tests/g4_phase30_expense_request_approval_tests.sql`
   - `supabase/tests/g4_phase2_cashier_session_foundation_tests.sql`
   - `supabase/tests/g1_security_closure_tests.sql`
5. Jalankan postflight Phase 40 sekali lagi sebagai closing check.

## Expected Evidence

- enam lifecycle column dan dua guarded RPC tersedia;
- enum `EXPENSE_ADDITIONAL_DISBURSEMENT` tersedia;
- browser tidak memiliki direct write ke request, disbursement, atau drawer;
- request rejected tidak memiliki efek final;
- request disbursed memiliki tepat satu linked disbursement dan Financial
  Event;
- Cash mempunyai drawer `OUT`, non-Cash tidak;
- total detail disbursement sama dengan total pada Expense document.

## Forward-Fix / Recovery

Migration bersifat forward-only. Jika migration gagal, transaksi `BEGIN`
melakukan rollback. Jangan mengedit migration yang sudah applied dan jangan
menulis status/request/drawer secara manual. Simpan error lengkap lalu buat
forward migration baru. Setelah applied, rollback bisnis dilakukan melalui
correction/reversal gate yang masih deferred, bukan delete histori.

## Setelah Semua PASS

Kirim seluruh output postflight dan konfirmasi behavioral/regression. Langkah
aman berikutnya adalah UI review/pencairan additional Expense sesuai channel
Cash/non-Cash; Deposit belum boleh dibuka sebelum Phase 40 ditutup.
