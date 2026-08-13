# ACP-6C Deposit Variance Permission Enforcement

Permission key: `finance.deposit_variances`.

Urutan manual:

1. Jalankan `supabase/migrations/20260813080000_acp_phase6c_deposit_variance_permission_enforcement.sql`.
2. Restart/reset Backoffice agar schema cache dan bundle terbaru aktif.
3. Jalankan `supabase/diagnostics/acp_phase6c_deposit_variance_permission_postflight.sql`.
4. Jalankan `supabase/tests/acp_phase6c_deposit_variance_permission_tests.sql`.
5. Jalankan regression `supabase/tests/g4_phase46_deposit_variance_resolution_tests.sql`.
6. Jalankan ulang postflight ACP-6C.
7. Smoke Backoffice Finance > Selisih Setoran:
   - list dan detail tetap terbuka untuk role view-only;
   - Finance dapat menetapkan penanggung jawab dan membuat resolusi;
   - Owner/Admin selain pembuat dapat approve/reject pengajuan maker-checker;
   - preset `LIHAT_SAJA` tidak dapat melakukan mutation;
   - switch Company tidak membawa exception, actor, atau dokumen sumber.

Migration ini tidak memproses `DEPOSIT_VARIANCE_RESOLUTION` Financial Event
yang masih `HOLD`, tidak membuat Journal, dan tidak memberikan authority Setor
Kas. Riwayat exception, allocation, request, dan audit tetap append-only.
