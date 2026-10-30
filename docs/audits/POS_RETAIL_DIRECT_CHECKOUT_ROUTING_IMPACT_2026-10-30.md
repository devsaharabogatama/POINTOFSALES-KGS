# POS Retail Direct Checkout Routing Impact — 2026-10-30

## Outcome dan keputusan bisnis

Perusahaan dengan `company_sales_process_settings.active_mode =
RETAIL_CONFIRM_INVOICE` memakai checkout Retail langsung. Customer Pickup
mengambil barang dan membayar di kasir; server menyelesaikan Payment, Stock,
FIFO, Movement, Financial Event, receipt, dan Invoice secara atomik. Pickup
tidak membuat Surat Jalan. Pilihan `Perlu dikirim` tetap berada di proses Retail,
tetapi hanya transaksi Delivery yang memuat dokumen Surat Jalan.

Mode `BACKOFFICE_DELIVERED_QTY_INVOICE` tetap memakai domain Quotation/Sales
Order Backoffice. Perubahan ini tidak mengubah tabel, RPC, lifecycle, atau UI
Backoffice.

## Evidence identifier dan execution path

- Switch proses: `company_sales_process_settings.active_mode`, dijaga oleh
  `private.assert_sales_process_root_creation_allowed` pada migration aktif.
- Retail Draft: `save_pos_sale_draft_with_pricelist`.
- Retail finalizer: `post_pos_sale_with_pricelist` melalui `postSale(...)`.
- Receipt: `sales_headers.receipt_snapshot` melalui `loadReceipt(...)`.
- Dokumen Retail: `get_pos_sales_invoice_document`; Surat Jalan hanya dibaca
  ketika `fulfillmentMode === 'DELIVERY'`.
- Backoffice: `backoffice_sales_orders` dan
  `confirm_backoffice_sales_order(...)` tetap terpisah.
- Root cause: checkout aktif di `pwa/src/App.tsx` memanggil
  `confirm_pos_sales_order`, sehingga Pickup Draft tanpa bentuk fulfillment
  Order dipaksa masuk ke jalur Reservation dan ditolak oleh
  `sales_headers_fulfillment_shape_check`.

## Impact map

### Direct impact

- Tombol final POS Retail kembali memanggil finalizer Retail langsung.
- Label tindakan menjadi `Selesaikan Transaksi`.
- Pickup membuka receipt dan Invoice, tanpa membaca/menawarkan Surat Jalan.
- Delivery tetap membaca/menawarkan Surat Jalan setelah posting berhasil.

### Downstream impact yang dipertahankan

- Pricing, Payment, shortage/negative-stock gate, Stock, FIFO, Movement,
  Financial Event, receipt, retry, dan idempotency tetap dihitung oleh RPC
  canonical server.
- Draft yang gagal karena shortage tetap Draft dan tidak mempunyai efek final.
- Historical/retained Order runtime dan panel Order tidak dihapus atau ditulis
  ulang.
- Backoffice Quotation/Sales Order, Dispatch, Invoice, Payment, dan fulfillment
  tidak diubah.

### Risiko regression

- Retry tidak boleh menggandakan efek final; tetap memakai idempotency key RPC.
- Pickup tidak boleh membuat/memuat Surat Jalan.
- Delivery harus tetap mempunyai Surat Jalan tanpa efek Stock/Finance kedua.
- Company Backoffice tidak boleh diarahkan ke finalizer Retail.
- Offline dan Order historical tidak boleh terbuka atau diubah diam-diam.

### Belum terbukti

- Authenticated Production smoke Pickup dan Delivery setelah client deploy.
- UAT Backoffice sesudah client deploy.
- Tidak ada Production mutation atau deployment pada pekerjaan lokal ini.

## Verification dan rollback

- PWA lint: PASS.
- PWA TypeScript/Vite production build: PASS.
- Playwright source/runtime contract: `7/7 PASS`.
- Playwright mocked Pickup browser flow: `1/1 PASS`; membuktikan direct Retail
  post, receipt/Invoice, tidak ada `confirm_pos_sales_order`, dan tidak ada
  query/tombol Surat Jalan.
- Rollback client: kembalikan routing `pwa/src/App.tsx`; tidak ada database
  rollback karena tidak ada migration/schema/data change.

Status: `LOCAL READY / DATABASE RUNTIME ALREADY EXISTS / CLIENT NOT DEPLOYED /
AUTHENTICATED SMOKE AND UAT PENDING`.
