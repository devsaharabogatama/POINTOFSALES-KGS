# G6 Corrective Phase 7A - Append-Only Journal Reversal Rollout

## Scope

- guarded reversal RPC untuk jurnal `MANUAL` dan `OPENING_BALANCE` yang sudah
  `POSTED`;
- membuat jurnal `REVERSAL` baru dengan debit/kredit terbalik;
- original journal tetap immutable;
- active Company, Finance role, expected version, reason, idempotency, dan
  target Accounting Period `OPEN/REOPENED` divalidasi server;
- satu original journal maksimal memiliki satu reversal;
- snapshot akun original dipertahankan walaupun akun kemudian inactive;
- audit `POST` pada jurnal reversal dan `REVERSE` pada original.

Jurnal `AUTOMATIC`, `PRIOR_PERIOD_ADJUSTMENT`, dan `REVERSAL` tidak dapat
direversal langsung oleh RPC ini. Koreksi operasional harus melalui Return,
Adjustment, source reversal/replacement, atau dokumen koreksi resminya agar
Stock/FIFO/AP/AR dan GL tetap konsisten.

## Urutan manual

1. Jalankan
   `supabase/migrations/20260811090000_g6_phase7_append_only_journal_reversal.sql`.
2. Jalankan
   `supabase/diagnostics/g6_phase7_append_only_journal_reversal_postflight.sql`.
3. Jalankan
   `supabase/tests/g6_phase7_append_only_journal_reversal_tests.sql`.
4. Rerun Phase 7 preflight, Phase 6C/6B closing checks, Phase 5/4/2, dan G1
   security regression.

Expected: seluruh baris non-`INFO` postflight `PASS` dan behavioral test
menampilkan `TEST PASSED`. Behavioral fixture seluruhnya rollback.

## Compatibility

- signature period, posting queue, report, dan reconciliation tidak berubah;
- migration tidak membuat reversal atas jurnal live;
- migration tidak memproses event HOLD atau queue;
- direct browser table writes tetap tertutup;
- Backoffice reversal UI belum dibuka sampai database gate ini PASS.

## Rollback/forward fix

Migration dijalankan dalam satu transaction. Sebelum commit, error menggagalkan
seluruh perubahan. Setelah applied, jangan edit file ini; koreksi memakai
forward-only migration. Existing journal/reversal history tidak boleh dihapus.
