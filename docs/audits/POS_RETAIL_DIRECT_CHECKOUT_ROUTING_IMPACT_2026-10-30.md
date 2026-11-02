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
- Root cause pertama: checkout aktif di `pwa/src/App.tsx` memanggil
  `confirm_pos_sales_order`, sehingga Pickup Retail dipaksa masuk ke jalur
  Reservation dan ditolak oleh `sales_headers_fulfillment_shape_check`.
- Temuan Production setelah client correction: direct finalizer mencapai update
  final, tetapi row hasil migration ODR masih membawa
  `order_runtime_status='DRAFT_INPUT'`. Constraint
  `sales_headers_order_runtime_shape` hanya menerima pasangan Posted dengan
  `LEGACY_POSTED`. Karena finalizer lama tidak memperbarui kedua kolom pada
  update atomik yang sama, client correction saja tidak cukup.

## Impact map

### Root cause downstream terklasifikasi dari Production

- Exact KGS diagnostic membuktikan policy dokumen aktif adalah
  `ALL_POSTED_SALES`. Karena `private.ensure_sales_documents` menerapkan policy
  tersebut pada semua `LIVE_POST`, Pickup POS menghasilkan Delivery Document
  walaupun `sj_required=false`. Ini konflik runtime terhadap keputusan terbaru:
  Pickup POS Retail hanya menghasilkan receipt/Invoice.
- Exact Bawang Bombay `BB` mempunyai Stock `-31`, FIFO positif `0`, kebutuhan
  Draft `1`, Gudang sale-source aktif dengan `allow_negative_stock=true`, dan
  cost basis `1`. Karena unified authority memakai Warehouse, hasil stok yang
  benar adalah negative authorization/allocation, bukan FIFO positif.
- Koreksi Product harus process-aware, bukan mengubah policy Company menjadi
  `DELIVERY_ONLY`: perubahan policy global dapat mengubah Pickup Backoffice yang
  saat ini memakai automatic Delivery Document. Forward fix hanya mengecualikan
  auto-creation untuk `sales_origin='POS'`, process Retail, fulfillment Pickup,
  dan tidak menghapus dokumen historis.

### Direct impact

- Tombol final POS Retail kembali memanggil finalizer Retail langsung.
- Label tindakan menjadi `Selesaikan Transaksi`.
- Pickup membuka receipt dan Invoice, tanpa membaca/menawarkan Surat Jalan.
- Delivery tetap membaca/menawarkan Surat Jalan setelah posting berhasil.
- Forward migration `20261030120000` menambahkan BEFORE UPDATE bridge yang
  hanya mengubah status runtime menjadi bentuk Posted yang sudah diizinkan
  constraint ketika source adalah direct `POS` atau `BACKOFFICE_CUTOVER` yang
  sudah diadopsi ke sesi Retail nyata, process `RETAIL_CONFIRM_INVOICE`, Company
  mode Retail, row masih Draft input/scheduled, dan tidak mempunyai Reservation.
- Forward migration lanjutan `20261030130000` mempersempit consumer policy
  dokumen: direct POS Retail Pickup tidak membuat Delivery Document baru,
  sedangkan Delivery, Backoffice, adopted cutover, existing Delivery Document,
  Invoice dan audit lain tetap mengikuti runtime lama.

### Downstream impact yang dipertahankan

- Pricing, Payment, shortage/negative-stock gate, Stock, FIFO, Movement,
  Financial Event, receipt, retry, dan idempotency tetap dihitung oleh RPC
  canonical server.
- Draft yang gagal karena shortage tetap Draft dan tidak mempunyai efek final.
- Historical/retained Order runtime dan panel Order tidak dihapus atau ditulis
  ulang.
- Backoffice Quotation/Sales Order, Dispatch, Invoice, Payment, dan fulfillment
  tidak diubah.
- Draft `BACKOFFICE_CUTOVER` yang masih detached tetap tidak dapat diposting.
  Compatibility hanya dipertahankan untuk row yang sudah memiliki Session/POS/
  created Session lengkap dan snapshot komersial preserved, sesuai migration
  aktif `20260911120000`.
- Behavior pengganti merekonsiliasi setiap `sale_stock_requirements` terhadap
  jumlah `sale_fifo_allocations.quantity_base` ditambah
  `negative_stock_sale_allocations.shortage_base_qty`. Jalur Stock minus sah
  tidak lagi dipaksa menghasilkan FIFO row palsu.

### Risiko regression

