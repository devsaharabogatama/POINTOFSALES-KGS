# ACP-5F Pricelist Permission Preflight

**Status:** SELECT-ONLY READY — manual Supabase execution pending  
**Gate:** ACP-5F, bagian dari ACP-5 Contacts/Purchase/Sales  
**Permission key:** `sales.pricelists`

## Tujuan

Membuktikan boundary Pricelist sebelum enforcement tanpa mengubah runtime:

- Backoffice list/detail memakai `VIEW`, mutation memakai `MANAGE`, dan export
  memakai `EXPORT`;
- Customer assignment tetap dimiliki `contacts.customers MANAGE`;
- kasir tetap dapat memakai Pricelist eligible melalui open Session/Store tanpa
  memperoleh hak kelola Backoffice;
- harga, rule, Customer default, Store eligibility, dan tier tetap diselesaikan
  server-side;
- snapshot Offline tetap memakai entitlement, Terminal policy, dan allowance
  sendiri;
- direct table read baru ditutup setelah Backoffice, POS online, Offline, dan
  Data Exchange berpindah ke API/RPC masing-masing.

## Yang Tidak Dibuka

- tidak ada DDL, DML, grant, RLS, function, audit, atau UI yang diubah;
- tidak mengubah Product base price, Sale snapshot, Tax, discount, payment,
  Offline queue, atau Customer assignment;
- tidak membuka generic Pricelist import;
- tidak mencabut read tabel sebelum semua consumer aktif dipindahkan;
- tidak mengaktifkan enforcement hanya karena `REVIEW`/`SETUP` terlihat sesuai.

## Cara Menjalankan

Jalankan satu file berikut di Supabase SQL Editor:

`supabase/diagnostics/acp_phase5f_pricelist_permission_preflight.sql`

Kirim seluruh output `check_name,status,details`.

- `BLOCKER`: berhenti; data/schema/privilege harus diperbaiki terlebih dahulu.
- `REVIEW`: boundary consumer yang wajib dipertahankan saat enforcement.
- `SETUP`: target implementasi selanjutnya, bukan kegagalan data.
- `BACKFILL`: scope provisioning yang harus ditutup saat implementasi.
- `PASS`: invariant live sesuai baseline.
- `INFO`: inventaris saja.

## Target Enforcement Setelah Preflight Bersih

1. satu composed RPC Backoffice yang memerlukan `VIEW`;
2. guarded save Pricelist/rules/Store scope yang memerlukan `MANAGE`;
3. export Pricelist/rules yang memerlukan `EXPORT`;
4. POS online memperoleh referensi eligible lewat open-session RPC sendiri;
5. Offline catalog snapshot tetap melalui policy/Terminal path yang sudah ada;
6. assignment Pricelist ke Customer tetap melalui Customer management;
7. direct SELECT empat tabel dicabut setelah seluruh consumer aktif cutover;
8. behavior menguji preset restriction, tenant isolation, resolver consistency,
   Customer default, explicit Global override, dan snapshot final Sale.

## Rollback

Preflight ini SELECT-only sehingga tidak memerlukan rollback. Jika ada
`BLOCKER`, jangan membuat atau menjalankan migration enforcement.
