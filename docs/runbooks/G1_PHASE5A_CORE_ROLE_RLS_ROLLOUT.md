# Runbook G1 Fase 5A — Core Role dan RLS

**Migration:** `supabase/migrations/20260720210000_g1_phase5a_core_role_rls.sql`  
**Requirement:** TEN-001, TEN-002  
**Scope:** Profile, Company, Company Membership, Store Membership, Store, POS Terminal, Warehouse.

## Perubahan Keamanan

- Helper role canonical membedakan Super Admin dari role Company tanpa mengubah compatibility helper lama.
- Profile dan membership menjadi read-only dari browser; provisioning tetap melalui workflow server.
- Celah policy lama yang memungkinkan user meng-update row Profile sendiri—termasuk kolom `role`—ditutup.
- Company Admin hanya dapat mutasi Store pada active Company miliknya.
- Store Manager hanya dapat mengelola POS pada Store assignment-nya.
- Store Manager/Warehouse Admin dapat mengelola Warehouse dalam Company karena schema Warehouse belum memiliki Store assignment.
- Cashier hanya melihat Store/POS yang memiliki Store Membership aktif.
- DELETE master tidak diberikan kepada role browser mana pun.

Product, Customer, transaksi, stock document, dan Finance belum diubah dalam fase ini.

## Urutan Manual

1. Pastikan authenticated selector smoke Phase 4 sudah PASS.
2. Jalankan `supabase/diagnostics/g1_phase5a_core_role_rls_preflight.sql`.
3. Semua 3 baris wajib `PASS` dengan `violation_rows = 0`.
4. Ambil backup/export, kemudian jalankan migration `20260720210000...sql` sebagai satu batch.
5. Jalankan `supabase/diagnostics/g1_phase5a_core_role_rls_postflight.sql`; harus 23 baris dan semuanya `PASS`.
6. Jalankan `supabase/tests/g1_phase5a_core_role_rls_tests.sql`; harus menghasilkan notice `TEST PASSED` dan berakhir `ROLLBACK`.
7. Reload Backoffice lokal sebagai Super Admin. Pastikan Company context, daftar Store/Warehouse, staff, Product, dan Stock masih terbaca.

## Stop Condition

- Context menunjuk Company inactive atau normal user tanpa membership: jangan migration.
- Behavioral test gagal membuat fixture `auth.users`: kirim exact error; jangan mengubah schema Auth secara manual.
- Frontend mendapat permission error pada read: catat tabel/request yang gagal; jangan mengembalikan policy `ALL`.
- Jangan lanjut ke transaction/stock/Finance RLS sampai core smoke aman.

## Forward Fix

Policy lama sengaja diganti dalam scope tujuh tabel ini. Setelah migration berhasil, jangan rollback dengan policy broad. Perbaikan dilakukan melalui forward migration berdasarkan role/action yang gagal. Runtime masih lokal + Supabase; Vercel belum diperlukan.
