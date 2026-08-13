# G6 Corrective Phase 3 Versioned Posting Mapping Preflight

## Tujuan

Mengaudit kontrak source-event dan kesiapan mapping sebelum model debit/kredit
serta expression nominal dibuat. Diagnostic ini memastikan Phase 3 memakai
Transaction Category, System Event, Account Function, rule versi yang disetujui,
dan akun compatible per Company—bukan akun pertama atau nominal tebakan.

Phase 3 belum membuka posting. Seluruh Financial Event `HOLD` dan jurnal yang
sudah ada tidak diubah.

## Cara menjalankan

1. Buka Supabase SQL Editor.
2. Jalankan seluruh file
   `supabase/diagnostics/g6_phase3_versioned_posting_mapping_preflight.sql`.
3. Kirim seluruh output `check_name,status,details`, terutama
   `hold_event_source_amount_contract_inventory` tanpa dipotong.
4. Jangan menjalankan migration posting engine atau retry event `HOLD`.

## Interpretasi

- `BLOCKER`: jangan membuat migration Phase 3 sebelum penyebabnya direview.
- `BACKFILL`: mapping akun required belum tersedia. Ini expected pada baseline
  yang belum mempunyai rule aktif, tetapi jumlahnya menentukan provisioning
  yang harus eksplisit.
- `SETUP`: model posting-line versioned atau snapshot memang belum dibuat.
- `PASS`: invariant existing aman untuk diteruskan.
- `INFO`: inventory konfigurasi; bukan kegagalan.

Khusus `explicit_system_function_account_scope`, resolver mengutamakan tepat
satu akun active/postable bertanda `is_system_account=true` dengan
`system_function_key` identik. Bila akun sistem tidak ada, sole explicit account
boleh dipakai. Jika tetap `BLOCKER`, `unresolved_functions` menampilkan function
key serta jumlah kandidat system/explicit tanpa membuka nama atau saldo akun.

`hold_event_source_amount_contract_inventory` hanya menampilkan system key,
event type, source table, jumlah event, dan nama key JSON nominal. Nilai uang,
source ID, nama Customer/Supplier, serta data bisnis tidak ditampilkan.

## Boundary setelah output

Output akan dipakai untuk mendesain migration Phase 3 yang additive:

- header rule-set versioned, effective-dated, approved, dan audited;
- line debit/kredit dengan expression key yang di-whitelist;
- account resolution tetap memakai canonical `transaction_account_rules` dan
  explicit `company_account_function_fallbacks`;
- mapping missing/ambiguous diarahkan ke exception queue pada Phase 4;
- tidak ada event lama yang diproses sebelum controlled backfill Phase 5.

Jika semua blocker nol, next step tetap review output lalu menulis migration,
postflight, behavioral test, manifest checksum, dan rollout runbook Phase 3.

Jika `explicit_system_function_account_scope=BLOCKER` karena
`systemAccountCount > 1`, jalankan diagnostic fokus
`supabase/diagnostics/g6_phase3_duplicate_system_account_resolution.sql`.
Diagnostic tersebut membandingkan kode/nama kandidat, seed minimum COA asli,
dan aggregate reference history. Jangan memilih akun dari satu contoh kode dan
jangan menonaktifkan/menghapus COA sebelum output ini direview.
