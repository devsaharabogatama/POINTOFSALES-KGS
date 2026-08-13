# ACP-5A Customer Permission Preflight

## Tujuan

Mengaudit satu key `contacts.customers` sebelum enforcement. Tahap ini hanya
membaca metadata dan agregat. Tidak ada schema, grant, Customer, saldo,
Pricelist, permission override, atau import job yang diubah.

Customer dipisahkan dari tiga authority lain:

- POS quick-create tetap dibatasi active Company, Store, dan Cashier Session;
- Customer Balance/credit tetap memakai workflow Finance dan maker-checker;
- modul Sales/Pricelist/Return hanya menerima reference Customer yang sempit.

## Urutan Eksekusi

1. Buka SQL Editor Supabase menggunakan owner/admin database.
2. Jalankan seluruh isi
   `supabase/diagnostics/acp_phase5a_customer_permission_preflight.sql`.
3. Kirim seluruh baris `check_name,status,details`.
4. Berhenti bila ada `BLOCKER`.

`REVIEW` dan `SETUP` adalah target desain/cutover, bukan izin untuk langsung
menyalakan enforcement. Khusus import `CUSTOMER_CATEGORY`, output harus
menentukan apakah catalog mendapat capability `IMPORT` eksplisit atau import
tetap role-only; `MANAGE` tidak boleh dianggap sama dengan `IMPORT`.

## Expected Sebelum Enforcement

- dependency ACP-4I, catalog, schema, data, tenant, hierarchy, Walk-In, saldo,
  dan direct-write boundary `PASS`;
- composed management read dan capability hook masih `SETUP`;
- direct read, shared consumers, authority split, serta Category import muncul
  sebagai `REVIEW`;
- tidak ada mutation, audit, atau perubahan saldo dari diagnostic ini.

## Setelah Output Direview

Baru buat satu rollout atomic untuk Customer management: guarded composed read,
capability-aware Customer/Category mutation dan export/import yang disetujui,
Backoffice cutover, direct-table read closure, postflight, role/two-Company
behavior, serta regression POS quick-create, Sales, dan Customer Balance.
