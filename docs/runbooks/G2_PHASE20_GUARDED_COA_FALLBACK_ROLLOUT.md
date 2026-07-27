# G2 Phase 20 Guarded COA + Company Fallback Rollout

## Outcome

Membuka tambah/edit/lifecycle Chart of Accounts dan fallback fungsi akun per
Company melalui RPC yang tenant-safe, versioned, dan diaudit. Resolver Finance,
worker, accounting period, dan journal posting tetap nonaktif.

## Evidence Preflight yang Disetujui

- dependency phase 19 `PASS`;
- 36 akun aktif/postable, tanpa duplicate, blank identity, hierarchy cycle,
  postable parent, atau histori jurnal;
- satu `normal_balance` override berstatus `REVIEW` dan valid sebagai akun
  kontra pendapatan;
- 33 category-function belum ter-resolve untuk 24 kategori pada satu Company;
  ini scope fallback/mapping eksplisit, bukan izin menebak akun;
- direct browser write tetap tertutup dan kedua guarded RPC belum ada.

## Urutan Manual Supabase

Jalankan satu file penuh per langkah:

1. `supabase/migrations/20260722230000_g2_phase20_guarded_coa_fallback.sql`;
2. `supabase/diagnostics/g2_phase20_guarded_coa_fallback_postflight.sql`;
3. pastikan tepat **8 PASS** dengan `violation_rows = 0`;
4. `supabase/tests/g2_phase20_guarded_coa_fallback_tests.sql`;
5. pastikan notice test menyatakan COA tenant-safe, hierarchical, versioned,
   audited, dan replacement fallback mempertahankan histori;
6. restart Backoffice dan smoke menu `Kategori & COA`: tambah/edit akun,
   buat versi fallback, tutup modal dengan Escape, dan cek menu existing.

## Guard yang Harus Terbukti

- direct write role `authenticated` tetap ditutup;
- RPC hanya untuk Finance/Accounting/Company Admin/Owner/Super Admin dalam
  Company aktif;
- kode/nama akun unik, parent tenant-scoped/aktif/non-postable/bertipe sama,
  tanpa cycle, dan maksimum tiga tingkat;
- akun yang dipakai rule/fallback aktif tidak dapat dinonaktifkan atau dijadikan
  non-postable;
- account type/function dengan histori jurnal dikunci;
- fallback hanya menerima akun aktif/postable yang compatible;
- versi aktif baru menutup periode lama secara atomic dan diaudit.

## Compatibility

- 26 kategori bawaan, mapping existing, dan satu contra balance override tidak
  diubah;
- 33 missing category-function tidak diisi dengan akun tebakan;
- tidak ada journal, event, stock, payment, checkout, resolver, atau Finance
  worker yang dijalankan.

## Rollback / Forward Fix

Kegagalan sebelum `COMMIT` rollback seluruh migration. Setelah applied, jangan
edit migration ini; gunakan forward migration baru. Jangan menghapus histori
akun/fallback/audit atau menyalakan posting untuk menutupi mapping yang belum
lengkap.

