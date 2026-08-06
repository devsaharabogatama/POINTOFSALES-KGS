# G4 Phase 34 — Expense Disbursement Foundation Rollout

## Status

`READY FOR MANUAL DATABASE ROLLOUT`

## Outcome

Membuka pencairan awal untuk Expense yang sudah `APPROVED` melalui satu RPC
guarded dan server-authoritative:

- nominal pencairan awal selalu sama dengan nominal pengajuan yang disetujui;
- Cash hanya dapat dikeluarkan melalui Cashier Session `OPEN` pada Store yang
  sama dan mengurangi expected drawer tepat satu kali;
- Transfer/QRIS/Card/E-Wallet hanya dapat dikonfirmasi Finance/Company Admin/
  Owner dan tidak mengubah drawer;
- retry dengan idempotency key yang sama mengembalikan hasil yang sama;
- snapshot approval, payment route, account function, COA, category, actor,
  Session, dan evidence disimpan pada event immutable;
- Financial Event dibuat `HOLD`; final journal tetap menunggu G6.

Fase ini hanya mendukung pencairan pertama. Additional disbursement,
settlement biaya aktual, pengembalian uang, Cash In, Offline Expense, dan
Deposit belum dibuka.

## Urutan Rollout

Jalankan satu per satu di Supabase SQL Editor.

### 1. Migration

`supabase/migrations/20260803070000_g4_phase34_expense_disbursement_foundation.sql`

Expected: `Success. No rows returned`.

Migration berhenti tanpa efek jika dependency Phase 30 hilang, migration sudah
tercatat, history pencairan muncul di luar rollout, atau sebagian runtime Phase
34 sudah ada.

### 2. Postflight

`supabase/diagnostics/g4_phase34_expense_disbursement_postflight.sql`

Semua baris selain inventory harus `PASS`. Pada saat ini dua Expense approved
user tetap boleh muncul pada `expense_disbursement_runtime_inventory`; migration
tidak mencairkannya otomatis.

### 3. Behavioral Test

`supabase/tests/g4_phase34_expense_disbursement_tests.sql`

Expected notice:

```text
TEST PASSED: Cash and non-Cash Expense disbursement is approved-only, atomic,
idempotent, drawer-safe, audited, and Finance-HOLD.
```

Seluruh fixture dan effect test di-rollback.

### 4. Regression

Jalankan ulang:

1. `supabase/tests/g4_phase30_expense_request_approval_tests.sql`;
2. `supabase/tests/g4_phase26_sales_return_foundation_tests.sql`;
3. `supabase/tests/g4_phase2_cashier_session_foundation_tests.sql`;
4. `supabase/tests/g1_security_closure_tests.sql`;
5. `supabase/diagnostics/g4_phase34_expense_disbursement_postflight.sql`.

Regression Sales Return dan Session wajib karena Phase 34 memperluas satu
canonical expected-cash calculator, bukan membuat kalkulator terpisah.

## Kontrak RPC

```text
public.disburse_expense(
  document_id uuid,
  master_version bigint,
  cashier_session_id uuid nullable,
  evidence_url text nullable,
  idempotency_key uuid
)
```

- Cash wajib mengirim Session `OPEN` dan drawer harus cukup;
- non-Cash wajib mengirim Session `null`;
- amount dan Payment Method tidak diterima dari client—server mengambil nilai
  approved dari dokumen;
- proof URL wajib HTTPS dan mengikuti `proof_mode` Payment Method;
- stale version ditolak, kecuali retry exact idempotency yang sudah berhasil.

## Compatibility dan Safety

- Tidak ada approved Expense existing yang dicairkan otomatis.
- Request/Submit/Approve/Reject/Cancel Phase 30 tidak berubah.
- Direct browser write ke document, disbursement, drawer movement, dan
  Financial Event tetap ditutup.
- Cash Sale serta Sales Return tetap menjadi bagian expected-cash calculation.
- Expense tidak menyentuh stock/FIFO/Movement.
- Journal Entries tidak dibuat pada fase ini.

## Rollback / Forward Fix

Migration berada dalam satu transaction; error sebelum `COMMIT` rollback
seluruh perubahan. Setelah ledger `20260803070000` tercatat, jangan edit atau
rerun migration. Koreksi wajib memakai migration forward-only dengan preflight,
postflight, test, dan checksum baru.

## Next Safe Step

Setelah migration, postflight, behavior, dan regression seluruhnya PASS, buka
UI pencairan Cash pada PWA dan konfirmasi non-Cash pada Backoffice. Jangan
langsung membuka settlement/return/Cash In dalam UI pencairan Phase 34.
