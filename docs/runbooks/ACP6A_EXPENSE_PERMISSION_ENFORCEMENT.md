# ACP-6A Expense Permission Enforcement

Permission key: `finance.expenses`.

Urutan manual:

1. Jalankan `supabase/migrations/20260813060000_acp_phase6a_expense_permission_enforcement.sql`.
2. Reset/restart Backoffice dan PWA agar schema cache serta bundle client terbaru aktif.
3. Jalankan `supabase/diagnostics/acp_phase6a_expense_permission_postflight.sql`.
4. Jalankan `supabase/tests/acp_phase6a_expense_permission_tests.sql`.
5. Smoke Backoffice: Expense list/detail; approve/reject; pembayaran non-Cash; settlement dan additional review.
6. Smoke PWA dengan open Cashier Session: kategori Expense, pengajuan, pencairan Cash, settlement, return, dan additional Cash.
7. Uji preset `LIHAT_SAJA`: list tetap terbuka, tombol approval/post/cancel hilang dan RPC final ditolak server.

`cash_drawer_movements` dan `cash_in_documents` tetap menjadi shared operational
relations. ACP-6A tidak mengubah Finance `HOLD` dan tidak membuat Journal.

