# ACP-5D Purchase Return Permission Preflight

**Status:** SELECT-ONLY READY — manual Supabase execution pending  
**Gate:** ACP-5D, bagian dari ACP-5 Contacts/Purchase/Sales  
**Permission key:** `purchase.purchase_returns`

## Tujuan

Membuktikan boundary sebelum enforcement tanpa mengubah runtime:

- Backoffice Return list/detail memakai `VIEW`;
- Review dan Post menjadi capability terpisah;
- Cashier Draft/Edit tetap dibatasi open session dan Store miliknya;
- cancel milik Cashier tidak berubah menjadi akses Backoffice umum;
- source Receipt, FIFO, Product-UOM, Supplier, Store, dan Warehouse diberikan
  melalui reference yang sempit;
- Return final tetap atomic terhadap Stock, FIFO, Movement, AP adjustment,
  Financial Event HOLD, audit, dan idempotency;
- direct browser read baru ditutup setelah seluruh consumer dipindahkan.

## Yang Tidak Dibuka

- tidak ada schema, grant, RLS, function, data, atau UI yang diubah;
- Goods Receipt, Supplier Order, Supplier Invoice, Supplier Payment, Finance,
  dan jurnal tidak mewarisi permission Return;
- tidak memproses Financial Event `HOLD`;
- tidak membuka posting Return untuk Cashier.

## Cara Menjalankan

Jalankan satu file ini di Supabase SQL Editor:

`supabase/diagnostics/acp_phase5d_purchase_return_permission_preflight.sql`

Kirim seluruh output `check_name,status,details`. Berhenti jika ada
`BLOCKER`; jangan membuat atau menjalankan enforcement sebelum blocker
diselesaikan. `REVIEW` dan `SETUP` adalah inventory desain yang memang
diharapkan sebelum cutover.

## Review Wajib

1. Dependency ACP-5C serta G5 Return chain lengkap.
2. Catalog masih `SHADOW` dengan capability `VIEW`, `CREATE_DRAFT`,
   `EDIT_DRAFT`, `REVIEW`, `POST`, dan `CANCEL_FINAL`.
3. Lima tabel Return tenant-safe, lifecycle/header-line konsisten, dan browser
   tidak memiliki direct write.
4. Empat public mutation RPC tersedia untuk `authenticated`, tertutup untuk
   `anon`, dan belum memakai hook ACP.
5. Backoffice direct read dan PWA composite direct read tercatat sebagai scope
   cutover, bukan dianggap aman untuk langsung dicabut.
6. Draft/nonfinal tidak memiliki final effect; Posted mempunyai FIFO/AP proof;
   cumulative quantity/AP serta Stock–Movement–FIFO tetap rekonsiliasi.

## Target Enforcement Setelah Preflight Disetujui

- composed Backoffice RPC dijaga `VIEW`;
- open-session PWA workspace RPC terpisah dari Backoffice authority;
- Draft/Edit/Review/Post/Cancel dijaga capability yang sesuai tanpa memperluas
  Store atau Company scope;
- active browser consumer dipindahkan sebelum direct SELECT dicabut;
- regression G5 Phase 8, ACP-5B Supplier, dan ACP-5C Supplier Order wajib PASS;
- authenticated preset dan two-Company smoke wajib dilakukan.

## Gate Berikutnya

Hanya setelah enforcement ACP-5D dan smoke user PASS, lanjut ke permission key
berikutnya sesuai roadmap. Jangan sekaligus meng-enforce seluruh Purchase,
Sales, atau Finance.
