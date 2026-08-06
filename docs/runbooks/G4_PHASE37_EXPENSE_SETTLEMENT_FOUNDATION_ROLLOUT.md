# G4 Phase 37 — Expense Settlement Foundation Rollout

## Status

`READY FOR MANUAL DATABASE ROLLOUT`

## Outcome

Foundation ini membuka kontrak database untuk:

- Cashier/Store user mengajukan biaya aktual tanpa langsung mengubah total;
- Store Manager/Finance/Admin mereview actual sebelum menjadi event final;
- actual yang disetujui menjadi detail append-only dan Financial Event `HOLD`;
- return Cash membuat Cash In + drawer `IN` pada Session penerima;
- return non-Cash tidak menyentuh drawer;
- dokumen menghitung `outstanding = disbursed - actual - returned`;
- additional disbursement hanya dibuat sebagai request mengikuti snapshot
  approval dan belum boleh mencairkan uang.

Offline Expense, execution additional disbursement, correction/reversal,
Deposit, dan jurnal G6 tetap tertutup.

## Urutan rollout

Jalankan satu per satu melalui Supabase SQL Editor.

### 1. Migration

`supabase/migrations/20260803100000_g4_phase37_expense_settlement_foundation.sql`

Expected: `Success. No rows returned`.

Migration menolak dependency Phase 34 yang hilang, versi yang sudah applied,
atau settlement/return history yang muncul setelah preflight.

### 2. Postflight

`supabase/diagnostics/g4_phase37_expense_settlement_postflight.sql`

Semua row selain inventory wajib `PASS`; tidak boleh ada `FAIL`.

### 3. Behavioral test

`supabase/tests/g4_phase37_expense_settlement_tests.sql`

Expected notice:

```text
TEST PASSED: reviewed actual is append-only, Cash return reconciles
drawer/outstanding, retry is idempotent, and additional request has zero cash
effect.
```

Semua fixture dan effect test di-rollback.

### 4. Regression

Jalankan:

1. `supabase/tests/g4_phase34_expense_disbursement_tests.sql`;
2. `supabase/tests/g4_phase30_expense_request_approval_tests.sql`;
3. `supabase/tests/g4_phase2_cashier_session_foundation_tests.sql`;
4. `supabase/tests/g1_security_closure_tests.sql`;
5. `supabase/diagnostics/g4_phase37_expense_settlement_postflight.sql`.

Phase 34 wajib dites ulang karena timestamp lifecycle baru diisi trigger dari
RPC disbursement lama. Session/G1 regression memastikan Cash In tidak membuka
direct write atau merusak expected-cash.

## RPC boundary

```text
save_expense_settlement(document, version, actual, evidence, key)
review_expense_settlement(request, version, APPROVE|REJECT, reason)
return_expense_funds(document, version, amount, method, session, evidence, key)
request_additional_expense_disbursement(
  document, version, amount, method, evidence, key
)
```

- actual masih cash-neutral sampai review `APPROVE`;
- reject wajib alasan dan tidak mengubah dokumen;
- Cash return wajib Session `OPEN` Store yang sama;
- non-Cash return wajib Session `null` dan authority Finance/Admin;
- retry exact memakai idempotency key stabil;
- additional request selalu `cashEffect=false` pada fase ini.

## Compatibility

- RPC initial disbursement Phase 34 tidak diubah; trigger baru hanya melengkapi
  `disbursed_by/at` ketika total pertama kali berubah dari nol;
- semua detail approved/return immutable;
- Expense tidak menyentuh stock/FIFO;
- Financial Event tetap `HOLD_UNTIL_G6`, tanpa Journal Entry;
- direct browser write ke request/final event/drawer tetap ditutup.

## Rollback / forward fix

Migration atomic dalam satu transaction. Setelah ledger `20260803100000`
tercatat, jangan edit atau rerun migration. Kesalahan setelah rollout wajib
diperbaiki lewat migration forward-only.

## Checksums

- migration: `d2b7e59a9ccd035b1e87da4cf4422b547bcf425a6a322d9e37344faf4a420c70`
- postflight: `182e89836a593313a027af72fca92a79665d20c97cc6eb8f7d2bf33e95ae51f0`
- behavioral: `05b4e2e47f54e8c04d1028eef973ab555ccf88afff2ad0c49b2974fbc6667fcf`

## Next safe step

Setelah seluruh database gate PASS, buka UI actual/review/return. Jangan membuka
execution additional disbursement sebelum approval/review/disbursement contract
khususnya selesai.
