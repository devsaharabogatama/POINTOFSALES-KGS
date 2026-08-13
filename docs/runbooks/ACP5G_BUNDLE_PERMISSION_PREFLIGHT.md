# ACP-5G Bundle Permission Preflight

**Status:** SELECT-ONLY READY — manual Supabase execution pending  
**Gate:** ACP-5G, bagian dari ACP-5 Contacts/Purchase/Sales  
**Permission key:** `sales.bundles`

## Tujuan

Membuktikan boundary Bundle sebelum enforcement tanpa mengubah runtime:

- Backoffice list/detail memakai `VIEW` dan save atomic memakai `MANAGE`;
- Product `STOCK` tetap dimiliki `inventory.products`, sedangkan identitas Bundle,
  sales UOM, dan komposisinya disimpan atomik oleh Bundle;
- Bundle tetap virtual: tidak mempunyai saldo stok, Movement, atau FIFO sendiri;
- availability hanya membaca kapasitas komponen secara sempit dan tidak memberi
  akses Stock Real/Movement umum;
- POS tetap memakai session/Store authority sendiri, melakukan expansion di
  server, dan mengurangi FIFO komponen;
- Sales Return memakai snapshot allocation final tanpa mewarisi hak kelola
  Bundle;
- generic Product import tetap menolak Bundle.

## Yang Tidak Dibuka

- tidak ada DDL, DML, grant, RLS, function, audit, atau UI yang diubah;
- tidak mengubah Product biasa, pricing, checkout, FIFO, Return, atau Finance;
- tidak membuka import/export Bundle;
- tidak mencabut read tabel sebelum semua consumer aktif dipindahkan;
- tidak mengaktifkan enforcement hanya karena `REVIEW`/`SETUP` sesuai desain.

## Cara Menjalankan

Jalankan satu file berikut di Supabase SQL Editor:

`supabase/diagnostics/acp_phase5g_bundle_permission_preflight.sql`

Kirim seluruh output `check_name,status,details`.

- `BLOCKER`: berhenti; data/schema/privilege harus diperbaiki terlebih dahulu.
- `REVIEW`: boundary consumer yang wajib dipertahankan saat enforcement.
- `SETUP`: target implementasi selanjutnya, bukan kegagalan data.
- `PASS`: invariant live sesuai baseline.
- `INFO`: inventaris saja.

## Target Enforcement Setelah Preflight Bersih

1. satu composed RPC Backoffice yang memerlukan `VIEW`;
2. save Bundle + Product identity + sales UOM + komponen tetap satu transaksi dan
   memerlukan `MANAGE`;
3. availability memakai `VIEW` dengan Product/Warehouse/Stock response sempit;
4. POS online tetap melalui session/Store checkout authority sendiri;
5. Return tetap memakai immutable sale allocation;
6. direct SELECT tabel khusus Bundle dicabut setelah UI cutover;
7. behavior menguji preset restriction, tenant isolation, atomic save,
   virtual-stock guard, availability, POS Bundle allocation, dan Return proof.

## Rollback

Preflight ini SELECT-only sehingga tidak memerlukan rollback. Jika ada
`BLOCKER`, jangan membuat atau menjalankan migration enforcement.
