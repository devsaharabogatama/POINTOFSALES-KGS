# G4 Phase 5 — Cashier Role Inheritance Forward Fix

## Status

`READY FOR MANUAL SUPABASE ROLLOUT`

## Alasan

Authenticated smoke menemukan Super Admin dapat login ke PWA tetapi pilihan
Terminal kosong. PWA dan `open_cashier_session(...)` hanya menerima
`store_memberships.role_code = 'CASHIER'`, sementara kontrak role yang disetujui
menyatakan:

- Super Admin mewarisi aksi Cashier lintas Company;
- Company Owner/Admin mewarisi aksi Cashier dalam Company aktif;
- Cashier biasa tetap wajib mempunyai assignment Store aktif.

Ini adalah forward fix pada authorization Session. Tidak ada perubahan pada
saldo, Movement, FIFO, Sale, Payment, Finance event, atau Session existing.

## Urutan Manual

Jalankan dari Supabase SQL Editor sesuai urutan:

1. `supabase/migrations/20260729080000_g4_phase5_cashier_role_inheritance_fix.sql`;
2. `supabase/diagnostics/g4_phase5_cashier_role_inheritance_postflight.sql`;
3. `supabase/tests/g4_phase5_cashier_role_inheritance_tests.sql`;
4. regression:
   - `supabase/tests/g4_phase2_cashier_session_foundation_tests.sql`;
   - `supabase/tests/g1_security_closure_tests.sql`.

Expected:

- postflight: seluruh `PASS`;
- behavioral test: notice `TEST PASSED`;
- seluruh fixture rollback dan tidak meninggalkan Session/data test.

## Smoke Aplikasi

1. restart Backoffice dan PWA;
2. login PWA menggunakan Super Admin atau Company Owner/Admin;
3. Terminal aktif dalam Company harus tampil tanpa assignment `CASHIER`
   tambahan;
4. Gudang hanya tampil bila aktif, `is_sale_source = true`, dan sesuai Store
   Terminal atau bersifat Company-wide;
5. buka Session dan lanjutkan G4 Phase-5 smoke;
6. untuk Cashier biasa, buat dari `Kontak > User & Akses > Tambah anggota`;
   pilihan Toko sekarang wajib.

## Security Boundary

- ordinary Cashier tanpa Store assignment tetap ditolak
  `ACTIVE_CASHIER_ASSIGNMENT_REQUIRED`;
- inherited role tidak melewati active Company, Terminal aktif, Gudang
  sale-source, satu Session OPEN, maupun RLS;
- service-role tetap hanya berada pada Backoffice server provisioning.

## Forward Fix / Rollback

Migration applied tidak diedit atau dihapus. Jika ditemukan regresi, hentikan
pembukaan Session baru dan buat migration forward yang mengoreksi predicate.
Session yang sudah tercipta tidak boleh dihapus; gunakan close/correction flow
canonical.
