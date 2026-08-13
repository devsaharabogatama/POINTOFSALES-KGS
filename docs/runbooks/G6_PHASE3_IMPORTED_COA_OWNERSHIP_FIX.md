# G6 Phase 3 Imported COA Ownership Forward Fix

## Outcome

Mempertahankan seluruh COA hasil import sebagai akun milik Company, bukan akun sistem.
UUID, kode, nama, hierarchy, Account Function, status, dan seluruh referensi
historis tidak dihapus atau diganti. Lima akun default bawaan tetap menjadi
system-owned canonical account.

## Urutan manual

Jalankan satu per satu dan berhenti pada error pertama:

1. `supabase/migrations/20260810185000_g6_phase3_company_owned_imported_coa_fix.sql`;
2. `supabase/diagnostics/g6_phase3_company_owned_imported_coa_postflight.sql`;
3. `supabase/tests/g6_phase3_company_owned_imported_coa_tests.sql`;
4. rerun
   `supabase/diagnostics/g6_phase3_versioned_posting_mapping_preflight.sql`.

Expected: seluruh postflight selain inventory `PASS`, behavioral test
menampilkan `TEST PASSED`, dan
`explicit_system_function_account_scope=PASS`. Baru setelah itu rollout
`20260810190000` boleh dimulai.

## Selection boundary

Lima function berikut adalah blocker live yang wajib kembali mempunyai satu
system-owned seed:

- `COGS`: seed `5110`;
- `INVENTORY_ASSET`: seed `1310`;
- `SALES_REVENUE`: seed `4110`;
- `STOCK_GAIN_INCOME`: seed `7110`;
- `STOCK_LOSS_EXPENSE`: seed `6130`.

Migration mempertahankan seluruh 36 seed minimum COA bawaan berdasarkan pasangan
function/code kanonis. Semua row system-owned lain—termasuk kode import seperti
`1010100-1`—diubah menjadi `is_system_account=false`. `system_function_key`
sengaja dipertahankan agar Finance tetap dapat memilih akun Company tersebut
melalui mapping explicit.

## Safety dan rollback

- migration transactional dan membutuhkan Phase 2 serta linked Super Admin;
- Phase 3 mapping harus belum dimulai;
- perubahan before/after dicatat di `finance_master_audit`;
- guard flag lama dinonaktifkan hanya selama table-locked correction dan selalu
  pulih saat commit/rollback;
- trigger baru menolak lebih dari satu system-owned account per
  Company/function;
- tidak ada Financial Event, jurnal, saldo, kode akun, atau UUID yang dimutasi;
- setelah migration commit, koreksi berikutnya harus melalui forward migration,
  bukan rollback destruktif terhadap histori Finance.
