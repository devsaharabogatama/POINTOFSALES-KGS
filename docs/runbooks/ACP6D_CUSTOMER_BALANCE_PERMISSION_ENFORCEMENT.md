# ACP-6D Customer Balance Permission Enforcement

Permission key: `finance.customer_balances`.

Urutan manual:

1. Jalankan `supabase/migrations/20260813090000_acp_phase6d_customer_balance_permission_enforcement.sql`.
2. Jalankan forward-fix
   `supabase/migrations/20260813100000_acp_phase6d_customer_balance_wind_down_compatibility.sql`.
   Fix ini wajib setelah migration utama: policy `WIND_DOWN` tetap dapat
   diselesaikan oleh role/capability yang sah. Policy `DISABLED` tanpa histori
   tetap tertutup; jika histori sudah ada, hanya `VIEW/EXPORT` yang dipertahankan
   untuk audit dan statement.
3. Restart/reset Backoffice agar schema cache dan bundle terbaru aktif.
4. Jalankan `supabase/diagnostics/acp_phase6d_customer_balance_permission_postflight.sql`.
5. Jalankan `supabase/tests/acp_phase6d_customer_balance_permission_tests.sql`.
6. Jalankan regression `supabase/tests/g4_phase49_customer_balance_foundation_tests.sql`.
7. Jalankan regression `supabase/tests/g4_phase52_customer_balance_sale_credit_tests.sql`.
8. Jalankan regression `supabase/tests/g4_phase56_customer_balance_tender_tests.sql`.
9. Jalankan ulang postflight ACP-6D.

Smoke Backoffice/PWA sengaja ditunda ke closing UAT gabungan sesuai keputusan
user. Status smoke tetap `PENDING`, bukan PASS.

Migration ini memindahkan list/queue/policy/actor ke composed RPC, menjaga
statement dengan `VIEW`, koreksi dengan `MANAGE`, keputusan dengan
`APPROVE/REVIEW`, dan export dengan `EXPORT`. POS overpayment credit serta
Customer Balance tender tetap memakai Sale/open-session authority proven dan
tidak mewarisi authority Backoffice. Financial Event tidak diproses dan
Journal tidak dibuat oleh ACP-6D.
