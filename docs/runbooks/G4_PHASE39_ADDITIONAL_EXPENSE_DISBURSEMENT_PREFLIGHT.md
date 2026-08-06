# G4 Phase 39 — Additional Expense Disbursement Preflight

Status: `READY FOR MANUAL PREFLIGHT`

## Tujuan

Mengaudit live state sebelum request dana tambahan Expense dapat direview dan
dicairkan. File SQL bersifat SELECT-only: tidak menyetujui request, tidak
mencairkan uang, dan tidak mengubah kas laci.

Phase 38 dinyatakan selesai berdasarkan konfirmasi user. Expense tetap harus
ditutup sebelum berpindah ke Deposit karena additional disbursement saat ini
baru request-only.

## Cara menjalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

`supabase/diagnostics/g4_phase39_additional_expense_disbursement_preflight.sql`

Kirim seluruh output `check_name,status,details`.

## Interpretasi

- `BLOCKER`: hentikan; data/reference/zero-effect contract harus dibetulkan.
- `REVIEW`: kondisi operasional perlu dipahami, tetapi bukan otomatis korupsi.
- `SETUP`: gap runtime yang memang akan dibuat pada foundation berikutnya.
- `PASS`: invariant siap.
- `INFO`: inventory/boundary, bukan kegagalan.

Expected pada baseline saat ini:

- lifecycle column review/reject/disburse masih `SETUP`;
- RPC review dan execution additional masih `SETUP`;
- enum `EXPENSE_ADDITIONAL_DISBURSEMENT` masih `SETUP`;
- direct browser write tetap `false`;
- request `SUBMITTED/APPROVED` tidak boleh sudah mempunyai disbursement effect.

## Boundary

Phase ini tidak membuka execution additional, Offline Expense, correction/
reversal, Deposit, Customer Balance settlement, Purchasing G5, atau jurnal
final G6. Jangan mengubah status request dengan direct table write.

## Next safe step

Jika seluruh `BLOCKER` nol dan setiap `REVIEW` dipahami, desain forward-only
foundation review + Cash/non-Cash additional disbursement dengan optimistic
version, exact idempotency, approval snapshot, drawer isolation, dan Financial
Event `HOLD`.
