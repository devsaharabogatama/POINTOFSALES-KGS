# ACP-6B Cash Deposit Permission Enforcement

Permission key: `finance.cash_deposits`.

Urutan manual:

1. Jalankan `supabase/migrations/20260813070000_acp_phase6b_cash_deposit_permission_enforcement.sql`.
2. Restart/reset Backoffice dan PWA agar schema cache dan client terbaru aktif.
3. Jalankan `supabase/diagnostics/acp_phase6b_cash_deposit_permission_postflight.sql`.
4. Jalankan `supabase/tests/acp_phase6b_cash_deposit_permission_tests.sql`.
5. Regression: `supabase/tests/g4_phase43_cash_deposit_foundation_tests.sql`.
6. Regression variance: `supabase/tests/g4_phase46_deposit_variance_resolution_tests.sql`.
7. Smoke Backoffice: buka Finance > Setor Kas, filter/list/detail, lalu approve
   atau reject satu dokumen `SUBMITTED` yang memang disiapkan untuk UAT.
8. Smoke PWA: dari Session Kasir yang sudah `CLOSED`, buat dan submit Setor Kas.
9. Preset `LIHAT_SAJA`: Backoffice tetap dapat melihat list/detail, tetapi
   approve/reject dan operasi channel Kasir harus ditolak server.

Migration ini tidak memproses Financial Event `HOLD`, tidak membuat Journal,
tidak mengubah kebijakan bukti setoran, dan tidak memberikan authority Setor
Kas kepada Deposit Variance. Deposit Variance hanya memperoleh referensi sempit
ke dokumen sumbernya melalui permission key sendiri.
