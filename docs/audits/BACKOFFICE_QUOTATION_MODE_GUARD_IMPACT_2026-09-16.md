# Backoffice Quotation Mode Guard Impact — 2026-09-16

## Outcome

Quotation Backoffice tidak lagi membuka editor ketika Company masih memakai
`RETAIL_CONFIRM_INVOICE`. UI membaca `active_mode` server-side, menjelaskan
penyebabnya, dan mengarahkan user ke Pengaturan Sales. Guard database
`SALES_PROCESS_ROOT_CREATION_MODE_BLOCKED` tetap menjadi authority.

## Execution path

- UI: `BackofficeSalesOrderView`.
- API: `GET /api/sales/backoffice-orders/workspace`.
- Authority: `company_sales_process_settings.active_mode`.
- Mutation: `save_backoffice_sales_order_draft` tetap tidak berubah dan tetap
  menolak root Office ketika mode Company bukan Office.

## Impact map

- Direct: read response workspace, tombol Quotation Baru, pesan error dan
  navigasi ke Pengaturan Modul. Cutover API juga meneruskan hanya token error
  domain yang disanitasi agar kegagalan converter tidak lagi berubah menjadi
  `SALES_PROCESS_CUTOVER_OPERATION_FAILED`; SQL/context mentah tetap ditutup.
- Downstream: tidak ada perubahan pada conversion/cutover, existing Quotation,
  SO, Delivery, Invoice, Return, Stock, Reservation, FIFO, Payment, Cashier
  Session, Finance, audit, atau history.
- Compatibility: Company Office tetap dapat membuat Quotation. Company Retail
  tetap dapat membaca histori/dokumen Office yang dipertahankan, tetapi tidak
  dapat membuat root Office baru.
- Tenant/role: active Company tetap berasal dari server; service-role hanya
  dipakai di Route Handler untuk satu read tenant-scoped. RPC writer dan
  permission existing tidak dilemahkan.
- Concurrency/idempotency: tidak berubah; database mode gate tetap memeriksa
  state transaksi saat mutation dijalankan.
- Rollback: revert empat file client/API; tidak ada SQL atau data rollback.

## Verification

- Targeted ESLint: PASS.
- TypeScript `tsc --noEmit`: PASS.
- Next production build: PASS, 85 pages/routes.
- Follow-up cutover error sanitization: targeted ESLint, TypeScript, dan Next
  production build seluruhnya PASS; build menghasilkan 85 pages/routes.
- Production authenticated smoke: wajib setelah client deployment. Pada SMS,
  Apply pergantian proses melalui Pengaturan Sales tetap merupakan langkah
  operasional terpisah; aktivasi feature saja bukan pergantian mode.
