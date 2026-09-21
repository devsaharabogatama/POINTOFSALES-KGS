# Manual Finance Journal Rollout

Status: **LOCAL READY**. Urutan ini wajib dijalankan pada target Production yang
sama. Jangan menjalankan migration bila preflight mempunyai `BLOCKER`.

1. Jalankan [preflight](../../supabase/diagnostics/manual_finance_journal_preflight.sql).
2. Pastikan seluruh gate kontrak `PASS`. Baris inventory `INFO` bukan kegagalan.
   Company tanpa eligible COA perlu dikonfigurasi di Master COA sebelum dipakai,
   tetapi tidak menghalangi Company lain.
3. Pastikan tidak ada Finance posting queue aktif dan hentikan mutation Finance
   selama rollout singkat.
4. Jalankan [migration](../../supabase/migrations/20260919120000_manual_finance_journal_runtime.sql) sekali, file penuh.
5. Jalankan [behavioral test](../../supabase/tests/manual_finance_journal_behavior.sql).
   Semua fixture dibatalkan oleh `ROLLBACK`.
6. Jalankan [postflight](../../supabase/diagnostics/manual_finance_journal_postflight.sql).
7. Deploy client Backoffice dari commit yang sama.
8. Authenticated smoke:
   - Finance: buat draft seimbang, edit, submit; tidak dapat approve.
   - Admin/Owner lain: approve dan pastikan jurnal masuk General Ledger.
   - Ulangi request yang sama dan pastikan tidak ada jurnal ganda.
   - Uji stale tab, akun manual dinonaktifkan sebelum approve, periode locked,
     cancel draft/pending, dan reversal posted.
   - Accounting: hanya dapat melihat.
   - Company lain: jurnal dan akun tidak bocor.
9. Tandai `SMOKE PASS` dan `UAT PASS` hanya setelah hasil nyata disimpan.

## Forward-fix

Jangan drop kolom/table atau menghapus jurnal bila runtime sudah dipakai.
Jika migration gagal, transaksi DDL rollback otomatis. Jika defect ditemukan
setelah commit, nonaktifkan pemakaian UI melalui deploy client sebelumnya dan
buat migration forward-fix yang mempertahankan jurnal/audit.
