# PRD-1 Existing User Multi-Company Rollout

**Status:** LOCAL READY — manual Supabase rollout pending

## Outcome

Satu Auth identity dapat diberi membership pada beberapa Company seperti pola
multi-company Odoo. Role tetap ditentukan per Company dan optional Store tetap
tenant-scoped. Selector Company Backoffice yang sudah ada otomatis menampilkan
seluruh membership aktif setelah login ulang/refresh context.

Hanya Super Admin dapat memakai `Tambah akses akun existing`. Lookup memakai
email exact melalui server; browser tidak memperoleh daftar akun global. UUID,
service-role key, dan password tidak dikirim ke UI.

## Urutan Manual

1. Jalankan migration:
   `supabase/migrations/20260812100000_prd_phase3_existing_user_company_assignment.sql`.
2. Jalankan postflight:
   `supabase/diagnostics/prd_phase3_existing_user_assignment_postflight.sql`.
   Semua `FAIL` harus nol.
3. Jalankan rollback-safe behavior:
   `supabase/tests/prd_phase3_existing_user_company_assignment_tests.sql`.
4. Restart Backoffice, login Super Admin, switch ke target Company.
5. Buka `Kontak -> Tim & Akses -> Tambah akses akun existing`.
6. Masukkan email akun yang sudah ada, pilih role khusus Company aktif dan
   optional Store. Kasir wajib mempunyai Store.
7. Login sebagai akun tersebut. Selector Company harus menampilkan kedua
   Company dan mengganti menu sesuai role pada Company yang dipilih.
8. Jalankan kembali
   `supabase/diagnostics/prd_phase2_uat_identity_tenant_postflight.sql`.

## Invariant dan Compatibility

- Satu user dapat memiliki role berbeda pada Company A dan B.
- Default Company existing tidak diubah saat assignment.
- Exact retry tidak menggandakan membership dan tetap diaudit.
- Assignment baru atau perubahan role/Store berlangsung atomically.
- Browser tetap tidak mempunyai direct INSERT/UPDATE/DELETE membership/audit.
- Create-user flow lama tetap tersedia dan tidak berubah.
- Company Admin/Owner tidak mendapat global user search; assignment existing
  lintas Company tetap khusus Super Admin pada v1.

## Rollback / Forward Fix

Migration bersifat additive. Bila UI perlu ditutup, sembunyikan action dan
revoke RPC dari `authenticated`; jangan menghapus membership/audit yang sudah
menjadi bukti akses. Koreksi assignment memakai RPC yang sama atau future
guarded deactivate workflow, bukan direct SQL/browser mutation.
