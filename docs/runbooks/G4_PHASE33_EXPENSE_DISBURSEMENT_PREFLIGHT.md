# G4 Phase 33 — Expense Disbursement Preflight

## Status

`READY FOR MANUAL PREFLIGHT`

## Tujuan

Mengaudit live state sebelum pencairan Expense Cash/Transfer dibangun. Fase
ini hanya menambahkan diagnostic SELECT-only; tidak mencairkan uang, mengubah
expected drawer, membuat Financial Event, atau membuka jurnal.

Kontrak yang diuji mengikuti `docs/POS_EXPENSE_CASH_FLOW_SPEC.md`:

- hanya Expense `APPROVED` yang dapat masuk proses pencairan;
- Cash harus memakai Cashier Session `OPEN` pada Store yang sama dan membuat
  satu immutable Cash Drawer Movement `OUT`;
- Transfer/QRIS/Card/E-Wallet tidak boleh mengubah drawer;
- setiap retry memakai idempotency key dan hanya menghasilkan satu event;
- nilai `disbursed_amount` merupakan total event append-only;
- pencairan menyimpan snapshot approval dan metode pembayaran;
- expected cash Session harus memasukkan movement Expense Cash;
- Finance Event boleh berada pada boundary `HOLD`; jurnal final tetap G6.

## Cara Menjalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

`supabase/diagnostics/g4_phase33_expense_disbursement_preflight.sql`

Kirim seluruh output `check_name,status,details`. File hanya berisi satu query
`WITH ... SELECT`, tidak menerima parameter, dan tidak menampilkan nama bisnis
atau identitas orang.

## Interpretasi

- `BLOCKER`: data/reference live belum aman; jangan membuat migration
  pencairan sebelum penyebab diselesaikan;
- `SETUP`: kontrak runtime berikutnya memang belum dibangun;
- `PASS`: invariant live aman;
- `INFO`: inventory desain/rollout, bukan kegagalan.

Expected sebelum migration pencairan:

- `canonical_disbursement_routine_state = SETUP`;
- `disbursement_approval_snapshot_state = SETUP`;
- `expense_disbursement_event_enum_state = SETUP`;
- `cashier_expected_cash_disbursement_state = SETUP`;
- tabel `expense_disbursements` masih kosong dan seluruh reconciliation existing
  tetap `PASS`;
- Expense yang baru disetujui dapat muncul pada `approved_expense_inventory`.

`stores_without_noncash` dilaporkan sebagai inventory dan tidak menggagalkan
Cash. Sebaliknya, Store aktif pada Company dengan Expense enabled wajib punya
metode Cash yang eligible karena flow POS Expense Cash termasuk MVP.

## Batas Fase Berikut

Output tanpa `BLOCKER` baru mengizinkan desain migration guarded disbursement.
Migration berikutnya harus transactional, idempotent, immutable, tenant-safe,
dan concurrency-safe. Jangan membuka settlement, Expense Return, Cash In,
Offline Expense, Deposit, final journal G6, atau G5 Purchasing pada Phase 33.
