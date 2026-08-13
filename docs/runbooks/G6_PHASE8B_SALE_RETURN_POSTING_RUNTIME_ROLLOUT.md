# G6 Phase 8B — Sale/Return Posting Runtime

Jalankan berurutan:

1. `supabase/migrations/20260814110000_g6_phase8b_sale_return_posting_runtime.sql`
2. `supabase/diagnostics/g6_phase8b_sale_return_posting_runtime_postflight.sql`
3. `supabase/tests/g6_phase8b_sale_return_posting_runtime_tests.sql`

Jika migration `20260814110000` sudah live tetapi behavioral lama berhenti pada
`ACCOUNT_MAPPING_MISSING_OR_AMBIGUOUS`, jalankan forward-fix berikut sebelum
mengulang behavioral:

1. `supabase/migrations/20260814120000_g6_phase8b_runtime_account_mapping_fix.sql`
2. `supabase/diagnostics/g6_phase8b_runtime_account_mapping_fix_postflight.sql`
3. ulangi `supabase/tests/g6_phase8b_sale_return_posting_runtime_tests.sql`

Expected: postflight seluruhnya `PASS/INFO`; behavioral mengeluarkan `TEST
PASSED` lalu `ROLLBACK`. Migration tidak memproses 14 historical Event. Jangan
menjalankan queue lama untuk Sale/Return: queue masih khusus `STOCK_OPENING`.
Setelah hasil dikirim dan bersih, next phase adalah controlled historical
Sale/Return preview/approval/process, lalu rekonsiliasi Journal.

Forward-fix only: jangan menghapus Journal/Event historis. Bila migration gagal,
seluruh transaction rollback; kirim error lengkap sebelum tindakan berikutnya.
