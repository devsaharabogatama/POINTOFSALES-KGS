# G2 Phase 19 — Finance History Trigger Forward Fix

## Masalah

Behavioral test phase 18 menemukan PostgreSQL `42703` karena function
`private.trg_g2_guard_finance_master_history()` dipasang pada dua tabel tetapi
mengakses `NEW.account_type` dalam ekspresi gabungan ketika record yang sedang
diubah adalah `transaction_categories`.

Migration phase 18 sudah applied dengan benar. Fixture test rollback dan tidak
meninggalkan data. File migration applied tidak diedit.

## Perbaikan

Forward migration mengganti function yang sama dengan percabangan tabel lebih
dulu:

```text
transaction_categories → akses system_key
chart_of_accounts       → akses account_type
```

Tidak ada perubahan tabel, kategori, mapping, COA, resolver, atau jurnal.

## Urutan Rollout

1. Jalankan
   `supabase/migrations/20260722210000_g2_phase19_finance_history_trigger_fix.sql`.
2. Jalankan
   `supabase/diagnostics/g2_phase19_finance_history_trigger_fix_postflight.sql`.
3. Pastikan seluruh **5 baris** `PASS` dengan `violation_rows = 0`.
4. Jalankan
   `supabase/tests/g2_phase19_finance_history_trigger_fix_tests.sql` dan pastikan
   notice `TEST PASSED`.
5. Jalankan ulang
   `supabase/tests/g2_phase18_required_transaction_categories_tests.sql` dan
   pastikan notice `TEST PASSED`.
6. Restart Backoffice dan smoke menu `Kategori & COA`.

## Forward-fix Note

Migration transactional. Setelah ledger `20260722210000` ada, jangan edit
migration ini. Finance posting tetap disabled.
