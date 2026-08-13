# G6 Phase 8A — Sale/Return Settlement Mapping Rollout

Phase ini hanya menutup mapping akun settlement yang ditemukan oleh exact
preflight. Ia tidak memproses Event `HOLD` dan tidak membuat jurnal.

Jalankan berurutan di Supabase SQL Editor:

1. `supabase/migrations/20260814100000_g6_phase8a_sale_return_settlement_mapping.sql`
2. `supabase/diagnostics/g6_phase8a_sale_return_settlement_mapping_postflight.sql`
3. `supabase/tests/g6_phase8a_sale_return_settlement_mapping_tests.sql`
4. ulangi `supabase/diagnostics/g6_phase8a_sale_return_posting_preflight.sql`

Expected:

- seluruh row postflight `PASS` atau `INFO`;
- behavioral test mengeluarkan `TEST PASSED`;
- exact preflight berubah menjadi `conditional_account_function_resolution=PASS`;
- `sale_return_posting_runtime` tetap `SETUP` sampai migration runtime berikutnya;
- tidak ada jurnal Sale/Return dan Event tetap `HOLD`.

Forward-fix policy: jangan menghapus fallback yang sudah direferensikan. Jika
kandidat akun kanonis tidak tepat satu, migration sengaja gagal sebelum commit;
perbaiki identitas COA lalu jalankan migration yang sama dari awal.