- Retry tidak boleh menggandakan efek final; tetap memakai idempotency key RPC.
- Pickup tidak boleh membuat/memuat Surat Jalan.
- Delivery harus tetap mempunyai Surat Jalan tanpa efek Stock/Finance kedua.
- Company Backoffice tidak boleh diarahkan ke finalizer Retail.
- Draft cutover Retail yang sudah diadopsi tidak boleh terblokir oleh guard
  source, sedangkan draft cutover detached wajib tetap fail-closed.
- Offline dan Order historical tidak boleh terbuka atau diubah diam-diam.

### Belum terbukti

- Migration `20261030120000` sudah terpasang tepat satu kali di Production dan
  bersifat immutable. Migration itu tidak boleh dijalankan ulang.
- Percobaan behavior pertama berhenti sebelum mutation bisnis karena source
  context test melebihi kontrak G1 maksimum 32 karakter dan ditolak dengan
  `INVALID_CONTEXT_SOURCE`. Ini `TEST HARNESS FIX`; migration tidak diubah atau
  diulang. Harness memakai source valid `POS_RETAIL_TEST` dan seluruh assertion
  bisnis tetap sama.
- Percobaan behavior kedua mencapai finalizer lalu membuktikan shape
  `Movement 1 / Event 1 / Payment 1 / Invoice 1 / Delivery 1 / FIFO 0` sebelum
  assertion gagal dan seluruh transaction di-rollback. Ini mencabut instruksi
  rerun behavior. Migration tetap live dan immutable.
- Diagnostic SELECT-only Production sudah membuktikan dua akar masalah:
  KGS memakai `ALL_POSTED_SALES`, sehingga consumer dokumen membuat Delivery
  Document untuk Pickup; dan Bawang Bombay memang wajib memakai Warehouse-
  authorized negative allocation karena Stock/FIFO positif tidak tersedia.
- Forward package `20261030130000` sudah dibuat secara lokal untuk memperbaiki
  hanya boundary dokumen Pickup dan mengganti assertion stok dengan rekonsiliasi
  FIFO plus negative allocation. Seluruh enam baris preflight Production sudah
  kembali sesuai expected: dependency/identity/runtime PASS, state
  `NOT_INSTALLED`, exact conflict `ROOT_CAUSE` tanpa violation, serta boundary
  Finance/Offline kosong. User kemudian mengonfirmasi migration lengkap
  `20261030130000` sukses; migration tersebut sekarang immutable dan tidak boleh
  dijalankan ulang.
- Percobaan pertama diagnostic tersebut tidak dieksekusi karena PostgreSQL
  menolak alias keyword `authorization` saat parse. Ini `TEST HARNESS FIX`,
  bukan perubahan state database. Alias telah diganti menjadi `authz`; file
  lengkap kini lolos parser PostgreSQL sebagai tepat satu statement `WITH` dan
  tetap tidak memuat mutation.
- Closing postflight belum dijalankan.
- Authenticated Production smoke Pickup dan Delivery sesudah database rollout.
- UAT Backoffice sesudah client deploy.
- Client commit `2746746` sudah deployed, tetapi Production Pickup masih gagal
  pada `sales_headers_order_runtime_shape`; klaim fix sebelumnya dicabut.

## Verification dan rollback

- PWA lint: PASS.
- PWA TypeScript/Vite production build: PASS.
- Playwright source/runtime contract membuktikan routing/source saja; test mock
  tersebut tidak memuat constraint Production dan bukan behavioral proof.
- Focused bridge/routing/Backoffice source boundary: `3/3 PASS`.
- Staging compile: `BELUM TERBUKTI`; harness berhenti sebelum SQL karena trusted
  staging CA tidak tersedia dan koneksi dengan normal trust store menolak
  self-signed chain. TLS verification tidak dinonaktifkan.
- Playwright mocked Pickup browser flow: `1/1 PASS`; membuktikan direct Retail
  post, receipt/Invoice, tidak ada `confirm_pos_sales_order`, dan tidak ada
  query/tombol Surat Jalan.
- Database change bersifat forward-only setelah transaksi baru berhasil.
  Sebelum ada transaksi baru, trigger/function dapat dilepas dalam maintenance
  window; sesudahnya gunakan forward fix, bukan rewrite Sale Posted.

Status: `CLIENT DEPLOYED / 20261030120000 DATABASE LIVE / ROOT CAUSE PROVEN /
20261030130000 DATABASE LIVE / BEHAVIOR PASS / POSTFLIGHT PASS / AUTHENTICATED
SMOKE AND UAT PENDING`. Behavior used the exact failed Draft, proved nonzero
downstream effects and retry, and rolled back all fixture mutations.
