# Active Development Handoff — KGS POS

### 2026-09-03 — INVENTORY PICKUP HANDOVER LIFECYCLE FIX LOCAL-READY

- Authenticated Backoffice smoke menemukan Pickup legacy berstatus READY gagal
  pada tindakan **Sudah diserahkan** dan API hanya menampilkan
  `SALES_DELIVERY_OPERATION_FAILED`.
- Root cause terkonfirmasi: constraint dari ODR Phase 3A mewajibkan
  `dispatched_at/dispatched_by` pada seluruh delivery document `DELIVERED`,
  padahal approved Pickup legacy tanpa Reservation sah langsung
  `READY -> DELIVERED` dan runtime sengaja tidak menulis marker Dispatch.
- Added SELECT-only preflight, additive forward migration `20260903130000`,
  rollback-safe behavioral test, SELECT-only postflight, dan rollout runbook.
  Perubahan hanya mengganti lifecycle constraint; tidak ada backfill dan tidak
  mengubah Stock, FIFO, Movement, Dispatch allocation, Finance, atau UI.
- Boundary dipertahankan: Pickup linked ODR masih wajib **Keluarkan barang**
  sebelum **Sudah diserahkan**; Delivery tetap dispatch-first; optimistic
  version dan audit DELIVER tetap aktif.
- Evidence lokal: package/static contract check PASS dan `git diff --check`
  PASS (hanya warning normal LF/CRLF). SQL belum dijalankan pada Supabase;
  behavioral test sengaja dapat memakai Pickup READY existing dan seluruh
  mutasinya dibungkus `ROLLBACK`.
- Manual gate: jalankan urutan pada
  `docs/runbooks/INVENTORY_PICKUP_HANDOVER_LIFECYCLE_FIX.md`, stop pada BLOCKER,
  SQL error, atau FAIL. Setelah PASS, hard refresh lalu ulang serah satu Pickup
  legacy dan pastikan tidak ada perubahan stock/finance.

### 2026-09-03 — INVENTORY DELIVERY BULK STATUS UI LOCAL-READY

- Inventory -> Surat Jalan menambah `Kirim terpilih` untuk pilihan Delivery
  READY dan `Tandai terkirim` untuk pilihan Delivery DISPATCHED. Checkbox,
  print/download satuan, ZIP, detail, partial Dispatch, dan Pickup existing
  dipertahankan.
- Bulk tidak menulis tabel langsung dan tidak menambah migration/RPC. Dokumen
  diproses berurutan melalui endpoint satuan canonical; linked Dispatch tetap
  menjalankan Reservation/FIFO/Movement/Finance, sedangkan Received tidak
  memberi stock effect kedua. Legacy row tetap memakai compatibility path.
- Pilihan campuran, Pickup, PARTIALLY_DISPATCHED, permission denial, stale
  master version, dan row tanpa sisa Reservation fail-closed. UI menampilkan
  sukses/gagal per nomor Surat Jalan; efek row sukses tidak diulang atau
  dibatalkan karena row lain gagal.
- Evidence lokal: scoped ESLint PASS; Next.js production build/TypeScript PASS
  (77 pages/routes). Browser visual smoke tidak dapat dijalankan karena koneksi
  browser automation environment gagal dibuka; database/deploy tidak dijalankan.
- Next safe step: deploy/restart Backoffice target, hard refresh, lalu ikuti
  `docs/runbooks/INVENTORY_DELIVERY_BULK_STATUS_UI.md`. Rerun closing postflight
  ODR-6B.2 setelah smoke dan stop pada mismatch Reservation/Stock/FIFO/Movement,
  queue aktif, atau Finance exception.

### 2026-09-03 — SALES ORDER REVISION IDEMPOTENCY FORWARD-FIX LOCAL-READY

- User telah memasang Revision foundation/runtime dan structural postflight
  awal PASS. Authenticated UAT pada Draft replacement nyata gagal saat Confirm
  dengan `IDEMPOTENCY_PAYLOAD_CONFLICT`; revision masih PENDING.
- Root cause terkonfirmasi di composition `confirm_pos_sales_order`: satu public
  operation UUID diteruskan sekaligus ke cancel source dan confirm replacement.
  Demand audit satu sesi mengikat UUID ke `saleId`, sehingga dua Sales aggregate
  berbeda benar-benar konflik. Error berada di runtime, bukan cara pakai user.
- Forward migration `20260903120000` membuat helper private untuk child UUID
  deterministik `CANCEL_SOURCE` dan `CONFIRM_REPLACEMENT`. Revision
  `apply_idempotency_key` dan audit APPLY tetap memakai root UUID; operasi tetap
  satu transaksi dan ordinary non-revision Confirm tidak berubah.
- Added dedicated SELECT-only preflight/postflight, definition-only rollback
  contract test, upgraded combined postflight/test, serta rollout note. Tidak
  ada database/deploy/data operasional yang dijalankan agent.
- Next safe step: jalankan preflight idempotency -> migration 120000 -> contract
  test -> postflight idempotency. Stop pada BLOCKER/SQL error/FAIL. Jika bersih,
  buka Draft revisi yang sama lalu Confirm; attempt sebelumnya rollback atomik,
  jadi tidak perlu membuat revisi baru. Sesudah berhasil, rerun combined
  revision postflight dan cek source canceled, replacement reserved, nomor
  Invoice/SJ berbeda, demand/Payment tidak ganda.

### 2026-09-03 — SALES ORDER REVISION LOCAL-READY

- Approved flow dibekukan di `docs/SALES_ORDER_REVISION_SPEC.md`: hanya Order
  `CONFIRMED/RESERVED`, zero Dispatch, dan tanpa payment `VERIFIED` yang boleh
  direvisi. Revisi membuat Draft replacement; source tetap aktif sampai apply.
- Migration additive `20260903100000` menambah lineage/audit zero-backfill.
  Runtime `20260903110000` membuat Draft dari snapshot tanpa payment, menjaga
  cancel source selama Draft revision pending, lalu mengomposisikan cancel
  source + canonical confirm replacement secara atomik dan exact-retry.
- PWA menambah tombol/modal **Revisi Order**, membuka Draft replacement melalui
  editor Draft canonical, menghitung ulang harga, mempertahankan override price
  saat resume, dan mewajibkan pemeriksaan ulang payment. Eligibility tombol
  berasal dari server sehingga Dispatch, payment VERIFIED, dan revisi PENDING
  tidak menghasilkan aksi palsu. Backoffice Invoice menampilkan linkage
  source/replacement read-only.
- Urutan row-lock pada start/apply/cancel diselaraskan agar cancel source tidak
  dapat menyelinap saat revision dibuat dan cancel Draft tidak deadlock dengan
  Confirm revision.
- Evidence lokal: PWA oxlint PASS dan production build PASS; Backoffice ESLint
  PASS dan production build PASS; `git diff --check` bersih selain warning EOL.
  SQL belum dijalankan terhadap Supabase oleh agent.
- Manual gate: preflight → foundation migration → runtime migration → contract
  test → postflight → deploy staging client → authenticated smoke lengkap pada
  `docs/runbooks/SALES_ORDER_REVISION_ROLLOUT.md`. Production tidak disentuh.
- Compatibility: Confirm/Cancel non-revision tetap memanggil runtime canonical
  sebelumnya; Draft revision tidak membuat Reservation, Invoice/SJ, Stock,
  FIFO, Movement, payment request, Purchasing effect, atau Finance effect.

### 2026-09-02 — STOCK OPNAME REVIEW ENCODING FIX LOCAL-READY

- Review PWA menampilkan mojibake pada panah, pemisah SKU, dan bullet daftar
  produk dilewati karena karakter Unicode tersimpan dengan encoding rusak.
- `StockOpnameModal` sekarang memakai icon `ArrowLeft`, pemisah ASCII, dan
  bullet berbasis elemen CSS sehingga tidak bergantung pada encoding source.
- Evidence lokal: pencarian mojibake pada modal bersih, PWA oxlint PASS,
  production build PASS, dan scoped `git diff --check` PASS. Database serta
  kontrak Stock Opname tidak diubah.

### 2026-09-02 — STOCK OPNAME PARTIAL REVIEW RUNTIME LOCAL-READY

- User menetapkan flow operasional: counter dapat melihat dan mengoreksi
  hitungannya sendiri pada sesi aktif; stok sistem/expected/variance/HPP dan
  hasil sesi lain tetap blind.
- Completion tidak wajib mencakup seluruh Product. Minimal satu line harus
  `COUNTED`; line `PENDING`/`RECOUNT_REQUIRED` hanya dapat dilewati setelah
  konfirmasi eksplisit dan menjadi `SKIPPED`. Nol wajib diinput eksplisit.
- Migration additive `20260902120000` menambah owner-only review RPC, partial
  complete RPC, status/constraint `SKIPPED`, dan posting compatibility. Posting
  tetap membentuk Adjustment hanya dari `COUNTED`; `SKIPPED` tidak mengubah
  Stock, FIFO, Movement, Adjustment, atau Finance. Partial completion juga
  mempunyai exact-retry response agar retry jaringan tidak menggandakan audit
  atau perubahan sesi.
- PWA menambah review screen, daftar jumlah tersimpan, koreksi angka, checklist
  partial submit, dan progress Dihitung/Belum/Dilewati. Backoffice menampilkan
  `SKIPPED` terpisah dan bukan sebagai fisik nol.
- Evidence lokal: PWA oxlint PASS dan production build PASS; Backoffice ESLint
  PASS dan production build PASS. PostgreSQL migration/behavior/postflight
  belum dijalankan agent.
- Manual gate baru: partial-review preflight → migration `120000` → behavioral
  rollback → partial-review postflight → ulang UI/ACP-4G postflight → deploy
  staging clients → authenticated partial-count/Post smoke. Stop pada SQL
  error, `BLOCKER`, atau `FAIL`; Production tidak disentuh.

### 2026-09-02 — STOCK OPNAME NEGATIVE-STOCK FORWARD-FIX LOCAL-READY

- Screenshot behavioral create membuktikan initial POS Opname rollout belum
  UAT-ready: `stock_opname_details_quantity_nonnegative` menolak snapshot
  `system_qty/system_qty_at_start` ketika Product Stock sah berada di bawah nol.
- Root cause ada pada constraint G3 lama, bukan UI atau permission. Runtime
  canonical memang menyalin signed On Hand untuk menjaga variance exact.
- Forward migration `20260902110000` mengganti constraint menjadi physical-only:
  jumlah fisik tetap wajib nonnegative, sedangkan system/expected snapshot boleh
  signed. Tidak ada Stock, FIFO, Movement, Adjustment, atau Finance mutation.
- Ditambahkan preflight, behavioral data-adaptive create/start/count dalam
  `ROLLBACK`, postflight, dan ACP-4G postflight diperbarui agar signed snapshot
  tidak dianggap data rusak.
- Gate manual: compatibility preflight → migration 110000 → behavioral harus
  `TEST PASSED` dan rollback → compatibility postflight seluruh PASS/INFO →
  ulang UI/ACP postflight → baru authenticated staging smoke. Jangan menyebut
  slice UAT-ready sebelum gate ini bersih.

### 2026-09-02 — POS STOCK OPNAME ONLINE UI LOCAL-READY

- User membuka scope UI Stock Opname PWA online; offline secara eksplisit tetap
  ditunda. Audit membuktikan tujuh mutation/detail RPC canonical sudah live,
  tetapi belum ada read contract untuk list/resume sesi setelah refresh.
- Migration additive `20260902100000_pos_stock_opname_online_workspace.sql`
  menambahkan `get_pos_stock_opname_workspace()` yang hanya mengembalikan sesi
  milik actor, status/progress, dan referensi sempit. Payload tidak memuat
  physical/system/expected/variance/difference/FIFO/HPP/nilai.
- Migration juga menambahkan key terminal `STOCK_OPNAME`; Backoffice terminal
  settings dan API allowlist ikut diperbarui.
- PWA menambah lazy modal `StockOpnameModal`: create/edit Draft, scope all/
  category/selected, start, blind count, movement-aware recount, complete,
  cancel, search, dan resume. Input quantity memakai text+numeric keyboard agar
  mouse wheel tidak mengubah angka. Offline button disabled dan tidak ada queue.
- Evidence lokal: PWA oxlint PASS; PWA TypeScript/Vite production build PASS;
  Backoffice ESLint PASS; Backoffice Next.js production build PASS; scoped
  `git diff --check` tidak menemukan whitespace error. PostgreSQL live tidak
  dijalankan agent.
- Manual gate: preflight → migration → fixture-free contract test → POS
  postflight → ACP-4G postflight → deploy staging kedua client → authenticated
  POS/Backoffice smoke. Stop pada SQL error, `BLOCKER`, atau `FAIL`.
- Compatibility: checkout/cart, canonical count mutation, Adjustment posting,
  Stock/FIFO/Movement/Finance, dan direct-table boundary tidak diubah. Jangan
  deploy Production atau membuka Offline Opname sebelum staging smoke bersih.

### 2026-09-01 — INVENTORY SJ ODR DOWNLOAD/PRINT COMPATIBILITY LOCAL-READY

- Reproduksi read-only pada Admin Gudang LSM dan SJ ODR `000042/000043`
  menghasilkan `SALES_DOCUMENT_NOT_FOUND` dari
  `private.acp5e_get_sales_delivery_document_core`; bukan denial permission
  Inventory. Sale ODR masih `DRAFT/RESERVED` secara sengaja, sedangkan Delivery
  immutable sudah `READY`.
- Migration `20260901110000` mengganti hanya dua wrapper Inventory: detail
  membaca snapshot/line Delivery tenant-scoped, dan print menulis audit PRINT
  append-only. Keduanya tetap membutuhkan effective capability
  `inventory.delivery_documents VIEW`.
- API mengenali error legacy `SALES_DOCUMENT_NOT_FOUND`; tidak ada perubahan
  status Order/SJ, Reservation, Stock, FIFO, Payment, Finance, atau snapshot.
- File baru: preflight SELECT-only, migration, behavioral rollback data-adaptive,
  postflight SELECT-only, dan runbook
  `INVENTORY_DELIVERY_ODR_PRINT_COMPATIBILITY.md`.
- Evidence lokal: execution path UI → API → RPC → snapshot/audit ditelusuri;
  scoped ESLint Backoffice PASS; `git diff --check` PASS. PostgreSQL migration
  belum dijalankan agent. CLI sudah dikembalikan ke
  project staging `yjxpddwrjdczuqyixqwi` setelah diagnosis production read-only.
- Manual gate: preflight → migration 110000 → behavioral rollback → postflight
  → deploy/restart Backoffice → hard refresh → Admin Gudang detail, unduh satu,
  print satu, dan bulk download campuran SJ lama/ODR. Stop pada SQL error,
  `BLOCKER`, atau `FAIL`.

### 2026-09-01 — ODR DISPATCH RUNTIME SCHEMA FORWARD-FIX LOCAL-READY

- Keluhan: modal Inventory Dispatch untuk `SJ/2026/08/000031` menampilkan
  `SALES_DELIVERY_OPERATION_FAILED` saat mengirim EGEP 7 dan KMP 4.
- Reproduksi terhadap database sumber di dalam rollback menemukan dua defect
  berurutan pada `private.dispatch_sales_delivery_stock_core_odr3c`: `digest`
  tidak menunjuk `extensions.digest`, serta runtime membaca kolom requirement
  legacy `stock_sku/stock_name` yang tidak ada.
- Migration `20260901100000` mempertahankan signature/kontrak runtime, tetapi
  mengualifikasi digest dan mengambil SKU/nama dari Product canonical melalui
  `stock_product_id`. Tidak ada business-data backfill.
- Exact Dispatch dengan definisi patched berhasil sampai hasil sukses di dalam
  rollback. Migration penuh juga diuji dengan COMMIT diganti ROLLBACK dan exit
  0; database produksi tidak diubah oleh agent.
- API Backoffice mempertahankan domain error yang dikenal dan UI memberi pesan
  operasional. Lint dan production build Backoffice PASS.
- Manual gate: jalankan preflight, migration, behavioral rollback, postflight,
  deploy/restart Backoffice, hard refresh, lalu retry SJ dan closing
  reconciliation. Stop pada SQL error, `BLOCKER`, atau `FAIL`. Runbook:
  `docs/runbooks/ODR_DISPATCH_RUNTIME_SCHEMA_FORWARD_FIX.md`.

### 2026-09-01 — PLATFORM HEALTH OPERASIONAL SUPER ADMIN LOCAL-READY

- Ditambahkan dashboard global **Platform → Health Operasional** yang hanya
  terlihat untuk Super Admin. Dashboard merangkum Company sehat/warning/kritis,
  metrik operasional, dan indikasi tracing tanpa memuat PII atau tindakan
  perbaikan data.
- Migration `20260901090000` hanya membuat RPC read-only
  `get_platform_operational_health()`. Guard Super Admin ditegakkan di database
  dan endpoint API; `anon` tidak memperoleh execute. RPC memakai refresh manual,
  `search_path` terkunci, dan statement timeout 8 detik.
- Tidak ada trigger, polling, auto-fix, backfill, perubahan policy, atau mutation
  POS/Reservation/Stock/FIFO/Purchasing/Payment/Finance. Kegagalan halaman tidak
  menjadi dependency menu atau transaksi lain.
- File baru: preflight SELECT-only, migration, behavioral rollback, postflight
  SELECT-only, API route, komponen UI, serta runbook
  `PLATFORM_OPERATIONAL_HEALTH_DASHBOARD_ROLLOUT.md`. Navigation Platform dan
  Manual Pengguna diperbarui.
- Evidence lokal: Backoffice ESLint PASS; Next.js/TypeScript production build
  PASS dan route `/api/platform/operational-health` terdaftar; static audit tidak
  menemukan trigger atau grant mutation. PostgreSQL parser/live execution belum
  tersedia pada environment agent karena local Supabase tidak berjalan.
- Status tetap `LOCAL READY`: database, deployment, Super Admin smoke, regular
  user denial, dan query-duration evidence masih manual. Urutan aman adalah
  preflight → migration → postflight → behavioral rollback → postflight ulang →
  deploy target yang dipilih user → authenticated smoke.
- Dashboard Company Owner/Admin adalah next-development note saja dan tidak
  diimplementasikan. Jangan menambah auto-fix atau menjalankan production deploy
  tanpa instruksi user.

### 2026-09-01 — MANUAL USER, UAT MATRIX, DAN RISK REGISTER DIPERBARUI

- `docs/MANUAL_PENGGUNA_KGS_POS.md` diselaraskan dengan runtime ODR: Draft tidak
  mempunyai final effect; Confirm membuat Reserved Out; Dispatch mengurangi On
  Hand/FIFO/Movement; Received tidak memberi stock effect kedua; Finance
  verification dan controlled queue terpisah dari pekerjaan kasir.
- Manual juga menambahkan lifecycle cancel/Invoice watermark, batas Return
  terhadap quantity Dispatch, procurement demand/Draft-PO amendment, Stock
  Real On Hand/Reserved/Available, payment verification asynchronous, serta
  batas Offline Order baru yang tetap fail-closed.
- Dokumen baru `docs/USER_UAT_EDGE_CASE_RISK_REGISTER.md` memuat P0 smoke,
  matriks akses/master/pricing/Order/Dispatch/NSC/Purchase/Payment/AR/dokumen/
  Finance, edge case, stop condition, evidence template, dan go/no-go.
- Risk register menyatakan secara eksplisit bahwa NSC runtime sudah terpasang
  tetapi E2E belum dilakukan, 49 negative allocation masih terbuka, full
  authenticated ODR matrix belum mempunyai closure terpadu, deployment dapat
  drift, automatic posting belum boleh diasumsikan aktif, dan checkout Offline
  Order baru masih fail-closed.
- Perubahan ini hanya dokumentasi. Tidak ada schema, data, RPC, client runtime,
  deployment, atau policy Company yang diubah.
- Next safe step: jalankan P0-01 sampai P0-14 pada Company dummy dan deployment
  target. Jika stok minus akan dipakai, NSC-01 sampai NSC-08 wajib PASS sebelum
  pilot diperluas.

### 2026-08-31 — SUPPLIER ORDER RECEIPT PROGRESS LOCAL-READY

- Riwayat Supplier Order sekarang dapat diexpand per PO dan menampilkan SKU,
  Product, UOM order, ordered, received, remaining, progress, jumlah receipt
  final, serta indikator over-receipt bila ada.
- Migration read-only `20260831110000` memperkaya `orderLines` dari
  `get_purchase_supplier_orders()`. Received memakai jumlah
  `goods_receipt_lines.received_base_qty` hanya dari dokumen `POSTED`, sama
  dengan source status PO existing; Draft/Canceled tidak dihitung.
- Tidak ada tabel/kolom/backfill baru dan tidak ada mutation PO, Goods Receipt,
  Stock, AP, atau Finance. Response diberi
  `supplierOrderReceiptProgressVersion=1`; UI fail-closed bila migration belum
  aktif agar tidak menampilkan nol palsu.
- Evidence lokal: scoped dan full Backoffice ESLint PASS; Next.js production
  build + TypeScript PASS (77 static pages); SQL delimiter/contract/static
  no-operational-mutation checks PASS; `git diff --check` tanpa error selain
  warning line-ending existing. Visual authenticated smoke belum dijalankan
  karena browser lokal tidak tersedia pada sesi agent.
- Manual gate: preflight -> migration -> postflight -> behavioral rollback ->
  postflight ulang -> deploy/hard refresh -> smoke Draft/partial/received,
  multi-receipt, export, role denial, dan two-Company. Database/deployment belum
  dijalankan agent.

### 2026-08-31 — PURCHASING DEMAND READ ALIAS FORWARD-FIX LOCAL-READY

- Root cause halaman `Purchase -> Supplier Order` gagal dibuka sudah
  terverifikasi pada `get_purchase_procurement_demands()`: aggregate luar
  memakai `product.name`, sedangkan alias `product` hanya hidup di subquery
  `row_data`.
- Forward migration `20260831100000` mempertahankan response, permission,
  tenant scope, dan seluruh join existing; ordering line saja diperbaiki menjadi
  `row_data.product_name`. Tidak ada backfill/mutation Demand, Request, PO,
  Stock, Reservation, atau Finance.
- Ditambahkan postflight SELECT-only dan behavioral rollback yang benar-benar
  memanggil RPC sebagai aktor dengan effective `purchase.supplier_orders VIEW`;
  test memvalidasi array Demand/line/amendment dan Product projection.
- Manual gate: migration -> postflight -> behavioral -> postflight ulang ->
  hard refresh -> buka PO dan cocokkan Demand Product. Database belum dijalankan
  oleh agent. Rollback dilakukan sebagai forward repair definisi read RPC,
  bukan mengubah data.

### 2026-08-30 — POS ACTIVE ORDER LOCAL SEARCH READY

- Modal `Reserved Out -> Order aktif` sekarang mempunyai search field tetap di
  atas daftar dan memfilter Order aktif serta terjadwal berdasarkan nomor Order,
  nama Customer, atau kode Customer.
- Perubahan murni client-side. Kode Customer memakai payload
  `get_pos_customer_references` yang memang sudah tersedia; tidak ada migration,
  RPC, mutation, Reservation, Stock, Payment, Finance, atau lifecycle yang
  diubah. Field `CustomerOption.code` opsional agar offline cache lama tetap
  kompatibel.
- Empty query mempertahankan seluruh daftar dan urutan existing; hasil kosong
  menampilkan pesan eksplisit. Evidence lokal: PWA oxlint PASS dan production
  TypeScript/Vite build PASS.
- Manual gate: restart/deploy PWA, hard refresh, lalu cari dengan ketiga jenis
  kata kunci dan pastikan expand/cancel/refresh Order tetap sama.

### 2026-08-30 — CLOSED-SOURCE-SESSION CASH ORDER CANCEL FORWARD-FIX LOCAL-READY

- Authenticated smoke migration `20260830110000` menemukan cancel Cash Order
  masih ditolak ketika sesi sumber sudah `CLOSED`, meskipun Kasir mempunyai sesi
  aktif baru. Penyebabnya helper reversal hanya menerima sesi sumber `OPEN`.
- Forward migration `20260830120000` memilih sesi sumber bila masih `OPEN`; jika
  sudah tutup, ia memakai satu sesi `OPEN` milik aktor pada Store yang sama.
  Reversal drawer tetap exact-once, payment audit append-only, dan seluruh
  cancellation composition Reservation/SJ/demand/Invoice tetap sama.
- Sesi sumber `CLOSED` tidak di-update. Tanpa sesi aktif Store yang sama,
  payment `VERIFIED`, atau setelah Dispatch, operasi tetap fail-closed.
- PWA menampilkan pesan operasional, bukan kode mentah. Backoffice menampilkan
  aksi cancel ketika aktor mempunyai sesi aktif Store yang sesuai.
- Files baru: preflight/migration/postflight bertema
  `sales_order_closed_session_cash_cancel`; runbook, gate, README, API/UI error
  mapping, dan handoff diperbarui.
- Manual gate: preflight 120000 -> migration 120000 -> postflight -> deploy/hard
  refresh -> Cash Order pada sesi lama CLOSED + sesi baru OPEN Store sama ->
  cancel -> cek reversal sesi baru, closing lama, Reservation/SJ/Invoice/demand,
  retry, dan negative test tanpa sesi aktif. Database/deployment tidak dijalankan
  agent.

### 2026-08-30 — CONFIRMED ORDER LEAK INTO DRAFT RESUME FORWARD-FIX LOCAL-READY

- Root cause terverifikasi: `list_pos_sale_drafts` legacy hanya memeriksa
  `document_status='DRAFT'`, sedangkan ODR confirmed/reserved sengaja tetap
  memakai document status tersebut sampai Dispatch. Order reserved lalu dibuka
  editor Draft dan repricing mencoba menghapus requirement yang sudah memiliki
  FK reservation line.
- Forward migration `20260830100000` membatasi daftar editable Draft pada
  `DRAFT_INPUT/SCHEDULED` dengan `confirmed_at IS NULL` dan menambah save guard
  sebelum repricing. FK, requirement, Reservation, stock, Invoice, payment, dan
  Finance tidak diubah atau dibackfill.
- PWA menampilkan pesan stabil `CONFIRMED_SALES_ORDER_IMMUTABLE` untuk tab lama,
  bukan pesan FK mentah.
- Evidence lokal: PWA oxlint PASS, TypeScript/Vite production build PASS, SQL
  delimiter dan parentheses seimbang, scoped `git diff --check` tanpa error
  (hanya warning line-ending existing).
- Manual gate menunggu user: preflight -> migration 100000 -> postflight ->
  deploy/restart PWA -> hard refresh -> smoke Draft biasa dan Order reserved.
  Jangan menjalankan delete requirement/reservation atau melonggarkan FK.

### 2026-08-29 - ODR-6D E2E CLOSURE PREFLIGHT LOCAL READY

- User mengonfirmasi closing postflight ODR-6C.2 seluruhnya PASS. Runtime
  payment request masih nol, tetapi seluruh boundary, maker-checker, drawer,
  audit, Event/Journal, queue, dan exception bersih.
- Ditambahkan preflight SELECT-only dan runbook ODR-6D untuk closure gabungan
  POS, Reservation, Dispatch, Purchasing, Payment, Journal, Return, AR,
  two-Company, role, retry, Offline, hard refresh, dan rollback rehearsal.
- Source audit menemukan gap nyata sebelum UAT final: Return dan AR/Collection
  existing masih mensyaratkan Sale legacy `document_status='POSTED'`. Order ODR
  tidak boleh diubah menjadi legacy POSTED karena final effect-nya per Dispatch
  dan perubahan status tersebut dapat menggandakan Stock/Finance.
- Preflight sengaja menghasilkan `BLOCKER` pada tiga consumer contract sampai
  forward-fix additive memakai `sales_dispatch_allocations` serta
  `sales_dispatch_financial_effects` tersedia. Tidak ada migration/data yang
  diubah pada tahap audit ini.
- Evidence lokal: Backoffice ESLint dan production build PASS (77 route/page);
  PWA oxlint serta TypeScript/Vite production build PASS; preflight SELECT-only
  mempunyai parentheses seimbang dan mutation scan nol.
- Next safe step: user menjalankan preflight ODR-6D dan mengirim seluruh output.
  Setelah blocker live terkonfirmasi, pecah forward-fix Return dan AR/Collection
  dengan behavioral/postflight masing-masing; jangan melakukan UAT final dulu.

### 2026-08-29 - ODR-6C.2 FINANCE PAYMENT VERIFICATION UI LOCAL READY

- User mengonfirmasi closing postflight ODR-6C.1 seluruhnya PASS: satu Demand
  aktif/tiga line terbaca, Draft PO dan allocation tetap konsisten, tanpa
  amendment atau violation.
- Backoffice Finance sekarang mempunyai tab `Verifikasi Bayar`. API dan UI
  hanya memakai composed read serta guarded review RPC canonical ODR-5D.
- `VIEW`, `REVIEW`, dan `APPROVE` diperiksa server-side. Maker tidak dapat
  memutuskan request sendiri; mutation membawa optimistic `masterVersion` dan
  idempotency key stabil.
- Verify hanya membuat Event `HOLD`. Posting tetap tindakan terpisah melalui
  controlled Posting Queue; mode Company tidak diubah menjadi automatic.
- Penolakan Cash tetap memerlukan sesi Kasir sumber OPEN agar reversal drawer
  exact-once. Browser tidak memperoleh direct write ke request, Event, atau
  Journal.
- File baru: API route Finance payment verification, panel UI, preflight,
  closing postflight, dan runbook ODR-6C.2. FinanceOperationsView hanya ditambah
  satu tab; flow Finance lain dipertahankan.
- Evidence lokal: Backoffice ESLint PASS; production build/TypeScript PASS (77
  page/route). Migration database tidak ada. Manual gate menunggu preflight,
  deploy/hard refresh, authenticated maker-checker smoke, controlled queue,
  lalu closing postflight.

### 2026-08-29 - ODR-6C.1 PURCHASING DEMAND UI LOCAL READY

- User mengonfirmasi closing postflight ODR-6B.2 seluruhnya PASS. Dua linked
  Delivery tetap `READY`; belum ada Dispatch allocation/effect karena smoke
  operasional belum melakukan Dispatch, bukan karena invariant gagal.
- Backoffice Supplier Order sekarang memuat composed Procurement Demand,
  Product shortage per sesi, managed Stock Request linkage, dan amendment
  reason/delta. Tidak ada direct browser read ke tabel protected.
- Perhitungan sisa request kini memasukkan allocation Draft dan final. Ini
  menutup risiko UI menawarkan PO duplikat untuk quantity yang sudah berada
  pada Draft PO.
- PO final tetap immutable. UI hanya menampilkan amendment; sinkronisasi
  otomatis tetap dibatasi private runtime ke satu Draft PO fully
  allocation-backed.
- Tidak ada migration atau database write baru. Lint dan production
  build/TypeScript PASS (76 page/route). Manual gate menunggu preflight,
  Backoffice deploy, authenticated demand/Draft-PO smoke, lalu closing
  postflight sesuai runbook ODR-6C.1.

### 2026-08-29 - ODR-6B.2 INVENTORY DISPATCH UI LOCAL READY

- User mengonfirmasi ODR-6B reservation/stock read-model gate seluruhnya PASS:
  dua open Reservation dengan 22 base qty terbaca, RPC POS/Stock Overview aman,
  dan seluruh rekonsiliasi Stock/Movement/Reservation bersih.
- Backoffice `Inventory -> Surat Jalan` sekarang memakai canonical composed
  workspace. Linked Delivery mendukung partial/full Dispatch per line melalui
  `dispatch_sales_delivery`; penerimaan memakai
  `confirm_sales_delivery_received` dan tidak memberi stock effect kedua.
- Dokumen historis tanpa Reservation tetap memakai runtime lama. Linked Order
  tidak dapat dibatalkan dari Inventory agar pelepasan Reservation tidak
  melewati kanal Order canonical.
- Tidak ada migration pada tahap UI ini. Preflight dan closing postflight
  SELECT-only baru tersedia khusus runtime terkini yang sudah mencakup event
  Finance ODR-5C; postflight ODR-3C lama tidak boleh dipakai untuk closure ini.
- Evidence lokal: lint PASS, production build/TypeScript PASS (76 page/route),
  dan source-contract scan PASS. Manual gate menunggu preflight, deploy
  Backoffice, authenticated partial/full Dispatch + Received smoke, lalu
  closing postflight sesuai runbook ODR-6B.2.

### 2026-08-28 - ODR-4B SESSION DEMAND RUNTIME LOCAL READY

- User mengonfirmasi ODR-4A migration, corrected behavior, dan closing
  postflight seluruhnya PASS. Tiga relation foundation database-live, RLS dan
  browser boundary aktif, zero backfill terjaga, serta dua Draft PO tetap utuh.
- Migration `20260828160000` local-ready. Confirm/Cancel Sales Order memanggil
  private demand refresh dalam transaksi yang sama dengan reservation dan
  confirmed documents; exact retry memakai audit idempotency per demand sesi.
- Penutupan sesi membekukan identitas demand tanpa menutup rekonsiliasi legal.
  Composed read Purchasing dijaga `purchase.supplier_orders VIEW`; tabel demand
  tetap tidak dapat dibaca/ditulis langsung browser.
- ODR-4B tidak membuat atau mengubah Stock Request/PO dan tidak menyentuh Stock,
  FIFO, Movement, atau Finance. Dua Draft PO lama/18 allocation baru akan
  ditangani di gate sinkronisasi berikutnya setelah migration, postflight,
  behavior, dan postflight ulang ODR-4B seluruhnya PASS.

### 2026-08-28 - ODR-4A PROCUREMENT DEMAND FOUNDATION LOCAL READY

- ODR-4 preflight ulang diterima tanpa `BLOCKER`: dependency, allocation final,
  tenant/session/warehouse, direct-write boundary, dan final-PO immutability
  seluruhnya PASS. Dua Draft PO dengan 18 allocation/2.264 base qty adalah
  mutable planning scope; open reservation shortage nol.
- Migration additive `20260828150000` local-ready. Ia membuat demand header unik
  per sesi, source line unik per reservation, serta audit append-only dengan
  tenant/identity trigger dan tanpa browser access.
- Migration mempunyai guard zero-backfill: bila open shortage muncul setelah
  preflight, rollout berhenti dan tidak menebak backfill. Stock Request manual,
  lima request stok-minus historis, dua Draft PO, seluruh PO final, Stock,
  FIFO, Movement, dan Finance tidak dimutasi.
- Postflight, behavioral rollback, dan runbook tersedia. Next safe step:
  migration -> postflight -> behavior -> postflight ulang. ODR-4B runtime belum
  dibuat dan tidak boleh dijalankan sebelum seluruh gate ODR-4A PASS.
- Behavioral attempt pertama berhenti karena fixture UUID acak lebih dahulu
  ditolak trigger Session scope yang valid, bukan karena migration rusak. Test
  diperbaiki untuk mengharapkan stable error tersebut; quantity CHECK sekarang
  diverifikasi fixture-free pada postflight. Migration tidak perlu diulang.

### 2026-08-28 - ODR-4 PROCUREMENT DEMAND PREFLIGHT LOCAL READY

- User mengonfirmasi migration, behavioral test, dan closing postflight ODR-3C
  seluruhnya PASS. Runtime atomic Dispatch database-live; inventaris nol hanya
  berarti belum ada linked order baru dan bukan kegagalan gate.
- ODR-4 dimulai secara SELECT-only melalui
  `supabase/diagnostics/odr_phase4_procurement_demand_preflight.sql` dan
  `docs/runbooks/ODR4_PROCUREMENT_DEMAND_PREFLIGHT.md`.
- Audit memisahkan Stock Request manual serta request stok-minus historis dari
  target demand baru yang bersumber pada open reservation shortage per sesi.
  Ia juga membuktikan tenant/session/warehouse lineage, allocation existing,
  direct-write boundary, dan guard bahwa hanya Draft PO yang dapat diubah.
- Belum ada schema, data, RPC, permission, Stock Request, Supplier Order, Stock,
  atau Finance yang diubah oleh ODR-4. Next safe step adalah menjalankan
  preflight dan menilai seluruh `BLOCKER`/`REVIEW`; migration belum boleh dibuat
  berdasarkan asumsi live state.
- Run pertama menghasilkan false blocker pada sembilan request line karena
  diagnostic ikut menjumlahkan allocation dua PO `DRAFT`. Check final sekarang
  kembali hanya mencakup `CONFIRMED/PARTIALLY_RECEIVED/RECEIVED`, sedangkan
  allocation Draft dilaporkan sebagai `REVIEW` terpisah untuk input sync ODR-4.
  Tidak ada data live yang diubah oleh koreksi diagnostic ini.

### 2026-08-28 - ODR-3C ATOMIC DELIVERY DISPATCH LOCAL READY

- User mengonfirmasi migration, behavior, dan closing postflight ODR-3B
  seluruhnya PASS: provenance, Confirm-document coverage, linked line,
  historical boundary, zero Stock/Finance effect, dan bypass quarantine bersih.
- Migration ODR-3C local-ready di
  `supabase/migrations/20260828140000_odr_phase3c_atomic_delivery_dispatch.sql`.
  Linked Delivery partial/full Dispatch mengunci order/reservation/Product-
  Warehouse/FIFO, mengurangi On Hand, menambah canonical Sale Movement, serta
  menyimpan immutable allocation dan exact-retry audit dengan quantity identik.
- Negative-stock Dispatch memakai policy/permission version snapshot dari
  Confirm; bundle tetap tidak boleh minus. `DELIVERED` hanya proof dan tidak
  mengurangi stok kedua kali. Delivery historis tidak disentuh.
- ODR-3C tidak membuat Financial Event atau Journal. Postflight/behavior/runbook
  tersedia di `docs/runbooks/ODR3C_ATOMIC_DELIVERY_DISPATCH.md`.
- Verification lokal: delimiter seimbang, finance-write scan kosong, dan
  `git diff --check` PASS. Manual SQL gate masih menunggu user. UI baru belum
  boleh diaktifkan sebelum SQL gate dan authenticated smoke selesai.
- Percobaan rollout manual pertama berhenti pada tahap parse dan otomatis
  rollback karena alias `authorization` dibaca sebagai keyword PostgreSQL.
  Alias tersebut sudah diganti menjadi `authz`; pencarian alias keyword
  serupa, delimiter, dan `git diff --check` kembali PASS. Migration version
  tidak diganti karena ledger maupun perubahan schema belum sempat ditulis.

### 2026-08-28 - ODR-3B CONFIRMED ORDER DOCUMENTS LOCAL READY

- User mengonfirmasi migration, behavior, dan closing postflight ODR-3A
  seluruhnya PASS: schema lengkap, zero backfill, historical Delivery tetap
  unlinked, browser write tertutup, dan Stock/Movement tetap reconciled.
- Audit lanjutan menemukan RPC status Delivery lama masih dapat melakukan
  `DISPATCH` tanpa stock effect. Migration ODR-3B local-ready di
  `supabase/migrations/20260828130000_odr_phase3b_confirmed_order_documents.sql`.
- Confirm order sekarang dirancang atomik dengan immutable `ORDER_CONFIRM`
  Invoice/SJ snapshot serta Reservation linkage. Exact retry memakai dokumen
  yang sama; Cancel sebelum Dispatch menutup linked SJ `READY`. RPC status lama
  menolak linked `DISPATCH` dengan `USE_CANONICAL_DISPATCH_RUNTIME`.
- Tidak ada backfill historical dan migration ini tidak menulis On Hand, FIFO,
  Movement, Payment, Financial Event, atau Journal. Postflight/behavior/runbook
  tersedia di `docs/runbooks/ODR3B_CONFIRMED_ORDER_DOCUMENTS.md`.
- Next safe step setelah manual gate seluruhnya PASS: ODR-3C atomic partial/full
  Dispatch. UI Dispatch baru tetap belum boleh dibuka.

### 2026-08-28 - ODR-3A DELIVERY DISPATCH FOUNDATION LOCAL READY

- User menjalankan ODR-3 preflight: seluruh invariant aktif `PASS`; empat
  `REVIEW` dan tiga `SETUP` adalah gap ODR-3 yang memang direncanakan. Tidak ada
  active Finance queue, Offline submission, reservation aktif, atau kerusakan
  Stock/FIFO/Movement.
- Migration additive local-ready di
  `supabase/migrations/20260828120000_odr_phase3a_delivery_dispatch_foundation.sql`.
  Ia menambah linkage nullable Delivery–Reservation, lifecycle
  `PARTIALLY_DISPATCHED`, counter dispatch, dan
  `sales_dispatch_allocations` immutable dengan RLS/no browser write.
- Historical Delivery tidak dibackfill dan tetap memiliki
  `reservation_id=NULL`. Migration ini tidak membuat Invoice/SJ, tidak mengubah
  On Hand/FIFO/Movement, dan tidak menulis Payment/Financial Event/Journal.
- Evidence lokal: `git diff --check` PASS. Manual gate menunggu migration →
  postflight → rollback-safe behavior → closing postflight sesuai
  `docs/runbooks/ODR3A_DELIVERY_DISPATCH_FOUNDATION.md`.
- Next safe step setelah semua PASS: ODR-3B confirmed-order document snapshot
  dan atomic Dispatch runtime. Jangan mengaktifkan UI Dispatch baru sebelum
  ODR-3B dan smoke terautentikasi selesai.

### 2026-08-28 - ODR-3 DISPATCH PREFLIGHT LOCAL READY

- User mengonfirmasi ODR-2B migration, rollback-safe behavioral test, dan
  closing postflight seluruhnya PASS. Runtime/privilege/audit/reconciliation
  bersih dan behavioral rollback meninggalkan zero reservation row.
- ODR-3 SELECT-only preflight local-ready di
  `supabase/diagnostics/odr_phase3_delivery_dispatch_stock_preflight.sql` dengan
  runbook `docs/runbooks/ODR3_DELIVERY_DISPATCH_STOCK_PREFLIGHT.md`.
- Audit memeriksa dependency ODR-2, Stock/Movement/FIFO, reservation quantity,
  tenant/line Delivery, historical legacy boundary, negative reservation,
  permission/direct-write, confirmed-order Invoice/SJ coverage, commercial ke
  stock-requirement lineage, partial lifecycle, allocation schema, dan tiga
  candidate runtime Dispatch.
- Belum ada schema/mutation ODR-3. Historical `LEGACY_POSTED` Delivery tidak
  akan diberi Stock effect kedua. Next safe step: user menjalankan preflight dan
  mengirim semua output; `BLOCKER` diselesaikan sebelum migration ODR-3.

### 2026-08-28 - ODR-2B ATOMIC RESERVATION RUNTIME LOCAL READY

- User menjalankan corrected ODR-2B preflight: seluruh invariant `PASS`, tiga
  RPC canonical expected `SETUP`, 7 Draft/10 requirement row, On Hand agregat
  `-102`, requested/shortage `399`, dan proyeksi minus maksimum `160`.
- Migration local-ready:
  `supabase/migrations/20260828110000_odr_phase2b_atomic_sales_order_reservation_runtime.sql`.
  Runtime menambahkan guarded Confirm/Cancel/composed read, optimistic version,
  exact retry, advisory Product-Warehouse lock, `Available to Sell = On Hand -
  Reserved Out`, projected-negative policy/permission validation, dan immutable
  reservation audit.
- Confirm hanya membuat reservation. Cancel hanya melepaskan reservation.
  Keduanya tidak menulis On Hand, FIFO, Movement, Invoice, Delivery, Payment,
  Financial Event, atau jurnal; historical POSTED Sale tetap tidak disentuh.
- Verification local: balanced delimiter/parentheses dan `git diff --check`
  PASS. Postflight dan rollback-safe behavioral test tersedia di
  `supabase/tests/odr_phase2b_atomic_reservation_runtime_{postflight,behavior}.sql`.
- Manual migration -> postflight -> behavior -> closing postflight sudah
  dikonfirmasi user seluruhnya PASS. ODR-3 masuk audit SELECT-only.

### 2026-08-28 - ODR-2 RESERVATION PREFLIGHT LOCAL READY

- User mengonfirmasi ODR-1 rerun tanpa `BLOCKER`: Stock/Movement/FIFO,
  Draft zero-effect, Delivery tenant/lineage, procurement allocation, offline,
  Finance queue, dan confirmed-PO immutability seluruhnya PASS.
- Empat `REVIEW` ODR-1 adalah collision expected: Post POS masih final-effect,
  Delivery belum mengonsumsi Stock, document creation masih sesudah POSTED, dan
  request sesi masih bersumber negative-stock. Candidate schema tetap `SETUP`.
- ODR-2 preflight SELECT-only dibuat di
  `supabase/diagnostics/odr_phase2_sales_order_reservation_preflight.sql` dengan
  runbook `docs/runbooks/ODR2_SALES_ORDER_RESERVATION_ROLLOUT.md`.
- Preflight mengaudit dependency, canonical RPC, Draft final effect lengkap,
  snapshot/identity cutover, Scheduled contract, Stock/FIFO, negative allocation,
  browser write boundary, permission catalog, dan candidate reservation schema.
- Belum ada migration/runtime/UI ODR-2 dan database/deployment tidak disentuh.
  Next safe step: jalankan preflight live dan review `BLOCKER/BACKFILL` sebelum
  menulis migration foundation.
- Koreksi preflight run pertama: enam Draft mempunyai
  `sale_stock_requirements`, tetapi tidak mempunyai Payment, Movement, FIFO,
  Financial Event, Invoice, atau Delivery. Requirement adalah derived planning
  snapshot dari save Draft dan merupakan sumber reservation ODR-2, bukan final
  effect. Diagnostic sekarang melaporkannya terpisah sebagai PASS/inventory;
  tidak ada data atau runtime yang diubah.
- User kemudian mengonfirmasi migration, behavioral, dan postflight ulang
  ODR-2A seluruhnya PASS: 3 relation RLS aktif, browser write nol, permission
  SHADOW, reservation backfill nol, histori 40 legacy-posted/2 canceled dan
  Draft 5+1 Scheduled terklasifikasi benar.
- ODR-2B preflight local-ready di
  `supabase/diagnostics/odr_phase2b_atomic_reservation_runtime_preflight.sql`.
  Ia menghitung On Hand minus existing reservation dan memvalidasi shortage
  terhadap policy, warehouse opt-in, izin actor, serta limit. Runtime mutation
  belum dibuat; next safe step menunggu hasil preflight tanpa BLOCKER.
- First live result showed 7 Draft/10 requirement rows, all shortage, aggregate
  On Hand `-102`, and requested/shortage `399`. Preflight limit comparison was
  tightened before runtime work: Company/User negative limit now checks the
  projected negative balance after reservation, not merely the newly requested
  shortage. Corrected rerun kemudian dikonfirmasi user seluruhnya PASS dengan
  proyeksi minus maksimum 160.
- ODR-2A migration first run gagal dengan PostgreSQL `55006` karena backfill
  classification pada `sales_headers` menyisakan deferred constraint-trigger
  events sebelum ALTER constraint kedua. Transaction rollback sebelum ledger.
  Migration asli kini menjalankan `SET CONSTRAINTS ALL IMMEDIATE` setelah
  UPDATE dan sebelum ALTER; business contract/schema target tidak berubah.

### 2026-08-28 - ODR-1 LIVE AUDIT LOCAL READY

- ODR-1 sudah dibuat sebagai audit satu statement SELECT-only di
  `supabase/diagnostics/odr_phase1_order_reservation_dispatch_preflight.sql`.
  Audit tidak mengubah schema, data, Stock, FIFO, Payment, Finance, atau UI.
- Audit memisahkan `BLOCKER` data/invariant dari `REVIEW` collision arsitektur
  expected, `SETUP` schema ODR yang belum ada, dan inventory `INFO`.
- Contract freeze rinci, historical cutover matrix, stable failure code, dan
  manifest ODR-2 ada di `docs/ODR1_LIVE_CONTRACT_AUDIT.md`; runbook manual ada
  di `docs/runbooks/ODR1_ORDER_RESERVATION_DISPATCH_PREFLIGHT.md`.
- Temuan source lokal: POS Post masih memiliki Stock/FIFO final effect;
  Delivery transition belum memiliki Stock effect; automatic documents masih
  bersumber dari Sale POSTED; request sesi otomatis masih khusus negative-stock;
  confirmed Supplier Order tetap immutable. Semua ini expected `REVIEW`, bukan
  alasan memutasi live pada ODR-1.
- Verification lokal: SQL static/catalog review dan `git diff --check` PASS.
  Database/deployment belum disentuh.
- Manual gate: user menjalankan preflight dan mengirim semua hasil. ODR-2 hanya
  boleh dimulai bila tidak ada `BLOCKER`.
- Koreksi setelah run pertama: check allocation awal menghitung allocation dari
  PO `DRAFT`/`CANCELED` sebagai committed quantity sehingga menghasilkan false
  `BLOCKER` pada sembilan request line. Diagnostic sekarang mengikuti guard
  canonical Confirm dan hanya menjumlah PO `CONFIRMED`, `PARTIALLY_RECEIVED`,
  atau `RECEIVED`. Deteksi immutable guard juga membaca private ACP core, bukan
  hanya wrapper public. Tidak ada data atau runtime yang diubah.

### 2026-08-28 - ORDER RESERVATION/DISPATCH ARCHITECTURE DOCUMENTED

- Atas keputusan user, rencana baru dibekukan pada
  `docs/POS_ORDER_RESERVATION_DISPATCH_FINANCE_PLAN.md`; belum ada schema,
  migration, RPC, UI, database, atau deployment yang diubah untuk rencana ini.
- Target: POS tetap satu flow kasir tetapi konfirmasi menghasilkan Sales Order
  + `Reserved Out`; On Hand/FIFO/Movement baru berubah saat SJ `DISPATCHED`.
- Future/active Sales Order keluar dari Draft. Shortage dihimpun per sesi;
  perubahan menyinkronkan demand/Draft PO, sedangkan confirmed PO memakai
  delta/amendment dan tidak pernah diedit diam-diam.
- Dispatch membuat event ekonomi Sale/Inventory/AR; Finance verification membuat
  settlement Cash/Bank/Clearing. Pembayaran sebelum Dispatch adalah advance,
  bukan revenue.
- Implementasi direncanakan enam fase ODR-1—ODR-6. ODR-1 artifact sudah
  local-ready; next safe step adalah live preflight dan review, bukan perubahan
  runtime ODR-2.
- Scheduled TEMPO rollout yang sudah PASS tetap compatibility runtime sampai
  ODR-2 menyediakan konversi controlled dan seluruh regression lulus.

### 2026-08-27 - POS SCHEDULED TEMPO ORDER LOCAL READY

- Migration `20260827154000_pos_scheduled_tempo_order.sql` menambah tanggal
  rencana dan klasifikasi `IMMEDIATE/BACKORDER/SCHEDULED` pada Sale, dengan
  aktivasi operasional berbasis tanggal bisnis Company tanpa cron atau auto-Post.
- Hanya Draft TEMPO yang boleh dijadwalkan. Due date dan tanggal kirim tidak
  boleh mendahului tanggal rencana. Server menolak Post sebelum tanggal aktif.
- Saat Post, Finance memakai timestamp Post aktual; tanggal rencana tetap
  tersimpan untuk referensi order. Draft tetap nol efek final sebelum Post.
- PWA menampilkan badge `Terjadwal`/`Order aktif`, mengizinkan tanggal mendatang,
  dan menonaktifkan tombol Post selama Draft belum aktif. Draft dapat dilanjutkan
  dari sesi baru pada Store yang sama melalui lock/reprice canonical yang sudah ada.
- Evidence lokal: PWA TypeScript/Vite/PWA production build PASS (19 precache
  entries). Database tidak dimutasi dan deployment belum dilakukan.
- Manual gate: preflight → migration → postflight → behavior → authenticated
  smoke sesuai `docs/runbooks/POS_SCHEDULED_TEMPO_ORDER_ROLLOUT.md`.
- Compatibility: Draft lama otomatis `IMMEDIATE`; transaksi non-TEMPO, Offline,
  pricing, Stock, Payment, Finance posting, dan dokumen final tidak diubah.
- User mengonfirmasi preflight, migration, postflight, dan behavior SQL seluruhnya
  PASS pada 2026-08-28. Database rollout selesai; authenticated PWA smoke dan
  deployment client masih menjadi gate tersisa.

### 2026-08-27 - FINANCE F1 PERIOD POLICY AND TEMPO RESUME LOCAL READY

- Migration `20260827090000_finance_period_policy_tempo_resume_fix.sql`
  menambah policy per Company (`MANUAL`/`AUTOMATIC`), immutable audit, dan
  idempotent current/next-month period ensure. Periode `LOCKED` tidak pernah
  direopen otomatis; posting masih `CONTROLLED`.
- Wrapper Draft POS membedakan intent `PRESERVE` dari `CASHIER_SELECTED`.
  Membuka/reprice Draft tidak lagi mengubah source tanggal transaksi. Due dan
  delivery guard membandingkan tanggal bisnis dalam timezone Company.
- Backoffice tab Periode menampilkan switch Manual/Otomatis melalui guarded RPC.
- Evidence lokal: PWA production build PASS; Backoffice Next production build
  PASS (73 routes); database tidak dimutasi.
- Manual gate: jalankan empat SQL sesuai runbook lalu smoke Draft TEMPO
  server-created, backdated, same-business-date due, dan locked-period denial.
- Behavioral test memakai satu statement SELECT-only tanpa temporary relation;
  ini kompatibel dengan SQL Editor yang melakukan commit antar-statement.
- Next safe step setelah user mengonfirmasi F1: F2 Customer Receipt/AR allocation,
  lalu F3 historical collection/advance dan F4 aging/export/posting policy.
- User mengonfirmasi behavioral F1 `same_business_date_validation` PASS untuk
  Company KMS pada business date `2026-08-01`. F2 dimulai dengan preflight
  SELECT-only `finance_customer_receipt_ar_preflight.sql`; migration F2 belum
  dibuat sebelum hasil account/source readiness ini dinilai. User kemudian
  mengonfirmasi semua readiness PASS dengan satu historical receivable KMS
  Rp133.500. Migration `20260827100000` dan postflight kini local-ready;
  event `SALE_PAYMENT` sengaja tetap HOLD sampai posting runtime berikutnya.

### 2026-08-25 - POS CATALOG RESTORE AND COMPACT CART LOCAL READY

- Atas koreksi user, mode Katalog dikembalikan ke baseline sebelum Compact
  (`cc3efab`): halaman kembali scroll normal, Katalog berada di kiri, sedangkan
  satu kolom kanan sticky memuat keranjang vertikal dan seluruh checkout.
  Kategori/Product card memakai CSS baseline; quantity, price override,
  discount, dan hapus tetap langsung pada card keranjang.
- Keranjang Katalog kemudian diringkas tanpa mengubah baseline layout: setiap
  Product menjadi satu baris horizontal berisi nama, quantity/UOM, indikator
  hanya bila harga/diskon berubah, dan tombol `Edit`. Tinggi daftar menampung
  tiga baris pada laptop sebelum scroll. Compact tetap memakai grid tiga kolom
  dan menjadi empat pada lebar >=1180px; mobile tetap satu kolom.
- Pergantian mode tetap tidak mengubah cart, Draft, pricing, maupun checkout.
- PWA oxlint PASS, TypeScript/Vite/PWA production build PASS (19 precache
  entries). Warning chunk >500 kB tetap warning lama non-blocking.
- Browser visual connector gagal tersedia pada environment agent; authenticated
  localhost smoke mode Katalog restored, Compact/modal Edit, Draft reload, dan Post
  masih manual. Tidak ada schema, RPC, Stock, pricing, payment, atau Finance
  contract yang berubah.

### 2026-08-25 - BACKOFFICE GOODS RECEIPT CHANNEL LOCAL READY

- Ditambahkan menu `Purchase → Penerimaan Barang` untuk Owner, Company Admin,
  dan Warehouse Admin. Draft Backoffice tidak membutuhkan sesi Kasir; PWA
  Goods Receipt lama tetap kompatibel.
- Migration `20260825130000_backoffice_goods_receipt_channel.sql` menambah
  permission `purchase.goods_receipts`, channel snapshot `POS/BACKOFFICE`,
  composed workspace RPC, serta guarded Draft/Post/Cancel wrappers. Wrapper
  Post memanggil canonical `post_goods_receipt`, bukan membuat mesin stok baru.
- API Backoffice dan UI mendukung daftar PO receivable, Draft/resume/cancel,
  partial/over receipt, kondisi baik/rusak/ditolak, dan atomic Post.
- Evidence lokal: targeted ESLint PASS; Next.js production build PASS (76 route,
  termasuk tiga route Goods Receipt). Full lint mencapai timeout 120 detik tanpa
  diagnostic sebelum targeted lint dijalankan.
- SQL rollout belum dijalankan. Manual gate: preflight → migration → postflight
  → rollback behavior → authenticated Backoffice smoke. Runbook:
  `docs/runbooks/BACKOFFICE_GOODS_RECEIPT_ROLLOUT.md`.
- Rollout manual kemudian menemukan `draftLines` mengurutkan `line_no` yang
  belum diproyeksikan. Fresh migration diperbaiki dan forward-fix additive
  `20260825131000_backoffice_goods_receipt_workspace_line_no_fix.sql` wajib
  dijalankan sebelum postflight/behavior. Behavioral sekarang memakai fixture
  synthetic penuh dan tidak membutuhkan data frontend/existing.
- User mengonfirmasi forward-fix, postflight, dan behavioral test PASS. Login
  Super Admin berikutnya memperlihatkan navigation catalog runtuh total ketika
  satu resolver mengembalikan `PERMISSION_KEY_NOT_FOUND`. Audit read-only pada
  database yang dipakai `backoffice/.env.local` membuktikan seluruh 15 key
  navigation tersedia, termasuk `purchase.goods_receipts` berstatus ENFORCED.
  Endpoint navigation sekarang fail-closed per menu: hanya key yang tidak dapat
  diresolusikan yang disembunyikan; katalog lain dan Super Admin tidak lagi
  dikosongkan. Error resolver selain missing-key tetap diteruskan. Targeted
  ESLint dan Next production build (73 static pages) PASS. Notice missing-key
  lama juga dibersihkan setelah katalog berhasil dimuat ulang. Database tidak
  dimutasi oleh koreksi client ini; authenticated browser refresh masih manual.

### 2026-08-25 - TERMINAL PRICE OVERRIDE DEPLOYED TO STAGING

- User mengonfirmasi dependency MADS Terminal UI, Pricelist preview, TEMPO,
  migration `20260825120000`, closing postflight, dan behavior seluruhnya
  PASS/INFO pada Supabase staging `yjxpddwrjdczuqyixqwi`.
- Backoffice commit `e769fa2` berhasil dibangun dan dideploy ke project
  `pointofsales-kgs-staging`; alias aktif:
  `https://pointofsales-kgs-staging.vercel.app`.
- PWA commit yang sama berhasil dibangun dan dideploy ke project
  `kgs-pos-pwa-staging`; alias aktif:
  `https://kgs-pos-pwa-staging.vercel.app`.
- Smoke publik PASS: kedua root HTTP 200, manifest PWA HTTP 200, dan endpoint
  pengaturan Terminal tanpa sesi HTTP 401 sebagaimana mestinya. Project/database
  production tidak disentuh oleh deployment ini.
- Manual gate tersisa: login staging, aktifkan override hanya pada satu
  Terminal, verifikasi Terminal OFF tidak menampilkan kontrol, Terminal ON dapat
  edit/reset harga dan Post, lalu cocokkan Invoice, stock/FIFO, event, journal,
  dan exact retry.

### 2026-08-25 - POS TERMINAL PRICE OVERRIDE LOCAL READY

- Point terakhir diimplementasikan sebagai policy per Terminal default OFF,
  bukan permission per kasir. Backoffice Platform dapat menyimpan policy secara
  versioned/audited bersama pengaturan UI Terminal.
- Migration `20260825120000_pos_terminal_price_override.sql` menambah policy
  Terminal serta snapshot harga canonical/final, actor, Terminal, sesi, source,
  dan waktu pada Sale line. Wrapper server memvalidasi Online, Company, Store,
  Terminal aktif, sesi OPEN, actor kasir, dan policy pada Save/Post.
- PWA menampilkan harga Pricelist sebagai default. Saat policy aktif kasir dapat
  edit/reset harga per line; Draft menyimpan dan memulihkan override. Jika
  policy dimatikan ketika Draft masih membawa override, input dikunci dan kasir
  harus meresetnya sebelum Save/Post. Offline tetap menolak override.
- File verifikasi: `pos_terminal_price_override_preflight.sql`, postflight, dan
  behavior rollback-safe. Runbook:
  `docs/runbooks/POS_TERMINAL_PRICE_OVERRIDE_ROLLOUT.md`.
- Evidence lokal: PWA oxlint PASS, PWA TypeScript/Vite production build PASS,
  Backoffice Next.js production build PASS (72 route). User mengonfirmasi
  preflight, migration, dan postflight seluruhnya PASS; database sekarang live dengan
  seluruh 4 Terminal default OFF. User kemudian mengonfirmasi behavior
  rollback-safe PASS. Manual gate tersisa: postflight ulang -> deploy staging -> authenticated two-Terminal
  ON/OFF/Offline/retry reconciliation smoke.

### 2026-08-25 - COMPANY PACK-ONLY UOM CUTOVER OPERATION READY

- Point 4 disiapkan sebagai operasi tenant-scoped, bukan perubahan global:
  `supabase/operations/convert_company_products_to_pack_only.sql`.
- Operasi default PREVIEW dan menerima kode atau UUID Company serta konfirmasi eksplisit
  untuk APPLY. PACK menjadi UOM beli/jual aktif; DUS dinonaktifkan untuk
  transaksi baru tanpa mengubah referensi transaksi historis.
- Relasi Supplier aktif dikonversi dari harga per DUS ke harga per PACK, rule
  Pricelist DUS aktif dipensiunkan, dan referensi berat DUS diskalakan ke PACK.
  DUS sebagai base UOM, Bundle, PACK hilang/harga kosong, atau konversi tidak
  valid menjadi BLOCKER agar data tidak dipaksa.
- Audit Product, Supplier, Pricelist, dan UOM ditulis pada APPLY. Runbook:
  `docs/runbooks/COMPANY_PACK_ONLY_UOM_CUTOVER.md`.
- Local static verification: `git diff --check` PASS. Manual gate menunggu user:
  jalankan PREVIEW pada Company tujuan; APPLY hanya jika seluruh BLOCKER PASS.
- Follow-up UI: editor Product sekarang hanya merender Product-UOM aktif.
  Product-UOM DUS nonaktif tetap tersimpan untuk referensi histori, tetapi tidak
  lagi muncul sebagai kemasan operasional atau pilihan editor.

### 2026-08-25 - TERMINAL PRICE OVERRIDE DECISION DOCUMENTED (SUPERSEDED)

- Catatan keputusan awal ini sudah dilanjutkan oleh implementasi local-ready di
  bagian paling atas. Price override per line menjadi policy Terminal/POS
  default OFF, bukan permission per Cashier.
- Jika Terminal mengizinkan, seluruh Cashier sah pada Terminal itu dapat memakai
  override; harga awal tetap canonical Pricelist dan override eksplisit
  mengalahkan seluruh Pricelist hanya pada line terkait.
- Server wajib memvalidasi policy pada Save/Post serta menyimpan harga resolver
  asal, harga override, actor, Terminal, Session, dan waktu. Master Product-UOM
  dan Pricelist tidak berubah. Scope awal online-only; Offline belum dibuka.
- Rencana lima tahap ditulis di `docs/POS_TERMINAL_PRICE_OVERRIDE_PLAN.md` dan
  dirujuk dari requirement index, POS notes, Pricelist notes, docs router, serta
  root README. Status implementasi terkini mengikuti handoff paling atas.

### 2026-08-25 - POS TEMPO TRANSACTION DATE LOCAL READY

- PWA TEMPO menampilkan tanggal transaksi/order read-only dan jatuh tempo.
  Server mengembalikan `sales_headers.transaction_date` pada hasil Save Draft
  dan daftar Draft sehingga edit ulang tidak membuat tanggal baru.
- Referensi Customer POS memperoleh `credit_limit` dan `credit_term_days`.
  Tenor hanya menyarankan due date; input kasir tetap dapat menggantinya.
- Migration additive `20260825110000_pos_tempo_transaction_date.sql`, postflight,
  authenticated read behavior, dan runbook ditambahkan. Request payload, core
  Save/Post, Finance, dan Offline TEMPO boundary tidak diubah.
- Wrapper Save menjadi `SECURITY DEFINER` hanya untuk membaca kembali tanggal
  Sale setelah core berhasil; `search_path` dipatok, hasil dibatasi active
  Company, execute anon tetap tertutup, dan core tetap mengulang otorisasi.
- Verification lokal: PWA oxlint PASS; TypeScript + Vite/PWA production build
  PASS; SQL transaction/delimiter scan dan `git diff --check` PASS. Build awal
  menemukan fixture Offline belum mengisi dua field Customer baru; fixture kini
  memberi nilai netral karena TEMPO Offline memang tertutup, lalu build ulang
  PASS. Manual gate: migration → postflight → behavior → authenticated TEMPO
  smoke.

### 2026-08-25 - PRICELIST PERCENTAGE TIER UI LOCAL READY

- Backoffice Pricelist kini selalu menawarkan `DISCOUNT_PERCENT` untuk rule
  Global dengan minimum quantity lebih dari satu; sebelumnya opsi hanya tampil
  untuk data percent existing sehingga rule baru tidak dapat dibuat lewat UI.
- Bantuan input dibedakan untuk harga final, potongan nominal, dan persen.
  Estimasi harga akhir tampil langsung dari harga normal Product-UOM; input
  persen tetap dibatasi 0–100.
- Tidak ada perubahan database. API parser, guarded save RPC, resolver POS
  online, dan resolver Offline memang telah mendukung `DISCOUNT_PERCENT`.
  Import Pricelist Distributor tetap memakai harga final absolut dan tidak
  diubah atau menebak persentase.
- File berubah: `backoffice/src/components/PricelistMasterView.tsx`, Manual,
  root README, dan handoff ini.
- Verification: targeted ESLint PASS dan Backoffice production build PASS (72
  routes). Full-repository lint melewati batas 120 detik tanpa diagnostic;
  targeted file lint kemudian PASS. Manual smoke: buat Global tier minimum > 1,
  pilih Diskon persen, simpan, lalu pastikan preview POS dan Draft/Post
  menghasilkan harga yang sama.

### 2026-08-24 - INVENTORY DELIVERY DATE FILTER LOCAL READY

- Inventory > Surat Jalan kini memiliki filter tanggal awal/akhir inklusif dan
  tombol `Semua tanggal`, berdampingan dengan pencarian serta filter status.
- API memvalidasi tanggal dan memanggil overload guarded
  `get_inventory_delivery_documents(date,date)`. Database menyaring tanggal
  efektif `scheduled_at/created_at` dalam timezone Company sebelum limit 500;
  RPC tanpa argumen dipertahankan untuk compatibility.
- Migration `20260824120000_inventory_delivery_date_range_filter.sql`,
  postflight SELECT-only, dan behavioral rollback-safe ditambahkan. User
  mengonfirmasi migration tanpa masalah.
- Backoffice staging berhasil dideploy ke alias
  `https://pointofsales-kgs-staging.vercel.app`; Vercel build PASS (72 route),
  root HTTP 200, dan API tanggal tanpa sesi HTTP 401 JSON. PWA dan seluruh
  project production tidak disentuh. Authenticated smoke rentang tanggal dan
  reset filter masih manual gate user.

### 2026-08-24 - DISTRIBUTOR PRICELIST STAGING DEPLOYED

- Working tree commit `90cc795` dideploy hanya ke dua project staging yang
  terverifikasi: `pointofsales-kgs-staging` (Root Directory `backoffice`) dan
  `kgs-pos-pwa-staging` (Root Directory `pwa`). Project production dan database
  production tidak disentuh; environment variable juga tidak diubah.
- Vercel build Backoffice PASS (Next.js 16.2.10, 72 route) termasuk
  `/api/sales/pricelists/import`. Vercel build PWA PASS; warning chunk utama
  561.09 kB tetap non-blocking dan tidak berubah menjadi build failure.
- Alias aktif: `https://pointofsales-kgs-staging.vercel.app` dan
  `https://kgs-pos-pwa-staging.vercel.app`.
- Smoke publik PASS: kedua root HTTP 200, manifest PWA HTTP 200, serta katalog
  Data Exchange Backoffice tanpa sesi HTTP 401 JSON. Authenticated smoke import
  Pricelist dan PWA login tetap manual gate user.

### 2026-08-24 - DISTRIBUTOR PRICELIST IMPORT LOCAL READY

- Global Data Exchange menerima `.xlsx`/`.csv` Price List Distributor untuk
  Company aktif dan mencocokkan `Kode Produk` ke SKU tanpa UUID.
- COGS/Retail dibaca per PACK lalu Product-UOM aktif diturunkan dengan faktor
  konversi. Agen/SM, Spesial, dan Khusus menjadi Pricelist Customer; tier
  60/100/150 PACK masuk Global default memakai Base-UOM equivalent.
- Migration `20260824100000_distributor_pricelist_import.sql` menambah IMPORT
  capability, guarded preview/apply atomik, immutable evidence, exact replay,
  serta Product/Pricelist audit tanpa menyentuh transaksi/Stock/Finance.
- UI, API, parser XLSX memakai `fflate` existing, postflight, behavioral test,
  runbook, Manual, Gate, dan README telah ditambah.
- Final review memisahkan capability `IMPORT` dari wrapper interaktif
  `MANAGE`: RPC memakai core transactional yang sudah dikarantina setelah dua
  guard IMPORT lolos. Katalog/API juga mensyaratkan IMPORT Pricelist sekaligus
  Product. UOM jual PACK ambigu dan profil harga target nonaktif kini memblokir
  Apply dengan pesan eksplisit, bukan memilih/mengaktifkan data diam-diam.
- SKU yang tidak ditemukan pada Company aktif kini berstatus `SKIPPED` dan
  tidak memblokir SKU valid lain. Apply tetap diblokir bila tidak ada satu pun
  SKU cocok atau terdapat error nilai/UOM pada Product yang ditemukan.
- Base migration ternyata sudah dipasang user sebelum keputusan SKIP. Karena
  itu dibuat forward-fix terpisah
  `20260824110000_distributor_pricelist_missing_sku_skip.sql`; base migration
  tidak boleh dijalankan ulang. Postflight kini membuktikan ledger dan source
  contract forward-fix tersebut.
- Evidence lokal: targeted ESLint PASS; TypeScript `--noEmit` PASS; Next
  production build PASS (72 static/dynamic routes); SQL delimiter/parentheses
  seimbang dan targeted `git diff --check` PASS.
- Manual gate: migration → postflight non-INFO PASS → behavioral tanpa
  exception → deploy staging → smoke satu file kecil per Company. Database dan
  deployment belum disentuh agent.

### 2026-08-21 — PRODUCT-UOM CONTEXT TEMPLATE AND JOB CANCEL LOCAL READY

- User mengoreksi UX additive Product-UOM: template placeholder satu baris
  tidak menjelaskan Base/UOM existing dan Export Data identik dengan template
  kosong. Target baru menampilkan semua UOM existing sebagai `REFERENCE`, urut
  faktor, lalu satu `INPUT` kosong di bawah setiap Product.
- Migration `20260821100000_product_uom_context_template_job_cancel.sql`
  mengganti dua read RPC, menambah guarded cancel RPC/core, menutup invalid
  Product-UOM validation secara otomatis, dan mengaudit cleanup job
  Product-UOM lama berstatus UPLOADED/MAPPED/VALIDATED/READY.
- API staging mengabaikan REFERENCE row server-side. UI menjelaskan row_mode,
  memberikan custom confirmation **Batalkan job**, dan best-effort cancel jika
  create/stage/validation request berhenti sebelum preview selesai.
- Riwayat Import memanggil guarded stale cleanup: job milik actor yang tetap
  UPLOADED/MAPPED lebih dari 15 menit otomatis CANCELED dan diaudit; VALIDATED,
  PROCESSING, job user lain, serta job Company lain tidak disentuh.
- Postflight SELECT-only, rollback behavioral test, runbook, Manual Pengguna,
  Gate, dan README telah ditambahkan/diperbarui.
- Behavioral test mencakup invalid-validation auto-cancel, cancel manual, dan
  cleanup job tanpa validasi yang melewati 15 menit. Cleanup memeriksa ulang
  permission efektif per jenis import sebelum menutup job.
- Evidence lokal: targeted ESLint PASS; Backoffice production build/TypeScript
  PASS (70 route/page); SQL dollar delimiter dan parentheses seimbang;
  `git diff --check` PASS. Database migration belum dijalankan.
- Manual gate: migration -> postflight PASS -> behavior sukses/ROLLBACK ->
  deploy staging -> smoke reference/input, valid commit, invalid auto-cancel,
  dan cancel manual. Jangan deploy client sebelum migration berhasil.
- Live postflight pertama menemukan dua false negative source-text pada
  `product_uom_reference_input_contract` dan
  `stale_unvalidated_cleanup_contract`; seluruh routine presence, privilege,
  ledger, serta invalid-validation auto-cancel PASS dan inventory nonterminal
  nol. Diagnostic diperbaiki untuk memeriksa `pg_proc.prosrc` lowercase alih-alih
  format hasil `pg_get_functiondef`. Migration/runtime tidak berubah dan tidak
  perlu dijalankan ulang; hanya postflight yang perlu diulang.
- Setelah user mencoba file berisi banyak perubahan, ditemukan interpretasi
  bisnis yang salah: migration awal membatalkan seluruh job bila satu baris
  invalid, sehingga semua baris valid tidak pernah dapat di-commit. Forward-fix
  `20260821110000_product_uom_partial_validation_restore.sql` mengembalikan
  kontrak partial preview/commit: valid tetap disimpan, error tetap dapat
  diunduh. Auto-cancel hanya untuk job UPLOADED/MAPPED yang ditinggalkan; cancel
  manual tetap tersedia. CSV user dapat di-upload ulang tanpa diisi ulang.
- Regression Product-UOM lama diselaraskan dengan template REFERENCE/INPUT dan
  sekarang membuktikan satu update valid tetap committed walau file yang sama
  mempunyai satu row invalid. Forward migration, postflight, dan behavioral
  test baru masih menunggu user rollout; database tidak diubah dari repo.
- File nyata user kemudian menunjukkan seluruh INPUT mempunyai faktor/izin/
  harga/berat tetapi `uom_name` kosong. Validator existing menganggapnya blank
  placeholder sehingga preview menghasilkan 0 create, 0 update, 0 error. API
  staging sekarang menolak kondisi setengah terisi dengan
  `PRODUCT_UOM_NAME_REQUIRED` beserta nomor baris; INPUT yang seluruh kolom
  mutasinya kosong tetap sah sebagai placeholder. Barcode turunan yang sama
  dengan Base dan faktor turunan <=1 tetap ditangani validator canonical.
- Evidence koreksi UI/API: targeted ESLint PASS; Next production build dan
  TypeScript PASS (70 route/page). Database dan deployment belum disentuh.
- Error export nyata berikutnya membuktikan mayoritas commit gagal karena
  barcode INPUT menyalin barcode Base UOM. API sekarang membandingkan barcode
  INPUT terhadap seluruh REFERENCE dan INPUT dalam template sebelum staging;
  pasangan berbeda ditolak dengan `PRODUCT_UOM_BARCODE_CONFLICT` dan nomor
  baris. Detail `message` dari `*_COMMIT_FAILED` kini ikut tampil/terunduh agar
  constraint database tidak lagi disamarkan sebagai error generik.

### 2026-08-20 — SELECTED SUPPLIER ORDER EXPORT LOCAL READY

- Supplier Order Backoffice sekarang memfilter daftar, menyediakan checkbox
  per PO, pilih-semua hasil filter, indikator jumlah, dan export XLSX gabungan
  hanya untuk dokumen yang dipilih. Batas satu workbook adalah 100 PO.
- Migration `20260820130000_selected_supplier_order_export.sql` menambah
  overload UUID-array yang memvalidasi effective EXPORT, active Company,
  pilihan nonkosong, UUID/duplikasi, batas, dan tenant setiap PO. Signature
  export tanpa argumen serta endpoint GET lama tetap dipertahankan.
- XLSX tetap tiga sheet: Daftar PO, Detail Barang, dan Informasi Export.
  Filter hanya mengubah daftar yang terlihat; perubahan filter membersihkan
  pilihan agar admin tidak mengekspor PO tersembunyi tanpa sadar.
- File verifikasi: SELECT-only postflight, rollback behavioral test, dan
  `docs/runbooks/SELECTED_SUPPLIER_ORDER_EXPORT_ROLLOUT.md`.
- Evidence lokal: targeted ESLint PASS; Next production build PASS (70
  route/page); SQL delimiter dan parentheses seimbang; `git diff --check` PASS.
  Database migration, deployment, dan authenticated smoke belum dijalankan.
- Next safe step: user menjalankan migration -> postflight seluruh PASS ->
  behavior sukses/ROLLBACK -> staging smoke dua PO terpilih. Jangan deploy UI
  ke environment yang belum menerima migration.
- Behavioral fixture correction: database target tidak mempunyai kombinasi
  Owner/Admin aktif pada Company yang berisi PO. Test kini mencoba kombinasi
  tersebut lebih dahulu lalu memakai linked Super Admin dan Company aktif yang
  mempunyai PO. Runtime migration dan aplikasi tidak berubah.
- User mengonfirmasi behavioral test terkoreksi sukses. Backoffice kemudian
  dideploy menggunakan project ID eksplisit hanya ke
  `pointofsales-kgs-staging`; Vercel Next build PASS (70 route/page) dan alias
  `https://pointofsales-kgs-staging.vercel.app` memberi HTTP 200.
- PWA dideploy terpisah menggunakan project ID eksplisit hanya ke
  `kgs-pos-pwa-staging`; TypeScript/Vite/PWA build PASS (19 precache entries)
  dan alias `https://kgs-pos-pwa-staging.vercel.app` memberi HTTP 200. Warning
  chunk >500 kB tetap non-blocking. Tidak ada project, environment, database,
  atau domain production yang dimutasi.
- Authenticated smoke tersisa: hard refresh, login staging, pilih dua PO pada
  Backoffice, export, lalu verifikasi workbook hanya memuat dua PO tersebut.

### 2026-08-19 — COMPANY TRANSACTION RESET UPDATED FOR NEGATIVE REQUEST

Controlled operation `prd_reset_company_transactional_data.sql` tetap menjadi
jalur reset hasil trial per Company tanpa menghapus master/config/user. Target
delete kini mencakup `stock_request_negative_allocations` dari migration
`20260819170000`, sehingga schema-drift guard tidak berhenti setelah fitur
request stok minus per sesi dipasang. Operasi menghapus balance Stock, FIFO,
Movement, dokumen operasional, POS/Purchase/Expense/Finance runtime, mereset
cache saldo Customer serta last purchase price, tetapi mempertahankan Product,
UOM, Customer, Supplier, Company, Gudang, COA, policy, dan permission. Static
transaction/delimiter check serta `git diff --check` PASS; preview dan execute
staging tetap manual serta membutuhkan exact Company UUID/name dan confirmation
phrase.

### 2026-08-19 — POS CART QUANTITY EDIT FIX LOCAL-READY

Bug pengeditan quantity Cart diperbaiki: field angka kini boleh kosong sementara
saat kasir mengganti nilai dan tidak lagi menghapus baris karena `Number('')`
menjadi nol. Tombol minus berhenti pada satu step minimum sesuai precision UOM;
penghapusan eksplisit hanya melalui tombol tong sampah. Input sementara ikut
dibersihkan saat Draft dimuat, Product ditambah ulang, transaksi di-reset, atau
baris dihapus. Evidence lokal: PWA `oxlint` PASS, production build PASS, dan
`git diff --check` PASS. Deployment PWA serta authenticated browser smoke masih
menunggu. PWA kemudian dideploy ke project staging eksplisit
`kgs-pos-pwa-staging` dan unauthenticated HTTP smoke `200` PASS. Catatan insiden:
percobaan CLI pertama dari target parent mengabaikan link folder dan sempat
mengalihkan alias Backoffice production `pointofsales-kgs` ke deployment baru;
user menerima deployment tersebut selama environment DB tidak diubah; tidak ada
environment atau database production/staging yang dimutasi. Backoffice kemudian
dideploy dengan project ID eksplisit ke `pointofsales-kgs-staging`. Kedua domain
staging (`pointofsales-kgs-staging.vercel.app` dan
`kgs-pos-pwa-staging.vercel.app`) memberi HTTP `200`.

### 2026-08-19 — NEGATIVE STOCK SESSION REQUEST LOCAL-READY

Atas keputusan user, Sale stok minus online tetap final dan shortage yang masih
outstanding saat close sesi kini dirancang menjadi tepat satu Stock Request
`SUBMITTED` per sesi. Migration `20260819170000` menambah immutable source dan
allocation lineage, mengizinkan snapshot sesi negatif, membungkus close secara
atomik/idempotent, serta memberi readiness RPC yang menjelaskan entitlement,
policy, Gudang, atau izin user yang belum siap. Request memakai Base UOM dan
Purchasing tetap memilih Supplier/UOM/harga serta boleh membagi satu permintaan
ke beberapa order. Offline dan Bundle tetap diblokir.

PWA menampilkan penyebab konfigurasi yang spesifik dan nomor request hasil
close; Supplier Order Backoffice memberi badge request otomatis. Preflight,
postflight, rollback behavior, regression order, serta UAT dicatat pada
`docs/runbooks/PRD_NEGATIVE_STOCK_SESSION_REQUEST_ROLLOUT.md`. Evidence lokal:
PWA `oxlint` PASS, PWA production build PASS, targeted Supplier Order ESLint
PASS, Backoffice production build PASS (67 page), SQL delimiter/privilege
static audit PASS, dan `git diff --check` PASS. Database behavior belum
dijalankan lokal karena Docker/Postgres tidak tersedia; migration dan
behavioral utama kemudian dijalankan user dan dikonfirmasi PASS. Fixture utama,
G4 Phase 60, dan G5 Phase 2 kini memakai Auth identity rollback-only sehingga
tidak berbenturan dengan sesi kasir operasional. Empat regression (G4 Phase 2,
G4 Phase 60, G5 Phase 2, dan ACP Phase 5C) kemudian dikonfirmasi user PASS.
Next safe step: final postflight ulang dan authenticated smoke POS → close sesi
→ Purchasing sebelum deploy/go-live data dilanjutkan.

### 2026-08-19 — CUSTOMER + ADDITIVE PRODUCT-UOM DATA EXCHANGE LOCAL-READY

Atas permintaan user menjelang pengisian data go-live, Global Data Exchange
sekarang mempunyai kontrak local-ready untuk `CUSTOMER` dan `PRODUCT_UOM`.
Customer non-Walk-In dapat diekspor serta diimpor melalui job staging,
mapping, preview, confirmation, optimistic version, dan audit. Kategori,
Customer induk, dan Pricelist harus sudah ada pada Company aktif; saldo,
opening AR, dan histori transaksi sengaja tidak ikut.

`PRODUCT_UOM` adalah jalur additive terpisah dari import Product penuh. Tombol
Template CSV mengambil seluruh Product aktif non-Bundle dan menghasilkan satu
baris kosong per Product. Baris `uom_name` kosong menjadi `SKIP`; baris terisi
menambah atau memperbarui pasangan Product+UOM, tanpa menonaktifkan/menghapus
UOM lain. Base UOM tidak dapat diubah, faktor wajib >1, UOM terbesar wajib
mempunyai berat, dan perubahan conversion existing ditolak setelah Product
mempunyai Stock Movement. Template dijaga capability `IMPORT`, sedangkan export
data dijaga `EXPORT`; keduanya tidak membuka direct table write.

File local-ready: migration `20260819150000` lalu `20260819160000`, dua
SELECT-only postflight, dua rollback behavioral test, Backoffice API/catalog/UI,
runbook, manifest, requirement notes, paket cutover, serta PRD closing chain.
Evidence lokal: targeted ESLint PASS, Next production build PASS (67 static
pages), `git diff --check` PASS sebelum final documentation pass. Migration dan
SQL behavior belum dijalankan pada Supabase; deployment/smoke authenticated juga
belum dilakukan. Next safe step: rollout Customer lengkap, lalu Product-UOM;
berhenti pada `FAIL`/error dan jangan deploy UI sebelum kedua postflight serta
behavior PASS.

### 2026-08-18 — GUARDED UOM/CATEGORY CLEANUP LOCAL-READY

Atas keputusan user sebelum UAT, halaman Master Data menampilkan kembali nama
UOM (stale CSS yang menyembunyikan kolom pertama dihapus), mempertahankan edit,
dan menambah modal delete untuk UOM serta Kategori Produk. Browser hanya
memanggil dua RPC baru yang membutuhkan `inventory.master_data MANAGE`, active
Company, optimistic version, dan actor audit. Hard delete hanya berhasil untuk
row tanpa referensi; master yang sudah dipakai harus dinonaktifkan. Tipe,
decimal policy, dan precision UOM yang sudah direferensikan dikunci, tetapi nama
dan status tetap dapat dikoreksi.

File rollout local-ready: migration `20260818090000`, SELECT-only postflight,
rollback behavioral test, serta runbook
`PRD_GUARDED_INVENTORY_MASTER_CLEANUP.md`. PRD-1 required migration chain juga
sudah memasukkan versi baru. Database staging/production belum diubah dan smoke
authenticated belum dijalankan. Local TypeScript no-emit, ESLint, Next.js
production build (67/67 static pages), SQL transaction/tag structure, migration
checksum manifest, dan `git diff --check` PASS. Next safe step: migration → seluruh postflight
PASS → behavioral `TEST PASSED`/ROLLBACK → postflight ulang → redeploy
Backoffice → smoke edit/delete unused dan penolakan delete used master.

Behavioral run pertama berhenti pada negative-access Finance karena fixture
mengganti JWT actor tetapi belum membuat `user_active_company_contexts` untuk
actor Finance tersebut. Migration/runtime tidak gagal. Test dikoreksi untuk
memanggil guarded `set_active_company_context()` setelah pergantian actor,
sehingga assertion berikutnya benar-benar menguji `CUSTOM_PERMISSION_DENIED`.
Jalankan ulang behavioral file lengkap; transaksi sebelumnya gagal di dalam
`BEGIN` dan tidak meninggalkan fixture final.

### 2026-08-14 — STAGING LIVE; AUTHENTICATED SMOKE MANUAL

Git `main` lokal dan `origin/main` sama pada commit `fc25640` (`update manual
book`) dan workspace awal bersih. Dua project Vercel dibuat serta
ditautkan ke repository GitHub: `pointofsales-kgs-staging` memakai root
`backoffice`/Next.js dan `kgs-pos-pwa-staging` memakai root `pwa`/Vite. Supabase
staging `yjxpddwrjdczuqyixqwi` sudah ACTIVE_HEALTHY dan local CLI sudah linked;
link memakai management login sehingga tidak memerlukan database password.

Fresh bootstrap membuktikan schema pra-ledger tidak reproducible dari folder
migration. Ditambahkan baseline `000`, runtime bridge `003`, dan bridge partial
Finance `20260810175000`; chain staging sekarang berhasil diterapkan lengkap
sampai `20260814170000` dan `supabase migration list --linked` menunjukkan
seluruh Local/Remote version identik. Parser fresh-chain juga menemukan satu
kurung tutup berlebih pada composed Expense read migration `20260813060000`;
syntax dikoreksi tanpa mengubah response/business contract dan sisa chain
kemudian berhasil diterapkan.
Migration koreksi akun impor `20260810185000` dibuat fresh-safe: no-op bila
tidak ada akun impor yang perlu didemosi, tetapi tetap menuntut linked Super
Admin serta audit bila correction scope nyata ada. Rollout berikutnya menunggu
satu Auth Super Admin staging sudah dibuat dan dipakai hanya sebagai actor
provisioning/audit. PWA lint/build PASS; Backoffice lint/build PASS dengan 67
route entries. User memberi persetujuan eksplisit dan lima Vercel
Production-target env sudah terpasang: URL/publishable staging untuk kedua
aplikasi, service-role staging hanya untuk Backoffice. Kedua alias stabil live:
`https://pointofsales-kgs-staging.vercel.app` dan
`https://kgs-pos-pwa-staging.vercel.app`. HTTP smoke membuktikan kedua root
`200 text/html`, Backoffice unauthenticated API `401 application/json`, bundle
PWA memakai project ref staging, dan tidak ada marker service-role/secret pada
PWA bundle maupun Backoffice HTML. Browser internal tidak tersedia dan password
user tidak dibagikan, sehingga authenticated login/role/terminal smoke masih
manual. Supabase Auth Site URL/Redirect URL untuk invite/recovery juga masih
perlu diatur manual di Dashboard; password login langsung tidak bergantung pada
redirect tersebut. Tidak ada key yang dicetak, ditulis ke repo, atau dipasang
ke project Production.

### 2026-08-14 — MANUAL PENGGUNA BERBAHASA INDONESIA

Ditambahkan `docs/MANUAL_PENGGUNA_KGS_POS.md` sebagai manual operasional
Backoffice dan PWA yang dapat dibaca langsung dari GitHub. Dokumen mempunyai
daftar isi bertaut, panduan seluruh modul aktif, alur lintas modul,
multi-company, hak akses, transaksi offline, dokumen cetak, Finance, pemecahan
masalah, praktik operasional, dan glosarium. Root `README.md` serta router
`docs/README.md` kini menautkan manual. Perubahan hanya dokumentasi; tidak ada
schema, permission, RPC, UI, atau business flow yang berubah.

### 2026-08-14 — CROSS-APP AUTH LOGOUT ISOLATION FIX

User melaporkan PWA/Backoffice keluar sendiri saat kedua aplikasi memakai akun
Supabase yang sama. Root cause: tombol logout PWA dan Backoffice memanggil
`auth.signOut()` dengan default global scope, sehingga refresh token aplikasi
lain ikut dicabut dan baru terlihat logout pada refresh berikutnya. Kedua manual
logout sekarang memakai `{ scope: 'local' }`. INVALID_SESSION tetap fail-closed
dan perubahan tidak mengubah role, tenant, atau server authorization. Existing
revoked token membutuhkan login ulang satu kali setelah deployment.

### 2026-08-14 — PWA EXPENSE SETTLEMENT MODAL LAYOUT FIX

User menemukan modal Penyelesaian Expense bertumpuk/miring pada viewport
desktop Vercel. Root cause adalah `.pos-expense-confirm-layer` tidak memiliki
positioning/layout CSS, sehingga nested dialog tetap berada di document flow;
field URL juga tidak memiliki bounded width. `pwa/src/App.css` sekarang memberi
centered absolute overlay, single-column bounded fields, internal scroll,
sticky-separated header/footer structure, mobile bottom-sheet behavior, serta
tiga tab Expense dengan grid yang konsisten. Flow, RPC, dan Finance effect tidak
berubah. PWA oxlint, TypeScript/Vite production build, dan `git diff --check`
PASS; authenticated visual smoke setelah Git/Vercel redeploy masih manual.

### 2026-08-14 — G6 PHASE 8H CLOSED; PRD-1 LOCAL BUILD/SECRET GATE PASS

User menjalankan Phase 8H final closure dan seluruh row PASS. Runtime Finance
historis sekarang mempunyai 32 final Financial Event: 31 POSTED Event/Journals
dengan 92 Journal lines dan satu exact-zero `NO_FINANCIAL_EFFECT`. HOLD, active
queue, open posting exception, duplicate journal, dan coverage gap semuanya nol.
FIFO–Inventory GL KGS reconcile tepat Rp89.485.000; Supplier AP dan Customer
Balance reconcile per Company.

Local predeploy verification kemudian dijalankan: Backoffice ESLint PASS,
Next.js production build PASS (67 static/dynamic route entries), PWA oxlint PASS,
TypeScript/Vite/PWA production build PASS. PWA main chunk 555,22 kB / 153,61 kB
gzip memberi warning performa non-blocking dan wajib diukur pada Preview. Tracked
env hanya dua `.env.example`; real env, `.vercel`, Supabase local state, build,
dump, log, export, dan test artifact di-ignore. Scan client build tidak menemukan
marker service-role/private key. `backoffice/vercel.json` tidak memuat Cron.

Next safe step: authenticated PRD-1 Preview UAT (role/preset, direct URL/API/RPC,
two-Company distinct override and isolation, Pickup/Delivery/Return/Purchase/
Finance/Data Exchange), lalu configure dua Vercel Preview project, environment,
Supabase Auth redirect allowlist, branding Storage/cache, dan PWA offline smoke.
Jangan menyebut Preview sebagai Production approval.

### 2026-08-14 - G6 PHASE 8E LIVE PASS; PHASE 8F PREFLIGHT READY

User mengonfirmasi Purchase/AP controlled live reconciliation seluruhnya PASS:
queue bersih dan `COMPLETED`, delapan Journal, satu exact-zero Receipt closure,
tidak ada duplikasi, semua Journal balance, source amount serta Supplier
dimension cocok. Inventory akhir: 3 Goods Receipt POSTED + 1 no-effect
CANCELED, 3 Supplier Invoice POSTED, 2 Supplier Payment POSTED, remaining HOLD
7.

Next safe step adalah Phase 8F. Ditambahkan one-statement SELECT-only preflight
`g6_phase8f_remaining_operational_posting_preflight.sql` untuk exact inventory
2 Stock Gain, 2 Expense Disbursement, 2 Cash Deposit, dan 1 Cash Variance.
Diagnostic memeriksa final source linkage, header/line/effect amount, immutable
account snapshot, postable period, zero early Journal, dan clean queue. Runtime
belum dibuat/dibuka. Jalankan preflight dan kirim seluruh row; semua `BLOCKER`
wajib nol.

User mengirim seluruh Phase 8F preflight PASS: source linkage 7/7, exact amount
untuk 2 Stock Gain + 2 Expense Disbursement + 2 Cash Deposit + 1 Cash Variance,
15 account snapshot valid, period siap, journal effect nol, queue bersih.
Migration `20260814160000` kini local-ready dengan satu dispatcher core dan
contract-separated source verification/journal plans. Postflight SELECT-only
serta rollback behavioral 2/2/2/1 tersedia. Static structure, migration hash,
dan `git diff --check` PASS. Next safe step: migration -> postflight -> behavior
-> postflight ulang; jangan buat live queue sebelum user mengonfirmasi PASS.

User mengonfirmasi Phase 8F migration/postflight dan behavioral seluruhnya PASS;
tujuh Event live masih HOLD dan journal effect nol. Phase 8G sekarang
local-ready: migration `20260814170000` menambah scope
`REMAINING_OPERATIONAL` dengan final-source-only preview, lalu memakai approval
dan processor queue yang sudah audited. Behavioral memproses tepat tujuh Event
di dalam rollback dan mensyaratkan `COMPLETED / 7 / 0 / 0` plus replay
idempotent. Static structure/hash/diff checks PASS. Next safe step: migration ->
postflight -> behavioral -> postflight ulang; live operation masih ditutup.

User mengonfirmasi seluruh Phase 8G install/postflight/behavior gate aman tanpa
blocker. Final controlled operation
`g6_phase8g_post_live_remaining_operational.sql` sekarang local-ready dan
mengunci scope exact 2/2/2/1, immutable preview hash, serta hasil wajib
`COMPLETED / 7 / 0 / 0`; mismatch merollback seluruh transaksi. Phase 8H
SELECT-only closure postflight juga tersedia untuk HOLD=0, event-journal 1:1,
no-effect contract, balance/header-line, FIFO-GL, Supplier AP-GL, Customer
Balance-GL, queue bersih, dan zero open posting exception. Static structure dan
`git diff --check` PASS. Next safe step: jalankan final operation sekali lalu
langsung Phase 8H postflight; kirim seluruh output.

### 2026-08-14 - G6 PHASE 8D USER-PASS; PHASE 8E CONTROLLED QUEUE READY

User mengonfirmasi Phase 8D closing postflight seluruhnya PASS: sembilan
Purchase/AP Event tetap HOLD, tidak ada early Journal, private runtime boundary,
dispatcher, runtime routine, migration ledger, dan 14 Sale/Return POSTED tetap
utuh. Migration/runtime serta zero-value behavioral sebelumnya juga dilaporkan
sukses.

Phase 8E sekarang local-ready: migration `20260814150000` menambah scope
`PURCHASE_AP`, preview RPC final-source-only, serta processor khusus yang tetap
memakai immutable approval/version/queue audit. Efek positif menjadi Journal;
exact Rp0 Goods Receipt menjadi valid `SKIPPED / NO_FINANCIAL_EFFECT` dan Event
`CANCELED`, tanpa jurnal nol. Stale preview atau runtime error tetap menghasilkan
`COMPLETED_WITH_ERRORS`. Migration tidak membuat queue atau memposting Event.

File baru: migration Phase 8E, SELECT-only postflight, rollback behavioral, dan
runbook `G6_PHASE8E_PURCHASE_AP_CONTROLLED_QUEUE_ROLLOUT.md`. Static structure,
SHA-256 manifest, dan scoped `git diff --check` PASS. Manual gate:
jalankan migration -> postflight -> behavioral dan kirim seluruh hasil. Jangan
jalankan live queue sebelum ketiganya PASS.

User kemudian mengonfirmasi behavioral Phase 8E PASS. Controlled live operation
`supabase/operations/g6_phase8e_post_live_purchase_ap.sql` dan SELECT-only live
reconciliation postflight sudah ditambahkan. Operation mengunci tepat satu
Company, 4 Receipt, 3 Invoice, 2 Payment, tepat satu Receipt Rp0, immutable
preview hash, serta hasil wajib `COMPLETED / posted 8 / failed 0 / skipped 1`;
selain itu seluruh transaksi rollback. Next safe step: jalankan operation sekali,
lalu segera jalankan live reconciliation postflight dan kirim seluruh output.

### 2026-08-14 — G6 PHASE 8A SALE/RETURN EXACT PREFLIGHT READY

### 2026-08-14 — G6 PHASE 8A SETTLEMENT MAPPING READY

### 2026-08-14 — G6 PHASE 8B SALE/RETURN RUNTIME READY

### 2026-08-14 — G6 PHASE 8B ACCOUNT-MAPPING FORWARD FIX READY

### 2026-08-14 — G6 PHASE 8C CONTROLLED SALE/RETURN QUEUE READY

### 2026-08-14 — G6 PHASE 8C CONTROLLED LIVE OPERATION READY

### 2026-08-14 - G6 PHASE 8C LIVE PASS; PHASE 8D PURCHASE/AP PREFLIGHT READY

Phase 8D exact preflight kemudian user-pass seluruhnya: 4 Goods Receipt, 3
Supplier Invoice, dan 2 Supplier Payment cocok dengan source, allocation,
account snapshot; event linkage 9/9 dan existing journal effect nol. Migration
`20260814140000` sekarang local-ready dengan source-verified atomic runtime,
signed PPV/nonrecoverable-tax line, Input Tax, AP Provisional/Final, immutable
Cash/Bank source account, Supplier dimension, period handling, balanced journal,
dan exact replay. Postflight dan behavioral 4/3/2 rollback test tersedia. Next
safe step: migration -> postflight -> behavioral -> postflight ulang. Jangan
membuka controlled live queue Purchase/AP sebelum seluruh langkah itu user-pass.

Behavioral pertama berhenti pada `FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH` tepat
di guard Receipt `<=0`; seluruh test transaction rollback. Root cause bukan
source mismatch: satu Goods Receipt mempunyai header/line/batch/Event yang
semuanya konsisten Rp0, sehingga preflight lama PASS tetapi runtime menolak
jurnal nol. Forward-fix `20260814143000` menutup hanya exact-zero Receipt sebagai
Event `CANCELED` dengan reason `NO_FINANCIAL_EFFECT` dan tanpa Journal; setiap
mismatch atau event positif tetap memakai runtime asli. Behavioral diperbarui
menguji closure + replay nol serta posting/replay positif. Next safe step:
forward-fix -> fix postflight -> runtime postflight -> behavioral -> kedua
postflight ulang; migration `20260814140000` tidak perlu direrun.

User menjalankan controlled queue `PST/2026/08/000003` dengan hasil
`COMPLETED`: preview 14, posted 14, failed/skipped nol. Live postflight seluruhnya
PASS: queue bersih, tepat satu jurnal per Sale/Return, settlement reconcile,
jurnal balance, dan actual Inventory GL delta `-3185000` sama dengan expected.
Runtime kini database-live untuk 13 Sale dan satu Sales Return; remaining HOLD
16 dan tidak disentuh oleh operasi tersebut.

Next safe step adalah Phase 8D Purchase/AP. Ditambahkan one-statement SELECT-only
`supabase/diagnostics/g6_phase8d_purchase_ap_posting_preflight.sql` beserta
runbook. Diagnostic memverifikasi empat Goods Receipt, tiga Supplier Invoice,
dan dua Supplier Payment secara source-exact: header/line/FIFO value, invoice
allocation provisional/actual, signed PPV, recoverable/nonrecoverable tax, AP
Final, payment allocation, tenant-valid active/postable account snapshots, dan
zero existing journal effect. Tidak ada Event, jurnal, queue, schema, RPC, grant,
atau business data yang diubah. Jalankan seluruh preflight dan kirim semua row;
`BLOCKER` wajib nol sebelum migration posting Purchase/AP dibuat.

User mengonfirmasi Phase 8C migration, postflight, dan rollback behavioral
sukses. Controlled live operation sekarang siap. File operasi mengunci scope
persis satu Company, 13 Sale + satu Return, tidak ada active queue, preview 14
item, dan hash event/version yang sama; approval/process harus menghasilkan
`COMPLETED`, posted 14, failed/skipped nol atau seluruh transaksi rollback.

Postflight live SELECT-only memeriksa event↔journal 1:1, balance setiap jurnal,
settlement debit/credit, net Inventory GL Sale–Return, clean queue result, dan
remaining HOLD inventory. Static SQL/diff checks PASS. Manual gate berikutnya:
jalankan operasi live sekali, lalu langsung postflight live. Jangan menjalankan
operasi ulang jika sudah commit; queue/event idempotency dan scope guard akan
menolaknya. Next safe step setelah live reconciliation PASS adalah Phase 8D
Purchase/AP contract, bukan menganggap seluruh Finance selesai.

User mengonfirmasi Phase 8B mapping fix, postflight, dan behavioral seluruhnya
sukses. Runtime Sale/Return kini terbukti atomic, balanced, dan idempotent dalam
rollback test. Phase 8C siap untuk manual rollout: migration `20260814130000`
memperluas queue scope secara terbatas ke `SALE_RETURN` dan menambah preview RPC
khusus. Approval/process lama tetap digunakan agar lifecycle, optimistic version,
immutable item/audit, exception handling, dan single-active-queue tidak diduplikasi.

Migration tidak membuat run dan tidak memproses Event. Behavioral melakukan
preview→approve→process lalu rollback. Static SQL/diff checks PASS. Manual gate:
jalankan install, postflight, behavioral pada runbook Phase 8C. Controlled live
operation baru boleh dijalankan setelah user mengirim hasil PASS; response live
wajib `COMPLETED`, failed/skipped nol sebelum lanjut rekonsiliasi.

Behavioral Phase 8B gagal pada `ACCOUNT_MAPPING_MISSING_OR_AMBIGUOUS`. Line
mapping menunjukkan kegagalan terjadi di komponen runtime, bukan settlement
leg: exact preflight sebelumnya hanya mengaudit conditional payment/refund dan
belum mengaudit `COGS` + `INVENTORY_ASSET` pada kontrak Return (katalog lama
Return hanya menandai `SALES_RETURN_DISCOUNT` required). Forward-fix
`20260814120000` memprovision seluruh fungsi GL yang benar-benar dipakai core
Sale/Return dari tepat satu akun sistem kanonis, dengan fallback audited sejak
2000. Migration menolak kandidat nol/ganda dan tidak membuat Journal/Event.

Postflight baru memeriksa setiap historical Event × required runtime function,
termasuk ambiguity dan zero journal effect. Static SQL checks dan diff check
PASS. Manual gate: migration fix, postflight fix, lalu ulangi behavioral Phase
8B. Jangan mengulang behavioral sebelum postflight fix seluruhnya PASS/INFO.

User mengonfirmasi exact preflight bersih: conditional mapping `PASS`, nol
missing/ambiguous function, 13 Sale + satu Return konsisten, dan existing Journal
nol. Phase 8B sekarang siap untuk manual rollout. Migration `20260814110000`
menambah immutable settlement account-function snapshot pada payment/refund,
mempertahankan Stock Opening core lama, dan memasang dispatcher menuju core
dinamis Sale/Return yang source-verified, atomic, balanced, dimensional, serta
idempotent. Return inventory debit dipisah per destination Warehouse.

Migration tidak memproses historical HOLD. Postflight membuktikan schema,
private boundary, legacy Stock Opening compatibility, dan zero historical final
effect. Behavioral test memproses tepat satu Sale dan satu Return, menguji exact
replay, lalu `ROLLBACK`. Static delimiter, parentheses, function routing, dan
`git diff --check` PASS. Manual gate: jalankan tiga file di
`docs/runbooks/G6_PHASE8B_SALE_RETURN_POSTING_RUNTIME_ROLLOUT.md`; kirim output
lengkap. Next safe step setelah PASS adalah controlled historical operation,
bukan menjalankan queue lama yang masih khusus Stock Opening.

Exact Sale/Return preflight user menunjukkan seluruh amount, source, payment,
refund, revenue, tax, FIFO, ongkir, rounding, dan existing-journal contract
PASS. Satu-satunya gap adalah 14 settlement leg belum mempunyai resolusi akun:
`CASH_DRAWER` dan `BANK_RECEIPT`. Required mapping Phase 3 memang tidak mencakup
conditional payment/refund function.

Migration `20260814100000` siap membuat fallback audited dan effective-dated:
`CASH_DRAWER` menuju akun sistem `CASH_DRAWER`, sedangkan `BANK_RECEIPT` menuju
akun sistem `BANK`. Migration menolak kandidat nol/ganda, tidak mencocokkan
nama/kode bebas, dan memprovision Company aktif berikutnya. Postflight dan
behavioral test memastikan resolver persis satu, Event tetap `HOLD`, dan jurnal
Sale/Return tetap nol. Static SQL delimiter, parentheses, dan signature PASS.

Manual gate: jalankan empat langkah di
`docs/runbooks/G6_PHASE8A_SALE_RETURN_SETTLEMENT_MAPPING_ROLLOUT.md`, lalu kirim
exact preflight terakhir. Next safe step hanya setelah conditional resolution
PASS: implement runtime jurnal dinamis Sale/Return. Historical queue belum boleh
diproses.

User mengirim Phase-8 live output tanpa blocker: seluruh sembilan contract,
source final, amount snapshot, identity, required mapping, accounting period,
dan zero existing journal effect PASS. Ringkasan `eventCount` diagnostic
diperbaiki agar menjumlahkan 30 Event, bukan sembilan grouped rows.

Karena Sale/Return memerlukan conditional account yang tidak dicakup required
mapping umum, ditambahkan Phase-8A SELECT-only exact preflight. Ia merekonsiliasi
Sale, payment, pajak, FIFO, ongkir, rounding, surcharge, Return/refund, dan
settlement account function. Tidak ada data atau runtime yang diubah. Next safe
step: jalankan Phase-8A dan kirim seluruh output; migration posting hanya dibuat
setelah `BLOCKER` nol dan conditional mapping tepat satu.

### 2026-08-14 — G6 PHASE 8 OPERATIONAL HOLD PREFLIGHT READY

User membuka penyelesaian Finance sebagai blocker utama sebelum presentasi.
Audit kode membuktikan canonical engine G6 masih hard-limited ke `STOCK_OPENING`;
sembilan kontrak operasional tidak aman dibuka hanya dengan menambah rule statis,
karena Sale/Return mempunyai payment/refund leg dinamis dan source lain membawa
snapshot akun berbeda. Ditambahkan preflight SELECT-only
`supabase/diagnostics/g6_phase8_operational_hold_contracts_preflight.sql` dan
runbook `docs/runbooks/G6_PHASE8_OPERATIONAL_HOLD_CONTRACT_PREFLIGHT.md`.

Preflight memeriksa dependency, active queue, exact contract identity, final
source linkage, amount snapshot, required mapping, split/TEMPO payment shape,
periode, dan existing journal effect. Tidak ada Event, mapping, journal, queue,
schema, RPC, grant, atau business data yang diubah. Next safe step: user
menjalankan seluruh preflight dan mengirim semua row. `BLOCKER` wajib nol;
`BACKFILL` harus direview sebelum migration posting pertama dibuat.

### 2026-08-13 — INVENTORY SURAT JALAN SPLIT USER-PASS

Atas instruksi langsung user, Backoffice Invoice dan Surat Jalan dipisahkan.
Migration additive `20260813150000` menambah permission ENFORCED
`inventory.delivery_documents` untuk Owner/Admin/Store Manager/Warehouse Admin,
delivery-only composed list/detail/print, serta MANAGE lifecycle. Permission
`sales.sales_documents` dipersempit menjadi Invoice `VIEW/EXPORT`. POS RPC,
canonical Sale/tables/UUID/number/snapshot, dan Stock/Payment/Finance effects
tidak berubah.

Frontend sekarang menampilkan `Sales → Invoice Penjualan` dan `Inventory →
Surat Jalan`. Inventory response tidak memuat harga/payment/Customer Balance;
Sales detail tidak lagi meminta payload Delivery. Backoffice ESLint dan
production build PASS dengan 67 entries. SQL delimiter/parentheses static check
PASS; migration SHA-256 `69a22bea5e97da444162d248fb478e8730bc6da1f91b683442ebd6dc1fe55ef9`.
User melaporkan seluruh rollout SQL dan behavioral test sukses. Migration,
postflight, dan behavior sekarang USER-PASS. Next safe step adalah authenticated
smoke untuk Warehouse Admin, Finance/Accounting, Company isolation, serta cetak
Invoice/Surat Jalan dari POS; jangan membuka table grant sebagai shortcut.

### 2026-08-13 — POS CUSTOMER BALANCE POLICY DIRECT-READ FIX

Pre-presentation POS smoke menemukan `permission denied for table
customer_balance_company_policies`. Penyebabnya terisolasi pada satu legacy
catalog query di `pwa/src/lib/pos.ts`: ACP-6D sudah benar mencabut direct
browser SELECT, tetapi PWA masih membaca lifecycle policy langsung. PWA kini
tidak membaca tabel protected tersebut. Tender availability diturunkan dari
kehadiran metode internal `CUSTOMER_BALANCE` pada guarded open-session RPC
`get_pos_payment_method_references`; credit tetap memerlukan feature enabled
dan tender yang diizinkan server. Ini mempertahankan ACTIVE/WIND_DOWN/DISABLED
contract tanpa membuka grant/RLS atau membuat migration baru.

Evidence lokal: pencarian PWA menemukan nol referensi direct table tersebut,
oxlint PASS, TypeScript/Vite production build PASS. Main chunk `555.22 kB`
(`153.61 kB` gzip) masih warning nonblocking yang sama. Manual smoke yang wajib:
restart PWA/hard refresh agar Service Worker mengambil bundle baru, login/open
Session, pastikan Catalog terbuka; jika Customer Balance ACTIVE metode tampil,
jika DISABLED metode tidak tampil. Tidak ada data, policy, payment, ledger,
atau migration live yang diubah.

### 2026-08-13 — ACP-7 / PRD-1 DATABASE CLOSURE CLEAR; UAT FIXTURE PENDING

User menjalankan ulang ACP-7 dan consolidated PRD-1 setelah Company-access
lifecycle live. Kedua diagnostic tidak memiliki `BLOCKER`. Migration chain
ACP-7 `25/25`, PRD-1 `32/32`, seluruh 24 permission `ENFORCED`, active-context,
tenant, protected browser write, Stock–Movement–FIFO, Sale/Document, dan
Journal invariant seluruhnya PASS. Regular non-Super-Admin multi-Company
identity juga sudah PASS pada ACP-7; live inventory menunjukkan dua Company,
empat active Company membership, satu permission override, dan satu immutable
permission-audit row.

Yang tersisa hanya fixture/manual UAT, bukan runtime defect:

- permission yang sama belum mempunyai override berbeda pada kedua Company;
- role `COMPANY_ADMIN`, `WAREHOUSE_ADMIN`, `ACCOUNTING`, dan Store role
  `CASHIER` belum seluruhnya terwakili;
- tepat satu Company aktif belum lengkap Store + Terminal + sale-source
  Warehouse;
- tepat satu Company aktif belum lengkap Product aktif + Customer aktif +
  Payment Method aktif.

Next safe step: melalui detail user dengan Company selector eksplisit, pasang
`inventory.stock_real=LIHAT_SAJA` pada Company A dan `TANPA_AKSES` pada Company
B untuk user multi-Company yang sama. Lengkapi role dan fixture Company yang
kurang lewat UI canonical, lalu rerun hanya ACP-7 dan PRD-1 preflight. Setelah
semua `SETUP` PASS, jalankan authenticated browser matrix di
`docs/runbooks/ACP7_AUTHENTICATED_CLOSURE_MATRIX.md`. Finance HOLD 29 row/9
contract tetap deferred dan tidak boleh diproses oleh tahap ini.

Local client gate pada state ini juga selesai: Backoffice ESLint PASS,
Backoffice production build PASS (66 static pages), PWA oxlint PASS, dan PWA
production build PASS. Vite hanya memberi warning ukuran main chunk `555.37 kB`
(`153.65 kB` gzip); ini bukan build failure, tetapi tetap dicatat untuk
pengukuran performa Preview. Authenticated matrix belum diklaim PASS karena
akun/role/fixture di atas masih perlu dilengkapi user melalui UI.

### 2026-08-13 — PRD COMPANY ACCESS LIFECYCLE DATABASE PASS

User akhirnya mengonfirmasi behavioral test sukses dan closing postflight
seluruhnya PASS: migration ledger satu, dua RPC tersedia untuk authenticated dan
tertutup untuk anon, active-context/membership integrity bersih, inactive
membership tidak menyisakan default/Store aktif, dan audit action contract
valid. Inventory live: empat membership aktif, satu regular multi-Company user,
satu membership inactive. Database gate selesai; UI role/Store/revoke smoke dan
ACP-7 authenticated matrix tetap pending.

User menemukan gap sebelum UAT: detail user multi-Company tidak menjelaskan
Company target untuk role/override dan tidak menyediakan revoke. Implementasi
local-ready menambahkan migration `20260813140000`, postflight, rollback-safe
behavior test, guarded API, dan Company selector eksplisit pada modal. Role,
Store, serta override sekarang memakai Company terpilih. Revoke menonaktifkan
Company/Store membership, membersihkan override dengan audit append-only,
memperbaiki default/active context, menjaga last Owner, dan tidak menghapus
Auth/Profile/histori transaksi.

Evidence lokal: Backoffice ESLint PASS; Next production build/TypeScript PASS
dengan 66 pages dan route `/api/staff/company-access`; migration/test dollar
delimiter serta tanda kurung seimbang; scoped `git diff --check` PASS. Live
Supabase belum dijalankan. Manual gate: migration → postflight → behavior →
restart Backoffice → two-Company role/revoke smoke → postflight ulang → ACP-7
dan PRD-1 preflight. PRD-1 chain sekarang mengharapkan 32 migration. Jangan
menandai UAT selesai sebelum user mengonfirmasi seluruh langkah tersebut.

Behavioral run pertama berhenti pada direct INSERT fixture ke
`user_active_company_contexts` setelah `SET LOCAL ROLE authenticated`. Ini
bukan runtime defect: browser write boundary bekerja benar. Test dikoreksi
dengan menyiapkan protected context sebelum browser role, lalu memverifikasi
context repair, override cleanup, permission audit, dan assignment audit
setelah `RESET ROLE`. Tidak ada migration, grant, RLS, atau runtime yang
diubah; hanya file behavior terbaru yang perlu dijalankan ulang.

Rerun berikutnya menemukan direct membership INSERT kedua di dalam blok
authenticated untuk negative self-revoke. Fixture itu juga tidak diperlukan
karena canonical guard menolak self-target sebelum membaca membership. Direct
write tersebut dihapus. Audit lexical penuh baris authenticated sekarang
menemukan nol `INSERT/UPDATE/DELETE public.*`; hanya tiga guarded RPC dan SELECT
assertion tersisa. Delimiter `6`, parentheses `34/34`, diff-check PASS.

Rerun berikutnya mencapai context-repair assertion. Runtime memilih membership
aktif pertama berdasarkan default/created order; target fixture memakai user
existing yang dapat memiliki Company lebih lama sehingga replacement tidak
wajib Company fixture A. Assertion diperbaiki mengikuti invariant: context
wajib non-null, bukan Company B yang dicabut, dan menunjuk membership target
yang masih ACTIVE. Seluruh assertion lain diaudit scope-nya terhadap dua UUID
Company fixture; tidak ada asumsi data existing lain. Auth direct-write scan
tetap nol; delimiter `6`, parentheses `34/34`, diff-check PASS.

### 2026-08-13 — ACP-6F USER-PASS; ACP-6G PAYMENT METHOD PREFLIGHT READY

User mengonfirmasi ACP-6F postflight seluruhnya PASS: permission Supplier
Payment sudah `ENFORCED`, direct table read/write tertutup, tiga public mutation
terhubung ke private core dan capability guard, cancellation tetap Draft-only,
akun sumber dijaga, alokasi balance, serta dua Financial Event tetap `HOLD`.
Behavior/regression sebelumnya juga telah dikonfirmasi sukses; authenticated
smoke tetap digabung pada closing UAT.

Gate berikutnya dibuka hanya sebagai SELECT-only ACP-6G. Ditambahkan
`supabase/diagnostics/acp_phase6g_payment_method_permission_preflight.sql` dan
`docs/runbooks/ACP6G_PAYMENT_METHOD_PERMISSION_PREFLIGHT.md`. Diagnostic
memetakan default per Company, Store eligibility, period/route/fee/Account
Function, system-owned Customer Balance/Ketul Offset, Sales snapshot,
tenant/audit/privilege, composed Backoffice read, export/import decision, serta
consumer authority POS online/offline dan Expense yang terpisah.

Supplier Payment ACP-6F sengaja tetap memakai kontrak `CASH/BANK_TRANSFER/CHEQUE`;
ACP-6G tidak menyatukannya diam-diam dengan Master Metode Pembayaran POS.
Tidak ada schema, data, grant, RLS, RPC, API, UI, Payment, Expense, Sale,
Financial Event, atau Journal runtime yang diubah. Next safe step: jalankan
seluruh preflight ACP-6G dan kirim semua row `check_name,status,details`.
Berhenti pada `BLOCKER`/`BACKFILL`; `REVIEW` dan `SETUP` adalah boundary/target,
bukan error.

### 2026-08-13 — ACP-6F SUPPLIER PAYMENT ENFORCEMENT LOCAL READY

User mengirim seluruh ACP-6F preflight tanpa `BLOCKER`/`BACKFILL`. Lifecycle,
allocation/AP balance, tenant, audit, source account, event coverage, dan
browser write boundary PASS; dua Payment Event tetap `HOLD`.

Migration `20260813120000` local-ready. Ditambahkan composed Supplier Payment
read, guarded Draft/Edit/Post, server validation akun sumber kas/bank,
Draft-only cancel, export XLSX bulanan, private proven G5 cores, dan penutupan
direct read tiga tabel. Backoffice API/UI/navigation dan Data Exchange sudah
cutover. Tidak ada review state baru; VALIDATED payment immutable dan Journal
tidak diproses.

Local evidence: Backoffice ESLint PASS; Next production build/TypeScript PASS;
SQL delimiter/parenthesis scan PASS; scoped diff-check PASS. Live SQL belum
dijalankan agent. Manual gate: migration → restart Backoffice → postflight
ACP-6F → behavior ACP-6F → regression G5 Phase-14 → regression ACP-6E → G5
postflight → postflight ACP-6F ulang. Authenticated smoke tetap closing UAT.

Behavioral run pertama berhenti pada composed-response assertion karena test
keliru mengharuskan `accounts=[]`. Provisioning Company otomatis membuat COA
bawaan sehingga eligible account array boleh terisi. Assertion diperbaiki
untuk memvalidasi bentuk/kolom, `ASSET`, dan status aktif setiap row tanpa
mengharuskan kosong. Runtime/migration tidak diubah dan tidak perlu direrun.

### 2026-08-13 — ACP-6E USER-PASS; ACP-6F SUPPLIER PAYMENT PREFLIGHT READY

User mengonfirmasi seluruh ACP-6E migration, postflight, behavior, regression,
dan closing check sukses/PASS. `finance.supplier_invoices` sekarang
database-live `ENFORCED`; Supplier Invoice Financial Event tetap `HOLD` dan
authenticated Finance smoke tetap ditunda ke closing UAT gabungan.

Gate berikutnya dibuka hanya sebagai ACP-6F SELECT-only. Ditambahkan
`supabase/diagnostics/acp_phase6f_supplier_payment_permission_preflight.sql`
dan `docs/runbooks/ACP6F_SUPPLIER_PAYMENT_PERMISSION_PREFLIGHT.md`. Diagnostic
mengaudit lifecycle DRAFT/VALIDATED/CANCELED, Draft-only cancellation,
header-allocation dan invoice-balance reconciliation, tenant/audit/idempotency,
narrow Supplier/payable-Invoice/source-account boundary, browser privilege,
optional export, override, dan Financial Event HOLD.

Tidak ada Payment, Invoice, account, Financial Event, Journal, grant, RLS, RPC,
API, atau UI runtime yang diubah. Next safe step: user menjalankan seluruh
ACP-6F preflight dan mengirim setiap row `check_name,status,details`. Berhenti
pada `BLOCKER`; `REVIEW`/`SETUP` adalah target enforcement, bukan failure.

### 2026-08-13 — ACP-6E SUPPLIER INVOICE ENFORCEMENT LOCAL READY

User mengirim ACP-6E preflight tanpa `BLOCKER`/`BACKFILL`. Schema/routine,
lifecycle, header-line/allocation reconciliation, tolerance, tenant, validated
event coverage, dan browser mutation boundary seluruhnya PASS. Tiga validated
event tetap `HOLD` dan tidak ada Journal yang diproses.

Migration `20260813110000` local-ready. Ditambahkan composed Invoice/matching
read, Draft/Edit/Post capability wrappers, tolerance policy melalui `APPROVE`,
export Faktur Supplier bulanan, narrow payable-Invoice RPC untuk Supplier
Payment, narrow linked-Invoice RPC untuk Purchase Return, serta penutupan enam
direct table reads. Latest proven G5 mutation bodies dipertahankan sebagai
private cores. Backoffice Invoice, Payment consumer, navigation action, dan
Data Exchange telah dicutover.

Local evidence: scoped ESLint PASS; Next production build/TypeScript PASS;
SQL transaction/delimiter scan PASS; scoped diff-check PASS. Supabase DB lint
tidak tersedia karena local Postgres tidak berjalan (`Failed to connect`),
bukan lint finding. Live SQL belum dijalankan agent.

Manual gate: migration → restart Backoffice → postflight ACP-6E → behavior
ACP-6E → regression G5 Phase-11 → regression G5 Phase-14 → optional-tolerance
postflight → postflight ACP-6E ulang. Berhenti pada error/`FAIL`. Smoke Finance
tetap ditunda ke closing UAT.

### 2026-08-13 — ACP-6D USER-PASS; ACP-6E SUPPLIER INVOICE PREFLIGHT READY

User mengonfirmasi forward-fix Customer Balance, postflight, behavior, serta
regression Phase-49/52/56 seluruhnya PASS. ACP-6D sekarang database-live
`ENFORCED`; authenticated Finance smoke tetap ditunda ke closing UAT sesuai
keputusan sebelumnya.

Gate berikutnya dibuka hanya sebagai ACP-6E SELECT-only. Ditambahkan:

- `supabase/diagnostics/acp_phase6e_supplier_invoice_permission_preflight.sql`;
- `docs/runbooks/ACP6E_SUPPLIER_INVOICE_PERMISSION_PREFLIGHT.md`.

Diagnostic mengaudit schema/routine invoice, matching dan tolerance, pemisahan
maker-validator, immutable validated/AP evidence, Supplier Payment consumer
boundary, tenant isolation, browser grant, dan Financial Event `HOLD`. Tidak ada
migration/RPC/UI live yang dijalankan agent. Next safe step: jalankan seluruh
ACP-6E preflight dan kirim semua row; berhenti bila ada `BLOCKER`.

### 2026-08-13 — ACP-6D WIND_DOWN REGRESSION FORWARD-FIX LOCAL READY

Regression G4 Phase-49 gagal pada koreksi `DEBIT` setelah feature Customer
Balance dimatikan. Root cause bukan role fixture: domain sengaja memindahkan
policy dengan liability ke `WIND_DOWN`, tetapi generic ACP feature gate
mengosongkan capability sebelum domain core dapat menyelesaikan liability.

Ditambahkan forward migration `20260813100000` yang membuat resolver tetap
role- dan override-aware hanya ketika permission `finance.customer_balances`
memiliki policy `WIND_DOWN`. Setelah saldo mencapai nol dan policy menjadi
`DISABLED`, Company dengan histori hanya mempertahankan `VIEW/EXPORT` untuk
statement/audit; mutation tidak dibuka dan Company tanpa histori tetap ditutup.
Phase-49 juga mengaktifkan rollback-only entitlement Company B agar
cross-Company negative test mencapai pemeriksaan tenant, bukan terhenti pada
feature gate. Phase-52 dan Phase-56 diaudit penuh: keduanya tidak memanggil RPC
Backoffice ACP dan tetap menggunakan Sale/open-session authority; fixture
feature serta active-company context sudah lengkap sehingga tidak perlu diubah.

Local evidence: delimiter/transaction static scan PASS untuk migration,
postflight, serta ketiga regression; Phase-49/52/56 call-path audit selesai.
Manual gate: jalankan `20260813100000` → postflight ACP-6D → Phase-49 →
Phase-52 → Phase-56 → postflight ulang. Jangan menandai ACP-6D regression PASS
sebelum seluruh output live tersebut dikonfirmasi user.

Regression Phase-52 kemudian mencapai konflik kontrak Phase-56:
skenario kembalian Cash memakai Customer pertama yang baru saja menerima saldo
Rp20. Runtime benar menolak Sale biasa dengan
`FULL_CUSTOMER_BALANCE_USAGE_REQUIRED`. Fixture diperbaiki memakai Customer
kedua bersaldo nol untuk membuktikan returned-change, sementara Customer utama
tetap membuktikan credit Rp20 dan idempotency. Tidak ada runtime atau business
rule yang dilonggarkan. Phase-56 diaudit ulang dan tetap menjadi bukti aturan
full-balance tersebut.

### 2026-08-13 — ACP-6D CUSTOMER BALANCE ENFORCEMENT LOCAL READY

User mengirim live preflight ACP-6D tanpa `BLOCKER`/`BACKFILL`. Policy,
ledger/cache reconciliation, source/event/audit, tenant, maker-checker,
canonical schema/routines, dan browser mutation boundary seluruhnya PASS.

Migration `20260813090000` sekarang local-ready. Backoffice Customer Balance
memakai composed `get_finance_customer_balances`; statement memakai `VIEW`,
request memakai `MANAGE`, review memakai `APPROVE/REVIEW`, dan export XLSX
bulanan memakai `EXPORT`. Proven G4 routines dipertahankan sebagai private
cores. Empat direct table reads ditutup. POS overpayment credit dan balance
tender tidak diubah, Financial Event tidak diproses, dan Journal tidak dibuat.

Local evidence: Backoffice ESLint PASS; Next production build/TypeScript PASS;
SQL delimiter/parenthesis/transaction scan PASS. Manual gate: migration →
restart Backoffice → postflight → behavior → regression G4 Phase-49 → Phase-52
→ Phase-56 → postflight ulang. Smoke ACP Finance tetap `PENDING` dan baru
dijalankan bersama pada closing UAT sesuai instruksi user.

Behavioral run pertama berhenti di `CUSTOM_PERMISSION_DENIED` pada composed
VIEW karena fixture Company sintetis belum mengaktifkan entitlement opsional
`customer_balance_enabled`. Test diperbaiki dengan rollback-only
`company_features` upsert yang sama dengan fixture G4 Phase-49/52/56. Runtime
migration tidak diubah; test sekarang memisahkan feature gate dari capability
gate yang memang sedang diuji.

### 2026-08-13 — ACP-6C DATABASE PASS; ACP-6D CUSTOMER BALANCE PREFLIGHT READY

User mengonfirmasi ACP-6C migration, postflight, behavioral test, dan regression
seluruhnya sukses. `finance.deposit_variances` sekarang database-live ENFORCED;
authenticated preset/two-Company/maker-checker smoke sengaja ditunda ke closing
UAT gabungan dan statusnya tetap `PENDING`.

Gate berikutnya dibuka hanya sebagai SELECT-only ACP-6D. Ditambahkan
`supabase/diagnostics/acp_phase6d_customer_balance_permission_preflight.sql`
dan `docs/runbooks/ACP6D_CUSTOMER_BALANCE_PERMISSION_PREFLIGHT.md`. Diagnostic
memetakan Backoffice VIEW, correction MANAGE/APPROVE/REVIEW maker-checker,
ledger/cache reconciliation, policy/feature lifecycle, immutable source/audit,
tenant, Customer master boundary, POS overpayment/balance-tender consumer yang
independen, direct browser read, dan Finance event boundary.

Tidak ada runtime, saldo, request, payment, event, Journal, grant, RLS, atau RPC
yang diubah. Next safe step: jalankan seluruh ACP-6D preflight dan kirim semua
row `check_name,status,details`; berhenti pada `BLOCKER`/`BACKFILL` yang tidak
diperkirakan. Smoke ACP-6B/6C/6D baru dijalankan bersama setelah rangkaian ACP
selesai.

### 2026-08-13 — ACP-6C DEPOSIT VARIANCE ENFORCEMENT LOCAL READY

User mengirim live preflight ACP-6C tanpa blocker/backfill. Schema/routine,
lifecycle, maker-checker, tenant, allocation/request/event/audit reconciliation,
browser mutation boundary, dan satu resolved historical exception seluruhnya
PASS; satu resolution Financial Event tetap HOLD.

Migration `20260813080000` sekarang local-ready. `get_finance_deposit_variances`
memberikan composed list/detail, linked Deposit snapshot, actor, dan member
picker sesuai effective capability. Tiga public mutation memakai
`MANAGE/APPROVE/REVIEW`, sedangkan proven G4 transaction code dipindahkan ke
private cores. Direct SELECT empat tabel dedicated ditutup. Backoffice API dan
tombol action menggunakan effective capability; tidak ada event yang diposting
atau Journal yang dibuat.

Local evidence: Backoffice ESLint PASS; Next production build/TypeScript PASS;
SQL delimiter/parentheses/transaction scan PASS. Manual gate: migration →
restart Backoffice → postflight → behavior → regression G4 Phase-46 →
postflight ulang → authenticated preset/two-Company/maker-checker smoke.
Runtime live masih SHADOW sampai migration dijalankan.

Next safe step setelah user mengonfirmasi database gates PASS: buka ACP-6D
Customer Balance preflight sesuai roadmap. Smoke ACP-6B/6C boleh digabung pada
closing UAT tetapi harus tetap dicatat pending sampai benar-benar dijalankan.

### 2026-08-13 — ACP-6B DATABASE PASS; ACP-6C VARIANCE PREFLIGHT READY

User mengonfirmasi migration, postflight, behavioral test, dan kedua regression
ACP-6B seluruhnya sukses. Authenticated Backoffice/PWA/preset smoke belum
dijalankan dan secara eksplisit ditunda ke closing UAT gabungan; status ini
dicatat `PENDING`, bukan dianggap PASS. `finance.cash_deposits` sekarang
database-live ENFORCED dan Financial Event tetap HOLD.

Gate berikutnya dibuka hanya sebagai SELECT-only ACP-6C. Ditambahkan
`supabase/diagnostics/acp_phase6c_deposit_variance_permission_preflight.sql`
dan `docs/runbooks/ACP6C_DEPOSIT_VARIANCE_PERMISSION_PREFLIGHT.md`. Diagnostic
memetakan composed Backoffice VIEW, responsible-party/resolution MANAGE,
Owner/Admin maker-checker, partial allocation, immutable audit, idempotent
request/event chain, linked Cash Deposit authority terpisah, tenant, direct
browser read, serta Finance HOLD. Tidak ada schema/runtime/grant/business row
yang diubah.

Next safe step: jalankan seluruh ACP-6C preflight dan kirim setiap row
`check_name,status,details`. Berhenti pada BLOCKER/BACKFILL; REVIEW/SETUP adalah
target desain enforcement. Jangan membuat ACP-6C migration sebelum output live
dinilai dan jangan melepas event Deposit Variance dari HOLD.

### 2026-08-13 — ACP-6B CASH DEPOSIT ENFORCEMENT LOCAL READY

User mengirim seluruh live preflight ACP-6B tanpa blocker/backfill. Lifecycle,
session allocation, totals, tenant, direct-write, Financial Event dan variance
coverage seluruhnya PASS; REVIEW/SETUP persis target cutover yang disetujui.

Migration `20260813070000` sekarang local-ready. Backoffice list/detail memakai
`get_finance_cash_deposits` dengan effective `VIEW`; approve/reject memakai
effective `APPROVE/REVIEW`. PWA tetap memakai lima public RPC lama, tetapi
implementasi proven dipindahkan ke private core dan custom restriction hanya
dapat mempersempit existing Store/CLOSED-session authority. Deposit Variance
memakai RPC referensi sempit yang dijaga `finance.deposit_variances VIEW`.
Direct SELECT empat tabel khusus Setor Kas ditutup; Finance event tetap HOLD.

File utama: migration ACP-6B, postflight, rollback-safe behavior, enforcement
runbook, Cash Deposit API, Deposit Variance API, dan `backoffice/src/app/page.tsx`.
Local evidence: Backoffice ESLint PASS; Next production build PASS; TypeScript
PASS. Manual gate: migration → restart apps → postflight → behavior → regression
G4 Phase-43 → regression G4 Phase-46 → authenticated Backoffice/PWA/preset
smoke. Runtime live masih SHADOW sampai migration dijalankan.

Next safe step setelah user mengonfirmasi semuanya PASS: buka ACP-6C hanya
sesuai urutan role-permission roadmap; jangan memproses BANK_DEPOSIT HOLD atau
membuka Journal dari fase ini.

### 2026-08-13 — ACP-6A USER PASS; ACP-6B CASH DEPOSIT PREFLIGHT READY

User mengonfirmasi ACP-6A migration, behavior, dan smoke sukses serta mengirim
postflight seluruhnya PASS/INFO: `finance.expenses` ENFORCED, 13/13 mutation
hooks, 13 private cores tertutup, 16 RPC tersedia, direct Expense table access
tertutup, Cashier workspace valid, shared drawer SELECT tetap dipertahankan,
dan dua Expense Financial Event tetap HOLD.

Gate berikutnya dibuka hanya sebagai SELECT-only ACP-6B. Ditambahkan
`supabase/diagnostics/acp_phase6b_cash_deposit_permission_preflight.sql` dan
`docs/runbooks/ACP6B_CASH_DEPOSIT_PERMISSION_PREFLIGHT.md`. Preflight memetakan
Backoffice VIEW/review, Cashier CLOSED-session Draft/Submit/Cancel, multi-session
allocation, idempotency, totals, variance exception, Finance HOLD, tenant,
direct browser boundary, serta consumer `finance.deposit_variances` terpisah.

Next safe step: user menjalankan seluruh ACP-6B preflight dan mengirim semua
row. Jangan membuat enforcement migration sebelum output live dinilai.

### 2026-08-13 — ACP-6A EXPENSE ENFORCEMENT LOCAL READY

User mengirim ACP-6A live preflight tanpa `BLOCKER`/`BACKFILL`; lifecycle,
totals, tenant, direct-write, drawer coverage, dan schema seluruhnya PASS.
Migration `20260813060000` sekarang local-ready: composed Backoffice
`get_finance_expenses`, PWA `get_pos_expense_categories` dan
`get_pos_expense_workspace`, capability `VIEW/MANAGE/APPROVE/POST/CANCEL_FINAL`,
restriction-only Cashier channel, 13 trusted private cores, dan direct read
closure sembilan tabel khusus Expense. Shared `cash_drawer_movements` serta
`cash_in_documents` tidak dicabut; Finance events tetap `HOLD`.

Backoffice Expense API dan tombol action sudah memakai effective capability.
PWA category/approved Cash/outstanding/additional Cash tidak lagi membaca tabel
Expense langsung. Local evidence: Backoffice ESLint PASS; Backoffice production
build PASS; PWA TypeScript/Vite/PWA build PASS; `git diff --check` PASS.

Manual gate menunggu user: jalankan migration, restart Backoffice/PWA,
postflight, behavior, lalu smoke Backoffice + PWA mengikuti
`docs/runbooks/ACP6A_EXPENSE_PERMISSION_ENFORCEMENT.md`. Runtime live masih
SHADOW sampai migration benar-benar dijalankan. Next safe step setelah seluruh
hasil PASS adalah ACP-6B Finance permission preflight, bukan membuka posting
event Expense yang masih HOLD.

### 2026-08-13 — ACP-5H USER PASS; ACP-6A EXPENSE PREFLIGHT READY

User mengonfirmasi seluruh ACP-5H rollout/regression PASS. Permission
`sales.sales_returns` sekarang database-live ENFORCED; authenticated
preset/two-Company/PWA smoke tetap closing UAT. Manifest, README, gate, role
plan, dan access matrix diperbarui sebagai penutupan ACP-5.

Gate berikutnya dibuka hanya sebagai SELECT-only ACP-6A. Ditambahkan
`supabase/diagnostics/acp_phase6a_expense_permission_preflight.sql` dan
`docs/runbooks/ACP6A_EXPENSE_PERMISSION_PREFLIGHT.md`. Diagnostic memetakan
Category/policy, Draft/Submit/Review/Cancel, Cash/non-Cash disbursement,
settlement/return/additional, Backoffice/PWA read split, Store/session, drawer,
totals/lifecycle, tenant, Finance HOLD, routine, privilege, serta target
permission hook. Tidak ada Expense, drawer, event, jurnal, schema, grant, RPC,
API, atau UI runtime yang diubah.

Next safe step: jalankan seluruh ACP-6A preflight dan kirim setiap row
`check_name,status,details`. Berhenti pada `BLOCKER`; `REVIEW`/`SETUP` adalah
target enforcement. Jangan membuat migration ACP-6A sebelum output live dinilai.

### 2026-08-13 — ACP-5H SALES RETURN ENFORCEMENT LOCAL READY

User mengirim live preflight ACP-5H tanpa blocker/backfill; seluruh invariant
quantity/refund/FIFO/final-effect/tenant/privilege PASS. Migration
`20260813050000` menambahkan composed Backoffice `get_sales_returns`, PWA
open-session `get_pos_returnable_sales`, guard efektif `VIEW/POST/CANCEL_FINAL`,
private final cores, dan menutup direct read lima tabel Return. Backoffice API
dan PWA modal sudah cutover; save Draft Kasir, lifecycle, idempotency, original
FIFO/Bundle restoration, refund ongkir eksplisit, serta Finance HOLD tetap sama.

Local evidence: Backoffice production build PASS; PWA TypeScript/Vite/PWA build
PASS. Ditambahkan postflight, rollback-safe behavior, runbook, manifest, root
README, gate, role plan, dan router. Belum ada Supabase SQL yang dijalankan oleh
agent. Next safe step: jalankan migration, postflight, behavior, regression,
postflight ulang, lalu authenticated preset/two-Company/PWA smoke persis sesuai
`docs/runbooks/ACP5H_SALES_RETURN_PERMISSION_ENFORCEMENT_ROLLOUT.md`. Berhenti
pada `FAIL`, perubahan refund/FIFO/final effect, source PWA kosong, Finance event
keluar dari HOLD, atau kebocoran lintas Company. Jangan membuka direct read.

### 2026-08-13 — ACP-5G USER PASS; ACP-5H SALES RETURN PREFLIGHT READY

User mengonfirmasi migration, postflight, behavior, seluruh regression, dan
closing ACP-5G PASS. `sales.bundles` ditutup database-live ENFORCED;
authenticated preset/two-Company/POS smoke tetap closing UAT. Manifest, README,
gate, dan role plan diperbarui.

Gate berikutnya dibuka hanya sebagai SELECT-only ACP-5H. Ditambahkan
`supabase/diagnostics/acp_phase5h_sales_return_permission_preflight.sql` dan
`docs/runbooks/ACP5H_SALES_RETURN_PERMISSION_PREFLIGHT.md`. Diagnostic memetakan
Backoffice composed VIEW, PWA open-session source/Draft, POST sebagai final
approval tanpa status baru, Draft cancel, direct reads, refund/quantity/FIFO,
Bundle restoration, delivery-fee decision, Finance HOLD, tenant, override,
privilege, dan final-effect coverage. Tidak ada schema, grant, function, API,
UI, Sale, Stock, refund, atau Finance runtime yang diubah.

Next safe step: jalankan seluruh ACP-5H preflight dan kirim semua row
`check_name,status,details`. Berhenti pada `BLOCKER`; `REVIEW` dan `SETUP` adalah
boundary/target enforcement. Jangan membuat migration ACP-5H sebelum live
output dinilai.

### 2026-08-13 — ACP-5G BUNDLE ENFORCEMENT LOCAL READY

User mengirim seluruh live ACP-5G preflight: tidak ada `BLOCKER`/`BACKFILL`;
catalog SHADOW, schema, privilege, tenant, composition, sales UOM, virtual stock,
dan posted allocation invariant PASS. REVIEW/SETUP tepat menunjukkan target
composed read dan permission hook.

Ditambahkan migration `20260813040000`, postflight, rollback-only behavioral
test, serta rollout runbook. Migration membuat `get_sales_bundles(boolean)`,
menjaga save Product Bundle + sales UOM + composition atomik di private core,
menjaga availability pada VIEW, mengaktifkan `sales.bundles`, dan mencabut
direct read hanya pada dua tabel khusus Bundle. POS checkout/component FIFO,
Sales Return allocation, Product biasa, shared Stock/Sale/FIFO tables, import,
dan Finance tidak berubah. Backoffice Bundle sekarang memakai composed RPC;
bug lama yang membaca capability Minimum Stock untuk tombol Bundle juga diganti
menjadi capability Bundle sebenarnya.

Evidence lokal: SQL delimiter/parenthesis seimbang, scoped diff-check PASS,
Backoffice lint PASS, production build PASS. Migration SHA-256
`83cc3ac4fe8a210a8e0fb3cdd6444cd216dd5c9e742600ad0369f98849a10034`.
Belum ada SQL live. Next safe step: migration → postflight all PASS → behavior
→ regression berurutan dalam runbook → postflight ulang → authenticated
preset/two-Company/POS Bundle smoke. Stop pada error/FAIL/regression berubah.

### 2026-08-13 — ACP-5F G4 PRICELIST FIXTURE IDENTITY FIX

The corrected regression reached G4 Phase 5 and failed on normalized Pricelist
code `GLOBAL`. Company provisioning already owns that preserved technical code;
the rollback-only deterministic resolver fixture reused it after merely
demoting the provisioned row. Updated only the fixture code to `G54-GLOBAL`.
The fixed UUID, default handover, Product-UOM rules, Customer assignments,
expected prices, resolver calls, and production runtime remain unchanged.

Static structure and scoped diff-check PASS. Rerun only G4 Phase 5, then
continue the ACP-5F runbook from the next regression step.

### 2026-08-13 — ACP-5F PRICELIST REGRESSION FIX

The first ACP-5F regression run reached G2 Phase 12 and failed because that
historical test still created the retired exclusive Customer-Pricelist model:
`pricelists.customer_id` plus `is_default=true`. Runtime correctly rejected it
through `pricelists_reusable_customer_scope_check`; no production invariant or
ACP-5F migration defect was indicated.

Updated the rollback-only regression suite, not applied migrations or business
data. G2 Phase 12 now uses the canonical code-less reusable Pricelist RPC,
assigns the reusable Customer Pricelist through `customers.default_pricelist_id`,
tests Walk-In denial there, verifies atomic Global-default handover, and checks
the ACP-5F public/legacy RPC boundary. G2 default-guard now uses the same
canonical RPC. G2 reusable-customer privilege assertions now require the
code-less guarded wrapper and deny the internal code-bearing overload. G4
Cashier resolver fixture demotes the auto-provisioned rollback-only Global
default before installing its deterministic default row.

Static evidence: all four corrected tests have balanced parentheses/tagged DO
blocks and scoped diff-check PASS. No migration checksum changed. Next safe
step is rerun corrected G2 Phase 12, then continue the ordered ACP-5F regression
list; stop on the first new error.

### 2026-08-13 — ACP-5F PRICELIST ENFORCEMENT LOCAL READY

User returned the complete ACP-5F preflight with no blocker or backfill.
Catalog, schema, default Global, reusable Customer assignment, Store scope,
Product-UOM rule, posted Sale snapshot, direct-write, tenant override, and both
server pricing resolver routines PASS. REVIEW/SETUP exactly match the approved
Backoffice/POS/Offline authority split.

Added migration `20260813030000`, postflight, rollback-only behavior, and an
ordered rollout runbook. Backoffice list/detail now consumes one composed
`VIEW` RPC; save uses `MANAGE`; Data Exchange adds Pricelist CSV under
`EXPORT`. POS online uses an active open-session Store-scoped reference RPC,
while the existing Offline snapshot and price resolver remain unchanged.
Customer assignment stays under `contacts.customers`. Four Pricelist table
reads close only after application cutover. The older code-bearing mutation
overload was also found and explicitly quarantined from browser execution so it
cannot bypass the new wrapper.

Local evidence: targeted Backoffice ESLint PASS; targeted PWA lint PASS;
Backoffice production build PASS with the new `/api/sales/pricelists/export`
route; PWA production build PASS with only the existing large-chunk warning;
active app scan finds zero direct reads of the four Pricelist relations. SQL
parentheses and scoped diff-check PASS. Migration SHA-256
`C4FE6BAAF1EAE5920F6D57E12A0D53C202DB321FF8FA151F9161A34770DDC103`;
postflight `A0695A3A20303A1F450D2AB47CB792BCAAA758339F8485D77A51DF1C1AEE0DDF`;
behavior `8C45E12BEEEF2FFDCCA2C4309CF731859B3E5A825D518EDA3C009856AD92F015`.

No ACP-5F SQL is live yet. Next safe step is manual execution of the enforcement
runbook in exact order. Stop on SQL error, postflight FAIL, pricing regression,
empty POS Pricelist, or cross-Company leak. ACP-5G must not open until ACP-5F
closes.

### 2026-08-13 — ACP-5E LIVE PASS; ACP-5F PRICELIST PREFLIGHT READY

User confirmed the complete ACP-5E migration, postflight, behavior, and
regression all pass. Treat `sales.sales_documents` as database-live ENFORCED.
Authenticated restriction-preset and two-Company smoke remains a closing UAT
item and does not reopen the proven Invoice/Delivery database boundary.

Opened only ACP-5F as SELECT-only. Added
`acp_phase5f_pricelist_permission_preflight.sql` and its runbook. The audit
separates Backoffice `VIEW`/`MANAGE`/`EXPORT` from Customer assignment,
open-session POS price selection, and the Offline policy snapshot. It also
checks catalog/schema/RPC privilege, server resolver references, default
Global and reusable Customer Pricelist contracts, Store scope, Product-UOM
rules, tenant overrides, final Sale snapshot references, and runtime inventory.
No schema, grant, runtime status, price, rule, Customer assignment, Sale,
Offline queue, application, or audit row changed.

Static evidence: one final SELECT statement, mutation-keyword scan zero,
balanced SQL parentheses, and scoped diff-check PASS. Next safe step is to run
the complete ACP-5F preflight and return every `check_name,status,details` row.
Stop on any `BLOCKER`; `REVIEW`/`SETUP` only document the approved cutover and
do not authorize enforcement.

### 2026-08-13 — ACP-5E SALES DOCUMENT ENFORCEMENT LOCAL READY

User returned the complete ACP-5E preflight with no blocker. Invoice snapshot,
Delivery document/line, lifecycle, tenant, duplicate identity, single Financial
Event, direct-write, runtime RPC, and catalog contracts all PASS. The three
REVIEW and three SETUP rows exactly match the approved authority/cutover work.

Added migration `20260813020000`, postflight, rollback-only behavior, and an
ordered rollout runbook. Backoffice now consumes one composed `VIEW` RPC;
Invoice/detail/print and Delivery status use effective capability wrappers;
Data Exchange adds Sales Document CSV guarded by `EXPORT`. PWA final Invoice,
Delivery, and print use independent posted-Sale-visible RPCs, so Cashier does
not inherit Backoffice permission. Four dedicated document table reads close
only after both apps are cut over; shared Sale/Return/Finance tables and final
effects are unchanged.

Local evidence: targeted Backoffice ESLint PASS; Backoffice production build
PASS with the new `/api/sales/documents/export` route; PWA lint and production
build PASS with only the existing large-chunk warning; active app scan finds no
direct reads of the four dedicated document tables. SQL parentheses are
balanced. Migration SHA-256
`66883B55BA991E9D9051AA26D4C47396D82AEDEC33A23AFA49F796D001CA66A3`;
postflight `2368F32188EE7B42C6C57965D557034EC1C69584FC3DD1E9F839E12F9824EF98`;
behavior `F720077264D9AE6061D286924CD92A92F95069591CE4DA15C84C10083121F01C`.

Next safe step is manual execution of the ACP-5E rollout in exact runbook
order. Stop on SQL error, postflight FAIL, or regression failure. ACP-5F must
not open until ACP-5E closes.

### 2026-08-13 — ACP-5D LIVE PASS; ACP-5E SALES DOCUMENT PREFLIGHT READY

User confirmed the complete ACP-5D enforcement rollout, postflight, behavior,
and regression all pass. Treat `purchase.purchase_returns` as database-live
ENFORCED. Authenticated preset and two-Company restriction smoke remains a
closing UAT item and does not reopen the proven G5 Return core.

Opened only ACP-5E as SELECT-only. Added
`acp_phase5e_sales_document_permission_preflight.sql` and its runbook. The
diagnostic inventories the SHADOW `sales.sales_documents` catalog, four
dedicated document relations, canonical Invoice/Delivery/print/status RPCs,
Backoffice VIEW/MANAGE/EXPORT split, PWA posted-Invoice consumer, Sales Return
and Finance independence, direct browser reads, tenant/snapshot/lifecycle,
Delivery line coverage, duplicate document identity, single Financial Event,
and runtime inventory. It performs no DDL, DML, grant, side-effecting function,
or business identity output.

Local evidence: SQL parentheses are balanced `179/179`, exactly one final
`SELECT check_name,status,details`, one statement terminator, and scoped
`git diff --check` passes. Preflight SHA-256:
`ACE267281E67B9AB5036479EE4D0F8FE733772304ECC95C6970A7C83CA960044`.

Next safe step is manual execution of the ACP-5E preflight and return of every
`check_name,status,details` row. Stop on any `BLOCKER`; `REVIEW`/`SETUP` are
expected design targets and do not authorize enforcement. Do not revoke shared
Sale table reads or grant Sales Document users POS, Return, or Finance
authority.

### 2026-08-13 — ACP-5D PURCHASE RETURN ENFORCEMENT LOCAL READY

User returned the complete ACP-5D preflight with no blocker. All tenant,
source-line, lifecycle/header-line, idempotency, nonfinal/final-effect,
cumulative quantity/AP, and Stock–Movement–FIFO invariants PASS. REVIEW/SETUP
matched the planned Backoffice/Cashier read and action split.

Added migration `20260813010000_acp_phase5d_purchase_return_permission_enforcement.sql`,
postflight, rollback-only capability behavior, and ordered rollout runbook.
Backoffice now reads one VIEW-guarded composed Return RPC and resolves separate
Review/Post/Cancel capabilities. PWA now reads one open-session, Store-scoped
Return workspace RPC instead of Return/Receipt/FIFO/UOM tables. Public mutation
signatures remain compatible; G5 cores move private; Cashier Draft remains
session-owned; manager Review/Post/Cancel Final are capability guarded; five
Return table SELECT grants close only after application cutover.

Local evidence: targeted Backoffice ESLint PASS after removing one obsolete
role import; Backoffice production build PASS; PWA targeted lint PASS; PWA
production build PASS with existing large-chunk warning only; active app scan
finds zero references to the five Return tables. SQL parentheses/delimiters and
scoped diff-check PASS. Migration SHA-256
`C292DB2F20F347FA9D3B16F34FA4F8816614CAE487FED2B469154FC15345118C`;
postflight `FE045A14F59B3AFCC339728044D8CB51684A227275A049224AD0E3EA2B484D4E`;
behavior `086484052DFF61DE4BC6AADA5D37867C5C733811E05A87864CA7426E0BE1753E`.
No ACP-5D SQL is marked live yet. Next safe step is the enforcement runbook;
stop on SQL error or postflight FAIL.

### 2026-08-13 — ACP-5C SQL PASS; ACP-5D PURCHASE RETURN PREFLIGHT READY

User confirmed the corrected ACP-5C behavior and all remaining SQL/regression
steps succeed. Treat `purchase.supplier_orders` as database-live ENFORCED;
authenticated preset/two-Company smoke remains a closing UAT item rather than a
reason to reopen its database design.

Opened only ACP-5D as SELECT-only. Added
`acp_phase5d_purchase_return_permission_preflight.sql` and its runbook. The
diagnostic inventories the SHADOW `purchase.purchase_returns` catalog, five
Return relations, four mutation RPCs, Backoffice versus Cashier authority,
direct browser reads, narrow Receipt/Supplier/Store/Warehouse and PWA
Receipt/FIFO/UOM sources, lifecycle/header-line/idempotency, final-effect/AP,
Stock–Movement–FIFO reconciliation, override tenant integrity, and runtime
inventory. It performs no DDL, DML, grant, function call with side effects, or
business identity output.

Static evidence: diagnostic has balanced parentheses `195/195`, one final
SELECT statement, and SHA-256
`D989E85143BDCC43B89F701F4BF1DF52DC192ABAD8F4CD0B8293FB1ADE8BE8AA`.
Next safe step is manual execution of the ACP-5D preflight and return of every
`check_name,status,details` row. Stop on any `BLOCKER`; `REVIEW`/`SETUP` alone
do not authorize enforcement.

### 2026-08-13 — ACP-5C SUPPLIER ORDER ENFORCEMENT LOCAL READY

User returned the complete ACP-5C preflight with no blocker. Lifecycle,
allocation/header reconciliation, zero-final-effect, tenant integrity, mutation
RPC inventory, direct-write boundary, and catalog contract PASS. REVIEW/SETUP
confirmed the planned split between Backoffice Supplier Order authority,
Cashier-owned Stock Request, Goods Receipt open-session consumption, and
independent Purchase Return/Supplier references.

Added migration `20260813000000_acp_phase5c_supplier_order_permission_enforcement.sql`.
It creates a VIEW-guarded composed Backoffice workspace and narrow POS Stock
Request, Goods Receipt, and Purchase Return reference RPCs; wraps manager/order
mutations with effective capability checks; preserves requester-owned Cashier
cancel; moves trusted legacy implementations private; sets
`purchase.supplier_orders` ENFORCED; and closes authenticated SELECT on the
seven Request/Order relations only after application cutover. Backoffice
navigation/actions and PWA consumers now use those scoped RPCs. Added
postflight, rollback-only behavior, and an ordered rollout/regression runbook.

Local evidence: targeted Backoffice ESLint PASS; Backoffice production build
PASS; targeted PWA lint PASS; PWA production build PASS (existing large-chunk
warning only); active application direct-read scan for the seven relations is
zero; SQL delimiter/parenthesis checks PASS; scoped diff-check PASS. Full
Backoffice lint exceeded 120 seconds without emitting an error, so the targeted
lint plus production build are the local evidence. No Supabase SQL from this
package is marked live yet.

First user execution of the ACP-5C behavior reached the final browser-boundary
assertion but failed with `permission denied for schema private`. This proved
the private-schema denial itself; the test incorrectly attempted to resolve a
private-qualified function name while already running as `authenticated`.
Corrected the rollback-only test to assert no `private` schema `USAGE`; the
owner-run postflight remains responsible for the individual private-core ACL.
Corrected test SHA-256:
`34AB6356938889E4D7A05E20D6208180A8BDC4601C851F9CB0E1018C80741A7F`.

Next safe step: execute
`runbooks/ACP5C_SUPPLIER_ORDER_PERMISSION_ENFORCEMENT_ROLLOUT.md` exactly in
order and stop on SQL error or postflight FAIL. After the final postflight,
perform authenticated Company Admin/Store Manager/Cashier restriction and
two-Company isolation smoke. Only then mark ACP-5C live and open ACP-5D
Purchase Return preflight.

### 2026-08-13 — ACP-5B SUPPLIER LIVE PASS; ACP-5C PREFLIGHT READY

User confirmed every ACP-5B Supplier SQL test succeeds. Treat
`contacts.suppliers` as live ENFORCED: Supplier/Product-Supplier management,
import/export, navigation, Purchase/Finance references, PWA Goods Receipt and
Purchase Return, regression, and authenticated smoke are accepted. Purchase,
Finance, and Cashier consumers retain independent authority.

Opened only the next roadmap boundary as SELECT-only ACP-5C for
`purchase.supplier_orders`. Added aggregate-only diagnostic and runbook covering
the seven Stock Request/Supplier Order relations, SHADOW catalog, mutation RPCs,
tenant/lifecycle/allocation/header reconciliation, zero-effect Order, direct
browser access, Stock Request Cashier split, Goods Receipt consumer, and narrow
Supplier/Product/UOM/Store/Warehouse references. No schema, grant, runtime
permission status, Purchase document, stock, FIFO, AP, Finance, application, or
audit data changed.

Local verification is static only. Next safe step: run the entire ACP-5C
preflight and return every `check_name,status,details` row; stop on any
`BLOCKER`. `REVIEW`/`SETUP` are expected design inventory and do not authorize
enforcement or direct-read closure.

### 2026-08-13 — ACP-5B SUPPLIER ENFORCEMENT LOCAL READY

User returned the complete ACP-5B preflight with no blocker. Supplier identity,
Product-Supplier preferred/UOM/value contract, tenant references, direct-write
boundary, import state, and operational-document integrity PASS. REVIEW/SETUP
confirmed the expected composed-read, consumer authority, and capability-hook
work.

Implemented migration `20260812230000`: `contacts.suppliers` is prepared as an
ENFORCED key with VIEW/MANAGE/EXPORT/IMPORT. Supplier/Product-Supplier UI and
Data Exchange use guarded RPCs; direct authenticated Supplier/audit table reads
and legacy browser writers close. Supplier Order, Purchase Return, Supplier
Invoice, and Supplier Payment use their own permission references. PWA Goods
Receipt and Purchase Return were explicitly migrated from direct Supplier
reads to Store/open-session-scoped reference RPCs so Cashier compatibility does
not widen Contacts access.

Added SELECT-only postflight, rollback-safe restriction/Finance/Purchase/
two-Company behavior, G2 Supplier regression update, and full rollout runbook.
No live SQL was executed by the agent. Targeted Backoffice/PWA lint PASS;
Backoffice production build PASS (62 pages) and PWA production build PASS.
SQL dollar delimiters and parentheses are balanced, postflight mutation scan is
clean, active application scan has zero direct Supplier/Product-Supplier reads
or legacy writer calls, and scoped `git diff --check` has no errors. Migration
SHA-256: `0e755a1e...6407dce`.

Next safe step: execute all 11 steps in
`runbooks/ACP5B_SUPPLIER_PERMISSION_ENFORCEMENT_ROLLOUT.md`, stopping on any
error/FAIL, then perform authenticated preset/Purchase/Finance/PWA/two-Company
smoke. Do not mark Supplier live or open ACP-5C Purchase until that evidence is
returned.

### 2026-08-13 — ACP-5A LIVE PASS; ACP-5B SUPPLIER PREFLIGHT READY

User confirmed every ACP-5A rollout step succeeds and all results PASS. Treat
`contacts.customers` as live ENFORCED; POS quick-create, Customer Balance/
credit, and Sales reference paths remain independently authorized.

Opened only the next roadmap boundary as SELECT-only ACP-5B for
`contacts.suppliers`. Added aggregate-only diagnostic and runbook covering
Supplier/Product-Supplier schema, tenant and operational references,
normalized identity, preferred relation, purchase UOM, value/last-price
metadata, direct browser access, mutation routines, nonterminal Supplier
imports, and the required authority split across Purchase, Product, Finance,
and Data Exchange. No schema, grant, runtime permission status, Supplier,
Purchase/AP document, stock, import job, or application code changed.

Static SQL safety and documentation checks are local verification only. Next
safe step: run the full ACP-5B preflight and return every row; stop on any
`BLOCKER`. `REVIEW`/`SETUP` are expected design inventory, not permission to
cut off shared Supplier reads or enforce Purchase/Finance early.

### 2026-08-13 — ACP-5A CUSTOMER ENFORCEMENT LOCAL READY

User returned the ACP-5A preflight with no blocker. Identity/category,
parent/Pricelist, Walk-In, tenant, balance-cache, direct-write, and existing
mutation invariants PASS; REVIEW/SETUP rows confirmed the expected composed
read, runtime hook, shared-consumer, and explicit import work.

Implemented migration `20260812220000`: `contacts.customers` is prepared as the
first ACP-5 enforced key. Customer/Category management uses effective
View/Manage, Customer Category adds explicit Import, export uses Export, and
browser direct reads of Customer/Category/audit close. POS open-session
quick-create/reference, Sales Document/Return labels, and Finance Customer
Balance/credit remain separately authorized and cannot be widened through the
Contacts key. Backoffice navigation, Customer workspace, Data Exchange, Sales,
Finance, PWA online catalog, and legacy sync consumers were cut over.

Added postflight, rollback-safe capability/credit/restriction/two-Company
behavior, legacy G2 privilege-regression compatibility, rollout runbook,
manifest, and living docs. No live SQL was executed
by the agent. Backoffice targeted lint and production build PASS; PWA production
build PASS. SQL delimiters, SELECT-only postflight scan, and scoped diff check
PASS. Migration SHA-256 is `ec3825f6...505d748`. Next safe step: execute the
nine SQL steps in the ACP-5A rollout runbook and stop on any error/FAIL; then
perform authenticated preset/POS/Sales/Finance/two-Company smoke. Do not open
Supplier/Purchase ACP cutover before Customer closure is confirmed.

### 2026-08-12 — ACP-4I LIVE PASS; ACP-5A CUSTOMER PREFLIGHT READY

User mengonfirmasi seluruh langkah ACP-4I sukses. Treat Minimum Stock sebagai
live ENFORCED dan Inventory selesai pada sembilan key; authenticated
preset/two-Company UI smoke tetap evidence closure terpisah.

Opened only ACP-5A as SELECT-only Customer permission audit. Added diagnostic
and runbook covering Customer/Category management, one-level parent and
Pricelist references, Walk-In/system invariants, balance-ledger cache,
tenant/direct-write boundary, composed-read and mutation hooks, Data Exchange
Category import decision, plus mandatory separation from POS quick-create,
Sales consumers, and Finance Customer Balance authority. No schema, grant,
Customer, balance, Pricelist, import job, permission override, or enforcement
status changed. Next safe step: run the complete ACP-5A preflight and return
every row; stop on any BLOCKER.

**Status dokumen:** ACTIVE — wajib diperbarui setiap agent
**Terakhir diperbarui:** 2026-08-13
**Workspace:** `C:\Users\sbi_l\OneDrive\Documents\POINT OF SALES`

### 2026-08-12 — ACP-4I MINIMUM STOCK ENFORCEMENT LOCAL READY

User returned the ACP-4I preflight with zero blockers. Dependency, schema,
catalog, threshold/Base-UOM, active reference, tenant, audit, direct-write, and
nonterminal import checks PASS. Three REVIEW and three SETUP rows exactly
identified direct browser reads, shared Product/Master/Stock dependencies,
Company-wide Store Manager scope, missing composed RPC, and absent
mutation/import capability hooks.

Implemented migration `20260812210000`: `inventory.minimum_stock` becomes the
ninth enforced Inventory key. One composed RPC supplies settings, narrow
Product/Base-UOM and authorized Warehouse references, pair balances, and audit.
Owner/Admin/Warehouse Admin remain Company-wide; Store Manager is restricted
to active Store-assigned warehouses. Mutation plus all four import lifecycle
wrappers enforce capability server-side; Data Exchange export/template/import
and job APIs use the same effective authority. Direct browser setting/audit
reads are closed. Minimum Stock remains a non-blocking notice and creates no
Stock, Movement, FIFO, Request, Order, or Finance effect.

Added postflight, rollback-safe four-role/two-Company behavior, Phase-46
regression, generic ACP-4 closing update, rollout runbook, and docs. Live SQL
has not been run by the agent. Static SQL delimiter/mutation checks and
`git diff --check` PASS; migration SHA-256 is
`f26e1754...dccc4df5`. Backoffice lint and production build PASS (62 generated
pages/routes). Next safe step: run the six SQL steps in the ACP-4I rollout
runbook and stop at any error/FAIL.

### 2026-08-12 — ACP-4H LIVE PASS; ACP-4I MINIMUM STOCK PREFLIGHT READY

User mengonfirmasi seluruh langkah ACP-4H PASS setelah active-context fixture
fix. Treat Opening Stock as live ENFORCED; authenticated preset/two-Company UI
smoke tetap evidence penutupan terpisah.

Opened only the next roadmap boundary as SELECT-only ACP-4I for
`inventory.minimum_stock`. Diagnostic mengaudit catalog SHADOW, schema dan
guarded mutation existing, composed read/reference/balance cutover, Base-UOM
threshold precision, active operational reference, tenant/audit, direct
browser boundary, type-aware import, global export, dan nonterminal job. Scope
Store Manager ditandai REVIEW karena runtime existing masih Company-wide dan
tidak diubah diam-diam. Added diagnostic plus runbook and synchronized router,
gate, manifest, and root README. No schema, grant, setting, stock, Movement,
import job, alert, or permission status changed. Next safe step: run the full
ACP-4I preflight and return every row; stop on any BLOCKER.

### 2026-08-12 — ACP-4H BEHAVIOR ACTIVE-CONTEXT FIX

First manual ACP-4H behavior execution reached the Manager negative-scope case
but was correctly rejected by the server with `ACTIVE_COMPANY_CONTEXT_MISMATCH`:
the rollback-safe fixture changed JWT identity from Accounting to Manager
without establishing that Manager's user-scoped active Company context. Added
`set_active_company_context(...,'ACP4H_TEST')` after the Manager, Finance, and
Admin identity switches. No migration, runtime function, permission, document,
Stock, FIFO, Movement, or business data changed. Next safe step: rerun only the
ACP-4H behavioral test, then continue the existing rollout at G3 regression.

### 2026-08-12 — ACP-4H OPENING STOCK ENFORCEMENT LOCAL READY

User rerun preflight mengonfirmasi blocker false-order sebelumnya hilang dan
seluruh lifecycle, tenant, no-prior-Movement, posted evidence, serta global
Stock reconciliation PASS. REVIEW/SETUP persis menunjukkan role UI lama,
browser table reads yang terlalu luas, helper executable, dan belum adanya
composed RPC.

Implemented migration `20260812200000`: `inventory.opening_stock` menjadi
ENFORCED; Company Owner/Admin dapat Post, Finance dan Store Manager dapat
prepare Draft, Accounting report-only, dan Store Manager hanya untuk Gudang
Store membership aktif. Public save/post signature dipertahankan sebagai
capability wrapper atas private atomic core. Satu composed RPC mengembalikan
document-linked Product/Gudang, balance, Opening Movement, FIFO, Event, audit,
serta scoped Movement eligibility tanpa membuka ledger Company penuh. Direct
browser read tiga tabel dan helper lama ditutup. Backoffice API/UI kini memakai
effective capabilities dan RPC tersebut.

Added SELECT-only postflight, rollback-safe four-role/two-Company behavior,
generic ACP-4 closing expectation/hook, rollout runbook, dan docs. Backoffice
lint serta production build PASS (62 pages/routes). Live SQL belum dijalankan
agent. Next safe step: jalankan enam langkah dalam runbook ACP-4H; berhenti pada
error/FAIL. Minimum Stock tetap SHADOW.

### 2026-08-12 — ACP-4H MOVEMENT ORDER DIAGNOSTIC FIX

The first ACP-4H preflight reported one prior non-Opening Movement. A read-only
service diagnosis exposed no identities and proved it was an Adjustment whose
`created_at` was 0.215 seconds before Opening `posted_at`, while its canonical
Movement `posted_at` was 0.152 seconds after Opening. This is PostgreSQL
transaction-start timestamp behavior during a lock wait, not an invalid
Opening Stock sequence. Corrected only the SELECT-only diagnostic to order by
`COALESCE(movement.posted_at,movement.created_at)`. No business data, schema,
permission, or runtime changed. Static mutation scan, delimiter balance, and
diff check PASS. Next safe step: rerun the full ACP-4H preflight; the false
blocker must clear before enforcement work starts.

### 2026-08-12 — ACP-4G LIVE PASS; ACP-4H OPENING STOCK PREFLIGHT READY

User confirmed the corrected ACP-4G behavior and every remaining rollout step
PASS. Treat Stock Opname as live ENFORCED; seven of nine Inventory keys are now
enforced. Authenticated preset/two-Company UI smoke remains closure evidence.

Opened only the next roadmap boundary as SELECT-only ACP-4H for
`inventory.opening_stock`. The audit covers approved Draft/Post roles, current
hardcoded UI/API/direct-table consumers, composed proof and narrow reference
requirements, no-prior-Movement eligibility, zero-cost reason, lifecycle,
version/idempotency, tenant references, POSTED Movement/FIFO/Finance evidence,
and global Stock reconciliation. It explicitly flags the catalog/runtime role
misalignment for review instead of silently changing authority. Added the
aggregate-only diagnostic and runbook; updated router, gate, manifest status,
handoff, and root README. No schema, grant, document, Stock, FIFO, Movement,
event, or permission status changed. Next safe step: run the full ACP-4H
preflight and return every row. Stop on BLOCKER. Minimum Stock remains SHADOW.

### 2026-08-12 — ACP-4G BEHAVIOR STORE COLUMN FIX

First execution of ACP-4G behavior stopped while inserting its rollback-only
Store fixture because it used noncanonical `code/name`. Corrected only the test
to canonical `store_code/store_name`, matching existing schema and ACP/G1
fixtures. The failure occurred before the DO behavior block and the surrounding
transaction rolled back; migration/postflight need not be rerun. Static diff
check PASS. Next safe step: rerun ACP-4G behavior step 3, then continue steps
4–7 if it passes.

### 2026-08-12 — ACP-4G STOCK OPNAME ENFORCEMENT LOCAL READY

User returned the ACP-4G live preflight with no blocker. All lifecycle,
tenant, direct-write, duplicate count/post identity, Adjustment evidence,
Stock–Movement/FIFO, catalog, and trusted-core invariants PASS. Expected three
REVIEW plus two SETUP rows confirmed the browser table reads, missing composed
report, and eight unhooked public lifecycle routines.

Implemented migration `20260812190000`. Backoffice now uses one VIEW-guarded
composed RPC for sessions, lines, attempts, used Gudang, actor labels, and
Adjustment proof. Review/Post/Cancel API and UI actions follow their effective
capability. Four Opname tables and legacy reference helpers are closed to the
browser. The blind-count channel remains separate: existing Store role and
Warehouse assignment are the authority ceiling, while custom restrictions can
only reduce access and never reveal system/expected/physical/variance values.
Post still reaches the private trusted Adjustment core from ACP-4F.

Added SELECT-only postflight, rollback-safe Cashier/Manager/Finance/two-Company
behavior, corrected generic ACP-4 expected status/hooks, ACP-4F compatibility
regression, rollout runbook, and manifest hash `dfa52796...26f82e67`.
Backoffice lint and production build PASS (62 generated routes/pages). No live
SQL was executed by the agent. Next safe step: run all seven SQL steps in the
ACP-4G rollout runbook; stop on error/FAIL.
Opening Stock and Minimum Stock remain `SHADOW`.

### 2026-08-12 — ACP-4F LIVE PASS; ACP-4G STOCK OPNAME PREFLIGHT READY

User confirmed the corrected G3 Opname regression and the generic ACP-4 closing
diagnostic are PASS/INFO. ACP-4F is live ENFORCED; six of nine Inventory keys
are now enforced. Opened only the next roadmap boundary as SELECT-only ACP-4G
for `inventory.stock_opnames`.

The source audit separates Backoffice report/review/post from the cashier blind
count channel. It checks eight public workflow routines, direct read/write,
tenant and lifecycle integrity, count attempts, recount/supersede, idempotency,
posted Adjustment evidence, Stock–Movement/FIFO reconciliation, and the private
Adjustment core retained by ACP-4F. Cashier Store/Warehouse eligibility must
remain intact without exposing Backoffice quantities or widening Store scope.

Added the aggregate-only preflight and runbook; updated router, active gate,
and root README. No schema, permission status, grant, Opname, Stock, FIFO,
Movement, Adjustment, API, or UI behavior changed. Next safe step: run
`supabase/diagnostics/acp_phase4g_stock_opname_permission_preflight.sql` in
full and return every row. Stop on `BLOCKER`; `REVIEW`/`SETUP` are expected
implementation targets. Do not enforce Opening Stock or Minimum Stock.

### 2026-08-12 — G3 OPNAME REGRESSION FIXTURE ALIGNED TO CANONICAL SALE MOVEMENT

During the ACP-4F rollout regression, the rollback-safe G3 Phase 10 Opname
test failed before exercising Opname because its two synthetic `SALE` Movement
rows still used the pre-G4 snapshot shape. Corrected the test fixtures to use
`reference_table='sales_headers'` and distinct non-null `source_line_id` values,
matching `stock_movements_sale_snapshot_complete` and the canonical Sale
posting runtime. No production function, constraint, permission, stock data,
or migration was changed or relaxed. Targeted SQL diff validation PASS.

Manual gate: rerun only
`supabase/tests/g3_phase10_stock_opname_foundation_tests.sql`; after PASS,
continue with the ACP-4F postflight and generic ACP-4 closing diagnostic from
the existing rollout runbook.

### 2026-08-12 — ACP-4F STOCK ADJUSTMENT ENFORCEMENT LOCAL READY

User returned the ACP-4F live preflight with no BLOCKER. All lifecycle,
tenant, direct-write, idempotency, FIFO, Movement, catalog, and routine
invariants PASS. Expected REVIEW/SETUP confirmed five browser-readable tables,
no composed read RPC, three unhooked document mutations, Master-dependent
references, and the public Stock Opname-to-Adjustment call path.

Implemented migration `20260812180000`. Four Adjustment mutations, including
the otherwise-unexposed Reason mutation, are guarded by effective capability.
The page/API now consume one VIEW-guarded composed RPC with narrow Product,
Gudang, Reason, balance, allocation, and Movement data; five direct browser
table reads are closed. UI actions separately follow CREATE_DRAFT, EDIT_DRAFT,
POST, and CANCEL_FINAL. `post_stock_opname` retains its public signature but its
proven body now invokes private Adjustment cores. A narrow role-guarded RPC
keeps the active Opname page able to show only its generated Adjustment links.

Added SELECT-only postflight, rollback-safe preset/two-Company behavior,
mandatory G3 Opname regression in the rollout, corrected generic ACP-4 status,
runbook, and manifest hash `62e76f8...1a538`. Backoffice lint PASS and production
build PASS (62 generated routes/pages). No live SQL was executed by the agent.
Next safe step: execute the six SQL steps in the ACP-4F rollout runbook and
return all output. Stop on error/FAIL. Do not enforce Stock Opname, Opening
Stock, or Minimum Stock yet.

### 2026-08-12 — ACP-4E LIVE PASS; ACP-4F ADJUSTMENT PREFLIGHT READY

User confirmed every ACP-4E migration/postflight/behavior/closing result is
PASS/INFO. Treat `inventory.stock_transfers` as live ENFORCED; authenticated
preset/two-Company UI smoke remains closure evidence.

Opened only the next roadmap boundary as SELECT-only ACP-4F for
`inventory.stock_adjustments`. Source audit confirms current Adjustment posting
is atomic, idempotent, tenant-scoped, FIFO/Movement-backed, audited, and emits
Finance events. It also confirms `post_stock_opname` currently calls the public
Adjustment Save/Post routines, so enforcement must introduce a trusted private
core: authorized Opname posting must keep working without granting standalone
Adjustment access. The browser currently reads five Adjustment relations
directly and uses Master Inventory references; both are explicit REVIEW targets.

Added the aggregate-only preflight and runbook. No permission status, grant,
RPC, schema, document, Stock, FIFO, Movement, Finance event, or UI behavior was
changed. Static check confirms exactly one executable SQL statement with 18
check rows; targeted `git diff --check` PASS (line-ending notices only). Next
safe step: run the full ACP-4F diagnostic and return every row.
Stop on any BLOCKER; REVIEW/SETUP are implementation targets. Do not enforce
Opname, Opening Stock, or Minimum Stock yet.

### 2026-08-12 — ACP-4E STOCK TRANSFER ENFORCEMENT LOCAL READY

User returned the ACP-4E live preflight with no blocker: Transfer lifecycle,
tenant isolation, paired Movement, FIFO/Stock reconciliation, guarded mutation
signatures, and direct-write boundary all PASS. Expected REVIEW/SETUP identified
four browser-readable Transfer tables, no composed read RPC, Master-dependent
Warehouse references, and three unhooked mutations.

Implemented migration `20260812170000`: the proven Save/Post/Cancel functions
are private cores behind capability wrappers; one VIEW-guarded RPC returns
documents, lines, allocation proof, balances, Transfer movements, and narrow
Product/Gudang references; direct authenticated SELECT on four Transfer tables
is revoked. Backoffice navigation/API/actions now use effective VIEW,
CREATE_DRAFT, EDIT_DRAFT, POST, and CANCEL_FINAL capabilities. Finance and
Accounting retain role-baseline VIEW without needing Master Inventory.

Added SELECT-only postflight, rollback-safe two-Company/preset behavior,
corrected generic ACP-4 expected status/hook diagnostics, rollout runbook, and
manifest hash `e91aeef...f554`. Backoffice `npm.cmd run lint` PASS and production
`npm.cmd run build` PASS (62 generated routes/pages). `git diff --check` PASS.
Live DB rollout and authenticated preset/two-Company smoke remain manual. Next
safe step is execute the five SQL steps in the ACP-4E rollout runbook and return
all output. Do not enforce Adjustment/Opname/Opening/Minimum Stock yet.

### 2026-08-12 — ACP-4D LIVE PASS; ACP-4E TRANSFER PREFLIGHT READY

User confirmed the complete ACP-4D migration/postflight/behavior/closing output
contains only PASS/INFO. Treat `inventory.stock_real` and
`inventory.stock_movements` as live ENFORCED together with Master and Product;
authenticated preset/two-Company smoke remains a closure item.

Opened only the next roadmap key as SELECT-only diagnostic:
`inventory.stock_transfers`. Source audit confirms canonical Transfer is already
atomic, FIFO-preserving, paired-Movement, idempotent, tenant-safe, audited, and
direct-write closed. The preflight deliberately records two required cutover
concerns: all four Transfer tables remain directly SELECT-able by authenticated
reviewers, which would bypass a `TANPA_AKSES` override; and the page loads
Warehouse references through Master Inventory even though Finance/Accounting
have Transfer VIEW without Master VIEW. Target design is a guarded composed
Transfer read RPC plus narrow Product/Warehouse references authorized by
Transfer VIEW, never by a client purpose flag.

Added `acp_phase4e_stock_transfer_permission_preflight.sql` and its runbook.
No catalog status, grant, API, RPC, Transfer document, Stock, FIFO, Movement, or
override was changed. Next safe step: user runs the full ACP-4E diagnostic and
returns every row. Stop on BLOCKER; REVIEW/SETUP are implementation targets and
must not be waived. Adjustment/Opname/Opening/Minimum Stock remain SHADOW.

First execution failed before returning rows because the diagnostic referenced
the nonexistent alias `capability_catalog`. The canonical ACP-2 column is
`supported_capabilities`; both the containment check and detail projection are
corrected. This was a SELECT-only parse/bind failure, so no database state or
catalog status changed. Rerun the corrected preflight from the beginning.

### 2026-08-12 — ACP-4D STOCK READ-MODEL ENFORCEMENT LOCAL READY

User returned the ACP-4D live preflight with every Stock/FIFO/Movement,
tenant, RLS, duplicate, and direct-write invariant PASS. The two REVIEW rows
and export SETUP were implementation targets, not data blockers.

Migration `20260812160000` adds two guarded composed reads and changes exactly
`inventory.stock_real` plus `inventory.stock_movements` from SHADOW to
ENFORCED. Stock Real now receives server-derived FIFO value, minimum threshold,
and latest posted Movement without downloading positive FIFO cost layers or the
full Movement ledger to the browser. Kartu Stok uses a separate guarded RPC.
Raw Stock/FIFO/Movement SELECT remains tenant/RLS-scoped for legacy operational
workflows; no client purpose flag can bypass the page/API/export guard.

Backoffice navigation resolves both permissions. Stock Real and Movement APIs
require effective VIEW. Global Data Exchange exposes separate CSV export-only
datasets only with effective EXPORT and replaces source UUID with a human
document number where a canonical document exists. Added postflight,
rollback-safe behavior, corrected generic ACP-4 diagnostic, rollout runbook,
manifest entry, and documentation status.

Local evidence: Backoffice ESLint PASS; Next.js production build PASS (62
static/dynamic pages, including `/api/inventory/export`); `git diff --check`
PASS apart from line-ending notices; migration SHA-256
`7cf5859a3d747c447f3a83b832a6b1ae655ea95d4bd79804c6da02d76f3fe3e6`.
No live SQL was executed by the agent. Next safe step: execute the five SQL
steps in `docs/runbooks/ACP4D_STOCK_READ_MODEL_ENFORCEMENT_ROLLOUT.md`, return
all output, then complete its authenticated preset/two-Company smoke. Do not
open the next Inventory workflow key before this gate passes.

### 2026-08-12 — ACP-4C LIVE PASS; ACP-4D STOCK READ PREFLIGHT READY

User confirmed all ACP-4C migration/postflight/behavior/closing output is
PASS/INFO. Treat `inventory.products` as live ENFORCED together with
`inventory.master_data`; authenticated preset/two-Company UI smoke remains an
ACP closure gate, not a reason to reopen applied SQL.

Opened only the next SELECT-only boundary: ACP-4D audits `stock_real` and
`stock_movements`. Current Stock Real API exposes balances, raw positive FIFO
layers with cost, and up to 20,000 raw movements to calculate summary values in
the browser. The preflight therefore checks reconciliation, tenant references,
RLS/read/write boundaries, override scope, and records mandatory separation:
Stock Real composite/valuation must use its own VIEW; the full immutable ledger
must use Stock Movement VIEW; operational on-hand references remain narrow and
authorized by their own consumer key; distinct exports need EXPORT authority.
No schema, grant, catalog status, API behavior, or stock data changed.

Next safe step: run
`supabase/diagnostics/acp_phase4d_stock_read_models_preflight.sql` and return
every row. Stop on BLOCKER; REVIEW/SETUP must be implemented rather than waived.

### 2026-08-12 — ACP-4C PRODUCT PERMISSION LOCAL READY

User returned ACP-4C preflight with no BLOCKER: direct Product/Product-UOM
write is closed, mutation signatures exist, legacy import execution is closed,
and there are zero overrides/nonterminal jobs. Expected SETUP showed missing
hooks; REVIEW confirmed the shared Product-reference concern.

Migration `20260812150000` preserves three Product/Tax and four generic import
implementations as private cores, recreates compatible public wrappers,
requires MANAGE for Product/UOM/Tax mutation, and requires IMPORT only for jobs
whose type is PRODUCT across create/stage/validate/commit. Other import types
are unchanged. Backoffice adds a VIEW-guarded Product-management endpoint and
closes the old full Product read behind the same Product VIEW boundary.
Separately authorized Stock/Pricelist/Bundle/Supplier consumers use a dedicated
reference endpoint requiring VIEW from at least one approved consumer key; no
client purpose can bypass Product access. Navigation/edit controls and Data
Exchange Product actions use effective capabilities. Permission editor accepts
both enforced Inventory keys. Bundle and Product-Supplier authority are
unchanged.

Added postflight, rollback-safe behavior, rollout runbook, and manifest entry.
Local evidence: Backoffice ESLint PASS and production build PASS including
`/api/master/product-management` and `/api/master/product-references`;
`git diff --check` PASS (line-ending notices only), and migration SHA-256 still
matches the manifest. Manual
migration/postflight/behavior, corrected ACP-4 diagnostic, and authenticated
preset/two-Company/reference smoke remain. Next safe step: execute the five SQL
steps in the ACP-4C rollout runbook and return all output.

### 2026-08-12 — ACP-4B LIVE SQL PASS; ACP-4C PRODUCT PREFLIGHT READY

User confirmed ACP-4B migration, first postflight, rollback-safe behavior, and
closing postflight all success. Rerunning the older generic ACP-4 diagnostic
then reported `non_shadow:1` as a blocker and zero hooks because that diagnostic
still assumed all nine keys SHADOW and only searched the thirteen document
routines. This is stale diagnostic logic, not a runtime regression: the single
non-shadow key is the intentionally enforced `inventory.master_data`, while
its four wrappers were outside the old routine list.

Updated the generic diagnostic to expect Master Data ENFORCED, the other eight
Inventory keys SHADOW, and four effective-capability Master wrappers. Opened
the next roadmap boundary only as SELECT-only ACP-4C Product preflight. It
explicitly inventories atomic Product/UOM mutation, tax, legacy/canonical
import, overrides/history, and the critical shared-read issue: Product
references are consumed by other authorized modules, so management read must
be separated without trusting a client-provided purpose flag. Added runbook.
No new catalog enforcement, grants, schema, or runtime behavior changed. Next
safe step: run corrected `acp_phase4_inventory_pilot_preflight.sql`, then
`acp_phase4c_product_permission_preflight.sql`, and return all rows. The
authenticated ACP-4B preset/multi-Company UI smoke remains pending.

### 2026-08-12 — ACP-4B INVENTORY MASTER ENFORCEMENT LOCAL READY

User returned ACP-4B preflight with the expected Product Category column-grant
BLOCKER and all data-integrity checks safe. The complete one-key cutover is now
local-ready. Migration `20260812140000` closes table plus column-level Category
identity writes, adds guarded/versioned/audited Category RPC, wraps proven
UOM/Warehouse/Category-Tax cores with effective `inventory.master_data/MANAGE`
authorization, and changes only that catalog key from SHADOW to ENFORCED.
Store/Terminal remain read-only; all other permission keys stay SHADOW.

Backoffice now resolves the key into Home/Fast Link navigation, uses a
VIEW-guarded consolidated Master Inventory endpoint, derives edit controls
from effective MANAGE rather than a duplicated role list, and exposes the four
restriction presets only for the enforced key in the grouped user-detail UI.
`LIHAT_SAJA` and `OPERASIONAL` are read-only, `TANPA_AKSES` hides and rejects,
and `IKUTI_ROLE` restores exact role parity. Product Category create/update now
uses the guarded RPC. Added postflight, rollback-safe behavioral test, and
rollout runbook. Local evidence: Backoffice ESLint PASS (warnings removed),
production build PASS, scoped diff check pending final docs. Live migration,
postflight, behavior, rerun of ACP-4 preflight, and authenticated two-Company
preset smoke remain manual. Next safe step: execute the five SQL steps in
`ACP4B_INVENTORY_MASTER_ENFORCEMENT_ROLLOUT.md`; stop on any FAIL/error.

### 2026-08-12 — ACP-4A LIVE PASS; ACP-4B PREFLIGHT LOCAL READY

User confirmed corrected ACP-4A behavioral test safe. ACP-4A is therefore
treated as database-applied with behavior PASS; closing UI smoke remains part
of the next integrated gate. The next roadmap slice is one complete enforced
key, `inventory.master_data`, rather than mass-enforcing nine Inventory keys.
Repository audit found Product Category identity still has authenticated
column-level INSERT/UPDATE grants, which ordinary table-privilege checks can
miss. The Master page also exposes Category Tax assignment, whose direct RPC
must be included in the same authorization cutover.

Added SELECT-only diagnostic
`acp_phase4b_inventory_master_enforcement_preflight.sql` and runbook. It checks
ACP-2/4A dependency, SHADOW state, existing override scope, table plus column
grants, guarded UOM/Warehouse/Category-Tax routines, missing guarded Category
identity RPC, ACP hook references, nonterminal imports, and normalized identity
integrity. No schema/runtime/UI enforcement changed. Next safe step: user runs
the diagnostic and returns every row; do not change catalog enforcement or
grants manually.

### 2026-08-12 — ACP-4A BEHAVIORAL SMALLINT CALL FIX

The first live ACP-4A behavioral execution reached the installed guarded UOM
RPC but PostgreSQL resolved the literal decimal precision `0` as `INTEGER`,
while the canonical RPC signature requires `SMALLINT`. This was a test-call
typing defect, not a missing migration or runtime RPC defect. Every behavioral
UOM call now explicitly uses `0::SMALLINT`. The already-applied migration was
not edited and no forward migration is required. Next safe step: rerun only
`supabase/tests/acp_phase4a_guarded_inventory_master_tests.sql`, then continue
with closing postflight and ACP-4 preflight if it passes.

### 2026-08-12 — ACP-4A GUARDED INVENTORY MASTER BOUNDARY LOCAL READY

Live ACP-4 output contained one real blocker: authenticated direct write still
existed on `uoms`, `warehouses`, `stores`, and `pos_terminals`; Inventory
permission hooks were not yet present. The corrective boundary is now
local-ready. Migration `20260812130000` adds tenant/role/version/idempotency
guarded and audited UOM/Warehouse RPCs, revokes browser table mutation from all
four simple masters, and intentionally leaves Store/Terminal read-only because
the active Backoffice has no approved browser CRUD for them. Generic Warehouse
write cannot change `allow_negative_stock`; that remains owned by its guarded
policy flow. Backoffice create/edit UOM and Warehouse routes now call the RPCs.
All permission catalog rows remain `SHADOW`; ACP runtime override enforcement
has not started.

Added migration, SELECT-only postflight, rollback-safe behavioral test, and
`docs/runbooks/ACP4A_GUARDED_INVENTORY_MASTER_BOUNDARY.md`. Local evidence:
Backoffice ESLint PASS and production build PASS. Live Supabase migration,
postflight, behavior, closing ACP-4 diagnostic, and authenticated UOM/Warehouse
smoke remain manual. Next safe step: execute the six runbook steps in order and
return the complete postflight/test output. Do not manually grant tables or
change `enforcement_status`.

### 2026-08-12 — ACP-4 INVENTORY PILOT PREFLIGHT READY

After ACP-3 detail UI acceptance, the next roadmap boundary is a SELECT-only
ACP-4 Inventory cutover preflight, not enforcement. New diagnostic
`acp_phase4_inventory_pilot_preflight.sql` checks the nine Inventory catalog
keys remain SHADOW/customizable, override membership integrity, fourteen
protected Stock/FIFO/document direct-write boundaries, five simple-master
browser-write boundaries, thirteen canonical routine names, permission-hook
inventory, and nonfinal document scope. The companion runbook explains that
any simple-master direct write is a blocker requiring a guarded boundary before
`inventory.master_data` cutover; it does not mass-revoke privileges. Static
single-statement/safety inspection and scoped `git diff --check` PASS. Live SQL
was not run by the agent. Next safe step: user runs the full diagnostic and
sends all rows; do not update `enforcement_status` manually.

### 2026-08-12 — ACP-3 PERMISSION PREVIEW MODULE ACCORDION

User accepted the corrected detail runtime and requested easier navigation.
The flat 32-row permission preview is now grouped by canonical module key into
expandable native accordions: Inventory, Kontak, Pembelian, Penjualan,
Keuangan, Data Exchange, and Platform. Each header shows submodule count and
active restriction count; collapsed modules that fully follow the role are
identified without scanning every row. This is presentation-only: resolver,
shadow status, and authorization remain unchanged. Focused ESLint PASS and
production build PASS; authenticated visual smoke remains manual.

### 2026-08-12 — ACP-3 CATALOG COLUMN CONTRACT FIX

Second authenticated detail smoke exposed that the new endpoint had assumed
generic catalog columns (`label`, `is_active`, `sort_order`) that do not exist
in the ACP-2 schema. Build/typecheck could not detect a PostgREST column-name
mismatch and must not be described as authenticated smoke. The endpoint now
uses the exact migration contract: `permission_label`, `module_key`,
`permission_key`, and `is_customizable`; the nonexistent filters/orders were
removed, and the UI type/render path was updated. All columns and relationship
names used by the endpoint were then audited against migrations. Focused ESLint
PASS; production build PASS. Live authenticated reopen remains the manual proof.

### 2026-08-12 — ACP-3 STORE EMBED RELATION FIX

First authenticated ACP-3 detail smoke reached the new API but PostgREST
rejected `store_memberships -> stores` embedding because both the legacy
single-column FK and canonical tenant composite FK exist. The query now pins
the canonical relationship explicitly with
`stores!fk_store_memberships_company_store(...)`. No schema, grant, or runtime
authorization changed. Focused ESLint PASS and production build PASS. Next safe
step: restart/reload Backoffice and reopen the same user detail.

### 2026-08-12 — ACP-3 USER DETAIL LOCAL READY

User confirmed corrected ACP-2 behavioral test PASS. ACP-3 Backoffice local
implementation now makes each Tim & Akses card open a custom Escape-close user
detail modal. The detail API requires the active Company and canonical
Owner/Admin/Super management authority, resolves ACP-2 profile through the
guarded RPC, and only returns cross-Company membership/Store options to Super
Admin. Super Admin can assign the selected UUID to another active Company using
the existing guarded assignment RPC, so email is not retyped. Permission rows
are clearly labeled preview SHADOW; there is no preset editor and no navigation,
API, RPC, RLS, or workflow enforcement change. Existing exact-email assignment
remains compatible.

Changed: `backoffice/src/app/page.tsx`, new
`backoffice/src/components/StaffAccessDetailModal.tsx`, new
`backoffice/src/app/api/staff/detail/route.ts`, additive target UUID support in
`backoffice/src/app/api/staff/assign-existing/route.ts`, and roadmap/status docs.
Evidence: scoped ESLint PASS; Next.js production build PASS including dynamic
`/api/staff/detail`; `git diff --check` pending final check. Full repository lint
timed out at 120 seconds without diagnostics, so scoped lint was used. Manual
gate: rerun ACP-2 postflight and ACP-1 diagnostic, then authenticated smoke as
Owner/Admin (same-Company subordinate detail), denied equal/higher target, and
Super Admin two-Company assignment/selector. ACP-4 enforcement remains closed.

### 2026-08-12 — ACP-2 INTERNAL ASSERTION ROLE-BOUNDARY FIX

Fourth ACP-2 behavior run reached the final persistence assertions but failed
because they queried `user_company_permission_overrides` while the session was
still `SET LOCAL ROLE authenticated`. That denial is the intended browser
security boundary; no SELECT grant is appropriate. The behavior test now ends
all browser/RPC assertions first, executes `RESET ROLE`, and performs override
and immutable-audit row-count assertions in a separate internal verification
block. All direct internal-table reads were audited: none remain under the
authenticated role. Migration/runtime are unchanged; scoped `git diff --check`
PASS. Next safe step: rerun only the corrected ACP-2 behavioral file, then the
ACP-2 postflight and ACP-1 regression if it passes.

### 2026-08-12 — ACP-2 DETERMINISTIC SYNTHETIC SUPER-ADMIN FIXTURE

Third ACP-2 behavior run showed that reading `public.profiles` after switching
to `authenticated` also correctly hides unrelated Super Admin rows through RLS;
the previous auth-table removal therefore still returned no actor. The test no
longer depends on live identities. It creates a fixed synthetic Super Admin
inside the rollback transaction and uses its UUID directly for the last-Owner
negative case. No `auth.users`/`profiles` SELECT grant is added, no production
identity is changed, and migration/runtime remain unchanged. Next safe step is
rerun only the latest behavioral file.

### 2026-08-12 — ACP-2 BEHAVIOR FIXTURE AUTH.USERS READ FIX

Second ACP-2 behavioral run passed synthetic profile setup but stopped when the
test searched for a Super Admin after `SET LOCAL ROLE authenticated` by joining
`auth.users`. Browser roles correctly have no SELECT on `auth.users`; granting
that access would violate the security boundary. The fixture now reads only
`public.profiles.role`, which is the same source used by canonical
`private_is_super_admin`. No application privilege, migration, or runtime logic
changed. The failed transaction rolled back. Next safe step: rerun only the
corrected behavior test, then ACP-2 postflight and ACP-1 regression.

### 2026-08-12 — ACP-2 BEHAVIOR FIXTURE PROFILE CONFLICT FIX

First ACP-2 behavioral run stopped during fixture setup with
`profiles_pkey` duplicate for the synthetic Owner. Root cause: inserting the
synthetic `auth.users` row activated the existing profile-provision trigger,
then the test attempted a second plain INSERT into `profiles`. The test now uses
`ON CONFLICT(id) DO UPDATE`, matching established G1 fixture behavior. Failure
occurred before permission assertions and the transaction rolled back; migration
and runtime contract are unchanged and must not be rerun. Static scoped diff
check PASS. Next safe step: rerun only the corrected ACP-2 behavioral test, then
postflight and ACP-1 regression.

### 2026-08-12 — ACP-2 SHADOW PERMISSION FOUNDATION LOCAL READY

User sent ACP-1 live output: zero `BLOCKER`; membership identity/vocabulary,
active context, Store tenant integrity, all 178 company-scoped relation RLS,
protected direct Stock/Finance/membership writes, and seven role helpers PASS.
Expected `SETUP`: custom permission schema absent, regular multi-Company user
and four UAT roles incomplete. Five generic company-scoped writable relations
remain `REVIEW`, not mass-revoked because protected final relations are clean.

ACP-2 local-ready artifacts:

- migration `20260812120000_acp_phase2_shadow_permission_foundation.sql`;
- postflight `acp_phase2_shadow_permission_postflight.sql`;
- rollback-only behavior `acp_phase2_shadow_permission_foundation_tests.sql`;
- rollout `runbooks/ACP2_SHADOW_PERMISSION_FOUNDATION_ROLLOUT.md`.

Migration seeds 32 stable keys with baseline view/operator/approver roles and
supported capabilities, restriction rows only (`IKUTI_ROLE` means no row),
optimistic version, immutable audit, actor/target hierarchy, self/equal/higher
denial, last-Owner protection, and guarded resolve/list/save RPC. Import remains
Owner/Admin-only. Every key is `SHADOW`; resolver response says
`enforced=false`, and no navigation/API/business RPC/RLS was modified. Thus
runtime remains exactly role-only even if a preview override is saved.

Static evidence: migration SHA-256
`b96f9ddf12f6996c58fdc21a8d57f40df1b495263b676daa8bedec7e49e7dac0`;
scoped diff check PASS. Live SQL not run by agent. Next safe step: migration ->
all-PASS postflight -> behavior -> postflight + ACP-1 regression. ACP-3 UI
remains closed until user confirms database gate.

### 2026-08-12 — ACP-1 ACCESS FINGERPRINT LOCAL READY

User memilih tetap memakai satu role baseline per Company dan menunda kebutuhan
multi-role; variasi akses diselesaikan melalui restriction-only custom
permission. ACP-1 sekarang local-ready tanpa perubahan runtime:

- `supabase/diagnostics/acp_phase1_access_compatibility_preflight.sql` — satu
  statement SELECT-only, aggregate metadata, tanpa identity/business payload;
- `docs/ACP1_ACCESS_ACTION_BASELINE_MATRIX.md` — freeze awal 32 navigation item,
  target stable permission key, baseline visibility, sensitivity, dan cutover;
- `docs/runbooks/ACP1_ACCESS_COMPATIBILITY_PREFLIGHT.md` — cara run dan
  interpretasi `BLOCKER/REVIEW/SETUP/PASS/INFO`.

Preflight memisahkan navigation, Route Handler/RPC, RLS, dan direct privilege;
memeriksa membership/context/Store tenant integrity, role UAT, regular multi-
Company identity, seluruh public table ber-`company_id` yang belum RLS,
protected Stock/Finance/membership direct write, helper role, dan expected
absence tiga custom permission relation. `custom_permission_schema_state=SETUP`
adalah expected. Direct writable company table hanya `REVIEW` karena harus
dibandingkan dengan guarded master workflow, bukan dicabut massal.

Static evidence: parenthesis `163/163`, tidak ada statement DDL/DML, dan
`git diff --check` scoped PASS. Live SQL belum dijalankan agent. Next safe step:
user menjalankan seluruh ACP-1 diagnostic dan mengirim semua row. ACP-2 shadow
foundation tetap tertutup sampai `BLOCKER` nol dan action split dibekukan.

### 2026-08-12 — ACP-0 ROLE BASELINE + CUSTOM RESTRICTION DOCUMENTED

User menyetujui model sederhana: role existing per Company tetap baseline dan
batas maksimum; Company Admin ke atas dapat memberi pembatasan opsional per
submodul melalui detail User. Override tidak dapat memberi akses baru, tidak
dapat menyalakan feature, dan tidak dapat melewati Store/Warehouse/workflow.
Tanpa override, behavior wajib identik dengan runtime sekarang.

Source of truth baru `docs/ROLE_BASELINE_CUSTOM_PERMISSION_PLAN.md` memecah
pekerjaan menjadi delapan fase ACP-0—ACP-7: contract, SELECT-only access
fingerprint, shadow database foundation, consolidated detail User/multi-Company,
Inventory pilot, Contacts/Purchase/Sales, Finance/Data/Platform, lalu security
closure. Governance melarang self/equal/higher edit oleh Company Admin, menjaga
Owner terakhir, melindungi entitlement/Company/Finance final operations, serta
mensyaratkan server-side navigation/API/RPC enforcement dan immutable audit.

Dokumentasi/router/requirement/gate/root README diperbarui. Tidak ada schema,
API, UI, role behavior, atau live database yang diubah dalam ACP-0; test runtime
tidak relevan. Next safe step adalah ACP-1 diagnostic SELECT-only dan execution-
path fingerprint. Jangan membuat table override atau editor permission sebelum
catalog/action matrix ACP-1 dibekukan.

### 2026-08-12 — PRD-1 EXISTING-USER MULTI-COMPANY LOCAL READY

User membuat Company kedua dan akun baru; PRD phase-2 postflight menutup
`two_company_uat_scope` PASS tetapi membuktikan belum ada regular multi-Company
identity dan beberapa role/fixture masih SETUP. Root cause confirmed: context/
selector Backoffice sudah membaca banyak membership, tetapi Tim & Akses hanya
dapat membuat Auth user baru dan belum dapat menempelkan akun existing.

Corrective implementation local-ready:

- migration `20260812100000_prd_phase3_existing_user_company_assignment.sql`;
- postflight `prd_phase3_existing_user_assignment_postflight.sql`;
- rollback-safe behavior `prd_phase3_existing_user_company_assignment_tests.sql`;
- server route `/api/staff/assign-existing` dengan exact-email lookup;
- action Super Admin `Tambah akses akun existing` pada Tim & Akses;
- rollout `runbooks/PRD1_EXISTING_USER_MULTI_COMPANY_ROLLOUT.md`.

Role ditentukan per Company, Store diverifikasi tenant aktif, default Company
tidak berubah, exact retry tidak menggandakan membership, dan immutable audit
disimpan. Browser tidak menerima global user directory atau direct membership
write. Backoffice lint PASS dan production build PASS; SQL static parentheses,
delimiter, checksum, dan diff check PASS. Live migration/postflight/behavior
belum dijalankan agent. Next safe step: user menjalankan rollout, assign satu
regular UAT user ke Company kedua, login ulang, lalu rerun phase-2 postflight.

### 2026-08-12 — PRD-1 PREFLIGHT CLEAR / UAT IDENTITY SETUP READY

User menjalankan PRD-1 preflight. Tidak ada `BLOCKER`; migration chain,
operational/master Company utama, Stock–Movement–FIFO, Finance queue/journal,
Invoice/Surat Jalan, Return, browser write boundary, import, dan Offline queue
PASS. Expected `SETUP` hanya satu Company kedua, missing role matrix, dan Kasir.
29 Finance HOLD dari 9 contract tetap deferred G6.

Manual canonical setup ditulis di
`docs/runbooks/PRD1_UAT_IDENTITY_TENANT_SETUP.md`; closing verifier SELECT-only
ada di `supabase/diagnostics/prd_phase2_uat_identity_tenant_postflight.sql`.
Tidak ada akun/password/Company yang dibuat agent. Next safe step: user membuat
Company UAT kedua dan akun role melalui Backoffice, lalu menjalankan postflight.
Postflight juga mewajibkan satu user biasa dengan dua membership aktif agar
selector Company tidak hanya diuji memakai Super Admin. Jika assignment akun
existing lintas Company belum tersedia di UI, jangan INSERT membership manual;
laporkan gap untuk corrective implementation sebelum matrix login.

### 2026-08-12 — SLD-R4 VERIFIED / PRD-1 PREFLIGHT READY

User mengonfirmasi seluruh rollout SLD-R4 sukses. Migration `20260811150000`,
postflight, behavioral test, dan regression tidak lagi menjadi manual gate.
Delivery fee Return sekarang ditutup dengan keputusan eksplisit: partial
Product Return tidak merefund ongkir, sedangkan full remaining Return dapat
merefund ongkir hanya bila operator memilihnya dan approver melihat snapshot
keputusan tersebut.

PRD-1 dibuka dengan diagnostic SELECT-only
`supabase/diagnostics/prd_phase1_predeploy_closing_preflight.sql` dan runbook
`docs/runbooks/PRD1_PREDEPLOY_CLOSING_PREFLIGHT.md`. Diagnostic tidak membuat
akun/password/Company/data bisnis. Expected `SETUP` adalah Company kedua dan
coverage role UAT yang memang ditunda user ke closing. Next safe step: user
menjalankan diagnostic dan mengirim seluruh output; perbaiki setiap `BLOCKER`
sebelum provision fixture, full E2E, atau Vercel Preview. Finance `HOLD` yang
belum didukung tetap deferred dan tidak boleh diproses oleh PRD-1.

### 2026-08-11 — SLD-R4 explicit delivery-fee Return LOCAL READY

User mengirim output preflight tanpa `BLOCKER`; `SETUP` hanya objek R4 baru,
sedangkan payment, legacy Return, partial-risk, Offline queue, dan tenant write
boundary aman. Local implementation sekarang tersedia:

- migration `20260811150000_sld_r4_explicit_delivery_fee_return.sql`;
- postflight `sld_r4_delivery_fee_return_postflight.sql`;
- rollback-safe behavior `sld_r4_delivery_fee_return_tests.sql`;
- PWA full-remaining selector refund ongkir default OFF;
- Backoffice detail approval yang menampilkan keputusan refund ongkir;
- rollout/UAT `runbooks/SLD_R4_DELIVERY_FEE_RETURN_ROLLOUT.md`.

Server memisahkan nilai Product dan ongkir, menolak refund ongkir pada partial
Return, menyimpan snapshot keputusan approver, dan menambahkan breakdown ke
`SALES_REFUND` event tanpa membuka posting G6. Validasi posting hanya menghitung
Return POSTED dan dokumen yang sedang diposting, bukan Draft paralel. Signature
RPC lama tetap kompatibel dan default tanpa refund ongkir.

Evidence lokal: PWA lint/build PASS; Backoffice lint/build PASS. SQL static
transaction/delimiter check PASS; live SQL belum dijalankan agent. Next safe
step: migration -> postflight seluruh `FAIL=0` -> behavioral -> Phase-26/R2
regression -> authenticated online/offline/two-Company UAT. PRD-1 tetap belum
dibuka dan Finance Sale/Refund tetap controlled HOLD.

Dokumen ini adalah catatan operasional tunggal untuk meneruskan pekerjaan ketika
agent berganti atau context/limit habis. Dokumen ini tidak menggantikan
spesifikasi bisnis; ia menunjuk source of truth dan mencatat posisi implementasi
terakhir.

### 2026-08-11 — SLD-R4 explicit delivery-fee Return PREFLIGHT READY

Setelah SLD-R2 user-verified dan SLD-R3 local-ready, audit active Return runtime
menemukan bahwa legacy `save_sales_return_draft` memakai seluruh sisa
`grand_total_after_rounding` ketika semua remaining Product dipilih. Karena
grand total sekarang termasuk ongkir, jalur lama berisiko otomatis me-refund
ongkir dan bertentangan dengan keputusan approved.

Preflight SELECT-only dibuat di
`supabase/diagnostics/sld_r4_delivery_fee_return_preflight.sql` dengan runbook
`docs/runbooks/SLD_R4_DELIVERY_FEE_RETURN_PREFLIGHT.md`. Ia mengukur dependency,
schema/RPC gap, payment dan Product amount reconciliation, legacy full Return,
Draft normalization, partial auto-refund risk, Event snapshot, direct-write,
Offline nonterminal state, serta Finance HOLD boundary. Belum ada schema/runtime
mutation R4. Next safe step: user menjalankan preflight dan mengirim seluruh
output; setiap `BLOCKER` harus nol sebelum forward migration dibuat.

### 2026-08-11 — SLD-R2 USER VERIFIED / SLD-R3 UI LOCAL READY

User mengonfirmasi migration R2, POST-repricing forward fix, postflight, dan
behavioral test seluruhnya sukses. Database gate R2 ditutup PASS.

SLD-R3 memindahkan fulfillment dari panel besar pada cart menjadi checkbox
ringkas `Perlu dikirim` di final checkout. Detail penerima, telepon, alamat,
jadwal, catatan, ongkir, dan pilihan breakdown Invoice berada dalam modal custom
yang dapat ditutup dengan Escape. Customer terpilih menjadi default transaksi;
Walk-In tetap diwajibkan mengisi tujuan eksplisit oleh server/client guard.

Ongkir sekarang ikut payload Draft online, Draft restore, shared POST repricing,
auto-fill pembayaran, Offline queue/slip, receipt, dan grand total. Invoice PWA
dan Backoffice hanya menampilkan baris Ongkir ketika mode
`SHOW_SEPARATE`; `HIDE_BREAKDOWN` tidak mengubah total. Surat Jalan tidak
diubah dan tetap tidak memuat harga/ongkir.

File task ini:

- `pwa/src/App.tsx`, `pwa/src/App.css`;
- `pwa/src/lib/pos.ts`, `pwa/src/lib/offline.ts`,
  `pwa/src/lib/offlineCheckout.ts`, `pwa/src/lib/salesDocumentPrinter.ts`;
- `backoffice/src/lib/sales-document-print.ts`;
- `docs/runbooks/SLD_R3_DELIVERY_CHECKOUT_PRINT_UAT.md`.

Evidence lokal: PWA `npm.cmd run lint` PASS dan `npm.cmd run build` PASS;
Backoffice `npm.cmd run lint` PASS dan `npm.cmd run build` PASS. Vite hanya
memberi warning chunk >500 kB yang sudah existing/non-blocking. Manual gate:
restart/hard refresh PWA dan jalankan online + Offline smoke pada runbook.
Setelah user mengonfirmasi, lanjut SLD-R4 explicit full-return delivery-fee
decision dan closing reconciliation/regression; PRD-1 belum dibuka.

### 2026-08-11 — Delivery confirmation + ongkir revision APPROVED / DOCUMENTED

User menyetujui perubahan SLD-3: pilihan `Perlu dikirim` dipindahkan dari cart
utama ke confirmation step sebelum payment/POST; Customer menjadi default
penerima/telepon/alamat. Ongkir opsional ikut grand total, payment, TEMPO/AR,
Customer Balance, offline snapshot/replay, dan Finance sebagai pendapatan
ongkir terpisah. Toggle Invoice hanya menyembunyikan breakdown, tidak mengubah
total atau ledger. Biaya kurir aktual tetap Expense terpisah.

### 2026-08-11 — SLD-R2 delivery-fee foundation LOCAL READY

User mengirim seluruh output SLD-R1 tanpa blocker dan meminta roadmap lanjut.
Expected `REVIEW` mengunci: tidak ada pajak ongkir implisit dan partial Product
Return tidak otomatis refund ongkir. Sepuluh Sale/Invoice historis menjadi
zero-value compatibility scope dan tidak dimutasi.

Artefak baru:

- migration `supabase/migrations/20260811140000_sld_r2_delivery_fee_finance_foundation.sql`;
- postflight `supabase/diagnostics/sld_r2_delivery_fee_postflight.sql`;
- rollback-safe behavior `supabase/tests/sld_r2_delivery_fee_tests.sql`;
- runbook `docs/runbooks/SLD_R2_DELIVERY_FEE_FOUNDATION_ROLLOUT.md`;
- manifest checksum `0d701b026554ea4be6fc05c18982ce12a9810055f5e509467df40937a04894be`.

Eksekusi manual pertama berhenti pada statement ledger karena file lokal salah
memakai kolom `name/description`, sedangkan schema canonical memakai
`migration_name/notes`. Migration dibungkus `BEGIN/COMMIT`, sehingga seluruh
DDL/DML sebelum error ter-rollback dan version belum tercatat. File dikoreksi
sebelum apply; tidak diperlukan cleanup atau forward migration.

Behavioral pertama setelah foundation berhenti atomically pada
`PAYMENT_TOTAL_MISMATCH`. Root cause terbukti pada active execution path:
`private.post_pos_sale_online_core` selalu memanggil shared Product repricer
sebelum Payment validation; R2 pertama menambahkan fee hanya sesudah Draft
save, sehingga POST repricing mereset total 125 kembali menjadi 100 sementara
payment intent tetap 125. Forward migration
`20260811143000_sld_r2_post_reprice_delivery_fee_fix.sql` memindahkan
penambahan fee ke shared Draft/Post repricing boundary dan menghapus double-add
dari public Draft wrapper. Checksum
`774175bb16bdf0bbf30d3ee1d209826c094437d02c2ec90e6433f8bdb2053ce1`.
Behavior error berada dalam outer test transaction dan rollback; tidak ada Sale,
Payment, Stock, atau Event fixture yang menetap. Next manual step: jalankan
forward fix, postflight terbaru, lalu behavioral yang sama.

Runtime local menambah fee hanya untuk DELIVERY, menambahkannya sekali setelah
Product rounding, dan mengalirkannya melalui Draft canonical sehingga online,
Pricelist, split/TEMPO/Customer Balance, serta Offline memakai total yang sama.
Receipt/Invoice/Event baru menyimpan fee; `SALE_POSTED.netSalesInclusiveTax`
dikurangi fee agar revenue Product tidak double. Account function, COA sistem,
future-Company provisioning, dan fallback mapping
`DELIVERY_FEE_REVENUE` tersedia. Existing snapshot/Event immutable tidak
ditulis ulang.

Boundary penting: G6 atomic posting live masih hanya mendukung Stock Opening.
Sale Event tetap `HOLD`; postflight memberi `DEFERRED`, bukan klaim jurnal Sale
aktif. Next safe step: user menjalankan migration → postflight (semua `FAIL`
nol) → behavior → regression sesuai runbook. Setelah user mengonfirmasi PASS,
baru SLD-R3 confirmation/print UI dibuka. Jangan memproses HOLD historis atau
membuka posting Sale dari phase ini.

Perubahan dibagi menjadi SLD-R1 contract/preflight, SLD-R2 canonical database/
Finance foundation, SLD-R3 checkout/print UI, dan SLD-R4 Return/reconciliation/
full regression. Source of truth tambahan:
`docs/SLD_DELIVERY_FEE_REVISION_PLAN.md`. UAT SLD-3 lama ditahan/superseded;
PRD-1 belum dibuka. R2 sekarang sudah tersedia secara lokal tetapi belum
di-rollout ke Supabase.

Dua keputusan R1 sudah terkunci: Tax ongkir tidak diterapkan implisit; refund
ongkir pada Return harus explicit/audited dan tidak otomatis pada partial
Return. Catatan SLD-R1 di bawah adalah evidence historis yang sudah user
jalankan, bukan next step aktif.

SLD-R1 yang sudah dijalankan memakai:

- diagnostic: `supabase/diagnostics/sld_r1_delivery_fee_preflight.sql`;
- runbook: `docs/runbooks/SLD_R1_DELIVERY_FEE_PREFLIGHT.md`.

Diagnostic adalah satu statement SELECT-only/aggregate-only. Ia memeriksa
dependency SLD-2/G6, required runtime routines, Sale total dan payment+
receivable reconciliation, Invoice/SJ coverage, offline nonterminal queue,
candidate Revenue account per active Company, Finance catalog/posting-rule
setup, Tax/Return decision scope, serta Sale/Invoice/event legacy inventory.
Static evidence: tidak ada DDL/DML/transaction statement. Live evidence user:
seluruh `BLOCKER` nol; schema/runtime/catalog `SETUP`, Sale lama `BACKFILL`, dan
Tax/Return `REVIEW` diterima sebagai expected scope R2.

### 2026-08-11 — SLD-3 POS/Backoffice/print UI LOCAL READY

User melaporkan seluruh SLD-2 migration, postflight, dan behavioral test PASS.
Database foundation dinyatakan applied dan status manifest diperbarui tanpa
mengubah checksum migration.

PWA sekarang menyimpan pilihan `PICKUP`/`DELIVERY` beserta penerima, telepon,
alamat, jadwal, dan catatan pada draft online/offline. Customer aktif menjadi
default identity yang tetap bisa direview. Setelah post sukses cart di-reset;
struk compatibility, Invoice A4, dan Surat Jalan A4 (delivery-only) dapat dibuka
di tab baru. Kegagalan loader/print dokumen setelah Sale sukses tidak memicu
retry posting Sale.

Backoffice mendapat server-authorized navigation `Sales -> Invoice & Surat
Jalan`, Route Handler list/detail/print/lifecycle, daftar/search/filter, detail
tanpa UUID, Invoice/SJ A4 new-tab print, serta lifecycle `READY -> DISPATCHED ->
DELIVERED`. Cancel hanya `READY` dan memakai modal internal beralasan; Escape
menutup modal. Finance/Accounting view-only, sedangkan Owner/Admin/Store Manager
dapat mengubah status melalui guarded RPC. Direct table write tetap tertutup.

Files utama:

- `pwa/src/App.tsx`, `pwa/src/App.css`, `pwa/src/lib/pos.ts`,
  `pwa/src/lib/offline*.ts`, `pwa/src/lib/salesDocumentPrinter.ts`;
- `backoffice/src/components/SalesDocumentView.tsx`,
  `backoffice/src/lib/sales-document-print.ts`,
  `backoffice/src/app/api/sales/documents/**`, `backoffice/src/app/page.tsx`,
  `backoffice/src/lib/navigation-catalog.ts`;
- `docs/runbooks/SLD3_POS_BACKOFFICE_PRINT_UI.md`.

Local evidence: PWA ESLint PASS dan Vite production build PASS (existing chunk
size warning only); Backoffice ESLint PASS dan Next production build PASS (55
static pages; kedua Sales document Route Handler terdeteksi); scoped
`git diff --check` PASS.

Manual gate masih wajib: Pickup/Delivery, Walk-In required identity, Cash/
Transfer/split/TEMPO yang tersedia, offline replay, Bundle, logo/no-logo,
Invoice/SJ print, lifecycle/reprint, role denial, two-Company state isolation,
serta closing SLD-2 no-double-effect postflight. Jangan menandai SLD-3 COMPLETE
sebelum user mengonfirmasi UAT. Next safe step setelah UAT PASS adalah PRD-1
full pre-deploy regression, bukan penambahan modul baru.

### 2026-08-11 — SLD-2 Sales document foundation READY FOR MANUAL DATABASE ROLLOUT

User mengirim hasil live SLD-1 tanpa `BLOCKER` dan meminta roadmap dilanjutkan.
`REVIEW` Customer/Store print identity diterima sebagai optional/default input
yang tetap wajib direview pada Delivery. Sembilan Sale POSTED (tujuh online,
dua offline) menjadi backfill formal; schema dan logo retention menjadi scope
SLD-2.

Migration baru
`supabase/migrations/20260811130000_sld_phase2_sales_document_foundation.sql`
menambahkan immutable `sales_invoice_snapshots`, delivery-only
`sales_delivery_documents`/lines, append-only audit, fulfillment snapshot pada
Sale, nomor `SJ/YYYY/MM/NNNNNN`, guarded configure/read/lifecycle/print RPC,
tenant RLS, dan deferred finalization. Deferred constraint trigger dipilih agar
online wrapper serta offline replay/enrichment selesai sebelum snapshot final
dibuat. Existing Sale mendapat provenance `LEGACY_CUTOVER`; tidak ada mutation
Stock/FIFO/Payment/Financial Event/Journal pada backfill atau lifecycle.

BRD-2 cleanup sekarang memanggil guarded
`company_branding_logo_is_referenced`. Bila RPC belum tersedia/error, cleanup
fail-closed; bila logo sudah direferensikan Invoice/Surat Jalan final, object
lama dipertahankan. Ini mencegah dokumen historis kehilangan logo setelah
replace/remove branding.

Verification artifacts:

- `supabase/diagnostics/sld_phase2_sales_document_postflight.sql`;
- `supabase/tests/sld_phase2_sales_document_tests.sql` (rollback-safe Pickup,
  Delivery, exact retry, lifecycle/print, immutable history, tenant boundary,
  single Stock/Finance effect);
- `docs/runbooks/SLD2_SALES_DOCUMENT_FOUNDATION_ROLLOUT.md`.

Local evidence: Backoffice ESLint PASS, `tsc --noEmit` PASS, Next production
build PASS (54 static pages), SQL dollar-delimiter parity PASS, dan scoped
`git diff --check` PASS. Migration checksum dicatat pada
`supabase/MIGRATION_MANIFEST.md`. Manual gate yang menunggu: migration ->
postflight -> behavior -> regressions -> closing postflight.
Jangan membuka SLD-3 sebelum user mengirim seluruh row non-`INFO` `PASS`.
Next safe step setelah database gate PASS adalah SLD-3 POS/Backoffice/print UI,
bukan PRD-1 langsung.

### 2026-08-11 — SLD-1 Sales document contract/preflight LOCAL READY

User menunda pembuatan Company kedua dan akun role berbeda ke closing PRD-1,
lalu meminta roadmap dilanjutkan. SLD-1 dibuka tanpa schema mutation. Contract
canonical baru berada di `docs/SALES_INVOICE_DELIVERY_DOCUMENT_SPEC.md`:
Sales Invoice tetap memakai Sale POSTED dan `invoice_no` existing, sedangkan
Surat Jalan hanya untuk `DELIVERY`, memakai nomor manusia
`SJ/YYYY/MM/NNNNNN`, dibuat atomic/idempotent bersama Post Sale, dan tidak
menulis Stock/Payment/Finance effect kedua. Pickup tidak membuat Surat Jalan.

Contract juga mengunci snapshot Company/branding, Store/Warehouse, Customer,
Cashier/Terminal, commercial Product/UOM/Tax/Payment/totals; Bundle tetap
dicetak sebagai line komersial. Historical Sale memakai provenance
`LEGACY_CUTOVER`. Logo versioned yang sudah direferensikan dokumen final tidak
boleh dihapus saat replace/remove branding—cleanup BRD-2 harus mendapat
reference guard pada SLD-2.

Audit client menemukan `loadReceipt` membaca `sales_headers.receipt_snapshot`
dan browser fallback membuka tab baru/print dialog, tetapi template thermal
masih memakai label Company/Store/Cashier hard-coded. Itu dipertahankan sebagai
struk compatibility; bukan sumber Invoice formal. SLD-3 wajib memakai snapshot
canonical untuk Invoice/Surat Jalan tanpa mematahkan struk existing.

File execution:
`supabase/diagnostics/sld_phase1_sales_document_preflight.sql` melalui
`docs/runbooks/SLD1_SALES_DOCUMENT_PREFLIGHT.md`. Diagnostic adalah satu
statement SELECT-only dan aggregate-only. Expected baseline: canonical schema
dan logo retention `SETUP`, existing POSTED Sale `BACKFILL`, missing optional
Customer/Store delivery identity mungkin `REVIEW`; semua `BLOCKER` wajib nol.
Belum ada migration/RPC/UI SLD-2. Next safe step: user menjalankan seluruh
preflight dan mengirim semua row. Multi-role/two-Company isolation tetap manual
gate PRD-1, bukan alasan membuka bypass sementara.

### 2026-08-11 — Company logo Home control + authorized Fast Link search LOCAL READY

Atas arahan user, `backoffice/src/app/page.tsx` sekarang mengambil resolved
branding dari `/api/platform/company-branding` berdasarkan active Company.
Logo tampil di header tepat di samping nama/selector Company; fallback memakai
ikon Company dan klik selalu menjalankan `goHome()`. Saat switch/logout URL logo
lama dibersihkan dan request lama dibatalkan agar logo tenant sebelumnya tidak
terbawa.

Fast Link sekarang mempunyai input search label + nama modul. Search hanya
memfilter `availableNavigation` yang dibentuk dari `navigationModules` hasil
endpoint server `/api/me/navigation-catalog`. Tidak ada registry kedua, fallback
all-menu, atau direct navigation bypass; `navigateTo` tetap memverifikasi view
berada dalam catalog aktif. Empty result tampil sebagai akses tidak ditemukan.

Evidence: scoped ESLint PASS, `tsc --noEmit` PASS, Next production build PASS
(54 static pages), dan `git diff --check` PASS. Manual matrix diperluas pada
`docs/runbooks/BRD2_COMPANY_BRANDING_UPLOAD_UI.md`: klik logo ke Home, search
allowed menu, search forbidden menu per role, serta switch Company A/B. Next
safe step tetap SLD-1 setelah authenticated BRD-2/shell smoke dikonfirmasi.

### 2026-08-11 — BRD-2 upload runtime/UI LOCAL READY

User mengonfirmasi BRD-1 migration, postflight, dan two-Company behavioral test
ALL PASS. Runtime berikutnya dibuat pada
`backoffice/src/app/api/platform/company-branding/route.ts` dan server-only
helper `backoffice/src/lib/company-branding-server.ts`. Active Company selalu
berasal dari server context; mutation membutuhkan Super Admin atau Owner/Admin.
File PNG/JPEG/WebP maksimal 2 MiB divalidasi dengan magic bytes, MIME,
extension, byte length, dan SHA-256. Path `{company}/logo/vN-checksum.ext`
dibentuk server. Object diupload sebelum guarded metadata RPC; kegagalan RPC
membersihkan object baru dan replace/remove membersihkan object lama best
effort. Service-role tidak masuk client.

UI `backoffice/src/components/CompanyBrandingView.tsx` ditambahkan ke Platform
-> Logo Perusahaan melalui shared navigation catalog. UI tidak menampilkan UUID,
path, atau checksum; menggunakan modal remove internal + Escape, fallback tanpa
logo, dan remount berdasarkan active Company. Static evidence: scoped ESLint
PASS, `tsc --noEmit` PASS, Next production build PASS (54 static pages dan route
branding terdeteksi), `git diff --check` PASS. Database tidak berubah lagi.

Manual gate ada di `docs/runbooks/BRD2_COMPANY_BRANDING_UPLOAD_UI.md`: valid/
invalid file, replace/remove, stale tab, role denial, dan logo A/B ketika switch
dua Company. Next safe step setelah user mengonfirmasi smoke PASS adalah SLD-1
Sales document SELECT-only preflight/contract. Full account-role matrix tetap
ditunda ke PRD-1 sesuai arahan user.

### 2026-08-11 — BRD-1 foundation READY FOR MANUAL DATABASE ROLLOUT

User melaporkan BRD-1 preflight ALL PASS dan meminta tenant isolation diuji
dengan multi-Company. Migration
`supabase/migrations/20260811110000_brd_phase1_company_branding_foundation.sql`
sekarang menyediakan one-profile-per-Company metadata, immutable audit,
active-Company guarded RPC, optimistic versioning, RLS, serta bucket
`company-branding` public-read tanpa direct authenticated write policy.

Verification tersedia di
`supabase/diagnostics/brd_phase1_company_branding_postflight.sql` dan
`supabase/tests/brd_phase1_company_branding_tests.sql`. Behavioral memakai dua
Company aktif dan menguji cross-Company path ditolak, RLS read dua arah,
resolved branding mengikuti active Company, stale version ditolak, exact retry
tidak menggandakan audit, serta direct browser update ditolak. Semua fixture
di-rollback. Static `git diff --check` PASS; database belum dijalankan oleh
agent.

Manual gate mengikuti
`docs/runbooks/BRD1_COMPANY_BRANDING_FOUNDATION_ROLLOUT.md`: migration ->
postflight -> behavior -> postflight. Next safe step setelah user mengonfirmasi
ALL PASS adalah server upload API dengan magic-byte/SHA-256 validation dan
best-effort Storage cleanup, lalu setting UI. Full multi-role dan multi-Company
isolation seluruh modul tetap wajib pada PRD-1; akun role berbeda dibuat pada
closing test sesuai arahan user.

### 2026-08-11 — BRD-1 Company branding preflight READY TO RUN

User menerima UXD-2 dan meminta pembuatan akun multi-role dilakukan pada test
akhir. Matrix Owner/Admin/Store/Warehouse/Finance/Accounting/Cashier tetap wajib
di PRD-1 dan tidak dianggap PASS sekarang.

BRD-1 dibuka hanya sebagai SELECT-only preflight. Contract canonical berada di
`docs/COMPANY_BRANDING_LOGO_SPEC.md`: PNG/JPEG/WebP maksimum 2 MiB, magic-byte
validation, SHA-256, server-owned versioned path, public-read bucket tetapi tanpa
direct authenticated write, one-profile-per-Company, audit, cache-busting,
cleanup, dan immutable document snapshot. Bukti transaksi/foto lain tetap link
eksternal.

Jalankan seluruh
`supabase/diagnostics/brd_phase1_company_branding_preflight.sql` sesuai
`docs/runbooks/BRD1_COMPANY_BRANDING_PREFLIGHT.md`, lalu kirim output lengkap.
Expected baseline: canonical schema/bucket `SETUP`, dependency/Storage/
identity/policy `PASS`, metadata `INFO`, operator mungkin `REVIEW`. Jangan buat
bucket manual atau migration sebelum semua `BLOCKER` nol. Target migration
setelah preflight aman adalah `20260811110000`.

### 2026-08-11 — UXD-2 two-level launcher LOCAL READY

Home Backoffice sekarang hanya berisi card modul dari catalog server; hero
sapaan, statistik, dan query Produk khusus Home dihapus. Klik modul membuka
landing card submodul. Sidebar memakai catalog yang sama. Faktur Supplier dan
Pembayaran Supplier hanya berada di Finance. Endpoint baru
`/api/me/navigation-catalog` memerlukan session + active Company dan menghitung
catalog dari profile/membership/feature server-side. API/RPC/RLS tetap authority
final; granular ACL baru tidak dibuat.

File utama: `backoffice/src/lib/navigation-catalog.ts`,
`backoffice/src/app/api/me/navigation-catalog/route.ts`, dan
`backoffice/src/app/page.tsx`. Evidence: scoped ESLint PASS, `tsc --noEmit`
PASS, Next production build PASS (53 static pages dan route catalog terdeteksi).
Tidak ada migration/data/grant. Manual gate berada di
`docs/runbooks/UXD2_TWO_LEVEL_LAUNCHER_ROLLOUT.md`: role matrix, Cashier
negative, feature OFF/ON, multi-Company reset, Back/Home, dan direct API denial.

Next safe step setelah user mengonfirmasi smoke PASS: BRD-1 Company branding
preflight. Jika smoke gagal, perbaiki UXD-2 dahulu; jangan membuka logo/Storage.

### 2026-08-11 — UXD-1 navigation authority dan repository hygiene COMPLETE

UXD-1 selesai sebagai audit/contract tanpa mengubah schema atau runtime bisnis.
Evidence berada di
`docs/audits/UXD1_NAVIGATION_AUTHORITY_AND_REPOSITORY_HYGIENE_AUDIT_2026-08-11.md`.
Registry navigation/module saat ini masih client-owned dan hanya memfilter
Super Admin/role; UXD-2 wajib memakai catalog server-readable, memisahkan
`canView` dari capability mutation, fail-safe saat Company berganti, serta
tetap mengandalkan API/RPC/RLS sebagai authority final. Faktur Supplier dan
Pembayaran Supplier ditetapkan canonical di Finance, bukan ganda di Purchase.
Audit 97 Route Handler tidak menemukan handler aktif tanpa auth/context atau
retirement guard.

Repository hygiene diperketat: root `.gitignore` menutup local Supabase/Codex/
agent/Vercel state, build/cache, test report, log/temp/export, serta DB dump/
local database. `.supabase/telemetry.json` dikeluarkan dari Git index tetapi
tetap ada lokal. `backoffice/.env.example` memakai placeholder. Canonical
migration/diagnostic/test/operation SQL dan fixed CSV template tetap tracked
karena merupakan source/evidence. Ukuran Git sekitar 9.8 MB; local `.next` dan
`node_modules` besar tetapi ignored.

Next safe step: UXD-2 clean two-level launcher. Sesudah lint/build dan manual
role/Company smoke PASS, lanjut BRD-1; jangan mulai upload logo atau Sales
document migration sebelum boundary itu.

## Update Terbaru — G6 Finance Corrective Boundary

### 2026-08-11 — Pre-deploy Modular Home, Branding, Invoice/Surat Jalan approved

User menutup DEX-4 UI sebagai oke, tetapi meminta roadmap berhenti sebelum
pre-deploy untuk perubahan frontend dan dokumen. Belum ada code/schema/runtime
yang diubah. Source of truth baru:
`docs/PREDEPLOY_MODULAR_HOME_BRANDING_SALES_DOCUMENT_PLAN.md`.

Keputusan: Home menjadi launcher murni tanpa hero `Halo, User` atau statistik;
klik modul membuka landing card submodul authorized. Logo Company opsional
dibuka sebagai exception sempit terhadap kebijakan external-link: storage hanya
untuk branding Company, bukan bukti transaksi. Sale POSTED existing sudah
memiliki `invoice_no` dan receipt snapshot, tetapi belum memiliki template
Sales Invoice formal. Supplier Invoice tetap domain Purchase. Surat Jalan Sales
belum ada; `supplier_delivery_no` existing hanya referensi Goods Receipt.

Urutan wajib sebelum kembali ke pre-deploy: UXD-1 navigation audit -> UXD-2
two-level launcher -> BRD-1 logo foundation -> SLD-1 Sales document preflight
-> SLD-2 canonical Invoice/Surat Jalan -> SLD-3 POS/Backoffice/print UI ->
PRD-1 full regression. Surat Jalan hanya untuk `Perlu dikirim`, menyimpan
snapshot, dan tidak boleh membuat Stock Movement/FIFO/Financial Event kedua.
Sales Invoice memakai Sale POSTED sebagai single source of truth dan bukan
e-Faktur. Next safe step adalah UXD-1 audit; jangan langsung membuat migration
delivery atau upload route sebelum contract dan authority dipetakan.

### 2026-08-11 — DEX-4 Inventory navigation cutover local-ready

User mengonfirmasi DEX-3 masih sesuai ekspektasi dan meminta roadmap
dilanjutkan. Duplicate entry `Inventory > Import & Export` telah dihapus dari
sidebar, launcher Inventory, `View` union, dan direct render pada
`backoffice/src/app/page.tsx`. Card Data Exchange sekarang menjelaskan Export
dan Import global. Global Data Exchange menjadi satu-satunya visible entry.

Compatibility sengaja dipertahankan: `MasterImportView` tetap digunakan oleh
`DataExchangeView`; template/export, import job, validation/commit/history API,
dan guarded RPC tidak dihapus atau diubah. Tidak ada schema/data/grant/migration.
Scoped ESLint PASS dan `git diff --check` PASS. Next production build/TypeScript
PASS; 52 static pages selesai dan route Data Exchange/import compatibility
tetap terdeteksi.

Manual closing gate berada di
`docs/runbooks/DEX4_INVENTORY_CUTOVER_AND_DEPLOYMENT_EVIDENCE.md`: restart +
hard refresh, single-entry verification, Inventory regression, Owner/Admin
CSV/import, Finance XLSX, negative Finance/Store/Warehouse Import, multi-Company
isolation, dan history parity. Setelah PASS, DEX-1–DEX-4 dapat ditutup dan
roadmap lanjut ke pre-deploy E2E/environment/Auth/secret/Vercel Preview
readiness; jangan membuka Production langsung.

### 2026-08-11 — DEX-3 global Import consolidation local-ready

Global `Data Exchange` sekarang memiliki tab Import hanya ketika catalog
server mengembalikan action `IMPORT`. `DataExchangeView` merender ulang
`MasterImportView` dengan allowlist type dari catalog; pipeline tetap memakai
fixed template, Master Import job API, staging, preview/validation, explicit
confirmation, guarded partial commit, audit/result, dan history existing.

Import permission tidak diperluas: hanya Company Owner/Admin dan Super Admin.
Guard `requireImportManager` pada API job tetap menjadi boundary server, jadi
role Finance/Store/Warehouse tidak dapat mengimpor walau memanggil endpoint
langsung. Sepuluh tipe existing dipertahankan; Opening Stock, transaksi final,
Stock/FIFO/Movement, Payment/Event/Journal, Company, Staff, role, dan
entitlement tetap workflow khusus. Tidak ada schema/data migration.

Compatibility: menu `Inventory > Import & Export` belum dihapus. Evidence
lokal: scoped ESLint PASS; Next production build dan TypeScript PASS dengan 52
static pages serta route catalog/import jobs terdeteksi. Manual gate
berada di `docs/runbooks/DEX3_GLOBAL_IMPORT_CONSOLIDATION.md`: Owner/Admin
template-preview-history parity, negative role/direct API, multi-Company
isolation, dan legacy Inventory parity. Next safe step setelah DEX-2/DEX-3
smoke PASS adalah DEX-4 navigation cutover; jangan menghapus backend route.

### 2026-08-11 — DEX-2 role-aware Export Center local-ready

DEX-2 runtime lokal telah dibuat tanpa schema/data migration. Shared authority
`backoffice/src/lib/data-exchange-server.ts` menghitung katalog dari active
Company dan role server-side, serta memisahkan action `EXPORT`/`IMPORT`.
Catalog API baru berada pada `/api/data-exchange/catalog`; direct master CSV
dan Finance export memvalidasi ulang action, sehingga hiding UI bukan security.

Backoffice home/sidebar sekarang memiliki aplikasi global `Data Exchange`.
`DataExchangeView` hanya merender item export dari catalog response. Sepuluh
master CSV existing tersedia sesuai role. Finance XLSX diperluas dari dua
menjadi tujuh: Journal Entries, General Ledger, Trial Balance, Income
Statement, Balance Sheet, Pending Analysis, dan Reconciliation Summary. Lima
report baru memakai RPC canonical yang sama dengan layar; Pending limit dijaga
sesuai contract maksimum 500. UUID tidak menjadi label user.

Compatibility: `Inventory > Import & Export`, template, staging, validation,
commit, history, dan route existing tidak dihapus. Template/import tetap
Owner/Admin. DEX-3 belum dibuat. Evidence lokal: scoped ESLint PASS; Next
production build/TypeScript PASS dan route catalog dynamic terdeteksi.
Production-server unauthenticated smoke untuk catalog dan Finance export sama-
sama mengembalikan HTTP 401 JSON `AUTHENTICATION_REQUIRED`.

Manual gate: restart Backoffice dan jalankan role/cross-Company/export/XLSX
smoke pada `docs/runbooks/DEX2_ROLE_AWARE_EXPORT_CENTER.md`. Next safe step
setelah smoke PASS adalah DEX-3 import consolidation. Jangan menghapus menu
Inventory atau melonggarkan import permission sebelum DEX-4 parity.

### 2026-08-11 — DEX-1 access/catalog audit complete

DEX-1 repository audit selesai dan dicatat pada
`docs/audits/DEX1_GLOBAL_DATA_EXCHANGE_ACCESS_CATALOG_AUDIT_2026-08-11.md`.
Execution path aktif telah dipetakan: sepuluh fixed master type memakai
`MasterImportView` → Master Import API → guarded job RPC, sedangkan Finance
memiliki canonical on-screen report RPC tetapi XLSX baru untuk Journal Entries
dan General Ledger.

Temuan implementasi: catalog type masih client-owned; `EXPORT`/`IMPORT` masih
memakai satu Owner/Admin guard; granular module/submodule/action grant per user
belum ada; Finance export route belum memiliki explicit Finance role guard;
master direct readers belum dibungkus server provider registry. Tidak ada
runtime/schema/grant/menu yang diubah. Inventory entry point tetap aktif.

Next safe step: DEX-2 role-aware export center. Buat shared server catalog dan
action evaluator, catalog API, global page/navigation, negative role/tenant/
scope tests, pindahkan dua Finance XLSX ke provider registry, lalu tambah Trial
Balance, Income Statement, Balance Sheet, Pending Analysis, dan Reconciliation
XLSX melalui canonical report/read contract. Jangan membuka hak Import baru dan
jangan menghapus route/menu Inventory sampai DEX-4 parity + user smoke.

### 2026-08-11 — Global Data Exchange Center approved; pre-deploy gap

User menyetujui satu Global Role-Aware Data Exchange Center untuk menggantikan
submodul Import/Export Inventory. Keputusan dicatat di
`docs/GLOBAL_DATA_EXCHANGE_CENTER_SPEC.md` dan requirement `MST-009`.

Katalog module/type/action wajib berasal dari authority server berdasarkan
active Company, module/submodule access, Store/Warehouse scope, serta permission
`EXPORT`/`IMPORT` terpisah. Finance reports dan seluruh histori posted/final
bersifat export-only; generic import tetap melalui staging/preview/guarded RPC
dan tidak boleh menulis Stock/FIFO/Movement/Payment/Event/Journal final.

Legacy Inventory entry point belum dihapus. Cutover dilakukan DEX-1 audit →
DEX-2 global export/Finance XLSX → DEX-3 guarded import consolidation → DEX-4
parity/authenticated smoke dan retirement navigation. Ini adalah gap pre-deploy
yang disetujui user, bukan fitur yang sudah aktif.

Status deployment: project boleh masuk **persiapan Vercel Preview/UAT**, tetapi
belum siap Production pilot. Gate tersisa adalah Finance Phase-7B authenticated
cross-role/cross-Company/XLSX smoke, Finance pilot reconciliation/stress,
DEX-1–DEX-4, full E2E/regression/cutover checklist, dan deployment environment/
Auth/secret verification. Sebanyak 25 HOLD/sembilan Finance posting contract
tetap deferred dan harus tampil sebagai Pending Analysis; tidak boleh diproses
hanya untuk mengejar deployment.

### 2026-08-11 — Guarded Finance UAT dataset local-ready

Atas permintaan user untuk data dummy yang mengikuti flow sistem, paket UAT
persisten telah ditambahkan tanpa schema/migration baru:

- preflight SELECT-only
  `supabase/diagnostics/g6_phase7b_finance_uat_seed_preflight.sql`;
- guarded operation
  `supabase/operations/g6_phase7b_create_finance_uat_dataset.sql`;
- postflight SELECT-only
  `supabase/diagnostics/g6_phase7b_finance_uat_seed_postflight.sql`;
- runbook `docs/runbooks/G6_PHASE7B_FINANCE_UAT_DATASET.md`.

Operation memakai linked Super Admin dan active Company context, membuat
Product melalui atomic Product-UOM RPC, Opening Stock melalui save/post RPC,
lalu mem-preview/approve/process tepat satu event melalui controlled Finance
queue. Hasilnya satu jurnal POSTED Rp5.000.000 dengan nomor manusiawi dan satu
Stock Gain Rp250.000 yang sengaja tetap HOLD untuk Pending Analysis karena
contract tersebut masih deferred. Final Stock/FIFO/Movement expected adalah
105 unit/Rp5.250.000. Tidak ada direct insert ke Stock, FIFO, Movement, Event,
Queue, atau Finance journal.

Safety boundary: operation hanya berjalan bila tepat satu Company ACTIVE,
tidak ada seed identity collision, tidak ada queue aktif, dan tidak ada
supported STOCK_OPENING HOLD lain. Preflight juga memeriksa current period serta
approved two-line STOCK_OPENING posting rule. Seluruh langkah berada dalam satu
transaction; kegagalan me-rollback dataset. Histori sukses bersifat permanen,
tidak mempunyai cleanup destructive, dan hanya boleh dijalankan pada database
test/pilot. Static evidence: parentheses preflight `104/104`, operation `53/53`,
postflight `85/85`; operation mempunyai BEGIN/COMMIT; postflight/preflight tanpa
mutation; scoped `git diff --check` PASS. Live Supabase preflight/operation/
postflight dan authenticated Finance UI smoke menunggu user.

Next safe step: user menjalankan preflight → operation → postflight sesuai
runbook, lalu mengecek Journal Entries, Buku Besar, Queue, Pending Analysis,
dan XLSX bulan berjalan. Jangan memproses Stock Gain HOLD atau membuka event
contract deferred untuk membuat dataset terlihat seluruhnya POSTED.

### 2026-08-11 — Phase 7B database user-verified; UI smoke berikutnya

User mengonfirmasi preflight, migration `20260811100000`, postflight, dan
behavioral test human Finance identifiers seluruhnya sukses. Database numbering
`JUR/JRB/PST/EXC/REC` ditutup `USER VERIFIED`. Belum ada konfirmasi untuk
authenticated Backoffice smoke Buku Besar, Journal Entries, XLSX, role, dan
cross-Company.

Next safe step menurut roadmap: restart Backoffice dan jalankan authenticated
Phase-7B UI smoke. Setelah smoke PASS, tutup Phase 7B lalu lanjut Phase-7 pilot
reconciliation/stress sebelum Vercel Preview. Jangan membuka 25 HOLD/sembilan
posting contract deferred pada langkah smoke ini.

### 2026-08-11 — Phase 7B UX forward fix local-ready

Perubahan rundown Finance yang disetujui user telah diimplementasikan:

- `20260811100000_g6_phase7b_finance_human_identifiers.sql` menyediakan nomor
  manusia `JUR/JRB/PST/EXC/REC` yang server-owned, tenant/month scoped, dan
  concurrency-safe; UUID/FK/idempotency serta nomor legacy tetap dipertahankan;
- preflight, postflight, rollback-safe behavior, dan runbook rollout tersedia;
- Buku Besar di Backoffice sekarang menampilkan semua akun sebagai summary dan
  lazy-expand detail transaksi POSTED/saldo berjalan;
- Journal Entries merupakan page dokumen terpisah dengan filter bulanan,
  search, detail debit/kredit, serta drill-through dari Buku Besar;
- `/api/finance/operations/export` menghasilkan XLSX bulanan nyata untuk Buku
  Besar dan Journal Entries memakai dependency ringan `fflate`, dengan metadata
  Company, timezone, periode, generated-at, dan report version;
- UI tidak lagi memakai UUID/random `journal_no`, `queue_no`, atau event code
  sebagai label utama user.

Evidence lokal: scoped ESLint PASS; Next production build PASS termasuk route
export; XLSX ZIP/XML smoke PASS. Full repository lint sempat melewati timeout
120 detik tanpa menghasilkan error, lalu scoped lint file perubahan selesai
PASS. `npm audit` masih melaporkan high advisories pada dependency existing
Next/build chain; tidak dilakukan forced major upgrade di task Finance ini.

Manual gate menunggu user, urutannya:

1. preflight `g6_phase7b_finance_human_identifiers_preflight.sql`;
2. migration `20260811100000_g6_phase7b_finance_human_identifiers.sql`;
3. postflight `g6_phase7b_finance_human_identifiers_postflight.sql`;
4. behavior `g6_phase7b_finance_human_identifiers_tests.sql`;
5. restart Backoffice dan smoke lintas-role/lintas-Company serta buka dua XLSX.

Runbook:
`docs/runbooks/G6_PHASE7B_FINANCE_HUMAN_IDS_LEDGER_EXPORT.md`. Next safe step
setelah user mengirim all-PASS adalah authenticated Phase-7 pilot
reconciliation/stress, bukan membuka 25 HOLD/sembilan deferred contract.

### 2026-08-11 — Phase 7A user-verified; Phase 7B Finance UI local-ready

User mengonfirmasi migration `20260811090000`, postflight, dan behavioral test
Phase 7A seluruhnya PASS. Manifest/root README/gate sekarang menutup Phase 7A
sebagai `COMPLETE; USER VERIFIED`.

Phase 7B Finance Operations Backoffice telah dibuat tanpa schema baru:

- `backoffice/src/app/api/finance/operations/route.ts` menyediakan tenant-safe
  reads untuk canonical journal/line, accounting period, controlled queue,
  posting exception, postable COA, serta enam report RPC;
- mutation create/lock/reopen period, append-only reversal, dan
  preview/approve/process queue hanya diteruskan ke guarded canonical RPC;
- `backoffice/src/components/FinanceOperationsView.tsx` menyediakan tab
  Ringkasan, Jurnal, Periode, Posting Queue, dan Laporan dengan custom modal,
  Escape close, explicit confirmation, version handling, dan role-aware action;
- `backoffice/src/app/page.tsx` tidak lagi membaca/render
  `public.journal_entries` legacy dan mengarahkan menu Finance ke workspace
  canonical;
- runbook smoke ada di
  `docs/runbooks/G6_PHASE7B_FINANCE_OPERATIONS_UI.md`.

Evidence lokal: `npm.cmd run lint` PASS tanpa warning; `npm.cmd run build` PASS
(Next production build, TypeScript, 51 static pages, route
`/api/finance/operations`). Compatibility: tidak ada migration/data mutation;
Master Finance, Supplier Invoice/Payment, Inventory, POS, dan PWA tidak diubah.

Saat smoke pertama, proses Backoffice user masih mengembalikan HTML untuk route
baru sehingga client menampilkan `Unexpected token '<'`. Client sekarang
memvalidasi body response dan memberi instruksi restart yang jelas apabila Next
mengembalikan HTML. Rebuild lint/production PASS; production-server smoke ke
`/api/finance/operations` tanpa token menghasilkan HTTP `401`, content-type
`application/json`, body `{"error":"AUTHENTICATION_REQUIRED"}`. Artinya route
valid; proses Backoffice yang sudah berjalan wajib direstart agar memuat route
baru.

Manual gate yang menunggu user: siapkan minimal Finance operator dan Company
Owner/Admin approver pada pilot Company, restart Backoffice, lalu jalankan smoke
lintas-role/lintas-Company sesuai runbook. Queue harus tetap hanya
`STOCK_OPENING`; jurnal otomatis tidak boleh memiliki action reversal; pending
analysis harus tetap memisahkan 25 HOLD dari laporan POSTED. Next safe step
setelah smoke PASS adalah Phase-7 pilot reconciliation/stress sebelum Vercel
Preview, bukan membuka sembilan deferred event contract.

UX requirement yang sudah disepakati sebelum smoke final: sembunyikan seluruh
UUID/random ID; gunakan nomor Finance manusiawi tanpa mengganti backend UUID;
pisahkan General Ledger account-centric (semua akun, expandable detail) dari
Journal Entries document-centric (daftar jurnal, expandable debit/kredit);
tambahkan export XLSX per accounting period. Implementasi belum dibuat dan
wajib menjaga tenant/RPC/report-version/performance boundary.

### 2026-08-11 — Phase 7 preflight safe; Phase 7A reversal local-ready

User mengirim Phase-7 operations/pilot preflight tanpa `BLOCKER` atau
`REVIEW`. Canonical Finance schema/routines, period lifecycle, queue, posted
journal/event coverage, reversal uniqueness, browser boundary, dan legacy
routine quarantine seluruhnya PASS. `pilot_company_role_readiness=BACKFILL`
berarti satu pilot Company masih harus mempunyai Finance operator dan Company
Owner/Admin approver sebelum UAT. `canonical_finance_reversal_runtime=SETUP`
adalah expected implementation gap. FIFO Rp84.710.000 versus Inventory GL
Rp450.000 dan 25 HOLD/sembilan contract tetap `DEFERRED`.

Phase 7A sekarang `LOCAL READY; MANUAL DATABASE ROLLOUT PENDING`:

- migration
  `supabase/migrations/20260811090000_g6_phase7_append_only_journal_reversal.sql`;
- postflight
  `supabase/diagnostics/g6_phase7_append_only_journal_reversal_postflight.sql`;
- rollback-safe behavior
  `supabase/tests/g6_phase7_append_only_journal_reversal_tests.sql`;
- runbook
  `docs/runbooks/G6_PHASE7A_APPEND_ONLY_JOURNAL_REVERSAL_ROLLOUT.md`.

Scope reversal sengaja hanya jurnal `MANUAL` dan `OPENING_BALANCE` yang POSTED
pada period target OPEN/REOPENED. Jurnal `AUTOMATIC`,
`PRIOR_PERIOD_ADJUSTMENT`, dan `REVERSAL` wajib dikoreksi melalui dokumen sumber
resmi supaya GL tidak terpisah dari Stock/FIFO, AP/AR, Payment, dan source
operasional. RPC memakai active Company, Finance/Owner/Admin role, row lock,
master version, reason, UUID idempotency, unique original-reversal link,
original line snapshots, debit/credit swap, serta audit POST+REVERSE. Tidak ada
live journal/event/queue yang dibuat migration.

Evidence lokal: migration parentheses `47/47`, delimiter tags `2`; postflight
`98/98`, mutation statement `0`; behavior `46/46`, transaction + rollback;
scoped `git diff --check` PASS. SHA-256 migration
`774c53b93a8e77833101bc3215f9faaec1aace9542ea741b610454f18dab9868`.

Manual gate: jalankan migration -> postflight (seluruh non-INFO harus PASS) ->
behavior (NOTICE TEST PASSED) -> Phase-7 preflight dan Finance regression.
Jangan membuka UI reversal/pilot atau memproses 25 HOLD sebelum output ini
direview. Role backfill wajib sebelum authenticated cross-role UAT/pilot, tetapi
tidak menghalangi rollout database rollback-safe memakai linked Super Admin.

### 2026-08-10 — Phase 6C preflight safe; rollout local-ready

User mengirim Phase-6C preflight tanpa `BLOCKER`/`REVIEW`. Posted journal
fixture, trial balance, Balance Sheet equation, timezone, browser boundary,
legacy report quarantine, dan exception baseline seluruhnya PASS. Expected
`SETUP`: empat report definition/RPC, dua reconciliation relation, dan P&L
nonzero fixture. Expected `DEFERRED`: 25 HOLD/9 contract serta FIFO Rp84.710.000
versus GL Rp450.000.

Rollout package sekarang tersedia:

- migration `supabase/migrations/20260810230000_g6_phase6c_statements_pending_reconciliation.sql`;
- postflight `supabase/diagnostics/g6_phase6c_statements_pending_reconciliation_postflight.sql`;
- rollback-safe behavior `supabase/tests/g6_phase6c_statements_pending_reconciliation_tests.sql`;
- runbook `docs/runbooks/G6_PHASE6C_STATEMENTS_PENDING_RECONCILIATION_ROLLOUT.md`.

Scope: P&L/Neraca hanya jurnal POSTED; pending event diberi label
`BELUM MASUK LAPORAN KEUANGAN`; reconciliation summary hanya current-state dan
`autoAdjustment=false`; historical date ditolak karena subledger history belum
dapat direkonstruksi. Reconciliation document/allocation foundation immutable
dan browser read-only. Migration tidak menulis journal/event/queue/reconciliation
business row. Evidence statis: migration parentheses `335/335`, 26 delimiter
tags; postflight `141/141`, one SELECT; behavior `64/64`; diff check PASS.
SHA-256 `eefc08147773656d3da4187904c0008b916efbf854f534ce5ae2951dc0ed0402`.

Manual gate: migration -> all-PASS postflight -> behavior -> Phase-6C preflight
rerun -> Phase-6A/6B, Phase-5/4/2, dan G1 regressions. Remaining HOLD tidak
boleh diproses oleh rollout ini.

### 2026-08-11 - Phase 6C complete; Phase 7 preflight local-ready

User mengonfirmasi migration `20260810230000`, postflight, dan behavioral test
Phase 6C seluruhnya PASS. Phase 6C ditutup `COMPLETE; USER VERIFIED` tanpa
memproses 25 event HOLD dan tanpa menutup selisih FIFO-Inventory GL melalui
adjustment buatan.

Next safe step adalah Corrective Phase 7. Artifact baru:

- `supabase/diagnostics/g6_phase7_finance_operations_pilot_preflight.sql`;
- `docs/runbooks/G6_PHASE7_FINANCE_OPERATIONS_PILOT_PREFLIGHT.md`.

Preflight bersifat SELECT-only dan mengaudit dependency/schema/RPC canonical,
queue aktif/failure, journal/event/reversal/period integrity, pilot role,
browser/legacy privilege, serta deferred HOLD dan FIFO-GL. Expected gap awal:
`canonical_finance_reversal_runtime=SETUP`; tidak boleh diganti dengan edit atau
delete journal posted.

Local execution-path correction: endpoint
`backoffice/src/app/api/worker/process-queue/route.ts` sekarang selalu 410
`LEGACY_FINANCE_WORKER_RETIRED`. Endpoint sebelumnya memakai service role untuk
memanggil `process_financial_events_queue`, yaitu worker legacy yang sudah
dikeluarkan dari jalur G6 canonical. Canonical queue tetap hanya melalui guarded
preview/approve/process RPC dan belum mempunyai UI Phase 7.

Manual gate: jalankan preflight Phase 7 dan kirim seluruh output. Jangan membuat
migration reversal, UI posting, memproses HOLD, atau membuka pilot sebelum
`BLOCKER`/`REVIEW` direview. Local evidence: preflight parentheses `213/213`,
mutation statement `0`, scoped `git diff --check` PASS; Backoffice
`npm.cmd run lint` PASS dan production `npm.cmd run build` PASS (50 generated
pages, termasuk endpoint worker fail-closed).

### 2026-08-10 — Phase 6B complete; Phase 6C preflight ready

User mengonfirmasi controlled live operation serta closing postflight Phase 6B
aman. Exactly one queue run final `COMPLETED`, satu posted item/journal, dua
journal line, nominal Rp450.000 tepat pada Inventory Asset dan Opening Balance
Clearing, tanpa duplicate, active queue, atau exception. Phase 6B ditutup
`COMPLETE; USER VERIFIED`.

Full FIFO–GL tetap deferred secara eksplisit: FIFO Rp84.710.000, Inventory GL
Rp450.000, difference Rp84.260.000, dan remaining 25 HOLD dari sembilan event
contract. Ini bukan kegagalan controlled event dan tidak boleh ditutup dengan
jurnal manual.

Next safe step:

- `supabase/diagnostics/g6_phase6c_statements_pending_reconciliation_preflight.sql`;
- `docs/runbooks/G6_PHASE6C_STATEMENTS_PENDING_RECONCILIATION_PREFLIGHT.md`.

Diagnostic memeriksa posted fixture/trial balance, Neraca equation, P&L fixture,
timezone, expected four report definitions/RPC, reconciliation relation,
pending HOLD/exceptions, legacy report quarantine, browser boundary, dan
FIFO–GL exposure. `BLOCKER`/`REVIEW` wajib nol; `SETUP` dan `DEFERRED` sesuai
runbook. Tidak ada event/queue/report mutation.

### 2026-08-10 — Phase 6B live preflight safe; controlled operation ready

User mengirim Phase-6B preflight tanpa `BLOCKER` atau `REVIEW`. Tepat satu
supported historical `STOCK_OPENING` pada satu Company siap diproses, amount
Rp450.000, source/rule/period valid, queue awal kosong, dan tidak ada journal
atau open exception. FIFO live Rp84.710.000 sedangkan Inventory GL nol. Dua
angka itu tidak identik karena 25 event dari sembilan contract lain masih HOLD
dan deferred.

Controlled live package sekarang tersedia:

- mutation operation
  `supabase/operations/g6_phase6b_post_one_live_stock_opening.sql`;
- SELECT-only closing postflight
  `supabase/diagnostics/g6_phase6b_stock_opening_live_reconciliation_postflight.sql`;
- runbook `docs/runbooks/G6_PHASE6B_CONTROLLED_LIVE_STOCK_OPENING.md`.

Operation menolak eksekusi bila live scope berubah dari tepat satu event total
Rp450.000, bila queue aktif muncul, atau linked Super Admin tidak tersedia.
Operation memakai canonical preview -> approve -> process, bukan direct table
write. Expected final run `COMPLETED`, posted 1, failed/skipped 0. Postflight
mewajibkan event/journal/amount/account-function/report coverage PASS, sementara
full FIFO–GL masih boleh `DEFERRED` dengan alasan unsupported operational event.
Jangan rerun operation dan jangan membuat adjustment manual.

First live attempt gagal sebelum queue creation pada
`set_active_company_context(...,'G6_PHASE6B_CONTROLLED_LIVE_STOCK_OPENING')`
karena source melebihi batas regex 32 karakter. Transaction rollback sehingga
tidak ada side effect. Operation dikoreksi in-place (belum pernah berhasil
dijalankan) menjadi source `G6_PHASE6B_LIVE_POST`; tidak ada schema/business
flow change dan tidak memerlukan migration.

### 2026-08-10 — Phase 6A user-verified; Phase 6B live preflight ready

User mengonfirmasi migration `20260810220000`, postflight, dan rollback-safe
behavioral test Phase 6A seluruhnya PASS. Trial Balance dan General Ledger
POSTED-only ditutup `COMPLETE; USER VERIFIED`. Tidak ada live event atau jurnal
yang dibuat oleh rollout tersebut.

Next safe step adalah menjalankan SELECT-only diagnostic:

- `supabase/diagnostics/g6_phase6b_stock_opening_live_reconciliation_preflight.sql`;
- `docs/runbooks/G6_PHASE6B_STOCK_OPENING_LIVE_RECONCILIATION_PREFLIGHT.md`.

Gate ini memeriksa dependency Phase 5/6A, source amount, approved rule, direct
atau later open period, existing journal/exception, active queue, RPC/browser
boundary, unsupported event, serta FIFO versus Inventory GL. Expected
`BACKFILL` untuk satu supported live event dan baseline FIFO–GL; unsupported
25 event tetap `DEFERRED`. `BLOCKER` dan `REVIEW` harus nol. File tidak
memanggil preview/approve/process dan tidak melakukan mutation. Jangan jalankan
live queue sebelum seluruh output diagnostic direview.

### 2026-08-10 — Phase 6 preflight reviewed; Phase 6A reports local-ready

User mengirim live Phase-6 preflight tanpa `BLOCKER` atau `REVIEW`. Seluruh
integrity/security/period/tenant check PASS. Expected setup object report dan
reconciliation belum ada. FIFO live bernilai Rp84.710.000 sedangkan Inventory
GL nol, serta satu supported historical event masih HOLD. Ini adalah expected
controlled backfill karena belum ada canonical journal POSTED; jangan membuat
jurnal manual penyeimbang. Sebanyak 25 event dari sembilan contract tetap
DEFERRED.

Phase 6A sekarang `LOCAL READY; MANUAL DATABASE ROLLOUT PENDING`:

- migration `supabase/migrations/20260810220000_g6_phase6a_posted_financial_reports.sql`;
- postflight `supabase/diagnostics/g6_phase6a_posted_financial_reports_postflight.sql`;
- behavior `supabase/tests/g6_phase6a_posted_financial_reports_tests.sql`;
- runbook `docs/runbooks/G6_PHASE6A_POSTED_FINANCIAL_REPORTS_ROLLOUT.md`.

Scope hanya POSTED-only Trial Balance dan General Ledger, active-Company dan
Finance-role server guard, timezone, filter Store/Gudang, version metadata,
source/prior-period drill-down, pagination, immutable report history, RLS, dan
browser read-only. Migration tidak memproses HOLD, tidak membuat journal, dan
tidak mengubah FIFO/AP/Customer Balance. P&L, Neraca, pending analysis,
reconciliation mutation, export worker, UI, dan unsupported events masih
tertutup.

Evidence lokal: migration/test/report artefact delimiter dan parentheses
seimbang (`199/199`, `50/50`, `105/105`); SHA-256 migration
`4e336d388fc434c44a23897dd89c097f2afaf9af351db376ef23bed9e162d56f`.
Manual gate berikutnya: migration -> all-PASS postflight -> rollback-safe
behavior -> Phase-6/5/4/2/G1 regression. Jangan menjalankan live Phase-5 queue
sampai closing output Phase 6A direview.

### 2026-08-10 — Phase 4 closed; Phase 5 controlled queue preflight

User mengonfirmasi migration `20260810200000`, postflight, dan rollback-safe
behavioral test Phase 4 seluruhnya PASS. Corrective Phase 4 ditutup
`COMPLETE; USER VERIFIED`. Runtime posting tetap hanya mendukung kontrak
`STOCK_OPENING`; historical event `HOLD` belum diproses batch.

Next safe step sekarang adalah menjalankan seluruh diagnostic SELECT-only:

- `supabase/diagnostics/g6_phase5_controlled_queue_preflight.sql`;
- petunjuk: `docs/runbooks/G6_PHASE5_CONTROLLED_QUEUE_PREFLIGHT.md`.

Diagnostic memeriksa dependency/runtime Phase 4, expected queue relation/RPC,
active-Company boundary, supported source/rule/period, early journal,
historical backfill scope, unsupported/deferred event, exception inventory,
dan privilege. Expected baseline: queue object `SETUP`, supported historical
event dapat `BACKFILL`, dan contract selain `STOCK_OPENING` dapat `DEFERRED`.
`BLOCKER` harus nol. Jangan membuat migration queue atau memproses HOLD sebelum
seluruh live output direview.

Evidence lokal: preflight mempunyai satu executable SELECT dan satu SQL
terminator (semicolon lain hanya komentar), tanda kurung seimbang `142/142`,
mutation keyword hanya muncul pada string privilege metadata, dan scoped
`git diff --check` PASS. Manual Supabase execution masih menunggu user.

User kemudian mengirim live Phase 5 preflight tanpa blocker/review. Satu
historical `STOCK_OPENING` pada satu active Company mempunyai source, rule,
period, identity, dan privilege yang siap; 25 event dari sembilan contract lain
tetap `DEFERRED`. Expected tiga table dan tiga RPC queue masih `SETUP`.

Rollout Phase 5 sekarang `LOCAL READY; MANUAL DATABASE ROLLOUT PENDING`:

- migration
  `supabase/migrations/20260810210000_g6_phase5_controlled_posting_queue.sql`;
- postflight
  `supabase/diagnostics/g6_phase5_controlled_posting_queue_postflight.sql`;
- rollback-safe behavioral test
  `supabase/tests/g6_phase5_controlled_posting_queue_tests.sql`;
- runbook
  `docs/runbooks/G6_PHASE5_CONTROLLED_POSTING_QUEUE_ROLLOUT.md`.

Migration membuat single-active-Company preview/approval/process queue,
immutable event/version/source/hash snapshot, optimistic version, RLS, audit,
dan per-event exception isolation dengan posting authority Phase 4. Migration
tidak membuat queue run serta tidak memproses event `HOLD`. Behavior memakai
dua synthetic `STOCK_OPENING`: satu sukses dan satu amount mismatch; test
memastikan failed item tidak mempunyai partial journal sementara item valid
tetap final, lalu seluruh fixture rollback.

Evidence lokal: migration 766 lines dengan delimiter seimbang dan parentheses
`180/180`; postflight 300 lines, satu SELECT, parentheses `125/125`; behavior
295 lines dan parentheses `65/65`; scoped `git diff --check` PASS. SHA-256
migration `62aad6e911ee4a198fa97b6366f67a032f01072f7840ec3fb26497435ff7ea7c`.
Manual gate: migration -> all-PASS postflight -> behavior -> Phase 4/3/2/G1
regression -> closing postflight. Jangan memproses satu historical live event
sebelum gate database ini selesai dan output closing direview.

User kemudian mengonfirmasi seluruh rollout package Phase 5 sukses. Migration
`20260810210000`, postflight, dan rollback-safe behavioral test dianggap
`COMPLETE; USER VERIFIED`. Karena runbook secara eksplisit melarang pemrosesan
live, satu historical `STOCK_OPENING` tetap HOLD menunggu controlled approval;
25 event lain tetap deferred.

Next safe step sekarang adalah G6 Corrective Phase 6 preflight SELECT-only:

- `supabase/diagnostics/g6_phase6_reporting_reconciliation_preflight.sql`;
- `docs/runbooks/G6_PHASE6_REPORTING_RECONCILIATION_PREFLIGHT.md`.

Diagnostic memeriksa POSTED-only canonical journal, balance/period/dimension,
active Company timezone, expected report/reconciliation schema dan enam RPC,
unsafe legacy report privilege, Stock FIFO versus Inventory GL, Supplier AP
versus GL, Customer Balance versus GL, Phase-5 queue, prior-period, serta
operational pending exposure. Expected `SETUP`, `BACKFILL`, dan `DEFERRED`
tidak otomatis blocker; `BLOCKER` wajib nol. Jangan membuat report migration
atau memproses live HOLD sebelum seluruh output direview.

Evidence lokal: diagnostic 590 lines, satu executable SELECT/semicolon,
parentheses `223/223`, mutation statement nol, dan scoped `git diff --check`
PASS. Manual Supabase execution masih menunggu user.

`CORRECTIVE PHASE 3 COMPLETE; PHASE 4 PREFLIGHT READY`
(2026-08-10).

- Review menemukan draft G6 Phase 2–11 tidak memenuhi kontrak approved:
  destructive journal reset, cross-Company `SECURITY DEFINER`, canonical rule
  schema relaxation, guessed account/amount fallback, dan migration chain tanpa
  ledger/manifest.
- Seluruh draft migration/postflight/test tersebut dikeluarkan dari jalur
  rollout. Endpoint/report UI automatic posting juga ditutup; menu Finance
  kembali memakai journal read-only existing.
- Corrective roadmap tercatat di
  `docs/G6_FINANCE_CORRECTIVE_RECOVERY_PLAN.md`.
- G6 Corrective Phase 1 sekarang berupa satu diagnostic SELECT-only:
  `supabase/diagnostics/g6_phase1_posting_engine_preflight.sql`.
- Supplier Invoice optional tolerance tetap merupakan keputusan user. File lama
  dipertahankan sebagai executed history dan forward migration authoritative
  `20260810160000` dibuat dengan transaction, guard, privilege, ledger,
  postflight, regression test update, runbook, dan manifest checksum.
- Supplier Payment Phase 14 tetap pada status user-reported PASS dan masih hanya
  menghasilkan Financial Event `HOLD`; jurnal G6 belum aktif.
- Evidence lokal corrective boundary: targeted ESLint PASS, `npm.cmd run build`
  PASS (TypeScript dan 50/50 static pages), `git diff --check` PASS selain
  peringatan normalisasi LF/CRLF, diagnostic mutation scan PASS, dan tidak ada
  lagi destructive journal reset/fabricated amount/universal account fallback
  pada jalur rollout aktif.
- Rencana inter-Company Sales/Purchase dicatat `DEFERRED AFTER PILOT/VERCEL` dan
  tidak memperluas MVP saat ini.

Manual gate berikutnya:

1. G5 corrective migration/postflight/regression `20260810160000` sudah
   dikonfirmasi user sampai G6 preflight dapat berjalan;
2. G6 preflight menemukan satu blocker terisolasi: 10 routine legacy/rejected
   G6 masih executable oleh `authenticated`; ledger G6 ditolak tetap kosong,
   canonical rule/trigger/tenant/journal checks lain seluruhnya PASS;
3. jalankan privilege-only forward migration `20260810170000`;
4. jalankan quarantine postflight dan behavior test sesuai
   `docs/runbooks/G6_PHASE1_FINANCE_ROUTINE_QUARANTINE_ROLLOUT.md`;
5. rerun G6 Corrective Phase 1 preflight; jangan membuat Corrective Phase 2
   sebelum seluruh `BLOCKER` nol.

User kemudian mengonfirmasi migration quarantine, postflight, behavioral test,
dan rerun Corrective Phase 1 seluruhnya sukses. Next manual gate adalah
SELECT-only `g6_phase2_journal_foundation_preflight.sql`; output wajib direview
karena live database sudah memiliki object `accounting_periods` dan
`journal_lines` tanpa ledger draft G6 yang sah.

Output Phase-2 preflight user: seluruh security/tenant/history check PASS;
`journal_lines` kosong menurut statistic tetapi memiliki FK ke
`journal_entries` legacy, sementara `accounting_periods` mempunyai 2 row dengan
`start_date/end_date` dan belum mempunyai `master_version`. Diagnostic fokus
`g6_phase2_period_journal_contract_resolution.sql` menjadi gate terakhir
sebelum migration foundation: audit exact rows, status, overlap, constraint,
policy, dan routine dependency tanpa mutation.

User mengonfirmasi diagnostic fokus tersebut seluruhnya PASS. Corrective Phase
2 foundation sekarang `LOCAL-READY, MANUAL ROLLOUT PENDING` melalui migration
`20260810180000`: mengadopsi dua period valid, menambah optimistic version/audit,
mengarantina rejected `journal_lines`, serta membuat additive
`finance_journals`/`finance_journal_lines`/`finance_journal_audit`. Browser tetap
read-only, posted journal balanced dan immutable, period lock/reopen guarded,
dan tidak ada satu pun event HOLD atau legacy journal yang diproses. Ikuti
`docs/runbooks/G6_PHASE2_TENANT_SAFE_JOURNAL_FOUNDATION_ROLLOUT.md`.

User kemudian mengonfirmasi migration `20260810180000`, postflight, dan
behavioral test Corrective Phase 2 seluruhnya PASS. Phase 2 ditutup COMPLETE.
Next safe step adalah menjalankan SELECT-only
`supabase/diagnostics/g6_phase3_versioned_posting_mapping_preflight.sql` sesuai
`docs/runbooks/G6_PHASE3_VERSIONED_POSTING_MAPPING_PREFLIGHT.md`. Diagnostic
mengaudit 26 event HOLD tanpa memprosesnya: source amount-key contract,
required Account Function, rule/fallback missing atau ambiguous, compatible
COA, dan kebutuhan model expression versioned. Jangan membuat mapping migration
atau menjalankan retry event sebelum seluruh output direview.

File Phase 3 yang ditambahkan:

- `supabase/diagnostics/g6_phase3_versioned_posting_mapping_preflight.sql`;
- `docs/runbooks/G6_PHASE3_VERSIONED_POSTING_MAPPING_PREFLIGHT.md`.

Evidence lokal: diagnostic berisi tepat satu statement non-comment, delimiter
dan tanda kurung seimbang, mutation scan nol, serta `git diff --check` PASS
dengan hanya warning normalisasi LF/CRLF. Manual gate menunggu seluruh output
preflight dari Supabase; belum ada migration/schema/business row Phase 3.

Eksekusi pertama preflight berhenti tanpa side effect pada PostgreSQL `42702`
karena output `unnest()` memakai alias `function_key` yang bertabrakan dengan
kolom `account_functions.function_key`. Seluruh empat lateral function-array
sekarang memakai alias tabel/kolom explicit dan setiap referensi sudah
qualified. Rerun wajib memakai file terbaru dari awal.

Rerun user memetakan 34 required mapping pada 25 Category serta 52
event-function row pada 26 event HOLD sebagai expected backfill; seluruh 16
Company–Function mempunyai compatible account candidate dan canonical journal
masih nol. Gate explicit awal menemukan 5 Company–Function unresolved karena
ia menghitung seluruh akun ber-tag sama sebagai ambiguity. Resolver dikoreksi
untuk memilih tepat satu akun `is_system_account=true`; bila tidak ada akun
sistem, tepat satu akun explicit diperbolehkan. Lebih dari satu akun sistem
tetap blocker dan preflight kini menampilkan function key serta kedua candidate
count. Corrective Phase 3 tetap local-ready melalui migration `20260810190000`, postflight,
behavioral test, dan rollout runbook
`docs/runbooks/G6_PHASE3_VERSIONED_POSTING_MAPPING_ROLLOUT.md`. Provisioning
hanya menerima canonical system-owned atau sole explicit
`chart_of_accounts.system_function_key`, bukan akun pertama atau sekadar tipe
compatible. Rule-set declarative belum
dieksekusi; posting engine dan historical HOLD tetap tertutup.

File baru Phase 3: migration
`supabase/migrations/20260810190000_g6_phase3_versioned_posting_mapping.sql`,
postflight, behavioral test, serta rollout runbook. Evidence lokal: version
unik, delimiter function dan tanda kurung seimbang. Setelah resolver canonical
system-owned diperbaiki dan dependency ownership fix ditambahkan, manifest
checksum menjadi
`0d0fde0f7224e0188a8b0ebf357a7c5abf02ef869f1c5188a44fbe9785c03a9e`.
SQL belum
dijalankan ke Supabase; manual gate wajib migration → postflight → behavioral
test → rerun preflight, berurutan dan berhenti pada error pertama.

Sebelum migration, latest preflight gate
`explicit_system_function_account_scope` wajib PASS. Resolver mengutamakan
tepat satu COA active/postable system-owned dengan `system_function_key`
identik; sole explicit fallback hanya berlaku bila kandidat system-owned nol.
Migration belum dijalankan; rerun preflight terbaru adalah next safe step.

Rerun terbaru membuktikan blocker riil pada lima function: `COGS`,
`INVENTORY_ASSET`, `SALES_REVENUE`, `STOCK_GAIN_INCOME`, dan
`STOCK_LOSS_EXPENSE`; masing-masing mempunyai dua akun active/postable yang
sama-sama `is_system_account=true`. User menjelaskan duplikat berasal dari COA
KGS yang pernah diimport langsung oleh agent lain dan menginstruksikan akun
import menjadi Company-owned. Forward migration `20260810185000` mempertahankan
seed `1310/4110/5110/6130/7110`, lalu hanya mengubah duplicate imported account
menjadi `is_system_account=false`; UUID, kode seperti `1010100-1`, nama,
hierarchy, function tag, dan semua referensi tetap utuh. Perubahan diaudit dan
trigger baru mencegah duplicate system ownership terulang. Seluruh
noncanonical `is_system_account=true` hasil import—bukan hanya lima blocker—
diturunkan menjadi Company-owned. Checksum fix
`ff3437771ddfa4dc10953cf2a963fdbd702906b620670c651344702ebf6ef1a8`.
User kemudian mengonfirmasi ownership migration `20260810185000`, postflight,
behavioral test, dan closing Phase-3 preflight seluruhnya sukses. Closing output:
`explicit_system_function_account_scope=PASS`, dependencies expected 3 PASS,
zero ambiguity/invalid contract, 34 Category mapping dan 52 historical
event-function row tetap expected `BACKFILL`, tiga expression table expected
`SETUP`, serta 26 event tetap HOLD tanpa canonical journal. Phase-3 mapping
`20260810190000` kemudian dijalankan sesuai rollout runbook; event HOLD tidak
diproses pada phase ini.

Behavioral Phase 3 pertama berhenti rollback-safe karena fixture lama membuat
akun system-owned kedua setelah Company trigger sudah menyediakan seed; guard
ownership baru dengan benar menolak `SYSTEM_FUNCTION_ACCOUNT_ALREADY_EXISTS`.
Test dikoreksi tanpa migration baru: fixture sekarang membaca canonical
`INVENTORY_ASSET` dan `OPENING_BALANCE_CLEARING` hasil provisioning Company,
lalu memakai UUID tersebut pada rule. Migration/postflight yang sudah sukses
tidak perlu diulang. User kemudian mengonfirmasi corrected behavioral test PASS;
Corrective Phase 3 ditutup `COMPLETE; USER VERIFIED`.

Next safe step adalah G6 Corrective Phase 4 preflight SELECT-only:
`supabase/diagnostics/g6_phase4_single_event_posting_preflight.sql`, dengan
petunjuk di
`docs/runbooks/G6_PHASE4_SINGLE_EVENT_POSTING_PREFLIGHT.md`. Diagnostic ini
mengaudit approved expression rule, source contract, Accounting Period,
idempotency, journal balance, exception, dan privilege tanpa menjalankan
routine atau mengubah 26 event `HOLD`. Kirim seluruh output
`check_name,status,details`; jangan membuat migration atomic posting sebelum
seluruh `BLOCKER` direview. `SETUP` routine dan `BACKFILL` approved expression
rule dapat expected pada baseline, tetapi bukan izin untuk menebak nominal.

File yang ditambahkan/diperbarui pada boundary ini:

- `supabase/diagnostics/g6_phase4_single_event_posting_preflight.sql`;
- `docs/runbooks/G6_PHASE4_SINGLE_EVENT_POSTING_PREFLIGHT.md`;
- router/status pada root README, docs README, implementation gate, corrective
  roadmap, migration manifest, dan handoff ini.

Evidence lokal: diagnostic tepat satu statement/semicolon, mutation-token scan
nol, tanda kurung seimbang `205/205`, referensi period memakai schema canonical
`start_date/end_date/status`, dan `git diff --check` PASS selain warning
normalisasi LF/CRLF existing. Manual Supabase preflight belum dijalankan.

User kemudian mengonfirmasi Phase 4 preflight aman tanpa blocker. Rollout Phase
4 sekarang `LOCAL READY; MANUAL DATABASE ROLLOUT PENDING`:

- migration
  `supabase/migrations/20260810200000_g6_phase4_atomic_single_event_posting.sql`;
- postflight
  `supabase/diagnostics/g6_phase4_atomic_single_event_posting_postflight.sql`;
- rollback-safe behavioral test
  `supabase/tests/g6_phase4_atomic_single_event_posting_tests.sql`;
- runbook
  `docs/runbooks/G6_PHASE4_ATOMIC_SINGLE_EVENT_POSTING_ROLLOUT.md`.

Kontrak runtime awal hanya `STOCK_OPENING`. Resolver membandingkan payload
dengan `opening_stock_documents.total_cost`, menyelesaikan approved rule/account,
memilih Accounting Period OPEN/REOPENED atau prior-period adjustment, merakit
semua line dalam memory, memvalidasi balance, baru menulis journal. Event berubah
POSTED terakhir dalam transaction yang sama. Unsupported event dikembalikan
HOLD dengan posting exception dan tanpa partial journal. Existing HOLD tidak
diproses oleh migration; queue historis tetap Phase 5.

Evidence lokal sementara: migration/test dollar delimiter dan seluruh file
parenthesis seimbang; postflight tepat satu SELECT; `git diff --check` PASS
selain warning LF/CRLF existing. Checksum migration saat ini
`b6dbb58dd5b1038204a6293929e3491c3a68f04adeba4b70ddb5ed76e6d0dd38`.
Manual gate berikut: migration → postflight → behavioral test, berhenti pada
error pertama dan kirim output lengkap. Jangan post event bisnis live.

## Update Sebelumnya — G5 Phase 15 Backoffice Supplier Payment / AP Settlement UI

`COMPLETE` (2026-08-07).

- Dibuat helper client & RPC error parser: `backoffice/src/lib/supplier-payment.ts`.
- Dibuat API Route: `backoffice/src/app/api/finance/supplier-payments/route.ts` (GET & POST handler untuk action `SAVE_DRAFT`, `VALIDATE`, `CANCEL`).
- Dibuat komponen UI: `backoffice/src/components/SupplierPaymentView.tsx` (2 Tab: `Daftar Pembayaran Supplier` & `Form Draf Pembayaran`, modal detail, modal validasi idempotency, dan modal pembatalan alasan wajib).
- Menu `Pembayaran Supplier` terintegrasi pada navigasi Backoffice (Finance & Purchase).
- Evidence Verifikasi Lokal: `npm run lint` & `npm run build` PASS 100% (Exit code 0, 50/50 pages compiled cleanly).

## Update Sebelumnya — G5 Phase 14 Supplier Payment Foundation Database Rollout

`COMPLETE & USER VERIFIED PASS` (2026-08-07).

- User mengonfirmasi Step 1 (Migration), Step 2 (Postflight Diagnostic), dan Step 3 (Behavioral Test Suite) seluruhnya **PASS** (`NOTICE: G5 Phase 14 Supplier Payment Behavioral Tests PASS`).
- Migration terpasang: `supabase/migrations/20260807150000_g5_phase14_supplier_payment_foundation.sql`.
- Postflight terverifikasi: `supabase/diagnostics/g5_phase14_supplier_payment_postflight.sql`.
- Behavioral test terverifikasi: `supabase/tests/g5_phase14_supplier_payment_tests.sql`.

## Update Sebelumnya — G5 Phase 13 Supplier Payment / AP Settlement Preflight

`COMPLETE` (2026-08-07).

- User mengonfirmasi diagnostik preflight Phase 13 seluruhnya PASS.

## Update Sebelumnya — G5 Phase 12 Backoffice Finance Supplier Invoice Matching UI

`COMPLETE` (2026-08-07).

- Dibuat migration forward-fix: `supabase/migrations/20260807120000_g5_phase12_flexible_tolerance_default.sql`
  agar ketika Kebijakan Toleransi KOSONG / BELUM DISETTING, sistem menganggap BEBAS (UNLIMITED TOLERANCE), sehingga draf faktur otomatis berstatus `WITHIN_TOLERANCE` dan langsung dapat divalidasi ke `VALIDATED`.
- Pemetaan nama kolom PostgreSQL pada API route dan UI diselaraskan 100% dengan skema fisik (`actual_value`, `provisional_value`, `price_variance`, `result_status`).
- Header session `Authorization: Bearer <token>` dan prop `session={session}` disertakan di `page.tsx` dan `SupplierInvoiceMatchingView.tsx`.
- User mengonfirmasi migration/postflight/behavior Phase 11 seluruhnya PASS.
- Backoffice Finance & Purchase sekarang mempunyai menu `Faktur Supplier`
  (Pencocokan Faktur Three-Way Matching):
  - View `SupplierInvoiceMatchingView` dengan 3 tab: `Daftar Faktur Supplier`,
    `Form Draf Faktur`, dan `Kebijakan Toleransi`.
  - API Routes: `GET/POST /api/finance/supplier-invoices` dan `GET/POST /api/finance/supplier-invoices/policies`.
  - Client helper & error parser: `backoffice/src/lib/supplier-invoice.ts`.
- Mutation sepenuhnya server-authoritative via RPC Phase 11:
  - `save_supplier_invoice_draft`: pembuatan & pengeditan draf faktur, kalkulasi
    pajak otomatis, dan alokasi ke Penerimaan Barang (*AP Provisional*).
  - `validate_supplier_invoice`: memvalidasi draf faktur dengan idempotency key
    dan menerbitkan Financial Event `SUPPLIER_INVOICE_VALIDATED` (HOLD_UNTIL_G6).
  - `cancel_supplier_invoice`: pembatalan faktur draf/hold/validated dengan alasan wajib.
  - `save_supplier_invoice_tolerance_policy`: pengaturan kebijakan toleransi
    kuantitas dan nilai (Company Default atau Per Supplier).
- Batasan ketat: Tanpa direct write dari browser, tanpa efek pada Stok/FIFO/Movement,
  dan tanpa Jurnal Keuangan / Pembayaran Supplier (Supplier Payment) awal.
- Evidence lokal: Backoffice lint & build PASS; Next.js mendeteksi route API
  `/api/finance/supplier-invoices` dan `/api/finance/supplier-invoices/policies`.
- Manual gate & runbook smoke:
  `docs/runbooks/G5_PHASE12_SUPPLIER_INVOICE_MATCHING_UI.md`.
- Next Safe Step setelah smoke UAT lulus: Lanjutkan ke preflight / foundation
  Supplier Payment / AP Settlement sesuai roadmap G5. Jangan membuka Jurnal penutupan G6 lebih awal.

## Update Sebelumnya — G5 Phase 11 Supplier Invoice Matching Foundation

`COMPLETE` (2026-08-06).

- User mengonfirmasi Phase 11 database rollout (migration, postflight, dan
  behavioral test) seluruhnya PASS.
- Migration local-ready:
  `20260806100000_g5_phase11_supplier_invoice_matching_foundation.sql`.
- Contract: Draft/HOLD/VALIDATED/CANCELED, exact Receipt/AP allocation
  many-to-many, row lock, optimistic version, idempotent validation, tolerance
  dan Purchase Tax snapshot, residual AP reconciliation, last purchase price,
  immutable audit, serta Financial Event `HOLD_UNTIL_G6`.
- Supplier Invoice tetap zero-effect terhadap Stock/FIFO/Movement. Supplier
  Payment, final valuation adjustment, Debit/Credit Note resolution, dan jurnal
  G6 belum dibuka.
- Integrasi penting: trigger AP provisional sekarang menjaga identity/nilai
  Receipt immutable tetapi mengizinkan status `OPEN -> MATCHED/REVERSED`.
  Purchase Return terhadap provisional yang baru terinvoice sebagian diblokir
  fail-closed sampai split AP Provisional/Supplier Credit tersedia.
- Local evidence: 10 PL/pgSQL routine dollar-tag seimbang, satu transaction,
  parenthesis migration/postflight/test seimbang, `git diff --check` scoped
  PASS, checksum migration
  `1d4703ff836d5ea55de9a203211a77d7fa05ece825d4d45a8768aadf6e357162`.
- Manual gate dan regression wajib mengikuti
  `docs/runbooks/G5_PHASE11_SUPPLIER_INVOICE_MATCHING_FOUNDATION_ROLLOUT.md`.
- Next safe step setelah seluruh database gate PASS: Backoffice Finance
  Supplier Invoice matching UI. Jangan membuka Supplier Payment/G6 lebih awal.

## Update Sebelumnya — G5 Phase 9 Purchase Return UI

`READY FOR AUTHENTICATED SMOKE TEST` (2026-08-06).

- User mengonfirmasi migration/postflight/behavior Phase 8 seluruhnya PASS.
- POS sekarang mempunyai `Retur Supplier`: hanya Session OPEN, memilih Goods
  Receipt POSTED + Gudang/FIFO asal, lalu menyimpan Draft approval.
- Backoffice mempunyai `Purchase > Retur Pembelian`: detail user-facing,
  approve tanpa alasan, reject/cancel dengan alasan, dan Post terpisah.
- Mutation tetap melalui empat RPC Phase 8; browser tidak mendapat direct write.
- Evidence lokal: PWA lint/build PASS; Backoffice lint/build PASS; Next build
  mendeteksi route list/review/post/cancel.
- Manual gate: jalankan smoke pada
  `docs/runbooks/G5_PHASE9_PURCHASE_RETURN_OPERATIONAL_UI.md`.
- Next Safe Step setelah smoke lulus: lanjutkan preflight Supplier Invoice/AP
  matching sesuai G5. Jangan membuka jurnal final G6 lebih awal.

### Penyesuaian UOM dan gate berikut (2026-08-06)

- Root cause: RPC Phase 8 dan loader PWA hanya menerima Product-UOM dengan
  `purchase_allowed=true`; ini salah untuk kasus Receipt 1 Dus, retur 3 Ketul.
- Forward-fix local-ready:
  `20260806080000_g5_phase9_purchase_return_uom_fix.sql` beserta postflight.
- Regression Phase 8 diperbarui agar Receipt memakai Box factor 10 dengan
  `purchase_allowed=true`, sedangkan Return memakai Piece factor 1 dengan
  `purchase_allowed=false`.
- PWA dropdown sekarang memuat semua Product-UOM aktif; backend tetap memeriksa
  Product yang sama, UOM aktif, precision, conversion ke base, dan FIFO source.
- Phase 10 Supplier Invoice preflight SELECT-only local-ready. The 2026-08-06
  correction removes the invalid legacy `purchases_headers.status` reference;
  financial backfill scope now uses only verified `grand_total`/`paid_amount`.
  Urutan manual
  wajib mengikuti `docs/runbooks/G5_PHASE10_SUPPLIER_INVOICE_PREFLIGHT.md`.
- Status: `READY FOR MANUAL DATABASE ROLLOUT`. Jangan menjalankan Phase 10
  preflight sebelum ledger `20260806080000` PASS.

## 1. Protokol Wajib Agent

Sebelum bekerja:

1. baca root `AGENTS.md` dan `backoffice/AGENTS.md` bila menyentuh Next.js;
2. baca dokumen ini sampai selesai;
3. baca source of truth yang dirujuk pada bagian fase aktif;
4. periksa dirty worktree dan jangan menimpa perubahan user/agent lain;
5. lanjutkan dari manual gate terakhir—jangan menjalankan ulang migration yang
   sudah dikonfirmasi applied.

Sebelum handoff/final response, agent wajib memperbarui:

- tanggal dan fase aktif;
- outcome yang benar-benar selesai;
- file yang dibuat/diubah dalam turn tersebut;
- evidence lint/build/postflight/test/smoke;
- manual action yang masih harus dilakukan user;
- blocker/error persis bila ada;
- satu `Next Safe Step` yang tidak memperluas scope diam-diam.

Status yang digunakan:

- `PLANNED`: belum ada implementasi;
- `LOCAL READY`: file selesai dan pemeriksaan lokal lulus;
- `READY FOR MANUAL PREFLIGHT`: menunggu hasil SELECT-only dari user;
- `READY FOR MANUAL DATABASE ROLLOUT`: menunggu migration/postflight/test user;
- `READY FOR SMOKE TEST`: database selesai, menunggu verifikasi UI/runtime;
- `COMPLETE`: seluruh gate yang disyaratkan fase tersebut dikonfirmasi.

## 2. Posisi Implementasi Saat Ini

### G1 — Tenant/Security Closure

`COMPLETE`

- migration canonical G1 sampai `20260721150000` applied;
- security closure audit dan behavioral test lulus;
- active Company, tenant FK, RLS, role, Finance, transaction, dan inventory
  browser boundary sudah ditutup.

### G2 — Canonical Master Data

| Fase | Status | Evidence utama |
|---|---|---|
| Product Category/UOM/Warehouse foundation | COMPLETE | `20260721180000`, postflight/test dan smoke user |
| Atomic Product + Product-UOM | COMPLETE | `20260721210000`, postflight/test dan Product UI smoke |
| Supplier + Product-Supplier foundation | COMPLETE | `20260721230000`, postflight/test dan Supplier UI smoke |
| Supplier API/UI | COMPLETE | lint/build dan user menyatakan urusan Supplier aman |
| Customer preflight | COMPLETE | zero Customer/balance/duplicate; satu Walk-In backfill diperlukan |
| Customer foundation | COMPLETE | `20260722010000`; migration sukses, 13/13 postflight PASS, behavioral test PASS |
| Customer API/UI | COMPLETE | API guarded, dua tab, lint/build PASS, dan menu Customer sudah dibuka user tanpa schema-cache error |
| Customer grouping + UX consistency | DATABASE COMPLETE; UX FOLLOW-UP | DB preflight/migration/postflight/test PASS; grouping panel bekerja, dropdown induk langsung di modal Edit masih wajib dibuat |
| Pricelist preflight | COMPLETE | Dependency, Sales/Product-UOM/Customer invariant PASS; satu expected Global default backfill |
| Pricelist foundation | COMPLETE | user mengonfirmasi migration, 12 postflight, dan behavioral test seluruhnya PASS |
| Pricelist default guard | COMPLETE | user mengonfirmasi migration, 6 postflight, dan behavioral test seluruhnya PASS |
| Pricelist API/UI | COMPLETE | guarded API + Backoffice UI; harga akhir direct-entry, tier discount per UOM; lint/build dan user smoke PASS |
| Reusable Customer Pricelist correction | COMPLETE | user mengonfirmasi migration, 12/12 postflight, behavioral test, dan Customer assignment smoke aman |
| Payment Method foundation | COMPLETE | user mengonfirmasi fixed migration, 13/13 postflight, dan behavioral test PASS |
| Payment Method API/UI | COMPLETE | guarded route, validation, list/form, role-aware navigation, Escape modal, lint/build PASS, dan user smoke aman |
| Transaction Category + minimum COA preflight | COMPLETE | live result: dependency/invariant PASS, zero Expense/Event/Journal history, satu expected Company COA backfill |
| Transaction Category + minimum COA foundation | APPLIED; RUNTIME SAFE | missing-table state diselesaikan user; menu dapat dimuat, exact 14-row/test output tidak ditranskrip ulang |
| Finance Master API/UI | COMPLETE AT CURRENT BOUNDARY | guarded Category/rule API, versioned mapping UI, COA read-only, Escape modal; lint/build dan user smoke PASS |
| Required default Transaction Categories | COMPLETE | corrected 11-row postflight dan phase-18 behavioral test PASS |
| Finance history trigger branch fix | COMPLETE | migration `20260722210000`, 5-row postflight, regression test, dan phase-18 rerun seluruhnya PASS |
| Guarded COA + Company fallback | COMPLETE | User mengonfirmasi migration, 8 postflight, behavioral test, dan UI smoke all good |
| Tax Sales/Purchase preflight | COMPLETE | User mengonfirmasi seluruh hasil hanya PASS/INFO; tidak ada blocker/review |
| Tax Sales/Purchase foundation | COMPLETE | User mengonfirmasi migration, 14-check postflight, behavioral test, dan compatibility smoke all pass |
| Tax Master API/UI | COMPLETE AT MASTER BOUNDARY | User menyatakan aman; guarded versioning dan entitlement-aware UI tersedia; resolver disabled |
| Module Settings API/UI | COMPLETE AT ENTITLEMENT BOUNDARY | User menyatakan good; Super Admin Company toggle tersedia melalui audited RPC |
| Role-aware App Launcher + fast-link sidebar | COMPLETE AT CURRENT ROLE BOUNDARY | User menyatakan layout/sidebar/grouping sudah oke; granular permission tetap deferred |
| Product/Category Tax assignment preflight | COMPLETE | User result: seluruh invariant PASS; no Rule/assignment, entitlement disabled, one Product/Category |
| Guarded Product/Category Tax assignment | COMPLETE | User confirmed migration, postflight, dan behavioral test all pass |
| Tax assignment API/UI | COMPLETE | User menyatakan seluruh UI aman; Category default dan Product inheritance/override memakai nama Tax Rule |
| App shell Home/Back/breadcrumb navigation | READY FOR SMOKE TEST | Brand kembali ke launcher; seluruh view non-dashboard mendapat Back berbasis history aplikasi dan breadcrumb Beranda/Modul/Halaman; lint/build PASS, authenticated click smoke menunggu user |
| Tax resolver/snapshot preflight | COMPLETE | User result: seluruh invariant PASS; no Rule/history; two enabled scopes resolve no tax; checkout untouched |
| Private Tax resolver/calculator | COMPLETE | User confirmed migration, postflight, dan behavioral test all pass; transaction cutover tetap disabled |
| Master Import/Export preflight | COMPLETE | Live result clean; expected legacy REVIEW only; identities/canonical Product-UOM/history safe |
| Master Import staging foundation | COMPLETE | User mengonfirmasi migration, 11-check postflight, dan behavioral test seluruhnya PASS; commit/stock disabled |
| Master Import identity validator | COMPLETE | User mengonfirmasi migration, 8-check postflight, dan behavioral test seluruhnya PASS; commit disabled |
| Master Import business validator | COMPLETE | User mengonfirmasi migration, 7-check postflight, dan behavioral test seluruhnya PASS |
| Master Import partial commit | COMPLETE | User mengonfirmasi migration `20260723190000`, 9-check postflight, dan behavioral test seluruhnya PASS |
| Master Import API/UI | READY FOR SMOKE TEST | Guarded API, CSV mapping, preview, exact UPDATE confirmation, partial result, history, error download, template/export; lint/build PASS |
| Full Master Import/Export expansion | PREFLIGHT COMPLETE; DESIGN FOLLOW-UP | User mengirim 15 hasil: seluruh invariant PASS/INFO, zero missing table/RPC, zero ambiguity/invalid reference, zero nonterminal job |
| Automatic hidden master code | COMPLETE | User mengonfirmasi DB all PASS dan melanjutkan setelah Phase-37 Backoffice name-only smoke; form/list/API tidak meminta kode teknis |
| Code-less simple master import | COMPLETE | User mengonfirmasi Phase-38 migration, 7-check postflight, dan behavioral test all good |
| Code-less Import UI cutover | COMPLETE | Template create/export/preview empat master tanpa kode teknis; Gudang memakai referensi Toko user-facing; user mengonfirmasi smoke aman |
| Remaining simple master import DB | COMPLETE | Main migration, UUID forward fix, 4-check postflight, Phase-40 behavior, dan Phase-38 regression dikonfirmasi PASS |
| Remaining simple master import UI | COMPLETE | Template/export/mapping/preview tiga tipe baru; lint/build dan authenticated smoke user PASS |
| Grouped Product Import preflight | COMPLETE | User mengonfirmasi seluruh live preflight PASS |
| Grouped Product Import database | COMPLETE | `20260727130000` + forward fix `20260727140000`; postflight, behavior, dan Phase-40/38 regression seluruhnya PASS |
| Grouped Product Import UI | READY FOR SMOKE TEST | Template/export `product_v1`, grouped preview per Product, nama UOM user-facing; lint/build PASS |
| Product-Supplier Import preflight | COMPLETE | User mengonfirmasi seluruh blocker live PASS; satu relation existing valid dan tidak ada job nonterminal |
| Product-Supplier Import database | COMPLETE | User mengonfirmasi migration `20260727160000`, 11-check postflight, behavioral test, dan regression seluruhnya PASS |
| Product-Supplier Import UI | COMPLETE | Fixed template/export, preview nama tanpa UUID, preferred-switch guidance; lint/build dan user smoke PASS |
| Minimum Stock Produk–Gudang preflight | COMPLETE | Live output seluruhnya PASS/INFO; 1 Product, 3 Gudang, 3 eligible pair, zero balance/movement/ambiguity/orphan/job aktif |
| Minimum Stock Produk–Gudang database | COMPLETE | User mengonfirmasi rollout aman dan melanjutkan; `20260728090000`, 12-check postflight, behavior + Phase-44/42/40/38 regression ditutup |
| Minimum Stock API/UI + fixed Import/Export | READY FOR SMOKE TEST | Guarded list/create/update route, Inventory page, Base-UOM label/precision UX, fixed template/export/preview; lint/build PASS |
| G3 Opening Stock preflight | COMPLETE | User mengirim seluruh hasil: 13 invariant PASS; 3 eligible pair; zero balance/movement/batch; expected enum/schema absent |
| G3 Opening Stock database | COMPLETE | User mengonfirmasi migration `20260728120000`, postflight, behavioral test, dan regression seluruhnya sukses |
| G3 Opening Stock API/UI | READY FOR SMOKE TEST | Guarded Draft/Posting, stok aktual total/per Gudang, serta indikator Minimum Stock local-ready; Backoffice lint/build PASS |
| G3 Stock Real API/UI | READY FOR SMOKE TEST | Halaman read-only sesuai spec: On Hand/Available per Product–Gudang, Reserved explicit deferred, FIFO valuation, last movement, serta minimum filter; lint/build PASS |
| G3 Stock Movement preflight | COMPLETE | User mengirim seluruh invariant PASS; satu Opening movement/pair/source, saldo cocok, browser direct write false; expected 8 column dan 5 enum gap |
| G3 canonical Stock Movement database | COMPLETE | User mengonfirmasi migration `20260728150000`, postflight, behavior, dan regression seluruhnya all good |
| G3 Stock Movement / Kartu Stok API/UI | COMPLETE | Read-only tenant-scoped ledger, nama bisnis tanpa UUID, Base-UOM/balance snapshot, source/actor aman, filter; lint/build dan user smoke PASS |
| G3 Stock Transfer preflight | COMPLETE | Live result seluruh blocker PASS; expected legacy RPC REVIEW; zero Transfer history; satu saldo sumber positif dan tiga Gudang aktif |
| G3 canonical Stock Transfer database | COMPLETE | User mengonfirmasi `20260728180000`, seluruh 15 postflight, behavior, dan Phase-4/1/46/G1 regression sukses |
| G3 Stock Transfer API/UI | COMPLETE | Guarded create/edit/post/cancel, saldo/FIFO proof, role-aware menu, nomor Transfer di Kartu Stok, dan authenticated user smoke PASS |
| G3 Stock Adjustment preflight | COMPLETE | User mengirim seluruh blocker PASS; zero legacy Adjustment/backfill, 2 positive FIFO layers/pairs, Finance dan Base UOM siap |
| G3 canonical Stock Adjustment database | COMPLETE | User mengonfirmasi migration `20260728210000`, 16-check postflight, rollback-safe behavior, dan regression seluruhnya sukses |
| G3 Stock Adjustment API/UI | COMPLETE | Guarded Draft/Edit/Post/Cancel, final physical quantity UX, reason arah selisih, gain cost override, FIFO/value proof, Kartu Stok source; lint/build dan user smoke PASS |
| G3 Stock Opname preflight | COMPLETE | User mengirim seluruh invariant PASS; legacy session/detail kosong, zero overlap/backfill/link error, balance/FIFO dan canonical Adjustment siap |
| G3 canonical Stock Opname database | COMPLETE | User mengonfirmasi migration `20260728230000`, 14-check postflight, rollback-safe behavior, serta regression seluruhnya sukses |
| G3 Stock Opname Backoffice API/UI | COMPLETE | Tenant-scoped report/review, attempt timeline, Adjustment proof, guarded recount/post/cancel, role-aware menu, Escape modal, dan user continuation smoke accepted |
| G3 Bundle foundation preflight | COMPLETE | User mengirim seluruh invariant PASS; zero Bundle/component/backfill/physical stock dan schema/RPC gap sesuai expected |
| G3 canonical Bundle foundation database | COMPLETE | User mengonfirmasi migration `20260729010000`, postflight, behavior, dan regression seluruhnya all good |
| G3 Bundle master API/UI | COMPLETE | Guarded create/edit dan availability, Sales UI dengan nama Product/UOM, harga final, derived weight, pemisahan Product stok; lint/build dan continuation smoke accepted |
| G3 inventory-core exit/stress preflight | COMPLETE | User mengirim seluruh core invariant PASS; `SETUP` hanya fixture stress, `DEFERRED` G4/G5 expected, dan live inventory tetap konsisten |
| G3 integrated inventory-core stress behavior | COMPLETE AT CORE BOUNDARY | User melanjutkan tanpa error dan Phase-14 rerun tetap seluruh core PASS; rollback menjelaskan fixture live tetap `SETUP` |
| G4 POS checkout readiness preflight | COMPLETE | User output: seluruh dependency/config/data PASS; blocker tepat pada legacy client-authoritative checkout, missing price resolver, dan missing canonical runtime |
| G4 canonical Cashier Session database | COMPLETE | User mengonfirmasi migration, 13-check postflight, behavioral test, dan regression seluruhnya sukses; checkout tetap tertutup |
| G4 Atomic Sale runtime preflight | COMPLETE | User output sesuai baseline: seluruh data/invariant PASS, dua blocker hanya checkout legacy, empat setup tepat pada runtime canonical |
| G4 Atomic Sale runtime database | COMPLETE | User mengonfirmasi migration, 17-check postflight, behavioral test, dan regression clear |
| G4 POS online integration | COMPLETE AT ONLINE SINGLE-PAYMENT BOUNDARY | User mengonfirmasi rollout dan PWA smoke clear; POS dua panel, reset POSTED, receipt print-tab, serta guarded Customer Pricelist AUTO/override aktif |
| G4 Sale Draft list/edit-lock | DATABASE FOUNDATION READY; MANUAL DB GATE PENDING | Live preflight bersih; nomor/metadata Draft, same-Store list, five-minute heartbeat lock, confirmed takeover, force release, cancel, audit, dan guarded Save/Post local-ready |
| G4 Payment-Leg identity | COMPLETE | User mengonfirmasi migration `20260729150000`, postflight, corrected behavior, dan regression sukses |
| G4 Split Payment PWA UI | READY FOR AUTHENTICATED TABLET SMOKE | Multi-leg exact-total UI, stable retry key, per-leg Cash/proof, server fee estimate, duplicate-method prevention; PWA lint/build PASS |
| G4 Online Checkout stress preflight | COMPLETE | User mengirim seluruh check PASS/INFO; fixture dua-user siap, lock/FIFO/idempotency core PASS, dan seluruh final-effect reconciliation bersih |
| G4 true-concurrent Post stress | COMPLETE | Setelah stok ditambah, 20-response concurrency assertions, POSTED state, posting key, Movement, Payment, audit, dan identity lolos; service read-only membuktikan tepat satu `SALE_POSTED` Event HOLD |
| G4 Offline Stock Allowance preflight | COMPLETE | User mengirim seluruh dependency/invariant PASS, expected lima-table SETUP, entitlement disabled, satu Terminal/operator/Gudang dan Cash/elektronik siap, dua positive stock/FIFO pair konsisten |
| G4 Offline Stock Allowance foundation | COMPLETE | User mengonfirmasi migration, seluruh postflight, corrected behavior, dan regression sukses; policy/reservation/stock/session/history guard aktif, ingest/sync/PWA offline tetap tertutup |
| G4 Offline submission/sync preflight | COMPLETE | User mengirim seluruh dependency/invariant PASS; tiga table, sembilan snapshot column, tiga RPC, dan Payment exception event tepat berstatus expected SETUP |
| G4 canonical Offline Sale Sync database | COMPLETE | Migration `20260729210000`, corrected postflight, behavioral, lima regression, dan reconciliation penutup dikonfirmasi seluruhnya PASS oleh user |
| G4 retained Offline PWA queue foundation | LOCAL-READY | Dexie v3 retained queue, canonical JSONB hash, stable submit/process/status retry, acknowledgement retention, dan Phase-22 Cart integration selesai; entitlement tetap disabled sampai UAT |
| G4 authoritative Offline catalog cache preflight | COMPLETE | User output: dependency dan seluruh invariant PASS; RPC serta Terminal policy tepat `SETUP`; entitlement disabled; Pricelist/Tax/Payment/Product-UOM inventory siap |
| G4 authoritative Offline catalog snapshot database | COMPLETE | Migration, postflight, corrected behavior, Phase-12/11/4/G1 regression, dan closing postflight dikonfirmasi seluruhnya PASS; zero Terminal policy tetap expected `SETUP` |
| G4 retained Offline PWA catalog cache | LOCAL-READY | Dexie v4 snapshot, exact scope/hash/freshness/invalidation, queue-aware allowance reconciliation, dan Phase-22 Cart pricing/validation selesai; lint/build PASS |
| G4 read-only Offline status/cache PWA UI | READY FOR AUTHENTICATED CLOSED-ENTITLEMENT SMOKE | Tombol header membuka drawer koneksi/scope/snapshot age/allowance; workspace tetap lega, lazy cache chunk selesai, checkout tetap diblokir; browser smoke agent tidak tersedia |
| G4 guarded Offline policy Backoffice UI | READY FOR AUTHENTICATED ROLE SMOKE | Default Company, override Toko, eligibility Terminal, audited RPC, custom confirmation/Escape, dan role-aware menu selesai; entitlement tetap Super Admin-only dan checkout tertutup |
| G4 Offline Allowance operations Backoffice UI | READY FOR AUTHENTICATED ROLE UAT | Session–Product list dan guarded issue/release/force-revoke tersedia tanpa direct write; lint/build PASS |
| G4 Cashier Offline Allowance PWA UI | READY FOR AUTHENTICATED TABLET UAT | Cashier issue/release sesi sendiri, server/local/queued quantity, authoritative refresh, serta fail-closed cache invalidation; lint/build PASS |
| G4 Offline checkout queue readiness preflight | COMPLETE | User output seluruh invariant PASS; expected UAT scope SETUP karena entitlement/Terminal/allowance/open Session belum diaktifkan |
| G4 Offline checkout retained queue PWA UI | READY FOR AUTHENTICATED TABLET UAT | Snapshot Pricelist pricing, Base-UOM allowance, exact Payment, retained local commit, Slip Offline watermark, retry/status/final invoice; lint/build PASS |
| G4 Offline cold-start/conflict recovery preflight | COMPLETE | User output seluruh kontrak server, recovery, final-effect, scope UAT, dan Stock–Movement–FIFO PASS; client contract expected SETUP |
| G4 Offline cold-start/recovery PWA | READY FOR AUTHENTICATED TABLET UAT | Dexie v5 exact operational scope, cached-auth match, snapshot/catalog/queue restore, status-first reconnect, time-bounded submit/process/status, nonblocking post-success reconciliation, dan controlled manual retry; lint/build PASS |
| G4 Offline disconnect/reconnect stress | COMPLETE | User mengonfirmasi controlled disconnect, recovery/status-first, sync UI, serta seluruh Phase-24/23/12 closing diagnostics PASS; Offline core ditutup pada boundary ini |
| G4 Sales Return database foundation | COMPLETE | Phase-26 migration/fix/postflight/behavior serta G4 Phase-10, G3 Phase-14, dan G1 regression dikonfirmasi PASS; `SETUP` G3 hanya fixture stress rollback |
| G4 Sales Return PWA Draft UI | COMPLETE AT DRAFT BOUNDARY | Online invoice search, qty/kondisi, Gudang Rusak, refund Cash/Transfer otomatis; PWA lint/build PASS dan user berhasil membuat Draft Return |
| G4 Sales Return Backoffice approval UI | COMPLETE AT REQUIRED-APPROVAL BOUNDARY | Sales list/detail dan guarded post berhasil diuji user; cancel tersedia; optimistic version/idempotency, role/store guard, dan Finance HOLD tetap aktif |
| G4 Expense/Cash Flow preflight | COMPLETE | User output: dependency/value/tenant/payment/category/account/privilege PASS; zero legacy rows; one expected legacy trigger REVIEW; nine canonical tables SETUP |
| G4 Expense request/approval foundation | COMPLETE | User mengonfirmasi migration, postflight, rollback-safe behavior, dan regression seluruhnya PASS; feature default off dan request/approval cash-neutral |
| G4 Expense request PWA UI | COMPLETE AT REQUEST BOUNDARY | User berhasil membuat dan mengajukan Expense; online-only, guarded/idempotent, dan tetap cash-neutral |
| G4 Expense approval Backoffice UI | COMPLETE AT CASH-NEUTRAL APPROVAL BOUNDARY | User mengonfirmasi approval berhasil setelah approve-reason bugfix; guarded review/cancel, optimistic version, role/store boundary, dan zero cash-effect tetap berlaku |
| G4 Expense disbursement preflight | COMPLETE | Live output: expected four runtime SETUP; dependency, two approved Expense, payment/Store/Session, category/account, privilege, dan seluruh reconciliation PASS |
| G4 Expense disbursement foundation | COMPLETE | User mengonfirmasi migration, postflight, behavioral test, regression, dan closing check seluruhnya aman |
| G4 Expense disbursement operational UI | COMPLETE | User mengonfirmasi jalur Cash PWA dan non-Cash Backoffice aman; RPC guarded, expected-cash, drawer isolation, role/channel boundary, dan idempotency tetap berlaku |
| G4 Expense settlement preflight | COMPLETE | User output: lima expected runtime SETUP; dependency, totals, lifecycle, account/session, Finance/drawer coverage, dan privilege seluruhnya PASS; zero settlement/return history |
| G4 Expense settlement foundation | COMPLETE | User mengonfirmasi migration, postflight, behavioral test, dan seluruh regression aman |
| G4 Expense settlement operational UI | COMPLETE | User melanjutkan tanpa error; POS actual/return Cash/request tambahan dan Backoffice review actual/return non-Cash diterima |
| G4 Additional Expense disbursement preflight | COMPLETE | User output: seluruh dependency, request-only zero-effect, tenant/reference, payment/document/Session, duplicate-open, dan direct-write invariant PASS; enam column, dua RPC, dan event tepat SETUP |
| G4 Additional Expense disbursement foundation | COMPLETE | User mengonfirmasi migration, postflight, corrected behavioral test, seluruh regression, dan closing postflight sukses; guarded approve/reject, Cash/non-Cash execution, exact idempotency, single linked disbursement, drawer isolation, audit, dan Finance HOLD aktif |
| G4 Additional Expense operational UI | ACCEPTED AT CURRENT BOUNDARY | User melanjutkan setelah local delivery tanpa blocker; Backoffice review/non-Cash payment dan POS approved-Cash execution tersedia melalui RPC guarded; lint/build kedua aplikasi PASS |
| G4 Cash Deposit multi-Session foundation | COMPLETE | User mengonfirmasi migration, postflight, behavior, regression, dan closing verification Phase-43 seluruhnya PASS |
| G4 Cash Deposit operational UI | COMPLETE AT APPROVAL BOUNDARY | User mengonfirmasi approval berhasil setelah approve-reason bugfix; create/submit/review server-authoritative dan bank matching/resolution/offline/G6 tetap tertutup |
| G4 Deposit variance resolution preflight | COMPLETE | User mengirim seluruh dependency/data/account/privilege invariant PASS; expected schema/RPC/event gap hanya SETUP; exception/allocation live nol |
| G4 Deposit variance resolution foundation | COMPLETE | User mengonfirmasi seluruh migration/postflight/behavior/regression aman; partial allocation, maker-checker, audit, exact retry, dan Financial Event HOLD aktif |
| G4 Deposit variance operational UI | COMPLETE | Finance list/detail/assign/partial resolution, Owner/Admin maker-checker, Accounting read-only, Escape, lint/build, dan authenticated user smoke aman |
| G4 Customer Balance readiness preflight | COMPLETE | User melaporkan tidak ada blocker/error; hanya provisioning metode internal per Company berstatus BACKFILL; legacy balance/payment tetap bersih |
| G4 Customer Balance ledger/correction foundation | COMPLETE | User mengonfirmasi base, digest forward fix, postflight, corrected behavior, regression, dan closing checks seluruhnya sukses |
| G4 Customer Balance operational UI | LOCAL-READY | Backoffice liability, request/review maker-checker, dan statement melalui guarded RPC; lint/build PASS dan menunggu authenticated smoke |
| G4 Customer Balance Sale credit preflight | COMPLETE | User mengirim seluruh dependency/data/account/tenant/privilege invariant PASS; tiga gap schema/runtime tepat berstatus SETUP; histori non-Cash overpayment nol dan Cash change lama tetap returned |
| G4 Customer Balance Sale credit foundation | COMPLETE | User mengonfirmasi migration, postflight, behavior, regression, dan closing checks seluruhnya PASS; atomic ONLINE credit serta compatibility returned aktif |
| G4 POS overpayment disposition UI | ACCEPTED | User menyatakan aman untuk lanjut; Cash/Transfer online menerima nominal aktual dan pilihan kembalian atau saldo; Walk-In/feature/offline fail-closed; receipt/print menampilkan saldo |
| G4 Customer Balance tender preflight | COMPLETE | User output: tiga expected SETUP, seluruh dependency/data/lifecycle/account/category/history invariant PASS, direct browser writes false, dan live positive balance nol |
| G4 POS negative-stock permission preflight | COMPLETE | User mengonfirmasi seluruh Phase-55 preflight PASS; runtime tetap OFF dan foundation menunggu setelah Customer Balance tender |
| G4 Customer Balance tender foundation | COMPLETE | User mengonfirmasi corrected postflight seluruhnya PASS dan behavioral test Phase-56 PASS |
| G4 Customer Balance tender POS UI | ACCEPTED AT CURRENT BOUNDARY | User meminta lanjut sesuai rundown setelah database Phase-56 serta PWA lint/build PASS; authenticated tender smoke dapat digabung pada E2E berikutnya |
| G4 POS Negative Stock policy foundation | COMPLETE | User mengonfirmasi migration, postflight, behavior, regression, dan closing checks Phase-58 seluruhnya PASS; default OFF dan canonical Sale tetap `STOCK_SHORTAGE` |
| G4 POS Negative Stock runtime preflight | COMPLETE | User output: tiga expected `SETUP`, satu G5/G6 `DEFERRED`, seluruh dependency/config/data/reconciliation/boundary PASS, zero history/config aktif |
| G4 POS Negative Stock online runtime | PHASE 60 COMPLETE; PHASE 61 UI LOCAL-READY | User mengonfirmasi responsibility fix/postflight/behavior/regression PASS; Backoffice guarded config dan PWA reason/retry siap authenticated smoke |
| G5 Purchasing foundation preflight | COMPLETE | User mengonfirmasi seluruh Phase-1 preflight PASS |
| G5 Stock Request + Supplier Order foundation | COMPLETE | User mengonfirmasi migration, postflight, dan behavioral test Phase 2 seluruhnya sukses; Stock/FIFO/AP/Finance tetap zero-effect |
| G5 Stock Request + Supplier Order operational UI | ACCEPTED; REMAINING-LINE UX LOCAL-VERIFIED | User menerima flow; baris penuh yang sudah dialokasikan order aktif hilang dan partial hanya menampilkan sisa; lint/TypeScript PASS |
| G5 Goods Receipt readiness preflight | COMPLETE | User mengonfirmasi seluruh hasil Phase 4 PASS |
| G5 Goods Receipt foundation | COMPLETE | User mengonfirmasi forward-fix, postflight, behavioral test, dan seluruh hasil sukses |
| G5 Goods Receipt PWA | ACCEPTED | Online order list, Draft/resume/cancel, partial/over warning, kondisi baik/rusak/ditolak, dan guarded Post tersedia; lint/build PASS dan user mengonfirmasi proses receive aman |
| G5 Purchase Return readiness preflight | COMPLETE | User mengonfirmasi seluruh output Phase 7 PASS |
| G5 Purchase Return foundation | LOCAL-READY; LIVE ROLLOUT PENDING | Cashier Draft, manager review/Post, exact Goods Receipt FIFO consumption, Stock/Movement, append-only AP adjustment, Event HOLD, idempotency, audit, dan direct-write closure |
| G5 Supplier Invoice + Payment | USER-REPORTED LIVE PASS; CORRECTIVE TOLERANCE FORWARD FIX PENDING | Exact Receipt/AP allocation, optional value tolerance with visible variance, Payment settlement, immutable audit/idempotency, dan Finance HOLD tanpa G6 journal posting |

Catatan UX aktif:

- label UOM operasional memakai `name` (`Ketul`, `Dus`), bukan kode internal
  (`UOM-02`, `UOM-03`);
- kode tetap disimpan sebagai identifier master;
- Product menyimpan stok pada Base UOM; kemasan memakai faktor langsung ke base;
- kemasan terbesar otomatis menjadi acuan berat/rekomendasi UOM pembelian.

## 3. Fase Aktif

**G5 Phase 8 — Purchase Return database rollout**

User mengonfirmasi migration `20260806010000`, postflight, dan behavioral test
seluruhnya sukses. Kasir dengan sesi OPEN dapat
membuat/submit Stock Request, sedangkan Supplier Order hanya dapat dibuat dan
dikonfirmasi Store Manager/Company Admin/Super Admin. Order menyimpan snapshot
Product/UOM/harga estimasi serta allocation ke Request; confirm/cancel memakai
row lock, optimistic version, idempotency key, immutable final history, dan
audit tenant-scoped.

Boundary fase sengaja ketat: Request/Order tidak menulis `product_stocks`,
`product_batches`, `stock_movements`, AP, `financial_events`, atau Journal.
Warehouse Admin/Cashier tidak dapat memilih Supplier atau confirm Order. Legacy
`confirm_purchase_order(UUID,UUID)` dicabut dari browser bila masih ada.

File aktif:

- `supabase/migrations/20260806010000_g5_phase2_stock_request_supplier_order_foundation.sql`;
- `supabase/diagnostics/g5_phase2_stock_request_supplier_order_postflight.sql`;
- `supabase/tests/g5_phase2_stock_request_supplier_order_tests.sql`;
- `docs/runbooks/G5_PHASE2_STOCK_REQUEST_SUPPLIER_ORDER_ROLLOUT.md`.

Local evidence: struktur transaction/dollar-tag seimbang, targeted final-effect
scan bersih, scoped `git diff --check` PASS, dan checksum migration
`a33117dcd91edd2535068548b3f0699ab8883a8d821421586ff4ca3303ad15f5`.
Supabase CLI lint tidak dapat dijalankan lokal karena CLI mencoba menulis
telemetry di luar workspace; live syntax/behavior tetap manual gate.

Phase 3 menambahkan tombol `Minta Stok` pada PWA, pilihan Product dan nama UOM
pembelian, tanggal kebutuhan, submit atomic, serta riwayat Request. Backoffice
mendapat launcher/menu `Purchase > Supplier Order`, daftar Request aktif,
Supplier/Gudang tujuan, suggested price dari Product-Supplier lalu Product-UOM,
Draft dan Confirm. ID/kode teknis tidak ditampilkan. Supplier yang belum
terhubung tetap boleh dipilih dengan warning; relasi tidak dibuat diam-diam.

Local evidence: PWA oxlint dan production build PASS; Backoffice ESLint dan
Next production build PASS (route Purchase terdeteksi). Authenticated smoke
belum dilakukan user. Goods Receipt/Stock/FIFO/AP tetap belum boleh dibuka
sebelum smoke Request → Order ini lolos.

Penyesuaian terakhir: allocation dari order berstatus `CONFIRMED`,
`PARTIALLY_RECEIVED`, atau `RECEIVED` dikurangi dari setiap Request line.
Baris dengan sisa nol tidak lagi ditawarkan; partial allocation hanya menawarkan
quantity sisa. Order `DRAFT/CANCELED` tidak mengurangi sisa. Backoffice ESLint
dan TypeScript `--noEmit` PASS.

User mengonfirmasi seluruh Phase-4 preflight PASS. Phase 5 sekarang local-ready:
`20260806040000_g5_phase5_goods_receipt_foundation.sql` menambah Draft/Post/Cancel
Goods Receipt dari Supplier Order, receipt parsial dan over, alokasi kondisi
GOOD/DAMAGED/REJECTED, FIFO intake dan Purchase Movement atomic, AP provisional,
Financial Event `HOLD_UNTIL_G6`, optimistic version, exact idempotency, audit,
RLS, serta direct-browser-write closure. Barang rejected tidak menambah stok/AP;
barang damaged diarahkan ke Gudang tipe DAMAGED. UI Goods Receipt belum dibuka.

Manual gate berikutnya: migration → postflight → behavioral test → postflight.
Runbook: `docs/runbooks/G5_PHASE5_GOODS_RECEIPT_FOUNDATION_ROLLOUT.md`.

File Phase 5: migration `20260806040000`, postflight
`g5_phase5_goods_receipt_postflight.sql`, behavioral test
`g5_phase5_goods_receipt_foundation_tests.sql`, dan runbook di atas. Local
evidence: delimiter/parenthesis seimbang, migration checksum
`5cf3db710105eebf12a056831380fdb34b596ecb413f9886ff6bd8c6b5e223f6`,
serta scoped `git diff --check` PASS. Tidak tersedia database lokal untuk
mengeksekusi PL/pgSQL; rollout SQL Editor dan hasil user masih manual gate.
Next safe step setelah seluruh hasil PASS adalah UI PWA Goods Receipt, bukan
Supplier Invoice/Purchase Return/Finance G6.

Behavioral run pertama gagal saat insert receipt line karena trigger history
foundation memakai satu ekspresi `CASE` yang membuat PostgreSQL mencoba
meresolve `NEW.receipt_line_id` pada record `goods_receipt_lines`. Forward fix
`20260806050000_g5_phase5_goods_receipt_history_trigger_fix.sql` menggantinya
dengan cabang `IF/ELSIF` table-specific dan return NEW/OLD yang eksplisit.
Migration foundation yang sudah applied tidak diedit. User harus menjalankan
forward fix, postflight terkoreksi (ledger mengharuskan dua version), behavioral
test, lalu postflight ulang.

Postflight versi ringkas pertama kemudian menghasilkan PostgreSQL `42601
syntax error at end of input` pada SQL Editor. File
`g5_phase5_goods_receipt_postflight.sql` sudah ditulis ulang penuh menjadi satu
CTE `checks` yang eksplisit (267 baris), ditutup satu final SELECT; local check
menunjukkan 102/102 parenthesis, quote genap, dan `git diff --check` PASS.
Gunakan isi file terbaru secara utuh, bukan query lama yang masih terbuka di tab
SQL Editor.

User kemudian mengonfirmasi forward-fix, postflight yang ditulis ulang, serta
behavioral test seluruhnya sukses. Phase 5 database dinyatakan COMPLETE.
Phase 6 menghubungkan PWA online ke tiga RPC canonical: tombol `Terima Barang`
memuat order `CONFIRMED/PARTIALLY_RECEIVED` pada Store sesi, hanya memakai nama
bisnis, menyimpan/resume/cancel Draft, mencatat partial/over, serta membuka field
baik/rusak/ditolak secara opsional. Post menutup modal dan refresh katalog stok.
PWA oxlint dan production build PASS; chunk modal terpisah sekitar 14.44 kB.
Browser in-app tidak berhasil tersambung sebelum membuka localhost, jadi tidak
ada authenticated UI effect yang dijalankan agent. Manual smoke mengikuti
`docs/runbooks/G5_PHASE6_GOODS_RECEIPT_PWA_SMOKE.md`. User kemudian
mengonfirmasi proses receive aman sehingga Phase 6 dinyatakan ACCEPTED. Phase 7
menyiapkan preflight SELECT-only Purchase Return; Supplier Invoice/matching,
payment Supplier, dan jurnal final Finance tetap menunggu urutan roadmap G5/G6.

User mengonfirmasi seluruh output Phase 7 PASS. Phase 8 sekarang local-ready:
migration `20260806070000` menambah dokumen/line Return, exact source allocation
dan Goods Receipt FIFO batch, review wajib sebelum Post, optimistic version,
exact idempotency, immutable final history, Movement `PURCHASE_RETURN`, AP
adjustment append-only, Financial Event `HOLD_UNTIL_G6`, RLS, dan browser
direct-write closure. Approve tidak membutuhkan alasan; reject/cancel wajib
alasan. Source AP `OPEN` memakai route `AP_PROVISIONAL`, sedangkan source yang
sudah matched/reversed dicatat `SUPPLIER_CREDIT_PENDING` tanpa menulis ulang
invoice/history lama. Local evidence: migration 287/287 parenthesis, 14
dollar-tags, satu transaction COMMIT, checksum
`ee1f70903bf45a9d9dcfc4035675f07b9b6b45aa5315f314c9c2c1307e1b22ba`,
dan scoped `git diff --check` PASS. Live migration/postflight/behavior belum
dijalankan. Runbook:
`docs/runbooks/G5_PHASE8_PURCHASE_RETURN_FOUNDATION_ROLLOUT.md`.

Behavioral run pertama berhenti sebelum menguji Return karena fixture membuat
Supplier Order langsung `CONFIRMED` lalu memasukkan line; canonical history
guard benar menolak line pada Order final. Test dikoreksi mengikuti lifecycle
produksi `DRAFT → insert line → CONFIRMED`. Migration tidak berubah dan tidak
perlu diulang; rerun hanya behavioral test terbaru lalu closing postflight.

Migration sudah berhasil dijalankan user. Postflight awal gagal sebelum
menghasilkan row dengan PostgreSQL `42P01 relation "public" does not exist` pada
dynamic table-name privilege lookup. Diagnostic telah dikoreksi memakai
`pg_namespace` + `pg_class.oid` untuk existence, trigger, RLS, dan privilege;
tidak ada migration/data/business-flow yang diubah. Rerun hanya postflight
terkoreksi, lalu behavioral test bila seluruh hasilnya aman.

User melaporkan error yang sama setelah koreksi pertama. Postflight kemudian
ditulis ulang penuh: seluruh `to_regclass`, `to_regprocedure`, dynamic qualified
name, dan signature-text privilege lookup dibuang. Table/routine/trigger kini
di-resolve dari `pg_catalog` ke OID, dan privilege juga diperiksa langsung lewat
OID. File terkoreksi berjumlah 170 baris dan mempunyai marker komentar
`Catalog objects are resolved by OID`; pastikan SQL Editor memuat isi baru ini,
bukan query lama yang masih tersimpan di tab browser.

Rewrite OID tersebut ternyata masih menghasilkan `42P01` pada live SQL Editor.
Postflight kini disederhanakan lagi menjadi metadata-only murni: tidak ada
`FROM/JOIN public.*`, `to_reg*`, `has_*_privilege`, ataupun runtime table read.
Existence/RLS/function body dibaca dari `pg_catalog`; trigger dan grant dibaca
dari `information_schema`. Ini hanya mengubah diagnostic, bukan migration/data.

### Riwayat Phase 54

User menerima Phase 53 dan meminta lanjut sesuai rundown. Phase 54 tidak
membuka mutation: diagnostic SELECT-only mengaudit contract POS-006 bahwa
seluruh saldo lama wajib dipakai, lifecycle `ACTIVE/WIND_DOWN`, cache versus
append-only ledger, Customer/Company scope, internal Payment Method,
category/account, histori tender, runtime defer guard, snapshot gap, dan direct
browser write boundary.

Jalankan
`supabase/diagnostics/g4_phase54_customer_balance_tender_preflight.sql` penuh
dan kirim seluruh output. `SETUP` di ledger source, Payment snapshot, serta
runtime diharapkan; `BLOCKER` harus nol dan `REVIEW` harus dijelaskan sebelum
foundation. Balance tender, refund-to-balance, Offline Customer Balance, Ketul,
dan Finance posting tetap tertutup.

### Riwayat Phase 53

User mengonfirmasi seluruh rollout/regression Phase 52 PASS. Phase 53
menghubungkan kontrak itu ke checkout PWA: pilihan baru hanya muncul ketika
Cash/Transfer yang diterima melebihi bagian tagihan. Default tetap
`Kembalikan ke Customer`; `Simpan sebagai Saldo` hanya aktif untuk Customer
reguler, POS online, serta feature/policy Customer Balance aktif. Receipt modal
dan print tab menampilkan credit saldo secara terpisah.

Tidak ada migration Phase 53. Customer Balance sebagai tender,
refund-to-balance, Offline Customer Balance, exceptional settlement, dan jurnal
G6 tetap tertutup. Manual gate berikutnya adalah authenticated smoke sesuai
`docs/runbooks/G4_PHASE53_POS_OVERPAYMENT_DISPOSITION_UI.md`. Setelah smoke
lulus, next safe step adalah preflight khusus balance-as-tender—bukan langsung
membuka mutation baru.

Local evidence: `npm.cmd run lint` PASS; `npm.cmd run build` PASS termasuk
TypeScript/Vite/PWA service worker. Warning chunk utama di atas 500 kB tetap
warning existing dan tidak memblokir build.

### Riwayat Phase 52

User mengonfirmasi seluruh Phase-51 data invariant PASS; tiga status `SETUP`
tepat menunjukkan kolom Payment, ledger source, dan runtime credit yang belum
ada. Phase 52 sekarang menambahkan jalur atomic dari overpayment Payment/Sale
ONLINE ke append-only ledger, Customer cache, Payment/receipt snapshot, audit,
dan Financial Event HOLD. Sale row serta Customer row dikunci; retry memakai
source/idempotency unik dan tidak menggandakan stock atau saldo.

Compatibility sengaja ketat: histori Cash change tetap nullable/legacy dan
dianggap sudah dikembalikan; Cash payload baru tanpa pilihan Phase-53 otomatis
`RETURNED`; non-Cash overpayment tanpa disposition ditolak. Customer harus
regular aktif, feature serta policy harus `ACTIVE`, dan request credit Offline
ditolak. Payment Method `CUSTOMER_BALANCE` belum dibuka sebagai tender.

File Phase-52:

- `supabase/migrations/20260805130000_g4_phase52_customer_balance_sale_credit.sql`;
- `supabase/diagnostics/g4_phase52_customer_balance_sale_credit_postflight.sql`;
- `supabase/tests/g4_phase52_customer_balance_sale_credit_tests.sql`;
- `docs/runbooks/G4_PHASE52_CUSTOMER_BALANCE_SALE_CREDIT_ROLLOUT.md`.

Local evidence: migration/postflight/test parentheses seimbang, dollar tags
seimbang, postflight SELECT-only, checksum manifest `e44a9f66...` tercatat, dan scoped
`git diff --check` PASS. Live Supabase rollout/regression belum dijalankan.

### Riwayat Phase 50

Phase 49 sudah ditutup user seluruhnya sukses. Backoffice sekarang mempunyai
menu `Finance > Saldo Customer` dengan total liability, saldo per Customer,
statement append-only, pengajuan koreksi, dan approval/penolakan oleh reviewer
berbeda. UUID serta key akun disembunyikan; user memilih label bisnis. Semua
mutation memakai RPC Phase 49, optimistic version, dan idempotency key.

File Phase-50:

- `backoffice/src/lib/customer-balance.ts`;
- `backoffice/src/app/api/finance/customer-balances/**`;
- `backoffice/src/components/CustomerBalanceView.tsx`;
- integrasi menu pada `backoffice/src/app/page.tsx`;
- `docs/runbooks/G4_PHASE50_CUSTOMER_BALANCE_OPERATIONAL_UI.md`.

Local evidence: Backoffice lint PASS, production build PASS (empat route baru),
dan scoped diff check PASS. Manual gate aktif adalah authenticated role/
maker-checker smoke Phase 50. Entry koreksi Cashier pada PWA, export/aging,
checkout/refund/offline Customer Balance, exceptional settlement, dan jurnal G6
belum dibuka oleh UI ini.

### Riwayat Phase 49

User mengonfirmasi Phase-48 tanpa blocker/error; hanya satu provisioning
Company berstatus BACKFILL. Migration `20260805090000` sekarang local-ready dan
tetap berhenti bila saldo nonzero atau histori Customer Balance payment muncul
setelah preflight. Foundation memprovision satu policy serta metode internal
`Saldo Customer` per Company, menjaga lifecycle `ACTIVE -> WIND_DOWN ->
DISABLED`, dan menyimpan ledger append-only sebagai authority sementara
`customers.current_balance` menjadi cache yang direkonsiliasi.

Cashier/operasional hanya dapat membuat request koreksi melalui RPC guarded;
Finance/Owner/Admin/Super Admin mereview dengan maker-checker. Approval membuat
tepat satu ledger entry, update cache atomic, audit, dan Financial Event `HOLD`;
reject tidak mempunyai final effect. Statement tenant-scoped tersedia read-only.
Canonical Sale tetap fail-closed terhadap `CUSTOMER_BALANCE`; overpayment,
refund-to-balance, Ketul credit/offset, exceptional settlement, offline use, dan
jurnal G6 belum dibuka.

File Phase-49:

- `supabase/migrations/20260805090000_g4_phase49_customer_balance_foundation.sql`;
- `supabase/diagnostics/g4_phase49_customer_balance_postflight.sql`;
- `supabase/tests/g4_phase49_customer_balance_foundation_tests.sql`;
- `docs/runbooks/G4_PHASE49_CUSTOMER_BALANCE_FOUNDATION_ROLLOUT.md`;
- `supabase/MIGRATION_MANIFEST.md`, root `README.md`, router/gate/handoff docs.

Local evidence: SHA-256 migration
`63a4bdbc7d27983879d3f9d402b7ca84b5fa0f85aa3e2303b7717659a4ee9b82`;
scoped `git diff --check` PASS. Base migration sudah applied, sedangkan complete
behavior/regression masih menunggu forward fix berikut.

Base migration kemudian berhasil applied. Behavioral test pertama diperbaiki
karena synthetic Company belum mempunyai row entitlement. Rerun berikutnya
berhenti sebelum request insert pada `digest(text,unknown)`: Supabase memasang
pgcrypto pada schema `extensions` dan menyediakan `digest(bytea,text)`.
Forward migration `20260805100000` mengganti RPC dengan
`extensions.digest(convert_to(...,'UTF8'),'sha256')`; tidak mengubah data,
saldo, policy, atau business flow. SHA-256 forward fix
`f607b3a0162452a63fcc2da4d81332ec3e392e9583600c1c28a3510f8476d3a8`.
User kemudian mengonfirmasi seluruh rangkaian sukses.

User mengonfirmasi seluruh manual rollout Phase-46 aman. Jangan rerun migration
`20260804160000`. Phase-47 tidak menambah schema: halaman
`Finance > Selisih Setoran` membaca exception, Setoran, allocation, request,
Store, dan actor dengan query tenant-scoped terpisah, lalu memakai guarded RPC
Phase-46 untuk seluruh mutation. Finance/Owner/Admin dapat menangani selisih;
Owner/Admin lain mereview request maker-checker; Accounting hanya membaca.

UI menyembunyikan UUID, menggunakan custom modal dan Escape, mempertahankan
optimistic version serta exact idempotency, dan menunjukkan dengan eksplisit
bahwa Financial Event masih HOLD. Bank matching, reversal/replacement source
aktual, Offline Expense/Deposit, internal cash transfer, dan jurnal G6 tidak
dibuka oleh phase ini.

Phase-26 database behavior dan seluruh regression sudah ditutup user. User
berhasil membuat Draft melalui Phase-27 PWA dan mempostingnya melalui Phase-28
Backoffice. Sales Return selesai pada boundary approval REQUIRED. Posting Kasir,
approval OPTIONAL, dan Finance journal tetap tertutup.

Phase-29 diterima tanpa blocker dan Phase-30 database/postflight/behavior/
regression sudah dikonfirmasi user seluruhnya PASS. Phase-31 local-ready
membuka entry point Expense online hanya ketika `expense_enabled` aktif. PWA
mengirim idempotent Draft lalu guarded Submit dengan kategori, metode eligible,
nominal, responsible party, deskripsi, target settlement, dan external evidence
link. `SUBMITTED` menunggu approval; auto-`APPROVED` tetap belum mencairkan
uang. Retained offline catalog sengaja tidak memuat Expense.

Cash Advance tidak menjadi domain baru; canonical flow tetap requested/
disbursed/actual/returned/outstanding. Pada boundary ini tidak ada pencairan,
perubahan `expected_cash`, Cash In, Stock Movement, atau jurnal final.

User mengonfirmasi pengajuan Expense Phase-31 berhasil. Phase-32 local-ready
menambahkan `Finance > Approval Expense` untuk list/detail, guarded approve,
reject beralasan, dan cancel sesuai authority. Accounting dapat membaca tetapi
tidak menyetujui; Store Manager/Owner/Admin/Finance/Super Admin mengikuti guard
server. Semua aksi pada fase ini tetap cash-neutral.

User mengonfirmasi approval Phase-32 aman. Phase-33 hanya membuka diagnostic
SELECT-only untuk menilai Expense `APPROVED`, metode dan Store scope, open
Cashier Session untuk Cash, account/category, snapshot approval, enum/RPC
Financial Event, Cash Drawer Movement, expected-cash calculator, privilege,
dan reconciliation. Belum ada RPC pencairan atau perubahan uang pada fase ini.

User mengirim output Phase-33 tanpa blocker: empat runtime gap tepat `SETUP`,
seluruh invariant live `PASS`, dan terdapat dua Expense approved—Cash serta
non-Cash. Phase-34 local-ready menambahkan schema snapshot dan guarded RPC
`disburse_expense`: amount/method berasal dari dokumen approved, Cash wajib
Session OPEN dengan expected drawer cukup dan satu movement OUT, non-Cash hanya
Finance/Admin tanpa drawer effect, retry exact idempotent, audit immutable, dan
Financial Event `HOLD`. Dokumen live tidak dicairkan otomatis oleh migration.

User mengonfirmasi seluruh rollout/regression/closing Phase-34 aman. Phase-35
sekarang local-ready tanpa migration baru. PWA mempertahankan satu menu
`Expense` dan menambahkan tab `Cairkan Tunai`: hanya dokumen `APPROVED + CASH`
Store aktif yang tampil; nominal/metode read-only; Session dan drawer effect
tetap divalidasi RPC; retry memakai satu idempotency key; expected cash hasil
server diperbarui pada state sesi. Backoffice `Finance > Approval Expense`
menambahkan konfirmasi Transfer/non-Cash untuk Super Admin, Owner/Admin, dan
Finance. Route server menolak Cash, Accounting/Store Manager tidak mendapat
action, dan pembayaran non-Cash tidak membuat Drawer Movement. Settlement,
return, additional disbursement, Cash In, Offline Expense, Deposit, dan jurnal
G6 tetap tertutup.

User mengonfirmasi Phase-35 aman. Phase-36 hanya menambahkan diagnostic
SELECT-only: rekonsiliasi total dokumen dengan detail append-only, validitas
lifecycle `DISBURSED/PARTIALLY_SETTLED/SETTLED`, coverage Financial Event dan
Cash drawer untuk histori, readiness category account/sesi Cash return,
outstanding aging, privilege boundary, serta inventaris gap schema/enum/RPC.
Belum ada actual settlement, return funds, additional disbursement, atau Cash
In yang dapat dieksekusi pada fase ini.

User mengirim output Phase-36 tanpa blocker/review: lima runtime gap tepat
`SETUP`, semua invariant `PASS`, direct browser write tertutup, dan tidak ada
history settlement/return yang membutuhkan backfill. Phase-37 local-ready
menambahkan request actual yang cash-neutral sampai direview, approved actual
dan return immutable, Cash return sebagai Cash In + drawer `IN`, non-Cash
drawer isolation, outstanding lifecycle, idempotency, Finance `HOLD`, dan
additional disbursement request-only tanpa cash effect. Execution additional,
UI settlement, Offline Expense, correction/reversal, Deposit, dan G6 masih
tertutup.

User mengonfirmasi rollout dan seluruh regression Phase-37 aman. Phase-38
tidak menambah schema: PWA menambahkan tab `Penyelesaian` untuk request biaya
aktual, return Cash pada Session aktif, dan request dana tambahan. Backoffice
menampilkan request aktual untuk approve/reject serta menerima return non-Cash
untuk Finance/Owner/Admin. Actual tetap cash-neutral sebelum review, return
Cash memperbarui expected cash, return non-Cash tidak menyentuh drawer, dan
additional disbursement tetap request-only. Lint/build kedua aplikasi PASS.

User melanjutkan tanpa melaporkan error Phase-38. Operational UI ditutup
`COMPLETE`. Phase-39 menahan Deposit dan mengaudit additional disbursement yang
masih request-only melalui diagnostic SELECT-only: lifecycle/data/reference,
zero cash effect, approval/execution schema dan RPC gap, event enum, Session
Cash readiness, privilege, serta inventory. Tidak ada mutation pada fase ini.

User mengirim seluruh output Phase-39: tidak ada blocker/review; seluruh
dependency, tenant/reference, zero cash effect, document/payment/Session,
duplicate-open, dan privilege check `PASS`. Inventory request masih nol.
Expected `SETUP` hanya enum event, enam lifecycle column, dan dua RPC.

Phase-40 sekarang `COMPLETE`. Migration
`20260804100000` menambahkan guarded review/reject dan execution additional
Expense. Review tetap cash-neutral. Cash wajib Session `OPEN`, expected cash
cukup, dan satu immutable drawer `OUT`; non-Cash hanya Finance/Admin tanpa
drawer. Setiap request hanya dapat terhubung ke satu disbursement, retry exact
idempotent mengembalikan snapshot expected cash yang sama, document totals dan
outstanding diperbarui atomic, audit ditulis, dan Financial Event tetap `HOLD`.
User mengonfirmasi corrected behavioral test sukses setelah fixture Company B
mengaktifkan Expense untuk mencapai negative tenant guard yang dimaksud.
Migration, postflight, database behavior, regression Phase-37/34/30/2/G1, dan
closing postflight seluruhnya dikonfirmasi user berhasil. Migration tidak
memproses request existing secara otomatis.

Phase-41 local-ready membuka UI tanpa schema baru. Backoffice menampilkan
riwayat request tambahan per dokumen, mereview `SUBMITTED`, dan membayar
`APPROVED` non-Cash. Route server menolak request Cash. POS memuat request Cash
approved pada Store aktif dan mencairkannya memakai Session aktif; expected
cash diambil dari hasil server. Nominal dan metode read-only, approval tetap
cash-neutral, dialog custom mendukung Escape, dan seluruh mutation memakai
version/idempotency RPC Phase-40. Offline Expense, correction/reversal,
Deposit, Purchasing G5, dan jurnal G6 tetap tertutup.

File utama Phase-40:

- `supabase/migrations/20260804100000_g4_phase40_additional_expense_disbursement.sql`;
- `supabase/diagnostics/g4_phase40_additional_expense_disbursement_postflight.sql`;
- `supabase/tests/g4_phase40_additional_expense_disbursement_tests.sql`;
- `docs/runbooks/G4_PHASE40_ADDITIONAL_EXPENSE_DISBURSEMENT_ROLLOUT.md`;
- `docs/runbooks/G4_PHASE41_ADDITIONAL_EXPENSE_OPERATIONAL_UI.md`;
- `backoffice/src/components/ExpenseApprovalView.tsx` dan route
  `expense-additional-requests/[id]/{review,disburse}`;
- `pwa/src/ExpenseSettlementPanel.tsx` dan `pwa/src/lib/pos.ts`;
- update manifest, root README, router, implementation gates, dan handoff.

Evidence Phase-41 lokal: Backoffice ESLint + production build PASS; PWA oxlint
+ TypeScript/Vite/PWA production build PASS. Manual gate berikutnya adalah
authenticated Cash/non-Cash/reject/effect smoke pada runbook Phase-41.

User kemudian meminta lanjut tanpa melaporkan blocker Phase-41. Sesuai POS-008,
Phase-42 membuat preflight SELECT-only untuk Setor Kas multi-sesi. Query
menginventarisasi legacy `bank_deposits`, sesi `CLOSED`, actual closing cash,
duplicate allocation, legacy event/trigger, Transaction Category
`CASH_DEPOSIT`, enam account function, browser write boundary, serta gap enam
table dan empat RPC canonical. Tidak ada DDL/DML, Deposit UI, variance
resolution, bank matching, atau Finance posting yang dibuka.

File utama Phase-42:

- `supabase/diagnostics/g4_phase42_cash_deposit_preflight.sql`;
- `docs/runbooks/G4_PHASE42_CASH_DEPOSIT_PREFLIGHT.md`.

User mengonfirmasi seluruh hasil live Phase-42 aman. Phase-43 database kemudian
di-rollout dan seluruh postflight, behavior, regression, serta closing check
dikonfirmasi PASS. Migration `20260804130000` menambahkan
enam tabel canonical, policy proof company/store, guarded list/save/submit/
review/cancel RPC, deterministic lock beberapa Session `CLOSED`, expected cash
server-authoritative, optimistic version, exact create/submit/review retry,
immutable audit, variance exception awal, dan Financial Event `HOLD`.

File utama Phase-43:

- `supabase/migrations/20260804130000_g4_phase43_cash_deposit_foundation.sql`;
- `supabase/diagnostics/g4_phase43_cash_deposit_postflight.sql`;
- `supabase/tests/g4_phase43_cash_deposit_foundation_tests.sql`;
- `docs/runbooks/G4_PHASE43_CASH_DEPOSIT_FOUNDATION_ROLLOUT.md`.

Phase-44 membuka operational UI tanpa schema baru. PWA menyediakan Setor Kas
meskipun Session aktif sudah ditutup, memilih beberapa Session `CLOSED`, saldo
sesi berikutnya, tujuan Bank/Brankas, nominal aktual, bukti, serta guarded
Save+Submit. Backoffice menambahkan `Finance > Setor Kas` untuk list/detail per
sesi dan guarded Approve/Reject. Accounting read-only; Approve hanya Super
Admin/Owner/Admin/Finance. UUID tidak ditampilkan sebagai identitas dokumen.

File utama Phase-44:

- `pwa/src/CashDepositModal.tsx`, `pwa/src/App.tsx`, dan `pwa/src/lib/pos.ts`;
- `backoffice/src/components/CashDepositApprovalView.tsx`;
- `backoffice/src/app/api/finance/cash-deposits/**`;
- `docs/runbooks/G4_PHASE44_CASH_DEPOSIT_OPERATIONAL_UI.md`.

Evidence lokal: PWA lint/build PASS; Backoffice lint/build PASS dan route API
terdeteksi pada production build. User mengonfirmasi jalur approval aman setelah
optional reason bugfix. Phase-45 menambahkan preflight SELECT-only untuk
exception source/amount/type, lifecycle, responsible party, allocation
reconciliation, account mapping, maker-checker, runtime/event gap, dan browser
boundary. Bank matching, variance allocation/resolution mutation, Offline
Deposit, correction/reversal, dan journal G6 tetap tertutup.

File utama Phase-45:

- `supabase/diagnostics/g4_phase45_deposit_variance_resolution_preflight.sql`;
- `docs/runbooks/G4_PHASE45_DEPOSIT_VARIANCE_RESOLUTION_PREFLIGHT.md`.

User mengirim output live Phase-45 seluruhnya aman: dependency, source,
amount/lifecycle, responsible party, allocation reconciliation, account
catalog, privilege, dan coverage `PASS`; satu Deposit approved berstatus
matched dan history exception/allocation masih nol. Phase-46 local-ready
menambahkan penetapan responsible party, partial append-only resolution,
maker-checker untuk loss/income/source correction, exact idempotency,
cross-Company guard, immutable audit, dan Financial Event `HOLD`.

File utama Phase-46:

- `supabase/migrations/20260804160000_g4_phase46_deposit_variance_resolution.sql`;
- `supabase/diagnostics/g4_phase46_deposit_variance_resolution_postflight.sql`;
- `supabase/tests/g4_phase46_deposit_variance_resolution_tests.sql`;
- `docs/runbooks/G4_PHASE46_DEPOSIT_VARIANCE_RESOLUTION_ROLLOUT.md`.

Verification lokal terbatas pada static SQL/diff karena PostgreSQL lokal tidak
tersedia. Migration, postflight, behavior, dan regression live masih menunggu
user. Tidak ada data live yang dimutasi oleh agent.

Online checkout, split Payment, true-concurrent Post, Offline Stock Allowance,
dan canonical Offline Sale Sync database telah dikonfirmasi sukses termasuk
regression serta reconciliation penutup.

User menutup Phase-23 preflight dengan seluruh kontrak server, browser boundary,
identity/lifecycle/idempotency, retry/status recovery, final-effect coverage,
scope UAT, stale sync, serta Stock–Movement–FIFO `PASS`. Client contract
expected `SETUP` kemudian diimplementasikan tanpa migration.

Dexie v5 menambah retained operational scope yang hanya ditulis setelah
snapshot authoritative sukses. Cold-start memerlukan cached Supabase Session
dengan `user.id` sama serta exact Company–Store–Terminal–Gudang–Session–
Cashier. Snapshot integrity, katalog, allowance, dan queue dipulihkan;
reconnect menetapkan active Company lalu menjalankan status-first recovery
sebelum retry. `SYNCING/NEEDS_CONFIRMATION` tidak auto-process dan `FAILED`
memerlukan aksi Kasir. Logout/close Session menginvalidasi snapshot dan
menghapus scope. Authenticated tablet UAT masih menunggu user.

Artifact Phase-13 local-ready:

- `pwa/src/lib/db.ts`;
- `pwa/src/lib/offline.ts`;
- `docs/runbooks/G4_PHASE13_OFFLINE_PWA_QUEUE_FOUNDATION.md`.

Dexie v3 menambah retained queue terpisah dari tabel legacy. Record menyimpan
payload, hash, client transaction ID, posting key, submission ID, attempt,
status, error, dan acknowledgement. Retry tidak membuat identity baru dan
response `POSTED` tidak menghapus record lokal. Adapter hanya memakai RPC
canonical browser-scoped; direct table write dan service-role tidak dibuka.
Keranjang, cache catalog/pricing/Tax, allowance lokal, Slip Offline, serta
entitlement activation masih tertutup sampai gate berikutnya.

Live Phase-14 preflight diterima bersih. Dependency Phase-12, Product-UOM,
Pricelist, Tax, Payment, submission, entitlement, dan browser boundary sesuai
kontrak. Snapshot RPC belum ada dan satu open Session belum memiliki Terminal
policy; keduanya tepat berstatus `SETUP`. Terminal eligibility tidak boleh
dibuat otomatis.

Migration `20260730010000` sekarang local-ready. RPC snapshot hanya menerima
actor pemilik Session `OPEN` pada active Company dan Terminal yang eligible,
lalu mengembalikan Product-UOM, base price, Pricelist/rule, Sales Tax metadata,
Payment Method, stock Gudang, dan active allowance pada satu timestamp.
Migration tidak mengaktifkan entitlement dan belum menghubungkan Keranjang PWA
ke checkout Offline.

User kemudian mengonfirmasi migration, postflight, corrected behavior, seluruh
regression Phase-12/11/4/G1, dan closing postflight Phase-14 aman. Database
snapshot sekarang `COMPLETE`; `terminal_policy_configuration_scope = SETUP`
tetap benar karena Offline belum diaktifkan.

Phase-15 menambah `offline_catalog_snapshots` pada Dexie v4 dan adapter
`pwa/src/lib/offlineCatalog.ts`. Refresh hanya melalui RPC canonical Phase-14,
response harus cocok dengan exact Company/Store/Terminal/Gudang/Session/Cashier,
dan payload disimpan bersama canonical JSONB SHA-256. Read memverifikasi hash,
version, optional caller-defined freshness, serta explicit invalidation tanpa
menghapus history. Local allowance dikurangi seluruh retained queue pada
catalog version yang sama, termasuk queue `POSTED` sampai snapshot baru
diambil. Keranjang dan tombol bayar Offline masih tertutup.

Phase-16 menambahkan menu read-only setelah Session terbuka: tombol `Offline`
pada header membuka drawer status koneksi,
Terminal/Gudang/Session user-facing, snapshot timestamp/age, jumlah Product
allowance, local available per Product, serta refresh online. Refresh error
feature/policy tampil pada drawer dan tidak mencemari error transaksi global.
Close Session/logout menginvalidasi cache tanpa delete; kegagalan IndexedDB
tidak menutupi close server yang sudah sukses. Library Dexie/cache di-lazy-load
setelah Session: build membagi main JS `471.65 kB` dan Offline chunk
`102.84 kB`, tanpa chunk warning.

Phase-17 menambahkan konfigurasi Backoffice di `Pengaturan Modul` →
`Point of Sale`. Super Admin tetap satu-satunya role yang dapat mengubah
entitlement. Pemilik/Admin Perusahaan dapat mengubah default Company, override
Toko, dan eligibility Terminal; Store Manager hanya melihat/mengubah Toko serta
Terminal assignment. API memakai authenticated active Company dan mutation
seluruhnya melalui `save_pos_offline_allowance_policy(...)`; tidak ada direct
table write. Konfirmasi memakai modal custom dan dapat ditutup dengan Escape.
Backoffice lint, TypeScript, serta production build PASS. Authenticated role
smoke Phase-17 dan closed-entitlement smoke Phase-16 masih menunggu user.

Atas permintaan eksplisit user, Phase-18 menambah create Customer dasar langsung
dari checkout POS. `quick_create_pos_customer(...)` tidak menerima Company dari
client; active Company dan Cashier Session `OPEN` actor menentukan tenant.
Kode dibuat otomatis, kategori dipilih dari kategori aktif Company, credit dan
balance selalu nol, parent/default Pricelist selalu kosong, serta audit CREATE
wajib tercatat. Direct Customer table write browser tetap tertutup.

PWA menampilkan tombol `Customer baru`, modal custom yang dapat ditutup dengan
Escape, nama active Company read-only, dan otomatis memilih Customer setelah
refresh katalog. PWA dan Backoffice kini menyembunyikan dropdown Company bagi
user satu Company dan hanya menampilkannya bagi user multi-Company. Backoffice
Customer API sebelumnya sudah benar memakai `requireActiveCompany` dan RPC
guarded; tidak ada perubahan authority API.

Local evidence Phase-18: PWA oxlint PASS, PWA TypeScript/Vite production build
PASS (`478.29 kB` main gzip `134.70 kB`; Offline chunk `102.84 kB` gzip
`33.59 kB`), Backoffice ESLint PASS, dan Next.js production build PASS.
Migration, postflight, dan behavioral test kemudian dikonfirmasi sukses oleh
user; visual tenant smoke dapat diulang sesudah restart bila diperlukan.

User kemudian mengonfirmasi seluruh Phase-18 sukses. Migration `20260730040000`
tidak boleh dijalankan ulang atau diedit. Postflight dan rollback-safe
behavioral test PASS; RPC active-Company/open-Session, automatic code, safe
Customer contract, audit, uniqueness, serta browser write boundary sekarang
`COMPLETE`. Authenticated visual smoke selector satu/multi-Company tetap dapat
diulang setelah restart bila diperlukan, tetapi bukan blocker database.

Phase-19 kemudian menambah operasional allowance pada Backoffice tanpa schema
atau migration baru. `GET/POST /api/platform/offline-allowances` memerlukan
authenticated active Company serta role Super Admin, Company Owner/Admin, atau
Store Manager. GET mengembalikan hanya Session `OPEN`, Product-stock, allowance,
dan referensi yang lolos RLS. POST hanya meneruskan issue/release/force-revoke
ke RPC Phase-11; tidak ada direct table mutation.

`OfflineAllowanceOperations` tersedia pada `Pengaturan Modul` → `Point of
Sale`. UI memakai nama Product/UOM/Toko/Terminal/Gudang/Kasir, menghitung
preview hanya sebagai informasi, dan menjelaskan jumlah final selalu dihitung
server. Force-revoke memakai modal custom, alasan wajib, Escape close, serta
optimistic version. Entitlement disabled memblokir issuance tetapi allowance
lama tetap dapat direview/release/revoke.

Local evidence Phase-19: Backoffice ESLint PASS; TypeScript/Next.js production
build PASS dan route `/api/platform/offline-allowances` terdaftar. Browser
connector gagal tersedia pada environment agent, sehingga authenticated visual
UAT belum diklaim. Checkout Offline, PWA cart, dan queue execution tidak
diubah.

Phase-20 menambah kontrol Cashier pada drawer `Offline` PWA. Cashier dapat
meminta allowance untuk Product stok eligible pada Session miliknya dan
melepaskan allowance sendiri bila belum consumed serta tidak dipakai retained
queue. Jumlah tidak pernah berasal dari input client; PWA hanya memanggil RPC
Phase-11 lalu merefresh snapshot authoritative Phase-14. UI menampilkan server
remaining, local queued, dan local available. Jika mutation berhasil tetapi
refresh/reconciliation gagal, cache lama di-invalidasi agar angka stale tidak
tetap dianggap aman. Force revoke tetap hanya pada Backoffice.

Local evidence Phase-20: PWA oxlint PASS; TypeScript/Vite production build dan
service-worker generation PASS. Browser connector kembali gagal tersedia pada
environment agent, jadi authenticated tablet smoke belum diklaim. Tidak ada
migration/schema change dan checkout Offline tetap closed.

Phase-21 live output sudah ditutup: seluruh invariant `PASS`, sedangkan
`offline_checkout_uat_scope=SETUP` expected karena entitlement, Terminal,
allowance, dan disposable open Session belum diaktifkan.

Phase-22 menghubungkan Cart ke retained queue tanpa migration. Saat koneksi
putus setelah Session/snapshot tersedia, harga dihitung dari resolver Pricelist
snapshot yang mengikuti selection AUTO/override server, discount dan rounding
Rp100 dihitung lokal, kebutuhan Product diagregasi ke Base UOM, lalu Payment
harus exact-total dan eligible. Payload/hash/catalog version/idempotency
disimpan lebih dulu di Dexie; hanya setelah local commit sukses Cart direset dan
Slip Offline ber-watermark ditampilkan. Drawer menyediakan retry, status check
untuk state ambigu, retained error/acknowledgement, serta invoice final setelah
`POSTED`.

Fail-closed tetap berlaku untuk cache/scope invalid, allowance kurang, Product
Bundle, TEMPO, Payment/reference snapshot tidak valid, dan direct table write.
Cold-start penuh tanpa network belum termasuk Phase-22. Authenticated tablet
UAT Phase-20/22 masih menunggu user.

Riwayat integrasi online yang mendasari phase aktif:

Smoke login pertama menemukan `Failed to fetch`. Root cause terverifikasi bukan
password/RLS: `pwa/.env` masih berisi URL dan key placeholder, sedangkan
`backoffice/.env.local` mempunyai konfigurasi publik yang valid. Vite PWA
sekarang fallback hanya ke `NEXT_PUBLIC_SUPABASE_URL` dan public publishable
key Backoffice ketika nilai PWA placeholder; deployment tetap membutuhkan
`VITE_*`. `supabase.ts` juga menolak konfigurasi kosong/placeholder dengan pesan
yang actionable. PWA lint/build PASS dan inspeksi bundle membuktikan URL/public
key aktif terpasang serta service-role key tidak ikut. Manual gate: restart
proses PWA, login ulang, lalu lanjutkan smoke; user tetap perlu assignment
Cashier/Store/Terminal yang valid setelah Auth berhasil.

Setelah login berhasil, PWA masih menampilkan Terminal/Gudang kosong untuk akun
Admin. Audit membuktikan ini bukan schema-cache atau data Backoffice: PWA dan
`open_cashier_session(...)` hanya menerima Store role persis `CASHIER`,
sedangkan spesifikasi menyatakan Super Admin serta Company Owner/Admin
mewarisi aksi Cashier. Forward migration `20260729080000` memperbaiki predicate
server tanpa melewati active Company/Terminal/Gudang/single-session guard.
PWA memakai role aktif yang sama untuk menampilkan Terminal. Provisioning
Cashier biasa di Backoffice sekarang mewajibkan Toko. Local PWA dan Backoffice
lint/build PASS; manual migration, 4-check postflight, behavior, regression,
restart, dan authenticated smoke masih menunggu user.

User berikutnya menguji akun `STORE_MANAGER` yang sudah di-assign ke Toko dan
tetap mendapat Terminal/Gudang kosong. Root cause: fix sebelumnya hanya
Super/Admin inheritance, sedangkan PWA dan RPC belum memasukkan Store Manager
walau role matrix menyatakan Store Manager boleh checkout bila memakai POS.
Migration forward `20260729090000`, postflight, behavior cross-Store negative,
dan PWA filter sudah local-ready. Store Manager hanya memperoleh Terminal pada
Store membership aktif; Gudang tetap wajib sale-source dan Store-compatible.
PWA lint/build PASS. Manual rollout kedua fix berurutan, regression, restart,
dan smoke masih menunggu user.

Sesudah restart, Backoffice user melaporkan `INVALID_SESSION`. Migration
Cashier tidak menyentuh Auth; root cause pada bootstrap UI adalah session object
lokal tetap dianggap aktif walaupun `/api/me/context` sudah menolak access
token. Catch khusus sekarang menjalankan local sign-out, membersihkan context,
dan mengembalikan UI ke Login. Backoffice lint dan production build PASS.
Manual gate: restart/refresh sekali, login ulang; bila browser masih memuat
bundle lama, hard refresh atau hapus site data localhost. Jangan mengubah
Auth user/password atau migration database untuk menangani token client ini.

User kemudian mengonfirmasi Terminal dan Gudang penjualan sudah terbaca. Empat
closure PWA berikut telah dibuat: layout tablet-first, cart/form langsung
direset setelah transaksi `POSTED`, receipt dibuka sebagai halaman print di tab
baru, serta pemilihan Pricelist di bawah Customer dengan mode otomatis dan
override Kasir. Migration forward `20260729100000` menambah wrapper guarded dan
resolver server-side; pilihan eksplisit hanya menerima Pricelist aktif yang
berlaku pada Store serta Global atau milik Customer terpilih. Bridge checkout
Backoffice memakai wrapper yang sama, sedangkan signature RPC lama dipertahankan
untuk kompatibilitas AUTO. PWA dan Backoffice lint/build PASS. Migration,
postflight, behavior/regression, hard refresh, dan tablet smoke masih menunggu
user. Browser preview connector gagal attach pada sesi ini sehingga belum ada
evidence visual otomatis; verifikasi visual harus dilakukan pada smoke manual.

Review user terhadap versi tablet pertama menyatakan hierarchy, keterbacaan,
dan affordance tombol masih terlalu lemah. PWA kemudian disusun ulang mengikuti
pola umum Moka-like tablet POS tanpa menyalin aset/brand: katalog/Product grid
dominan di kiri, Order panel tegas di kanan, header putih, tiga tahap form
bernomor, Total berkontras tinggi, category tab rectangular, Product add control
solid, serta action Draft/Post besar dan sticky. Kontras label/input/tombol
diperkuat dan icon-only Printer/Keluar mendapat label pada viewport yang cukup.
Tidak ada dependency visual baru. PWA lint dan production build PASS; visual
authenticated tablet smoke masih menunggu user karena browser preview connector
tidak dapat attach pada sesi ini.

User meminta pekerjaan diteruskan sampai terbentuk satu relasi stok aktual yang
bisa dipakai menguji Minimum Stock. Boundary aman pertama sudah dibuat sebagai
diagnostic SELECT-only:

- `supabase/diagnostics/g3_phase1_opening_stock_preflight.sql`;
- `docs/runbooks/G3_PHASE1_OPENING_STOCK_PREFLIGHT.md`.

Preflight mengaudit dependency G2, Base UOM Product aktif, pasangan
Product-Gudang eligible, konsistensi saldo terhadap movement, FIFO remaining,
Finance function `INVENTORY_ASSET`/`OPENING_BALANCE_CLEARING`, Transaction
Category `STOCK_OPENING`, enum, serta schema Opening Stock yang belum tersedia.
File ini tidak membuat saldo, movement, batch, event, atau dokumen.

Live preflight, migration `20260728120000`, postflight, behavioral test, dan
regression sudah ditutup sukses oleh user. Database menyediakan Draft/Posted
Opening Stock, guarded role boundary, atomic movement/balance/FIFO, event
Finance `HOLD`, audit, idempotency, serta hard guard prior movement.

Backoffice sekarang menyediakan menu `Inventory > Stok Awal`, Draft yang belum
mengubah saldo, konfirmasi Posting final, dan detail bukti stok aktual,
movement, serta FIFO. Seluruh referensi menampilkan nama Product, Gudang, dan
Base UOM; UUID tetap internal. Manual gate aktif mengikuti
`docs/runbooks/G3_PHASE2_OPENING_STOCK_API_UI.md`.

Follow-up read model sudah ditambahkan setelah user menemukan saldo belum
terlihat: `Produk & Stok` membaca saldo aktual total/per Gudang, sedangkan
`Minimum Stock` membandingkan saldo aktual terhadap batas dan menandai
`Stok menipis` bila notifikasi aktif serta `actual <= minimum`. Ini adalah
indikator saat halaman dimuat/refresh, belum push/background notification.

Audit ulang roadmap mengonfirmasi struktur resmi: Stock Real merupakan halaman
operasional utama di Inventory; Minimum Stock hanya konfigurasi; Stock Movement
adalah halaman ledger read-only berikutnya; notice Cashier/inbox/Stock Request
baru G4 dan Purchasing baru G5. Karena itu menu `Produk & Stok` dikoreksi
menjadi `Produk & UOM`, dan `Inventory > Stock Real` dibuat terpisah dengan
On Hand, Reserved explicit belum aktif, Available sementara sama dengan On
Hand, nilai FIFO, threshold, movement terakhir, serta filter Gudang/menipis.

Audit langkah Kartu Stok menemukan schema `stock_movements` existing belum
menyimpan seluruh minimum contract: actor, Base UOM snapshot, status,
source-line identity, notes, dan balance-after. Karena field audit tidak boleh
ditebak dari UI, boundary aktif dipindahkan ke diagnostic SELECT-only
`supabase/diagnostics/g3_phase4_stock_movement_preflight.sql` dan runbook
`docs/runbooks/G3_PHASE4_STOCK_MOVEMENT_PREFLIGHT.md`.

Live result user seluruhnya bersih: satu movement Opening, satu source/pair,
saldo cocok, tidak ada duplicate/orphan/negative/missing coverage, dan browser
write false. Delapan missing snapshot serta lima missing future enum sesuai
ekspektasi. Migration `20260728150000`, postflight, behavioral test, dan
regression sudah ditutup sukses oleh user. Backoffice sekarang menyediakan
menu `Inventory > Kartu Stok` sebagai ledger read-only dengan snapshot Base
UOM, quantity masuk/keluar, saldo setelah movement, jenis, dokumen sumber,
actor aman, waktu posting, catatan, serta filter. UUID tidak ditampilkan dan
tidak ada jalur mutation baru.

User mengonfirmasi Kartu Stok aman. Urutan target Inventory berikutnya adalah
Transfer Stok. Audit repo menemukan RPC legacy masih sengaja server-only sejak
G1 karena menerima quantity negatif, tidak memiliki row-lock/idempotency/source
document canonical, dan tidak memindahkan FIFO dengan contract production.
Boundary aktif adalah SELECT-only preflight:

- `supabase/diagnostics/g3_phase6_stock_transfer_preflight.sql`;
- `docs/runbooks/G3_PHASE6_STOCK_TRANSFER_PREFLIGHT.md`.

Live preflight seluruh blocker PASS: tidak ada Transfer history/backfill,
saldo/FIFO/Base UOM/category valid, browser stock write false, dan legacy RPC
tetap non-executable bagi browser. Migration `20260728180000` sekarang
local-ready dengan Draft/Posted/Canceled document, positive quantity, atomic
balance/FIFO relocation, source-batch lineage, paired canonical movement,
operator guard, idempotency, audit, dan full application-role revoke untuk RPC
legacy. User kemudian mengonfirmasi migration, 15-check postflight, behavioral
test, dan seluruh regression sukses. Backoffice sekarang menyediakan
`Inventory > Transfer Stok`, guarded Draft/Edit/Post/Cancel, stok tersedia dari
Gudang asal, bukti saldo/movement/FIFO setelah Posting, serta lookup nomor
Transfer pada Kartu Stok. UUID tidak ditampilkan. Authenticated smoke mengikuti
`docs/runbooks/G3_PHASE7_STOCK_TRANSFER_API_UI.md`; user mengonfirmasi seluruh
smoke sukses.

Roadmap berikutnya adalah Stock Adjustment sebelum Stock Opname karena Posting
Opname menghasilkan Adjustment otomatis untuk line variance. Diagnostic
SELECT-only:

- `supabase/diagnostics/g3_phase8_stock_adjustment_preflight.sql`;
- `docs/runbooks/G3_PHASE8_STOCK_ADJUSTMENT_PREFLIGHT.md`.

Diagnostic mengaudit legacy `stock_adjustments`, linkage dan snapshot Movement,
reason backfill, balance/FIFO, Base UOM, kategori/fungsi Finance, privilege, dan
missing canonical document/RPC. User mengonfirmasi seluruh blocker PASS, zero
legacy Adjustment/backfill, dua positive balance/FIFO pair bersih, dan Finance
siap.

Database foundation telah dikonfirmasi user seluruhnya sukses:

- `supabase/migrations/20260728210000_g3_phase8_stock_adjustment_foundation.sql`;
- `supabase/diagnostics/g3_phase8_stock_adjustment_postflight.sql`;
- `supabase/tests/g3_phase8_stock_adjustment_foundation_tests.sql`;
- `docs/runbooks/G3_PHASE8_STOCK_ADJUSTMENT_FOUNDATION_ROLLOUT.md`.

Kontrak memakai stok fisik akhir, server-derived difference, reason reusable,
FIFO gain/loss, immutable canonical Movement, Finance `STOCK_GAIN`/`STOCK_LOSS`
berstatus `HOLD`, optimistic version, idempotency, audit, serta Store Manager
yang hanya dapat memproses Gudang Store assignment. Browser direct write tetap
tertutup.

Backoffice Phase 9 sekarang local-ready:

- helper validation `backoffice/src/lib/stock-adjustment.ts`;
- empat guarded route di
  `backoffice/src/app/api/inventory/stock-adjustments`;
- UI `backoffice/src/components/StockAdjustmentView.tsx`;
- menu role-aware serta Kartu Stok source lookup;
- runbook `docs/runbooks/G3_PHASE9_STOCK_ADJUSTMENT_API_UI.md`.

Form menjelaskan bahwa user memasukkan stok fisik akhir, menampilkan stok sistem
dan selisih otomatis, memakai nama Base UOM, menyaring reason berdasarkan arah,
serta meminta alasan bila gain cost dioverride. Draft/Edit/Post/Cancel dan
seluruh modal Escape tersedia. Lint dan production build 34 pages PASS.
User melanjutkan setelah authenticated smoke, sehingga Phase 9 ditutup.

Preflight Stock Opname sudah ditutup bersih:

- `supabase/diagnostics/g3_phase10_stock_opname_preflight.sql`;
- `docs/runbooks/G3_PHASE10_STOCK_OPNAME_PREFLIGHT.md`.

Kontrak target adalah blind count nonblocking oleh kasir, movement watermark
pada `counted_at`, recount bila ada movement dalam window count, supersede
per-line untuk sesi overlap, review/post sesuai assignment, dan variance yang
diposting atomic melalui canonical Stock Adjustment. Preflight hanya membaca
aggregate legacy session/detail, linkage Adjustment, balance/FIFO, Base UOM,
channel Store/POS/Cashier, privilege, enum, dan gap schema. Preflight tidak
membuat mutation; G4 dan G5 tetap tertutup.

Database foundation sudah `COMPLETE` berdasarkan konfirmasi user:

- `supabase/migrations/20260728230000_g3_phase10_stock_opname_foundation.sql`;
- `supabase/diagnostics/g3_phase10_stock_opname_postflight.sql`;
- `supabase/tests/g3_phase10_stock_opname_foundation_tests.sql`;
- `docs/runbooks/G3_PHASE10_STOCK_OPNAME_FOUNDATION_ROLLOUT.md`.

Foundation menjaga detail direct-read reviewer-only dan menyediakan
`get_stock_opname_blind_session(...)` untuk kasir agar system/expected/variance,
physical count lama, HPP, dan nilai tidak bocor. Posting memakai satu canonical
Adjustment secara atomic; zero variance tidak membuat Adjustment line.
Membership Cashier aktif belum ada pada hasil preflight, sehingga tidak
memblokir migration tetapi harus disiapkan sebelum smoke POS. Checksum migration
local `23e5026157f21dec4ee8d6df93f2363baffd67a79ee598b1831d8ced4814322d`.

User kemudian mengonfirmasi seluruh rollout database berhasil. Migration Phase
10 tidak boleh diedit atau dijalankan ulang. Backoffice Phase 11 sekarang
menyediakan route read-only tenant-scoped, guarded action `recount`, `post`, dan
`cancel`, helper error contract, serta UI `Inventory > Stock Opname`. Report
menampilkan snapshot, expected saat hitung, fisik, variance, counter, attempt
timeline, dan bukti Adjustment memakai nama bisnis tanpa UUID. Finance dan
Accounting read-only; reviewer mutation tetap divalidasi oleh RPC.

Lint dan production build PASS; build mendeteksi empat route Opname sebagai
dynamic API. Pembuatan sesi dan blind count POS sengaja tidak dipasang pada PWA
prototype. Requirement STK-004 melintasi G3/G4 dan jalur kasir baru boleh
dibuka setelah G4 menyediakan production auth, Company/Store/Terminal context,
Cashier Session, dan offline queue. Database sudah menyediakan
`get_stock_opname_blind_session(...)` sebagai contract aman untuk G4.

User menyatakan halaman report belum dapat diuji end-to-end karena belum ada
POS production yang membuat sesi. Ini expected dependency STK-004 lintas G3/G4,
bukan error dan bukan alasan memasang flow kasir pada PWA mock. Sisa roadmap G3
berpindah ke Bundle STK-006. Boundary aktif:

- `supabase/diagnostics/g3_phase12_bundle_foundation_preflight.sql`;
- `docs/runbooks/G3_PHASE12_BUNDLE_FOUNDATION_PREFLIGHT.md`.

Diagnostic hanya membaca aggregate dependency, Bundle/component existing,
nested/self reference, quantity, duplicate, canonical Base UOM, sales/purchase
UOM, physical stock/Movement/FIFO yang ilegal pada Bundle virtual, browser
privilege, serta gap column/audit/RPC. Existing Product RPC masih sengaja
menolak `BUNDLE_COMPONENTS_REQUIRED_G3`; tidak ada schema, stock, checkout,
Import, atau allocation mutation pada fase preflight ini.

User mengirim seluruh hasil: dependencies dan seluruh invariant PASS, zero
Bundle/component/backfill/physical stock, dua sale-source warehouse, serta
schema/RPC/audit gap sesuai expected. Direct INSERT/UPDATE legacy pada
composition masih terbuka dan menjadi bagian boundary migration.

Database foundation sekarang local-ready:

- `supabase/migrations/20260729010000_g3_phase12_bundle_foundation.sql`;
- `supabase/diagnostics/g3_phase12_bundle_foundation_postflight.sql`;
- `supabase/tests/g3_phase12_bundle_foundation_tests.sql`;
- `docs/runbooks/G3_PHASE12_BUNDLE_FOUNDATION_ROLLOUT.md`.

Migration membuat Product Bundle dan composition sebagai satu mutation atomic,
menurunkan berat dari UOM/berat komponen, melarang nested/self/cross-Company,
mengunci Product type, menjaga Bundle tanpa physical stock/FIFO, menyimpan
audit/version, serta menyediakan private expansion untuk G4 dan availability
reviewer per Gudang. Direct browser write composition dicabut. Checkout,
allocation, Return, Import, dan PWA tetap tidak dibuka.

### Boundary sebelumnya: G2 Phase 47

**G2 Phase 47 — Backoffice Minimum Stock + fixed Import/Export UI**

Phase 46 database sudah ditutup `COMPLETE` berdasarkan konfirmasi user bahwa
seluruh rollout aman dan pekerjaan boleh dilanjutkan. Jangan mengedit atau
menjalankan ulang migration `20260728090000`.

Sebelum Phase 47 dilanjutkan, app shell mendapat follow-up navigasi global:

- tombol `Kembali` pada seluruh halaman non-dashboard memakai history view
  internal Backoffice dan tidak bergantung pada browser Back;
- breadcrumb menampilkan `Beranda / Modul / Halaman`;
- breadcrumb Beranda dan nama Modul dapat dipakai untuk berpindah konteks;
- tombol brand tetap kembali ke app launcher dan mereset history;
- pergantian Company juga mereset history agar user tidak kembali ke halaman
  tenant sebelumnya.

Phase 47 kini local-ready. Modul Inventory memiliki halaman **Minimum Stock**
untuk create/edit pasangan Product–Gudang. UI hanya menampilkan Product,
Gudang, nama Base UOM, threshold, serta status notifikasi; UUID tetap internal.
Create/update melewati guarded RPC Phase 46 dengan optimistic master version.

Import & Export mendukung tipe `PRODUCT_WAREHOUSE_MINIMUM_STOCK`: template
create memakai SKU Product dan nama Gudang; export update menambahkan
`internal_id`; preview menjelaskan threshold Base UOM dan status notifikasi.
API export menggabungkan settings/Product/Gudang melalui query terpisah agar
tidak bergantung pada PostgREST embedded relationship. Tidak ada saldo,
movement, request, order, atau Opening Stock yang dimutasi.

User mengonfirmasi Phase-40 main migration, UUID forward fix, postflight,
behavioral test, dan Phase-38 compatibility regression seluruhnya PASS pada
2026-07-27. Database tujuh simple master dinyatakan `COMPLETE`.

Preflight tiga master sederhana berikutnya bersih: seluruh invariant `PASS`,
tidak ada job nonterminal, duplicate, blank identity, hierarchy issue, atau
invalid System Event. Guarded RPC lengkap. Inventory live berisi 1 Customer
Category sistem, 36 COA sistem tanpa histori jurnal, 26 required Transaction
Category, dan 1 custom Transaction Category.

Forward migration `20260727090000` sudah applied. Constraint job diperluas
secara additive; public create/validate/commit signature tidak berubah. Empat
import existing didelegasikan ke implementation Phase 38/33 yang dipindahkan
ke private. Tiga tipe baru memakai validator sendiri dan commit melalui guarded
master RPC existing. Kategori Customer sistem, COA sistem, dan required
Transaction Category menjadi export-only. COA tetap menampilkan
`account_code` sebagai identitas bisnis.

Behavioral test pertama berhenti pada preview parent COA dengan PostgreSQL
`42883 function min(uuid) does not exist`. Root cause hanya satu aggregate UUID
pada validator. Karena migration utama sudah applied, file tersebut tidak
diedit. Forward migration `20260727100000` menggantinya dengan
`min(id::text)::uuid`; public signature, schema, data, grant, dan flow bisnis
tidak berubah.

Phase-41 Backoffice menambahkan Kategori Pelanggan, Chart of Account, dan
Kategori Transaksi ke tipe Import & Export. Template create tidak menampilkan
kode teknis Customer/Transaction Category; COA tetap memakai kode akun bisnis.
Export memuat `internal_id` untuk update. System-owned rows tetap tampil sebagai
referensi export namun validator menolak mutasinya. Local lint, production
build, dan authenticated smoke user PASS. Phase 41 dinyatakan `COMPLETE`.

Phase 42 memulai grouped Product Import melalui diagnostic SELECT-only.
Kontrak fixed memakai beberapa row per Product: satu row per UOM dan seluruh
row dengan `product_key` yang sama diproses atomic. Tepat satu faktor base `1`,
UOM aktif berfaktor terbesar menjadi acuan berat, minimal satu UOM jual/beli
aktif, dan reference Category/UOM/Tax harus sudah tersedia. Product import
tidak membuat master referensi, stock, FIFO, movement, atau Opening Stock.

User mengonfirmasi seluruh hasil live Phase-42 preflight PASS. Migration
`20260727130000` menambahkan job type `PRODUCT`, grouped validator,
optimistic preview capture, dan per-group partial commit ditambahkan tanpa
mengubah signature public import RPC. Tujuh simple master existing tetap
didelegasikan ke implementation Phase 40 yang dipindahkan ke private.

Validator menyelesaikan Category/UOM/Tax berdasarkan nama tenant yang aktif,
menolak group header yang tidak konsisten, duplicate UOM/barcode, Base UOM
selain tepat satu faktor `1`, acuan berat yang ambigu, serta Product tanpa UOM
jual/beli. Commit hanya memanggil overload atomic
`save_product_with_uoms(..., sales_tax_rule_id, purchase_tax_rule_id)`.
Product Bundle, stock, Opening Stock, dan auto-create reference tetap ditolak.
SKU, Base UOM, struktur UOM, dan faktor terkunci bila sudah ada Sales,
Purchase, atau stock-movement history.

Migration Phase 42 kemudian berhasil applied. Behavioral test mencapai commit
tetapi rollback pada constraint `master_import_job_events_type_check` karena
private Product commit menulis event `COMMIT`, sementara vocabulary canonical
adalah `COMPLETE`. Seluruh fixture/write test rollback; migration utama tetap
applied. Forward migration `20260727140000` hanya mengganti literal audit
tersebut tanpa mengubah signature atau business behavior.

User kemudian mengonfirmasi forward migration, 4-check postflight, behavioral
test Phase 42, serta regression Phase 40 dan Phase 38 seluruhnya PASS. Database
Grouped Product Import kini `COMPLETE`; migration utama maupun forward fix
tidak boleh dijalankan ulang.

Phase 43 menambahkan tipe **Produk + Satuan** pada Backoffice Import & Export.
Template fixed memakai satu baris per Product-UOM dan `product_key` yang sama
untuk seluruh satuan Product. Export menambahkan `internal_id` hanya untuk mode
update dan mereferensikan Category/UOM/Tax berdasarkan nama. Preview
mengelompokkan baris berdasarkan Product, menampilkan nama Product, SKU, nama
UOM, faktor langsung ke Base UOM, fungsi beli/jual, dan harga. Ringkasan
create/update/skip/error dihitung per Product group. Tidak ada stock, Opening
Stock, movement, FIFO, atau auto-create master reference.

Phase 44 melanjutkan dependency order fixed import ke Product-Supplier. Kontrak
create memakai `product_sku`, `supplier_name`, `purchase_uom_name`,
`supplier_product_code`, reference price, preferred flag, dan status. Diagnostic
baru hanya membaca aggregate live state. Ia memblokir reference aktif ambigu,
Product stok tanpa UOM pembelian, orphan/cross-Company relation, relasi aktif
ke master nonaktif/UOM non-pembelian/Bundle, preferred Supplier ganda, nilai
existing invalid, guarded RPC hilang, serta import job nonterminal.

User mengirim seluruh hasil live Phase-44 preflight: semua blocker `PASS`,
job type `PRODUCT_SUPPLIER` belum ada sesuai expected pre-migration, tidak ada
job nonterminal, dan satu relation existing valid. Migration
`20260727160000` menambahkan job type/dispatcher secara additive, validator
tenant-scoped, optimistic version capture, dan partial commit melalui
`save_product_supplier(...)`. Pergantian preferred memproses row `false`
sebelum `true`; final preview tetap menolak lebih dari satu preferred aktif.
Import tidak menyentuh `last_purchase_price`, Purchase, stock, FIFO, movement,
atau Opening Stock.

User kemudian mengonfirmasi seluruh rollout Phase 44 PASS. Phase 45 menambah
tipe **Relasi Produk–Supplier** pada Backoffice Import & Export. Template create
berisi tujuh header fixed tanpa ID; export update menambahkan `internal_id`.
Product ditampilkan sebagai SKU, sedangkan Supplier dan UOM pembelian selalu
ditampilkan sebagai nama. Preview tidak memperlihatkan UUID dan menjelaskan
harga referensi, preferred/alternatif, serta status. Export menggabungkan query
relation/Product/Supplier/UOM secara terpisah agar tidak bergantung pada nested
PostgREST relationship schema cache. Lint dan production build PASS.

User melanjutkan setelah verifikasi tersebut sehingga Phase 45 ditutup
`COMPLETE`. Phase 46 mengaudit Minimum Stock per Produk–Gudang sebelum schema
ditulis. Kontrak approved menyimpan threshold opsional dalam base UOM dan
memisahkan lifecycle konfigurasi dari saldo `product_stocks`. Dengan demikian,
pasangan Product–Gudang tanpa movement/saldo tetap dapat dikonfigurasi tanpa
membuat row saldo nol palsu.

Diagnostic Phase 46 hanya membaca aggregate state. Ia memeriksa dependency
Phase 44, SKU Product dan nama Gudang aktif yang kosong/ambigu, tepat satu base
Product-UOM aktif berfaktor `1`, orphan/duplicate/negative saldo, movement pair
tanpa materialized balance, import job nonterminal, direct browser stock write,
eligible pair inventory, serta state schema/job/RPC yang memang belum tersedia.
Tidak ada threshold, stock mutation, movement, Stock Request, Supplier Order,
atau Opening Stock yang dibuat.

User mengirim hasil live: seluruh check hanya `PASS`/`INFO`. Satu Product stock
aktif dan tiga Gudang aktif menghasilkan tiga eligible pair; belum ada balance
atau movement. Tidak ada reference kosong/ambigu, base UOM invalid,
orphan/duplicate/negative balance, movement tanpa balance, browser write, atau
job nonterminal. Schema/RPC/job type belum ada sesuai expected pre-migration.

Migration `20260728090000` kini local-ready. Ia membuat tabel settings dan
audit terpisah dari `product_stocks`, guarded optimistic RPC dengan advisory
pair lock, RLS read boundary, serta fixed import
`PRODUCT_WAREHOUSE_MINIMUM_STOCK`. Template memakai SKU Product dan nama
Gudang; threshold memakai base UOM. Validator/partial commit bersifat
tenant-safe dan tidak membuat balance, movement, Stock Request, Supplier
Order, atau Opening Stock.

File aktif:

- `supabase/diagnostics/g2_phase42_grouped_product_import_preflight.sql`;
- `supabase/migrations/20260727130000_g2_phase42_grouped_product_import.sql`;
- `supabase/diagnostics/g2_phase42_grouped_product_import_postflight.sql`;
- `supabase/tests/g2_phase42_grouped_product_import_tests.sql`;
- `supabase/migrations/20260727140000_g2_phase42_product_import_complete_event_fix.sql`;
- `supabase/diagnostics/g2_phase42_product_import_complete_event_fix_postflight.sql`;
- `docs/runbooks/G2_PHASE42_GROUPED_PRODUCT_IMPORT_PREFLIGHT.md`;
- `docs/runbooks/G2_PHASE42_GROUPED_PRODUCT_IMPORT_ROLLOUT.md`;
- `docs/runbooks/G2_PHASE42_PRODUCT_IMPORT_COMPLETE_EVENT_FIX.md`;
- `docs/runbooks/G2_PHASE43_GROUPED_PRODUCT_IMPORT_UI.md`;
- `supabase/diagnostics/g2_phase44_product_supplier_import_preflight.sql`;
- `docs/runbooks/G2_PHASE44_PRODUCT_SUPPLIER_IMPORT_PREFLIGHT.md`;
- `supabase/migrations/20260727160000_g2_phase44_product_supplier_import.sql`;
- `supabase/diagnostics/g2_phase44_product_supplier_import_postflight.sql`;
- `supabase/tests/g2_phase44_product_supplier_import_tests.sql`;
- `docs/runbooks/G2_PHASE44_PRODUCT_SUPPLIER_IMPORT_ROLLOUT.md`;
- `docs/runbooks/G2_PHASE45_PRODUCT_SUPPLIER_IMPORT_UI.md`;
- `supabase/diagnostics/g2_phase46_product_warehouse_minimum_stock_preflight.sql`;
- `docs/runbooks/G2_PHASE46_PRODUCT_WAREHOUSE_MINIMUM_STOCK_PREFLIGHT.md`;
- `supabase/migrations/20260728090000_g2_phase46_product_warehouse_minimum_stock.sql`;
- `supabase/diagnostics/g2_phase46_product_warehouse_minimum_stock_postflight.sql`;
- `supabase/tests/g2_phase46_product_warehouse_minimum_stock_tests.sql`;
- `docs/runbooks/G2_PHASE46_PRODUCT_WAREHOUSE_MINIMUM_STOCK_ROLLOUT.md`;
- `backoffice/src/lib/master-import.ts`;
- `backoffice/src/app/api/master/import-export/route.ts`;
- `backoffice/src/app/api/master/import-jobs/[id]/route.ts`;
- `backoffice/src/components/MasterImportView.tsx`;
- `docs/MASTER_IMPORT_FIXED_CSV_CONTRACTS.md`;
- `docs/PRODUCT_STOCK_MASTERDATA_SPEC.md`.

Prompt handoff siap-copas tersedia pada
`docs/AGENT_CONTINUATION_COPY_PASTE_PROMPT.md`. Prompt tersebut selalu
memerintahkan agent membaca living handoff ini sehingga tidak menjadi basi
setelah fase berganti.

Phase-35 live preflight selesai bersih pada 2026-07-24: seluruh check hanya
`PASS`/`INFO`; 22 tabel dan 12 guarded RPC tersedia; tidak ada duplicate,
ambiguous reference, invalid grouped master, atau nonterminal import job.

User meminta perubahan identitas sebelum migration ekspansi ditulis: Product
dan Customer tetap memiliki kode bisnis user-facing, sedangkan master lain
sebisa mungkin tidak meminta user mengetik kode teknis. UUID existing tetap
menjadi identitas sistem canonical. Kode otomatis harus dibuat server-side,
tenant-scoped, concurrency-safe, dan tidak boleh memakai `MAX(code)+1`.
Keputusan pengecualian kode yang memang bermakna bisnis sudah ditutup user:
Product SKU, Customer code, COA account
code, Tax code, barcode, dan Supplier-owned Product code tetap user-facing.
Delapan master lain menerima kode otomatis server-side untuk row baru; existing
code tidak ditulis ulang. Phase-36 preflight dibuat untuk memeriksa target
column, unique normalized name, prefix inventory, snapshot dependency, dan
nonterminal import job sebelum allocator migration ditulis.

User mengirim hasil Phase-36 bersih: lima invariant `PASS`; 41 legacy code
dipertahankan; tidak ada generated-format row, duplicate name, blank identity,
atau nonterminal import job. Migration applied `20260724010000` menyediakan
atomic counter per Company/entity, reservation untuk explicit code milik import
lama, immutable guard delapan tabel, dan lima overload RPC tanpa parameter
kode. User mengonfirmasi migration, 11-check postflight, dan behavioral test
seluruhnya PASS.

Cutover Backoffice lokal selesai: direct-table create Category/UOM/Warehouse
memakai allocator trigger; Supplier, Customer Category, Pricelist, Payment
Method, dan Transaction Category memakai overload RPC tanpa kode. Form, list,
search, serta dropdown terkait menampilkan nama. Product SKU, Customer code,
COA, Tax, barcode, dan kode Product Supplier tetap user-facing.

User melanjutkan setelah smoke Phase 37, sehingga gate UI automatic-code
dinyatakan aman. Phase 38 lokal memindahkan dependency CSV empat master dari
kolom kode: public validator sekarang menyiapkan stable technical code
server-side sebelum menjalankan private validator Phase 31. Mapping/CSV lama
yang memiliki kode tetap memakai lifecycle/version lama.

Phase 38 juga memperbaiki compatibility validator Gudang: kontrak lama
`^[A-Z]{1,5}$` tetap diterima, dan format allocator baru `WH-000001` kini valid.
Commit Phase 33, partial success, confirmation, optimistic version, audit,
Product/stock exclusion, dan signature API public tidak diubah.

User mengonfirmasi seluruh Phase-38 database gate aman. Phase 39 Backoffice
lokal kini menghapus kode dari template create, export, preview, diff, dan
error download. `internal_id` hanya ada pada export update dan baru ditampilkan
di mapping bila user sengaja memilih mode ID. Gudang memakai `store_name`;
export menulis label `Nama Toko (KODE)`, lalu API menyelesaikan label/nama
unik/kode ke Toko aktif tenant yang sama. Missing/ambiguous reference menjadi
row error dan tidak membuat Toko baru. Lint dan production build PASS.

User meminta Import/Export untuk seluruh item yang dapat dibuat user, bukan
hanya Product Category/UOM/Warehouse/Supplier. Kontrak fixed CSV sudah
ditetapkan untuk Product group, Product-Supplier, Customer Category, Customer,
Pricelist group, Payment Method group, Tax Rule, COA, Transaction Category,
Transaction Account Rule, dan Company Account Fallback.

Referensi template memakai nama/kode bisnis, bukan UUID. Missing/ambiguous
reference menjadi preview error dan tidak boleh auto-create. Product,
Pricelist, serta Payment Method wajib atomic per group. Company, Staff/password,
entitlement, Opening Stock, transaksi, movement, dan journal tetap memakai
workflow khusus dan tidak masuk generic master CSV.

Reusable Customer Pricelist `20260722100000` sudah applied. User mengonfirmasi
migration, 12/12 postflight, behavioral test, dan smoke Customer assignment
aman. Resolver harga serta checkout tetap belum dicutover.

Payment Method preflight diterima bersih dan foundation canonical
`20260722120000` sudah applied. Percobaan pertama rollback pada pending deferred
trigger; ordering diperbaiki, lalu user mengonfirmasi rerun migration, 13/13
postflight, dan behavioral test seluruhnya PASS.

Keputusan terbaru:

- header Pricelist `CUSTOMER` reusable dan tidak dimiliki satu Customer;
- banyak Customer boleh menunjuk Pricelist yang sama;
- dropdown Pricelist dipindahkan ke menu/form Customer;
- satu Customer menunjuk maksimal satu Pricelist khusus; `NULL` memakai Global;
- Walk-In tidak boleh diberi Pricelist khusus;
- migration applied tidak diedit dan checkout/resolver tetap deferred.

Implementasi lokal sudah tersedia: legacy `customer_id` dipertahankan sebagai
kolom kompatibilitas tetapi wajib `NULL`; assignment canonical berada pada
`customers.default_pricelist_id`. Form Pricelist tidak lagi meminta Customer,
sedangkan form Customer menyediakan pilihan Harga Umum atau satu Pricelist
Customer aktif. Satu Pricelist Customer dapat dipakai banyak Customer.

Boundary Payment Method aktif:

- default `Tunai` diprovision per Company aktif;
- master mendukung Store scope, settlement route, proof mode, dan configured
  fee percent/fixed/gabungan;
- Customer Balance/Ketul Offset tidak dapat dibuat lewat generic RPC;
- `sales_payments.payment_method` legacy tetap aktif dan snapshot canonical
  masih nullable;
- foundation menyimpan satu configured fee pada master; effective-dated
  store-specific fee override dan ambiguity resolver tetap wajib dibangun pada
  G4 sebelum checkout cutover;
- checkout, split-payment resolver, offline, settlement, reconciliation, dan
  Finance posting tetap deferred.

Guarded API/UI lokal sekarang tersedia pada menu `Metode Pembayaran`. Form
memakai nama user-facing, mengisi account-function internal otomatis, mendukung
Store scope/proof/settlement/current fee/default/lifecycle, dan dapat ditutup
dengan Escape. Authorization tetap ditegakkan RPC, bukan hanya UI.

User sudah mengonfirmasi smoke menu Metode Pembayaran aman. Phase 15 ditutup
`COMPLETE`. Fase aktif berikutnya mengaudit Transaction Category bersama minimum
COA karena versioned category mapping wajib menunjuk Account ID. Audit ini tidak
mengaktifkan worker/jurnal production dan tidak membuka G6 enforcement.

Live phase-16 preflight diterima bersih: tidak ada Expense, Financial Event,
Journal, blank identity, collision, invalid line, atau unbalanced group. Tiga
Payment Method membawa dua Account Function berbeda dan seluruh function tidak
blank. Satu Company aktif membutuhkan expected minimum COA provisioning.

Foundation lokal menyediakan 37 Account Function, 26 System Event, 36 akun
template per Company, Transaction Category, versioned/effective mapping,
explicit Company fallback storage, posting-exception queue, audit, dan nullable
Event/Journal snapshot. Browser direct write tetap ditutup; guarded RPC hanya
untuk Category dan rule. Worker/resolver/posting masih disabled.

User terakhir menyatakan seluruh menu existing aman tanpa notification error.
Output exact 14-row postflight dan notice behavioral test tidak disalin ulang
pada chat, sehingga handoff tidak boleh mengarang evidence tersebut. Backoffice
lokal kini memiliki menu `Kategori & COA`: Category create/edit dan versioned
mapping memakai guarded RPC; COA masih read-only. Label memakai nama bisnis,
modal dapat ditutup dengan Escape, dan worker/resolver/posting tetap disabled.

Living application README sudah dibuat pada root `README.md`. Root `AGENTS.md`
mewajibkan setiap perubahan material ikut memperbarui README tersebut selain
handoff ini.

File utama phase 17:

- `backoffice/src/lib/finance-master.ts`;
- `backoffice/src/app/api/master/finance-masters/route.ts`;
- `backoffice/src/app/api/master/finance-masters/[id]/route.ts`;
- `backoffice/src/components/FinanceMasterView.tsx`;
- integrasi menu pada `backoffice/src/app/page.tsx`;
- `docs/runbooks/G2_PHASE17_FINANCE_MASTER_API_UI_ROLLOUT.md`;
- root `README.md`, `AGENTS.md`, dan router `docs/README.md`.

User kemudian mengonfirmasi missing-table state sudah aman dan meminta kategori
transaksi wajib agar non-Finance dapat belajar serta menjelaskannya. Phase 18
menyediakan 26 kategori bawaan per Company. Nama/kode/keterangan dapat
disesuaikan, tetapi event, status aktif, dan keberadaannya dilindungi. Custom
category seperti Listrik/Bensin/ATK tetap didukung. Provisioning tidak membuat
Account Rule, fallback, Financial Event, atau Journal.

Live phase-18 preflight diterima `PASS`: dependency phase 16 ada, seluruh 26
System Event tersedia, tidak ada collision kode/nama, dan satu kategori existing
tidak menghalangi rollout. Satu Company aktif akan menerima tepat 26 row bawaan.
Migration kemudian applied dan seluruh data invariant sebenarnya PASS. Run
postflight pertama menunjukkan dua false-negative karena expected count trigger
dan routine tertukar: live menemukan 2 trigger dan 3 routine, tepat sesuai DDL.
Diagnostic diperbaiki; migration tidak perlu dan tidak boleh dijalankan ulang.
Behavioral test berikutnya menemukan bug lama phase 16: shared history trigger
membaca `NEW.account_type` pada record Category. Forward migration phase 19
memisahkan akses field setelah cabang `TG_TABLE_NAME`. File baru mencakup
migration, 5-check postflight, regression test, dan rollout runbook; tidak ada
business data atau Finance posting yang diubah.
User mengonfirmasi phase-19 migration, seluruh 5 postflight, regression test,
dan rerun phase-18 test PASS. Required categories dan trigger fix ditutup.
Next audit hanya SELECT-only untuk mengukur COA hierarchy, history lock,
compatible account candidate, serta required function yang belum memiliki
Transaction Rule/explicit Company fallback.

Live phase-20 preflight sudah diterima tanpa `BLOCKER`. Satu override saldo
normal adalah akun kontra yang valid. Sebanyak 33 category-function pada 24
kategori belum mempunyai rule/fallback dan harus diselesaikan eksplisit; sistem
tidak melakukan auto-mapping ke akun tebakan. Implementasi lokal menyediakan
guarded hierarchical COA RPC, explicit versioned Company fallback, audit,
concurrency serialization, postflight/test, API, serta tab UI Daftar Akun dan
Fallback Company. Label UI memakai nama fungsi/akun, warning contra balance
ditampilkan, dan Escape menutup modal. Finance resolver/posting tetap off.

File utama phase 20:

- `supabase/migrations/20260722230000_g2_phase20_guarded_coa_fallback.sql`;
- `supabase/diagnostics/g2_phase20_guarded_coa_fallback_postflight.sql`;
- `supabase/tests/g2_phase20_guarded_coa_fallback_tests.sql`;
- `backoffice/src/lib/finance-master.ts`;
- `backoffice/src/app/api/master/finance-masters/route.ts`;
- `backoffice/src/app/api/master/finance-masters/accounts/[id]/route.ts`;
- `backoffice/src/components/FinanceMasterView.tsx`;
- `docs/runbooks/G2_PHASE20_GUARDED_COA_FALLBACK_ROLLOUT.md`.

User kemudian mengonfirmasi seluruh phase-20 rollout dan UI smoke `all good`.
Phase 20 ditutup `COMPLETE`. Fase berikutnya adalah Tax master karena masih
merupakan deliverable G2 dan menjadi dependency Product/Category, Sales,
Purchase, serta Finance. Preflight phase 21 hanya mengaudit dua entitlement
independen, akun INPUT/OUTPUT TAX, histori transaksi, assignment nullable, dan
snapshot gap. Tidak ada entitlement, Tax Rule, kalkulasi, checkout, atau journal
yang diaktifkan.

File phase-21 saat ini:

- `supabase/diagnostics/g2_phase21_tax_master_preflight.sql`;
- `docs/runbooks/G2_PHASE21_TAX_MASTER_PREFLIGHT.md`.

User mengonfirmasi phase-21 hanya menghasilkan `PASS` dan `INFO`. Tidak ada
blocker, review, atau histori yang membutuhkan keputusan bisnis. Foundation
phase 22 lokal menyediakan identitas Tax stabil, configuration version
effective-dated, entitlement guard per scope, nullable Product/Category
assignment, nullable Sales/Purchase snapshot, audit, RLS, dan guarded RPC.
Tidak ada entitlement/rate default yang diprovision dan tidak ada kalkulasi,
resolver, checkout, Supplier Invoice Tax, return/reversal, atau journal.

File utama phase 22:

- `supabase/migrations/20260723010000_g2_phase22_tax_master_foundation.sql`;
- `supabase/diagnostics/g2_phase22_tax_master_foundation_postflight.sql`;
- `supabase/tests/g2_phase22_tax_master_foundation_tests.sql`;
- `docs/runbooks/G2_PHASE22_TAX_MASTER_FOUNDATION_ROLLOUT.md`;
- update manifest, root README, router, dan handoff.

File utama phase 18:

- `supabase/diagnostics/g2_phase18_required_transaction_categories_preflight.sql`;
- `supabase/migrations/20260722180000_g2_phase18_required_transaction_categories.sql`;
- `supabase/diagnostics/g2_phase18_required_transaction_categories_postflight.sql`;
- `supabase/tests/g2_phase18_required_transaction_categories_tests.sql`;
- `docs/FINANCE_TRANSACTION_CATEGORY_USER_GUIDE.md`;
- `docs/runbooks/G2_PHASE18_REQUIRED_TRANSACTION_CATEGORIES_ROLLOUT.md`;
- update API/UI Finance Master, manifest, README, spec decision log, dan router.

## 4. Source of Truth per Development

### Aturan umum dan urutan gate

- `docs/POS_V1_MVP_REQUIREMENT_INDEX.md`
- `docs/POS_V1_IMPLEMENTATION_GATES.md`
- `docs/AI_AGENT_CONTINUATION_PLAYBOOK.md`
- `docs/PRE_BUILD_IMPLEMENTATION_GAP_AUDIT_2026-07-20.md`

### G2 Master Data

- Product/Category/Warehouse/Supplier:
  `docs/PRODUCT_STOCK_MASTERDATA_SPEC.md`
- UOM/weight/valuation: `docs/UOM_WEIGHT_VALUATION_SPEC.md`
- Customer/Walk-In/credit boundary:
  `docs/SALES_CUSTOMER_MASTERDATA_SPEC.md`
- Pricelist: `docs/SALES_PRICELIST_NOTES.md`
- Payment Method: `docs/PAYMENT_METHOD_MASTERDATA_SPEC.md`
- Transaction Category: `docs/TRANSACTION_CATEGORY_ACCOUNT_MAPPING_SPEC.md`
- Tax: `docs/TAX_ENGINE_SPEC.md`
- COA minimum: `docs/FINANCE_CORE_ACCOUNTING_SPEC.md`
- import framework: G2 section pada implementation gates dan gap `B-04`.

### G3 Stock Ledger

- `docs/PRODUCT_STOCK_MASTERDATA_SPEC.md`
- `docs/UOM_WEIGHT_VALUATION_SPEC.md`
- G3 section `docs/POS_V1_IMPLEMENTATION_GATES.md`
- gap `B-02` dan Inventory matrix pada pre-build audit.

Jangan masuk G4/G5 sebelum atomic stock ledger, FIFO, idempotency, nonnegative
concurrency, dan source document contract G3 stabil.

### G4 POS/Checkout/Offline

- `docs/POS_DEVELOPMENT_NOTES.md`
- Product/UOM/stock spec
- Payment Method, Tax, Pricelist, Customer, Expense, Deposit, dan evidence-link
  specs yang dirujuk requirement index.

### G5 Purchasing

- `docs/PRODUCT_STOCK_MASTERDATA_SPEC.md` bagian 9.4;
- `docs/POS_DEVELOPMENT_NOTES.md` bagian Stock Request/Goods Receipt;
- `docs/PURCHASE_MATCHING_TOLERANCE_SPEC.md`;
- `docs/DEBIT_CREDIT_NOTE_SPEC.md` untuk Return Supplier.

Flow wajib: `Stock Request → Supplier Order → Goods Receipt → Supplier Invoice → Payment`.
Supplier Order tidak membuat stock/AP; hanya Goods Receipt posted yang dapat
membentuk stock/FIFO/AP provisional.

### G6 Finance

- `docs/FINANCE_INTEGRATION_NOTES.md`
- `docs/FINANCE_CORE_ACCOUNTING_SPEC.md`
- `docs/FINANCE_REPORTING_AND_CUTOFF_SPEC.md`
- Transaction Category, Tax, matching, note, collection, Expense, Deposit specs.

## 5. Manual Gate Terakhir

Database Online Sale, Payment-Leg, true-concurrent Post, Offline allowance/sync,
Sales Return, Expense/Cash Deposit, dan Deposit Variance sudah ditutup pada
boundary masing-masing. Gate manual aktif sekarang adalah Phase-52 database
rollout. Authenticated smoke Customer Balance Phase-50 tetap perlu ditutup
sesuai `docs/runbooks/G4_PHASE50_CUSTOMER_BALANCE_OPERATIONAL_UI.md`.

File Pricelist yang sudah ditutup:

- `backoffice/src/lib/pricelist-master.ts`;
- `backoffice/src/app/api/master/pricelists/route.ts`;
- `backoffice/src/app/api/master/pricelists/[id]/route.ts`;
- `backoffice/src/components/PricelistMasterView.tsx`;
- integrasi menu pada `backoffice/src/app/page.tsx`;
- `docs/runbooks/G2_PHASE13_PRICELIST_API_UI_ROLLOUT.md`.

Evidence: Backoffice lint PASS, production build PASS, dan authenticated user
smoke diterima. API menggabungkan header/assignment/rule dari query terpisah
sehingga tidak bergantung pada nested PostgREST relationship.

Review final menemukan exact-one default Global belum sepenuhnya enforced.
Forward-only gate berikut sudah applied dan dikonfirmasi PASS:

- `supabase/migrations/20260722080000_g2_phase13_pricelist_default_guard.sql`;
- `supabase/diagnostics/g2_phase13_pricelist_default_guard_postflight.sql`;
- `supabase/tests/g2_phase13_pricelist_default_guard_tests.sql`;
- `docs/runbooks/G2_PHASE13_PRICELIST_DEFAULT_GUARD_ROLLOUT.md`.

Checksum migration `f4ce694...`; 6 postflight dan behavioral test PASS.
Forward fix memungkinkan perpindahan default secara atomic dan mengaudit
default lama. UX terbaru memakai harga akhir langsung: harga normal Rp5.000
menjadi Rp4.000 diisi `4000`; potongan per UOM hanya untuk tier Global.

## 6. Next Safe Step

Current G5 step (menggantikan instruksi rollout lama di bawah): jalankan seluruh
`supabase/diagnostics/g5_phase4_goods_receipt_preflight.sql` dan kirim semua row
`check_name,status,details`. `BLOCKER` wajib nol; `REVIEW` harus dijelaskan;
schema/RPC/lineage `SETUP` adalah expected baseline. Jangan membuat atau posting
Receipt/AP/jurnal sebelum hasil ini direview.

Catatan berikutnya di bagian ini adalah guard historis fase sebelumnya; jangan
menjalankan ulang migration yang sudah dinyatakan sukses user.

Jangan rerun migration `20260805090000` atau forward fix `20260805100000`.
Jalankan Phase-52 migration `20260805130000`, postflight, rollback-safe
behavior, regression Phase-4/8/10/49, G3 Phase-14, G1 Security Closure, lalu
closing postflight sesuai runbook. Hentikan pada FAIL/error dan kirim pesan
persisnya. Phase-50 authenticated smoke dua-user tetap perlu dilakukan sebelum
UI dinyatakan complete.

Jangan mengubah status Deposit/Session/exception/Financial Event secara direct.
Jangan membuka checkout usage/refund-to-balance, credit Ketul,
exceptional settlement, TEMPO, Ketul, Offline Customer Balance, bank matching,
reversal/replacement source aktual, jurnal G6, atau G5 Purchasing pada phase ini.

`/api/pos/sync` legacy tetap closed; Receipt Supplier/Purchase Return tetap G5.

Jangan rerun migration Phase 46, Phase 44, atau migration/forward fix Phase 42.

Jangan mengubah atau rerun migration Phase 30–34 yang sudah applied; explicit-code CSV
lama tetap compatibility surface selama transisi.
Product Brand tetap menunggu canonical master.
Permission granular per-user/submodule tetap follow-up access-control terpisah.
Jangan mengaktifkan resolver, checkout calculation, journal, e-Faktur, atau
official tax reporting.

UX follow-up wajib Customer: tambahkan dropdown `Customer induk` langsung pada
modal Edit Customer. Saat ini grouping tersedia pada panel terpisah dan tombol
baru aktif setelah minimal dua Customer non-sistem tersedia.

## 7. Update Log
| 2026-08-06 | Codex — Phase-8 behavioral fixture order fix | Error `FINAL_SUPPLIER_ORDER_LINES_IMMUTABLE` berasal dari fixture yang mengisi line setelah header final, bukan runtime Return | Fixture sekarang DRAFT → line → CONFIRMED; 61/61 parentheses, transaction rollback, diff check PASS | Jangan rerun migration; rerun behavioral test terbaru lalu postflight |
| 2026-08-06 | Codex — G5 Phase-8 Purchase Return foundation | Phase-7 user output seluruhnya PASS; menambahkan Cashier Draft, manager review/Post, exact Receipt FIFO consumption, Stock/Movement, append-only AP adjustment, Event HOLD, audit/idempotency/RLS | Migration 287/287 parentheses, checksum `ee1f7090...e1b22ba`; postflight/test/runbook dibuat; scoped diff check PASS; live rollout pending | Migration `20260806070000` → all-PASS postflight → behavior → closing postflight; setelah PASS baru UI PWA/Backoffice |
| 2026-08-06 | Codex — G5 Phase-7 Purchase Return preflight | User menerima Goods Receipt PWA; diagnostic SELECT-only Purchase Return memeriksa source receipt, kondisi/FIFO/Movement/AP provisional, category/event, reconciliation, schema/RPC, dan browser boundary | Metadata table memakai `pg_namespace`/`pg_class` tanpa dynamic relation parsing; local structural/mutation/diff checks PASS; live output pending | Jalankan preflight penuh; hanya schema/routine diharapkan `SETUP`, kirim seluruh output sebelum foundation |
| 2026-08-06 | Codex — G5 remaining-order UX + Phase-4 preflight | Order workspace mengurangi allocation order aktif per Request line, menyembunyikan baris fulfilled, dan menawarkan sisa partial; Goods Receipt readiness SELECT-only dibuat | Backoffice ESLint + TypeScript PASS; SQL mutation scan zero; parentheses 112/112; diff check PASS | User jalankan Phase-4 preflight penuh dan kirim seluruh output |
| 2026-08-06 | Codex — G5 Phase-3 Stock Request/Supplier Order UI | User menutup Phase-2 migration/postflight/behavior sukses; PWA request tanpa Supplier dan Backoffice Purchase order Draft/Confirm ditambahkan memakai RPC guarded | PWA lint/build PASS; Backoffice lint/build PASS; no schema migration; authenticated smoke pending | Smoke Request → Order dan buktikan Stock/FIFO/Finance zero-effect; setelah PASS lanjut Goods Receipt preflight |
| 2026-08-05 | Codex — G4 Phase-56 Customer Balance tender foundation | User menutup Phase-55 seluruhnya PASS; menambahkan full-balance ONLINE tender, Payment/receipt snapshot, append-only debit/cache/Event/audit, exact retry, WIND_DOWN closure, postflight/test/runbook | Migration 353 lines, postflight 190, behavior 264; delimiter/parentheses seimbang; SHA-256 `b31cbdc...9b297`; live rollout pending | Migration `20260805160000` → all postflight PASS → behavior → regression → closing postflight |
| 2026-08-05 | Codex — G4 Phase-57 Customer Balance tender POS UI | User mengonfirmasi corrected Phase-56 postflight dan behavior seluruhnya PASS; PWA memuat saldo/lifecycle, membuat mandatory full-balance leg otomatis, memblokir shortfall, memperbarui receipt/print, dan menutup Offline | PWA oxlint PASS; TypeScript/Vite production build + service worker PASS; authenticated tablet smoke pending | Restart/hard refresh dan jalankan smoke Phase-57; bila PASS lanjut STK-006 foundation |
| 2026-08-05 | Codex — Phase-56 postflight execution-chain correction | Live migration applied dan 11 checks PASS; satu false FAIL berasal dari `bool_and` yang keliru menuntut setiap routine memiliki seluruh marker. Diagnostic sekarang memeriksa gabungan tiga routine | User mengonfirmasi corrected postflight seluruhnya PASS dan behavioral test PASS | Phase-57 POS UI |
| 2026-08-05 | Codex — G4 Phase-55 POS negative-stock permission preflight | User menutup Phase-54 aman dan membuka STK-006; menambahkan SELECT-only audit current nonnegative data, Warehouse hard guard, shortage runtime, FIFO/HPP/replenishment gap, Offline boundary, direct writes, serta roadmap default-OFF | User mengonfirmasi seluruh preflight PASS; runtime tetap OFF | Lanjut Phase-56 balance tender sebelum STK-006 foundation |
| 2026-08-05 | Codex — G4 Phase-54 Customer Balance tender preflight | User menerima Phase-53; menambahkan SELECT-only audit mandatory full-balance usage, ACTIVE/WIND_DOWN lifecycle, ledger/cache, Customer/method/category/account, historical tender, runtime/snapshot/source gap, dan direct-write boundary | User output: tiga expected SETUP; seluruh invariant PASS; direct writes false; positive balance/history tender nol | Phase-55 negative-stock permission preflight, lalu kembali ke balance tender foundation |
| 2026-08-05 | Codex — G4 Phase-53 POS overpayment disposition UI | User menutup Phase-52 seluruhnya PASS; PWA menambahkan nominal aktual Transfer, pilihan returned/balance untuk selisih Cash/Transfer online, eligibility Customer/feature/offline, serta receipt/print credit snapshot | PWA oxlint PASS; TypeScript/Vite/PWA production build PASS; user menerima dan meminta lanjut | Phase-54 balance tender preflight |
| 2026-08-05 | Codex — G4 Phase-52 Customer Balance Sale credit foundation | Phase-51 live output seluruh invariant PASS/expected SETUP; menambahkan atomic ONLINE overpayment disposition, ledger/cache/Event/audit, Payment/receipt/expected-cash snapshot, Customer lock, exact replay, Offline fail-closed, dan compatibility Cash returned tanpa membuka balance tender | Migration 609 lines, postflight 216, behavior 313; parentheses/tags seimbang; postflight SELECT-only; migration SHA `e44a9f66...`; scoped diff check PASS; user mengonfirmasi rollout/regression/closing seluruhnya PASS | Phase-53 POS disposition UI |
| 2026-08-05 | Codex — G4 Phase-51 Customer Balance Sale credit preflight | Roadmap overpayment diperjelas: server atomic credit lalu UI POS disposition, baru balance usage; menambahkan SELECT-only audit Payment/change, snapshot, ledger source, account/category, identity, reconciliation, dan direct-write boundary | User output: seluruh invariant PASS; 3 expected SETUP; zero non-Cash overpayment, 1 historical Cash change tetap returned | Phase-52 atomic foundation |
| 2026-08-05 | Codex — G4 Phase-50 Customer Balance operational UI | Phase-49 dikonfirmasi user seluruhnya sukses; menambahkan Backoffice liability, koreksi, maker-checker review, statement, API guarded, custom modal/Escape, serta label bisnis tanpa UUID/account key | Backoffice lint PASS; production build PASS dengan 4 route Customer Balance; scoped diff check PASS | Restart Backoffice dan jalankan authenticated smoke dua-user sesuai runbook Phase-50 |
| 2026-08-05 | User confirmation — G4 Phase-49 closure | User mengonfirmasi seluruh rangkaian setelah digest forward fix sukses | Base/fix postflight, corrected behavior, regression, dan closing checks diterima PASS | Lanjut Phase-50 UI tanpa rerun migration |
| 2026-08-05 | Codex — Phase-49 pgcrypto digest forward fix | Behavior berhenti sebelum request insert karena RPC memakai `digest(text,text)` tanpa schema; Supabase menyediakan `extensions.digest(bytea,text)` | Forward migration `20260805100000`, 3-check postflight, manifest checksum `f607b3a0...6d3a8`, scoped diff check PASS; base migration tidak diubah/direrun | Jalankan forward fix → 3 PASS → rerun behavior terbaru |
| 2026-08-05 | Codex — Phase-49 behavior entitlement fixture fix | Behavioral test pertama berhenti `CUSTOMER_BALANCE_CREDIT_DISABLED` karena synthetic Company tidak otomatis memperoleh row `company_features`; fixture sekarang UPSERT entitlement rollback-only agar lifecycle trigger menerima INSERT/UPDATE | Error terjadi sebelum request/ledger/balance final effect; migration tidak berubah dan tidak perlu direrun; scoped diff check PASS | Rerun behavioral test Phase-49 terbaru, lalu regression/closing postflight bila PASS |
| 2026-08-05 | Codex — G4 Phase-49 Customer Balance foundation | Phase-48 user preflight ditutup tanpa blocker/error; menambahkan Company lifecycle, internal method, append-only ledger, correction maker-checker, statement, immutable audit, idempotency, RLS, dan Finance HOLD tanpa membuka checkout | Migration SHA-256 `63a4bdbc...9b82`; scoped diff check PASS; postflight/test/runbook local-ready; manual Supabase pending | Migration `20260805090000` → postflight all PASS → behavior → Phase-46/43/4/G1 regression → closing postflight |
| 2026-08-05 | Codex — G4 Phase-48 Customer Balance readiness preflight | Phase-47 user smoke ditutup aman; mengaudit entitlement, legacy balance/payment, internal method, category/account, Sale fail-closed, direct privilege, dan canonical gap | User melaporkan tanpa blocker/error; hanya Company internal-method provisioning BACKFILL; exact row output tidak dicopy ke chat | Phase-49 guarded foundation |
| 2026-08-05 | Codex — G4 Phase-47 Deposit variance operational UI | Phase-46 ditutup COMPLETE dari konfirmasi user; menambahkan Finance list/detail, responsible party, partial resolution, maker-checker review, role boundary, custom modal/Escape, dan runbook | Backoffice lint PASS; Next production build PASS (42 pages, 4 route variance); authenticated user smoke safe | Phase-48 Customer Balance SELECT-only preflight |
| 2026-08-04 | Codex — G4 Phase-46 Deposit variance resolution foundation | Phase-45 live preflight ditutup bersih; menambahkan responsible party, partial append-only allocation, maker-checker, exact retry, audit, dan Finance HOLD | User confirmed migration/postflight/behavior/regression all safe | Phase-47 operational UI |
| 2026-08-04 | Codex — G4 Phase-45 Deposit variance resolution preflight | Phase-44 approval smoke ditutup aman; membuat SELECT-only audit source/coverage, lifecycle, responsible party, allocation totals, category/account readiness, maker-checker/runtime gap, event, dan privilege | SQL 525 lines, parentheses 188/188, satu statement, scoped diff check PASS; live Supabase output pending | Jalankan seluruh Phase-45 preflight dan kirim output; jangan lanjut bila ada BLOCKER |
| 2026-08-04 | Codex — Phase-44 approve reason bugfix | Smoke approval Setor Kas memunculkan `REASON_REQUIRED` karena client mengirim `reason: ''` dan API mem-parsing optional text sebelum membedakan aksi | Approve sekarang menghilangkan field reason dan API mem-parsing reason hanya untuk Reject; Reject tetap wajib alasan | Restart Backoffice lalu Approve ulang dokumen SUBMITTED yang sama |
| 2026-08-04 | Codex — G4 Phase-44 Cash Deposit operational UI | User mengonfirmasi seluruh Phase-43 rollout/verification PASS; membuka PWA multi-Session create/submit dan Backoffice Finance list/detail/approve/reject tanpa schema baru | PWA lint + TypeScript/Vite/PWA build PASS; Backoffice ESLint + Next production build PASS; scoped diff check PASS; authenticated smoke pending | Restart kedua aplikasi dan jalankan smoke Phase-44; lalu closing postflight Phase-43 |
| 2026-08-04 | User confirmation — Phase-40 corrected behavior | User mengonfirmasi behavioral test Phase-40 sukses setelah fixture Company B diperbaiki | Atomic Cash execution, retry, stale version, rejected zero-effect, cross-Company isolation, document/event/drawer reconciliation rollback-safe PASS | Jalankan Phase-37/34/30/2/G1 regression lalu closing postflight |
| 2026-08-04 | Codex — G4 Phase-42 Cash Deposit preflight | User melanjutkan dari Phase-41; membuat SELECT-only audit Setor Kas multi-sesi, legacy deposit, closed Session, account/category, event/trigger, privilege, dan canonical gap | SQL 344 lines, parentheses 131/131, satu result query, scoped diff check PASS; live Supabase output pending | Jalankan seluruh Phase-42 preflight dan kirim semua output; jangan lanjut bila ada BLOCKER |
| 2026-08-04 | Codex — G4 Phase-43 Cash Deposit foundation | User mengonfirmasi Phase-42 aman; membuat multi-Session lifecycle, lock, expected/actual/variance, proof policy, approval/reject/cancel, audit, exception, dan Financial Event HOLD | Migration 791 lines; SQL delimiter scan, Store schema correction, scoped `git diff --check` PASS; manual Supabase belum dijalankan | Migration `20260804130000` → postflight all PASS → behavioral test → regressions Phase-40/37/34/2/G1 → closing postflight |
| 2026-08-04 | Codex — G4 Phase-41 Additional Expense operational UI | User menutup seluruh Phase-40 regression/closing postflight; membuka review tambahan dan non-Cash execution di Backoffice serta Cash execution pada active POS Session | Backoffice ESLint + Next production build PASS; PWA oxlint + TypeScript/Vite/PWA build PASS; user melanjutkan tanpa blocker | Lanjut POS-008 Deposit preflight tanpa membuka mutation/UI lebih dulu |
| 2026-08-04 | Codex — Phase-40 cross-Company behavioral fixture correction | Behavioral test berpindah ke Company B untuk negative tenant test, tetapi fixture B belum menyalakan `expense_enabled`, sehingga feature guard benar berhenti sebelum request-not-found guard | User error `EXPENSE_FEATURE_DISABLED` hanya di rollback-safe test; fixture B kini mengaktifkan Expense, test 343 lines/65–65 parentheses/SHA `7f3af4b5...`; migration tidak diubah atau diulang | Rerun behavioral test Phase-40 dari awal; setelah PASS lanjut regression |
| 2026-08-04 | Codex — G4 Phase-40 Additional Expense disbursement foundation | Phase-39 live output ditutup bersih; menambahkan lifecycle terminal, guarded review/reject, atomic Cash/non-Cash execution, exact retry, unique request-disbursement link, drawer isolation, audit, Finance HOLD, postflight, rollback test, dan runbook | User: seluruh Phase-39 invariant PASS dan expected SETUP tepat; migration/postflight/test 591/290/343 lines, parentheses 92/92, 134/134, 65/65; SHA `45e0112d...`, `0e04667e...`, `7f3af4b5...`; postflight mutation scan 0 dan `git diff --check` PASS; live migration applied, behavioral rerun pending | Rerun corrected behavior → Phase-37/34/30/2/G1 regression → closing postflight |
| 2026-08-04 | Codex — G4 Phase-39 Additional Expense disbursement preflight | Phase-38 ditutup COMPLETE; SELECT-only audit request lifecycle, runtime/event gap, zero-effect, tenant/payment/session, privilege, dan inventory dibuat | User melanjutkan tanpa error; mutation keyword 0; parentheses 115/115; `git diff --check` PASS | Jalankan seluruh Phase-39 preflight dan kirim semua output |
| 2026-08-04 | Codex — G4 Phase-38 Expense settlement operational UI | Phase-37 ditutup COMPLETE; POS actual/return Cash/request tambahan dan Backoffice review actual/return non-Cash dibuka melalui guarded RPC | User: Phase-37 all safe; PWA lint/build PASS; Backoffice lint/build PASS; `git diff --check` PASS | Authenticated role/effect smoke sesuai runbook Phase-38; additional execution tetap tertutup |
| 2026-08-03 | Codex — G4 Phase-37 Expense settlement foundation | Phase-36 live output bersih; menambahkan actual request/review, immutable settlement/return snapshots, Cash In + drawer IN, expected-cash/outstanding lifecycle, idempotency, Finance HOLD, participant RLS, and request-only additional disbursement | Migration 1053 lines/247–247 parentheses/8–8 blocks; postflight 314 lines/167–167; behavior 290 lines/55–55; checksums/scoped diff PASS. Supabase local DB lint unavailable karena local Postgres tidak berjalan; live rollout pending | Migration → postflight → behavior → Phase-34/30/2/G1 regression → closing postflight |
| 2026-08-03 | Codex — G4 Phase-36 Expense settlement preflight | User mengonfirmasi Phase-35 aman; menambahkan diagnostic SELECT-only actual/return/outstanding/additional disbursement, event-total reconciliation, lifecycle, Finance/drawer coverage, category-account, Cash return Session, aging, privilege, dan gap schema/enum/RPC | SQL 448 lines, 166/166 parentheses, satu statement, zero mutation; scoped diff check PASS; live Supabase output menunggu user | Jalankan seluruh preflight Phase-36; `SETUP` expected, `BLOCKER` wajib nol sebelum foundation |
| 2026-08-03 | Codex — G4 Phase-35 Expense disbursement operational UI | User menutup Phase-34 seluruhnya aman; menambahkan satu menu Expense PWA dengan tab pengajuan/Cash approved, Cash Session disbursement + expected-cash update, Backoffice non-Cash confirmation, authenticated server route, proof/idempotency/custom confirmation, dan explicit role/channel separation | PWA oxlint PASS; PWA TypeScript/Vite/PWA build PASS; Backoffice ESLint PASS; Next 16 production build PASS dengan route `/api/finance/expenses/[id]/disburse`; `git diff --check` PASS; authenticated cash/noncash smoke pending | Jalankan runbook Phase-35, lalu closing Phase-34 postflight; settlement/return/Cash In tetap closed |
| 2026-08-03 | Codex — G4 Phase-34 Expense disbursement foundation | Phase-33 live output bersih dengan dua approved Expense; menambahkan migration guarded initial disbursement, approval/payment/account snapshots, exact approved amount, Cash Session/drawer sufficiency + OUT movement, non-Cash Finance isolation, expected-cash integration, idempotency, audit, Finance HOLD, postflight, rollback test, manifest, dan rollout guide | Migration 591 lines/98–98 parentheses; postflight 343 lines/147–147 and SELECT-only; test 358 lines/72–72; scoped diff check PASS; SHA migration `28b27f47ff075bae3cae3940553b28797da320ca4ea11c6094eceda9addc9540`, postflight `b9d39329c7e539d5aeb75de89851e44e2bf52623bbed1dede11147a8d4d3a16e`, test `6629a799eb5815b8af894361c6e215508cab419e0decd56efa94d869d1900f3a`; live rollout pending | Migration → all-PASS postflight → behavior → Phase-30/26/2/G1 regressions → closing postflight |
| 2026-08-03 | User confirmation — G4 Phase-33 preflight | User output: four expected runtime SETUP, all data/reference/category/account/Session/privilege/reconciliation checks PASS; approved inventory two documents totaling 325000 | Live SELECT-only preflight complete; one Cash and one non-Cash approved fixture available; zero disbursement history | Rollout Phase-34 foundation; no direct/manual cash mutation |
| 2026-08-03 | Codex — G4 Phase-33 Expense disbursement preflight | User mengonfirmasi Phase-32 approval aman; membuat diagnostic SELECT-only untuk approved Expense, eligible payment/Store/Session, category/account, approval snapshot, event/drawer/expected-cash runtime, direct-write boundary, dan event-total reconciliation | SQL: 443 lines, 140/140 parentheses, satu statement, zero mutation token; seluruh referenced column diaudit terhadap migration aktif; scoped `git diff --check` PASS; live Supabase output menunggu user | Jalankan seluruh preflight Phase-33; jangan rollout pencairan bila ada BLOCKER |
| 2026-08-03 | Codex — Phase-32 approve reason bugfix | Smoke pertama memunculkan `Alasan wajib diisi` saat approve karena client mengirim `reason: ''` dan API memakai optional parser yang memvalidasi string kosong sebagai required | Approve kini tidak mengirim reason dan parser menetapkan `null` tanpa validasi; reject/cancel tetap required; Backoffice ESLint + production build PASS | Hard refresh lalu approve ulang Expense yang sama |
| 2026-08-03 | Codex — G4 Phase-32 Expense approval Backoffice UI | User mengonfirmasi pengajuan Phase-31 aman; menambahkan Finance navigation, tenant-scoped list/detail, role-aware approve/reject/cancel, optimistic version, required reason, user-facing snapshots/evidence, dan custom confirmation/Escape tanpa cash effect | Backoffice ESLint PASS; Next 16 production build PASS; dynamic routes `/api/finance/expenses`, `[id]/review`, `[id]/cancel` terdeteksi; authenticated role smoke pending | Uji approve + reject disposable, Accounting read-only, dan zero cash/stock/journal effect; lalu preflight disbursement |
| 2026-08-03 | Codex — G4 Phase-31 Expense request PWA UI | User menutup Phase-30 seluruhnya PASS; menambahkan entitlement-aware online Expense entry point, category/payment lookup, responsible party, nominal/description/evidence/target settlement, idempotent Draft + guarded Submit, status yang membedakan approval dari pencairan, custom modal/Escape, dan offline fail-closed | `pwa` oxlint PASS; TypeScript + Vite production build PASS; generated Expense chunk terpisah; authenticated tablet smoke pending | Restart/hard refresh; uji entitlement off/on, Cash dan Transfer, status, serta zero cash/stock/journal effect |
| 2026-08-03 | Codex — G4 Phase-30 Expense request/approval foundation | Phase-29 output diterima tanpa blocker; menambahkan sembilan tabel canonical, default policy/category untuk Company existing/future, guarded category/policy/Draft/Submit/Review/Cancel, immutable future-event tables, RLS/audit, feature default off, targeted retirement trigger Cash Advance legacy, dan concurrency-safe Draft idempotency | Audit schema exact `stores.status`, `pos_terminals.status`, Session/Payment/COA/Transaction Category/composite FK; parentheses migration/postflight/test `513/513`, `135/135`, `47/47`; mutation diagnostic hanya privilege strings; `git diff --check` PASS; SHA migration `499561965867459FE250B8FF33C1917BB4698B3A8EDA113740F2F71882BB89E3`, postflight `E5B6D733DD7626DE9E05CD53C8A0EF1054CFC0D0F18A03430EE322EAB5B7935F`, test `2052AEB01B6C265D33B6D446BB468C3AF1706FF24032DB699966452681863FC3`; live rollout pending | Jalankan migration → all-PASS postflight → rollback-safe behavior → Phase-26/2/G1 regressions |
| 2026-08-03 | User confirmation — G4 Phase-29 preflight | User mengirim output tanpa BLOCKER: seluruh readiness/integrity PASS, legacy rows zero, expected legacy trigger REVIEW dan nine-table canonical SETUP | Live SELECT-only preflight complete; satu active Store/Terminal/open Session serta Cash/Transfer ready | Rollout Phase-30 foundation; jangan membuka cash effect |
| 2026-08-03 | Codex — Phase-29 Store column correction | First live run failed before returning rows because preflight incorrectly assumed `stores.is_active`; corrected to verified canonical `stores.status = 'ACTIVE'` and re-audited every referenced column against repository schema/migrations | User error `42703`; failed statement SELECT-only/no side effect; corrected SQL static balance/mutation/diff checks pending | Rerun corrected Phase-29 preflight once and send full output |
| 2026-08-03 | Codex — G4 Phase-29 Expense/Cash Flow preflight | User mengonfirmasi Backoffice Return berhasil posting; menutup Phase-28 dan membuat SELECT-only audit legacy Cash Advance, tenant/value, trigger/Event, Store Cash/Transfer, Session, required category/account, entitlement, privilege, dan canonical schema gap | Phase-28 user smoke PASS; preflight 1 executable statement, parentheses 136/136, mutation scan zero, scoped diff check PASS | Jalankan seluruh Phase-29 preflight dan kirim semua output; jangan rollout bila ada BLOCKER |
| 2026-08-03 | Codex — G4 Phase-28 Sales Return Backoffice approval UI | User mengonfirmasi Draft Return berhasil; menambahkan Sales menu/list/detail user-facing, guarded post/cancel route, required-role boundary, optimistic version/idempotency, alasan cancel, custom confirmation/Escape, dan explicit open-session warning | Backoffice lint PASS; production build PASS; 3 dynamic Return route terdeteksi; authenticated role/effect smoke pending | Jalankan runbook Phase-28 dengan satu cancel disposable dan satu post; kirim hasil/notifikasi persis |
| 2026-08-03 | Codex — G4 Phase-27 Sales Return PWA Draft UI | Regression Phase-26 ditutup user; menambahkan modal Return online, invoice search, user-facing Product/UOM/Customer, qty tersisa, condition/Gudang Rusak, refund Cash/Transfer exact-total otomatis, Draft-only submit, Escape/backdrop, dan tablet layout | User: G4/G1 success, G3 Phase-14 seluruh invariant PASS dengan expected SETUP/DEFERRED; PWA lint PASS; production build PASS | Restart/hard refresh dan jalankan smoke Phase-27; setelah PASS bangun Backoffice approval/post |

| Tanggal | Agent/Turn | Perubahan | Evidence | Next gate |
|---|---|---|---|---|
| 2026-08-03 | User confirmation — Phase-26 lineage + behavior closure | User mengonfirmasi forward-fix migration, fix postflight, dan behavioral Return seluruhnya sukses | Return/refund/FIFO/Movement/Cash Session/idempotency/immutability/audit/Finance HOLD rollback-safe behavior PASS | Jalankan G4 Phase-10, G3 Phase-14, dan G1 Security Closure regression; UI tetap closed |
| 2026-08-03 | Codex — Phase-26 Return batch-lineage forward fix | Behavioral test membuktikan `source_batch_id` masih dikunci khusus Transfer oleh constraint G3; membuat migration forward-only yang mengizinkan exactly-one Transfer/Return lineage dan index Return line tanpa mengubah migration applied | User error `23514 product_batches_transfer_lineage_check`; transaction test rollback; parentheses migration 9/9 dan postflight 25/25; SHA-256 migration `AA6558B0E43F7897EE26C286FC6572AA5D7C8EF86076C092E3B4884D92C8C189`, postflight `54FCA51792711E3943452F038820627937C4972CCEB24C830A9867C6D7EA3ED2`; scoped `git diff --check` PASS | Apply `20260803020000` → all-PASS fix postflight → rerun behavior Phase-26 |
| 2026-08-03 | User confirmation — G4 Phase-26 migration/postflight | User mengonfirmasi migration Sales Return dan seluruh postflight sukses tanpa FAIL | Live ledger/schema/RPC/grant/invariant postflight all PASS; behavioral/regression belum dijalankan | Jalankan rollback-safe Phase-26 behavior; hanya setelah PASS lanjut G4 Phase-10/G3 Phase-14/G1 regression |
| 2026-08-03 | Codex — G4 Phase-26 Sales Return foundation | Phase-25 user output seluruh source PASS/expected SETUP; menambahkan 5 canonical tables, 4 guarded RPC, default required approval, cumulative quantity/refund guard, condition-based original FIFO restoration, Cash expected integration, RLS/grant boundary, audit/idempotency, Finance HOLD, postflight, rollback-safe behavior, dan rollout runbook | Parentheses migration 417/417, postflight 119/119, test 49/49; dollar tags balanced; SHA-256 migration `5FFD8A2CB6D1CADF1BD74D0C5167ED34D477259F50FC97ED2ED323F950167C57`, postflight `9D4094D0592BBFFA0A3A94EFADE5CCB3FAB99E80A3FCD92E516BB60FAAF04330`, test `E1811BDED208F10645E0AE04EDA5608323E8D96D63CFD34316FC6D6C450B4FEB`; scoped `git diff --check` PASS; live SQL pending | Migration `20260803010000` → all-PASS postflight → rollback-safe behavior → G4 Phase-10/G3 Phase-14/G1 regression; UI tetap closed |
| 2026-08-03 | User confirmation — G4 Phase-25 readiness | Dependencies, source header/line/Payment, totals, Bundle/FIFO, Offline state, warehouse, Finance catalog, dan browser boundary PASS; schema/routines expected SETUP | User output: 6 Sale, 6 line, 6 Payment leg, 6 stock requirement, 7 FIFO allocation; zero blocker | Roll out Phase-26 foundation only; jangan buka UI sebelum database behavior/regression lulus |
| 2026-08-03 | Codex — G4 Phase-25 Sales Return readiness preflight | Setelah user menutup Offline core, menambahkan SELECT-only audit source Sale/line/Payment/receipt, Bundle/FIFO, Offline terminal state, warehouse condition, refund method, Finance catalog, expected Return schema/RPC, dan browser write boundary; Return mutation/UI tetap tertutup | 1 executable statement; parentheses 147/147; SHA-256 `3963294354832AB194B44F95A14D5AA4FCD6DD2884BA7AA4A3ED7F9C6AC32459`; scoped `git diff --check` PASS; live SQL pending | Jalankan seluruh Phase-25 preflight dan kirim output; expected schema/routine `SETUP`, tetapi tidak boleh ada source `BLOCKER` |
| 2026-07-31 | Codex — Phase-22 payment/offline UAT correction | Single-payment allocation mengikuti total final otomatis, Cash over-tender dipisah sebagai `Uang diterima`/kembalian, summary kembalian ditambahkan, Offline snapshot dicoba otomatis saat Session online terbuka, dan blocked reason dibuat eksplisit; Customer Balance tetap deferred | PWA oxlint PASS; TypeScript/Vite production build + service worker PASS; `git diff --check` PASS; in-app browser tidak dapat attach karena environment sehingga authenticated visual smoke belum diklaim | User restart/hard refresh PWA; uji E2E-09/E2E-14/E2E-22 lalu warm-session Offline happy path; kirim exact blocker bila snapshot/allowance belum siap |
| 2026-07-30 | Codex — Phase-22 POS end-to-end UAT gate | Checklist 40 jalur Online/Offline, negative path, retry/recovery, final reconciliation, evidence, cleanup, dan batas warm-session didokumentasikan tanpa membuka cold-start atau modul deferred | Documentation-only; memakai Phase-12 postflight dan Phase-21 preflight existing sebagai oracle server; no schema/runtime change | User jalankan E2E disposable dan kirim dua output SQL + kegagalan per ID; hanya setelah PASS lanjut cold-start restore/conflict stress |
| 2026-07-30 | Codex — Phase-21 Offline checkout queue preflight | SELECT-only dependency/RPC/grant, UAT scope, allowance/Product/Payment, submission identity/final effect, Session guard, dan Stock–Movement–FIFO readiness audit | 1 executable statement; mutation line 0; parentheses 170/170; SHA-256 `11300EA1F048A3372BD73A19EC0720C599DACEEC5074C8A40CD37B29D1BADBB0`; `git diff --check` PASS | Jalankan seluruh preflight dan kirim semua PASS/SETUP/INFO/BLOCKER; checkout Offline tetap closed |
| 2026-07-30 | Codex — Phase-22 Offline checkout retained queue PWA UI | Phase-21 ditutup PASS/expected SETUP; Cart sekarang memakai snapshot pricing, Base-UOM allowance, exact Payment, retained commit, Slip Offline watermark, queue retry/status, dan final invoice acknowledgement secara fail-closed | User: seluruh Phase-21 invariant PASS, UAT scope SETUP; PWA oxlint PASS; TypeScript/Vite production build + service worker PASS; `git diff --check` PASS; browser connector environment gagal attach sehingga visual/authenticated UAT belum diklaim | Jalankan combined Phase-20/22 disposable tablet UAT; setelah sukses lanjut cold-start restore/conflict stress, bukan membuka deferred module |
| 2026-07-31 | Codex — Phase-23 Offline cold-start/conflict recovery preflight | Menambahkan SELECT-only audit dependency, browser boundary, immutable lifecycle, idempotent submit, controlled retry, status recovery, final-effect coverage, stale sync, dan Stock–Movement–FIFO; PWA cold-start tetap closed | 1 statement; mutation line 0; parentheses 151/151; SHA-256 `5A06EDCE0496D72E5F79BDD0EBD5926776F34DE013EE34DA48E4B60460D5E9AA`; scoped `git diff --check` PASS | Jalankan seluruh Phase-23 preflight; kirim semua hasil dan jangan mulai client bootstrap bila ada `BLOCKER` |
| 2026-07-31 | Codex — Phase-23 Offline cold-start/recovery PWA | User preflight seluruh core PASS dan UAT scope PASS; Dexie v5 operational scope, cached-auth exact match, offline catalog/queue restore, reconnect active-Company reconciliation, status-first recovery, dan controlled retry dibuat tanpa server migration | PWA oxlint PASS; TypeScript/Vite production build + service worker PASS; scoped `git diff --check` PASS; in-app browser tidak dapat diinisialisasi pada environment sehingga authenticated visual smoke belum diklaim | Restart/hard refresh online sekali, jalankan cold-start/negative UAT Phase-23, lalu rerun Phase-23 preflight + Phase-12 postflight |
| 2026-08-03 | Codex — Phase-23 Offline sync latency recovery | User menemukan satu order dapat tertahan pada UI hingga hitungan menit. Client sekarang membatasi status 10 detik, submit 15 detik, dan process 25 detik; outcome timeout dengan submission ID menjadi `NEEDS_CONFIRMATION`, status server diperiksa sebelum retry, `POSTED` tidak lagi menunggu refresh katalog penuh, cache hanya diverifikasi sekali per load, dan record final tidak lagi mengurangi allowance lokal dua kali | PWA oxlint PASS; TypeScript/Vite production build + service worker PASS; tidak ada schema/migration/data mutation | Hard refresh PWA, buka transaksi yang macet lalu `Periksa status`; setelah terminal state, buat satu transaksi Offline disposable dan catat durasi submit/process serta pastikan tombol bebas kembali maksimal sekitar 35 detik bila server tidak merespons |
| 2026-08-03 | Codex — Phase-24 Offline disconnect/reconnect stress preflight | User mengonfirmasi sync latency aman; SELECT-only gate dan runbook dibuat untuk baseline zero-nonterminal, fixture Session/Cash/allowance, RPC/browser boundary, identity/final effect, allowance ledger, Stock–Movement–FIFO, serta lima titik pemutusan jaringan | SQL aggregate-only; no schema/data/entitlement mutation; local structural verification pending | Jalankan seluruh Phase-24 preflight dan kirim semua hasil sebelum stress |
| 2026-08-03 | Codex — Phase-24 Terminal readiness correction | Eksekusi pertama berhenti sebelum menghasilkan output karena diagnostic memakai `pos_terminals.is_active`; referensi dikoreksi ke canonical `status='ACTIVE'` dan readiness diselaraskan dengan Store aktif, Gudang sale-source aktif, serta Cash effective/CASH_DRAWER | Error hanya SELECT parse; tidak ada mutation atau stress yang berjalan; structural verification diulang | Rerun seluruh Phase-24 preflight terbaru |
| 2026-08-03 | User confirmation — Phase-24 stress readiness | Seluruh preflight PASS/INFO; satu ready Session/Cash/allowance, zero nonterminal, dua posted submission existing valid, max attempt 1, dan seluruh identity/final-effect/allowance/stock reconciliation bersih | User mengirim output lengkap 14 checks; tidak ada BLOCKER/SETUP | Jalankan controlled disconnect saat `PROCESSING`, status-first recovery, lalu closing diagnostics |
| 2026-08-03 | User confirmation — Phase-24 Offline core closure | Controlled disconnect/reconnect berhasil, sync selesai melalui UI, dan user mengonfirmasi seluruh Phase-24/23/12 closing diagnostic PASS | Authenticated UI stress + database reconciliation all clear | Lanjut G4 Phase-25 Sales Return readiness preflight; Finance posting, TEMPO, Expense, Deposit, dan G5 Purchasing tetap tertutup |
| 2026-07-30 | Codex — Phase-20 Cashier Offline Allowance PWA UI | Cashier issue/release allowance sesi sendiri via RPC, server/local/queued quantity, custom confirmation, snapshot reconciliation, dan fail-closed cache invalidation tanpa membuka checkout | PWA oxlint PASS; TypeScript/Vite production build + service worker PASS; browser connector unavailable, authenticated tablet UAT pending | Restart Backoffice/PWA; jalankan combined Phase-19/20 UAT; checkout Offline tetap closed |
| 2026-07-30 | Codex — Phase-19 Offline Allowance operations UI | Active-Company manager API, scoped Session/Product-stock list, guarded issue/release/force-revoke, reason modal, status history, dan explicit disabled-entitlement state tanpa direct table write | Backoffice ESLint PASS; Next.js production build PASS; route terdaftar; browser connector unavailable, authenticated UAT pending | Restart Backoffice; jalankan disabled-state + disposable issuance/revoke UAT; checkout Offline tetap closed |
| 2026-07-30 | User confirmation — Phase-18 database closure | User mengonfirmasi seluruh rollout POS Customer quick-create sukses | Migration applied; postflight dan behavioral test all success | Jangan rerun Phase-18; kembali ke guarded Offline allowance operational UI |
| 2026-07-30 | Codex — Phase-18 POS Customer quick-create | RPC create-only active-Company/open-Session, automatic code, safe zero-credit contract, audit, PWA modal/select-refresh, serta selector Company adaptif PWA/Backoffice | PWA oxlint + production build PASS; Backoffice ESLint + production build PASS; SQL manual gate pending | Migration `20260730040000` → all-PASS postflight → rollback-safe behavior → restart dan tenant smoke |
| 2026-07-30 | Codex — Phase-16 Offline status drawer UX | Panel permanen dipindah ke tombol header `Offline` dan drawer kanan; indikator cache tetap terlihat, drawer tutup via tombol/Escape/backdrop, workspace checkout tidak lagi terdorong | PWA `oxlint` PASS; TypeScript/Vite production build PASS; visual browser connector unavailable, authenticated smoke pending | Restart PWA dan smoke tombol/drawer bersama closed-entitlement behavior |
| 2026-07-30 | Codex — Phase-17 guarded Offline policy Backoffice UI | Menu Pengaturan Modul dibuka bagi Owner/Admin/Store Manager sesuai scope; entitlement tetap Super Admin-only; default Company, override Toko, Terminal eligibility, custom confirmation/Escape, dan guarded API ditambahkan | Backoffice ESLint PASS; TypeScript/Next production build PASS; `/api/platform/offline-settings` terdaftar; authenticated role smoke pending | Restart Backoffice/PWA dan jalankan smoke Phase-16 + Phase-17; jangan aktifkan entitlement |
| 2026-07-30 | Codex — Phase-16 read-only Offline status/cache UI | Panel connection/scope/snapshot age/allowance, refresh message, close/logout invalidation, minute refresh, responsive tablet/mobile layout, dan lazy cache chunk dibuat tanpa membuka checkout | PWA `oxlint` PASS; production build PASS; main `471.65 kB`, cache chunk `102.84 kB`, no chunk warning; automated browser unavailable, manual smoke pending | Restart PWA dan jalankan closed-entitlement smoke sesuai runbook Phase-16 |
| 2026-07-30 | Codex — Phase-14 closure dan Phase-15 retained catalog cache | User menutup seluruh regression/closing postflight; Dexie v4 snapshot, guarded RPC adapter, scope/hash/freshness/invalidation, dan queue-aware allowance reconciliation dibuat tanpa membuka checkout | User: Phase-12/11/4/G1 + Phase-14 closing postflight all good; PWA `oxlint` PASS; TypeScript/Vite production build PASS | Read-only Offline status/cache UX; entitlement dan checkout tetap disabled |
| 2026-07-30 | Codex — Phase-14 corrected behavior closure | User mengonfirmasi behavioral test terbaru aman setelah rollback-safe feature upsert | Snapshot shape, Product price/Tax completeness, Session/Terminal scope, dan browser privilege behavior PASS; migration tidak berubah | Jalankan regression Phase-12/11/4/G1 lalu rerun postflight Phase-14 |
| 2026-07-30 | Codex — Phase-14 behavior feature-fixture fix | Behavior gagal sebelum snapshot karena test memakai `UPDATE` terhadap Company yang belum mempunyai entitlement row; fixture diperbaiki menjadi rollback-safe upsert dan explicit enabled assertion | User error `OFFLINE_POS_FEATURE_DISABLED`; test SHA-256 `46ea0d836fc3870858a0384b80c067c28574af7190a046231f3ce537b463aea1`; migration/RPC/postflight tetap valid | Rerun hanya behavioral test Phase-14 terbaru |
| 2026-07-30 | Codex — Phase-14 migration/postflight live | User menjalankan migration authoritative Offline catalog snapshot dan postflight; ledger, RPC, privilege boundary, serta closed entitlement PASS; Terminal policy tetap tidak diprovision | `migration_ledger`, `offline_catalog_snapshot_rpc`, RPC boundary, dan `offline_entitlement_remains_closed` PASS; source inventory INFO; zero Terminal policy expected SETUP | Jalankan rollback-safe behavioral test Phase-14 |
| 2026-07-30 | Codex — G4 Phase-14 authoritative Offline catalog snapshot | Live preflight diterima bersih; guarded Session/Terminal snapshot Product-UOM, Pricelist/rule, Sales Tax metadata, Payment Method, stock Gudang, dan allowance beserta postflight/test/runbook dibuat; feature dan PWA checkout Offline tetap tertutup | User: dependency/invariant PASS, RPC dan Terminal policy expected `SETUP`, entitlement disabled; migration SHA-256 `386a0edc...`; local structural/diff verification PASS | Migration `20260730010000` → postflight → rollback-safe behavior → Phase-12/11/4 + G1 regression |
| 2026-07-29 | Codex — G4 Phase-11 Offline Stock Allowance preflight | Phase-10 ditutup COMPLETE; diagnostic SELECT-only entitlement, Terminal/Session/Gudang, Payment offline, Stock–Movement–FIFO, identity, expected schema, dan browser boundary dibuat; offline tetap tertutup | GitHub checkpoint `cdd1e26` terverifikasi di `origin/main`; SQL SHA-256 `7724C17C...`; executable mutation keyword 0, satu statement, parenthesis balanced, `git diff --check` PASS | Jalankan seluruh Phase-11 preflight dan kirim semua hasil |
| 2026-07-29 | Codex — G4 Phase-11 Offline Stock Allowance foundation | Live preflight ditutup bersih; policy Company/Store/Terminal, reservation Base UOM, stock/session guard, release/revoke, immutable audit/history, closed submission envelope, postflight/test/runbook dibuat; sync/PWA tetap tertutup | User: seluruh blocker PASS, expected 5-table SETUP, entitlement disabled, terminal/payment/stock ready; migration SHA-256 `3dd7c002...`; local structural/diff checks | Migration `20260729180000` → all-PASS postflight → behavior → listed regression |
| 2026-07-29 | Codex — Phase-11 behavior Profile fixture fix | Test gagal sebelum behavior karena Auth insert trigger sudah membuat `profiles`; explicit fixture sekarang memakai idempotent `ON CONFLICT(id) DO UPDATE` | User error `profiles_pkey` UUID `...060091`; test SHA-256 baru `19fe98dc...`; delimiter/parenthesis/diff check PASS; migration tidak berubah dan tidak perlu direrun | Rerun hanya behavioral test Phase-11 terbaru |
| 2026-07-29 | Codex — G4 Phase-12 Offline submission/sync preflight | User menutup Phase-11 all success; diagnostic submission/hash/version, consumption, Sale/Payment snapshot, acknowledgement, payment exception/Finance, routine, Session guard, stock reconciliation, dan browser boundary dibuat; endpoint/PWA tetap closed | User: Phase-11 migration/postflight/corrected behavior/regression success; preflight SHA-256 `ca1a46e8...`; one statement, mutation keyword 0, balanced, diff check PASS | Jalankan dan kirim seluruh hasil Phase-12 preflight |
| 2026-07-29 | Codex — Phase-12 preflight routine-alias fix | Pemeriksaan routine memakai derived table yang hanya mengekspos `proname`, tetapi agregasi lama salah merujuk `p.oid`; filter diperbaiki menjadi `p.proname IS NULL` tanpa mengubah kontrak check | User error PostgreSQL `42703`; preflight SHA-256 baru `057b49101a9a087b255aef2b5ae81879e6dd3eff7da5ea91cf845f77587c0cac`; satu statement, mutation 0, parenthesis balanced, `git diff --check` PASS | Rerun hanya seluruh file preflight Phase-12 terbaru; tidak perlu rerun migration/test Phase-11 |
| 2026-07-29 | Codex — G4 Phase-12 canonical Offline Sale Sync database | Live preflight ditutup bersih; immutable client/server hash+version, snapshot price resolver, canonical Draft/Post, atomic allowance consumption, Payment verification exception, acknowledgement, failure rollback, postflight/test/runbook dibuat; PWA tetap tertutup | User: seluruh prerequisite/invariant PASS dan expected SETUP tepat pada objek baru; migration SHA-256 `a2c7865c...`; local delimiter/parenthesis/diff verification PASS, manual Supabase pending | Migration `20260729210000` → all-PASS postflight → behavior → Phase-11/8/4, G3 Phase-15, G1 regression |
| 2026-07-29 | Codex — Phase-12 postflight routine-signature fix | Live migration ledger, tables, columns, grants, RLS, triggers, dan reconciliation PASS, tetapi routine check false-fail karena `pg_get_function_identity_arguments()` menyertakan nama parameter. Expected routine sekarang diperiksa sebagai exact signature memakai `to_regprocedure()` | Perubahan hanya diagnostic SELECT-only; SHA-256 `da18d87cb07ebcddf283e613fe0aa98457522f08f91f8ea56d5cc2fd19e623c0`; satu statement, mutation keyword 0, parenthesis balanced, `git diff --check` PASS; migration yang sudah applied tidak diubah | Rerun hanya postflight Phase-12 terbaru; bila seluruh non-INFO PASS, lanjut behavior Phase-12 |
| 2026-07-29 | Codex — Phase-12 corrected postflight closure | User mengonfirmasi corrected postflight seluruhnya sukses; false-fail routine signature tertutup tanpa migration ulang | Migration ledger dan seluruh postflight invariant live PASS; behavioral test belum dijalankan pada turn ini | Jalankan hanya behavioral test Phase-12, lalu regression sesuai runbook |
| 2026-07-29 | Codex — Phase-12 behavioral closure | User mengonfirmasi behavioral test Offline Sale Sync PASS | Atomic price snapshot/variance, allowance consumption, canonical Sale effect, retry/idempotency, failure rollback, dan acknowledgement test selesai tanpa migration tambahan | Jalankan lima regression file sesuai runbook, lalu rerun postflight Phase-12 |
| 2026-07-30 | Codex — Phase-12 rollout closure dan Phase-13 retained queue | User mengonfirmasi lima regression serta postflight penutup PASS; Dexie v3 queue dan canonical RPC adapter dibuat tanpa membuka checkout offline | PWA lint PASS; production build PASS; payload/acknowledgement lokal tidak dihapus; no service-role/direct write; functional offline smoke belum berlaku | Lanjut snapshot catalog/pricing/Tax/Payment + allowance cache; entitlement tetap disabled |
| 2026-07-30 | Codex — G4 Phase-14 Offline catalog cache preflight | SELECT-only diagnostic authoritative snapshot RPC, Product-UOM, Pricelist, Tax, Payment, open Session/Terminal policy, allowance, submission, dan browser boundary dibuat; client resolver tidak ditebak | SHA-256 `0d05550e7461897e3962b3eea8d59b331c3ec9fead88cefacb649923073bb244`; one statement, mutation 0, parenthesis balanced, `git diff --check` PASS; live execution pending | Jalankan seluruh preflight Phase-14 dan kirim semua output termasuk INFO/SETUP |
| 2026-07-21 | Codex — G2 Supplier/Customer handoff | Supplier API/UI complete; label UOM memakai nama; Customer preflight clean; dokumen handoff dibuat | Backoffice lint/build PASS; live Customer preflight dari user | Customer foundation manual DB rollout |
| 2026-07-21 | Codex — G2 Customer foundation | Migration `20260722010000`, postflight, behavioral test, manifest, dan rollout runbook dibuat | Checksum manifest cocok; 13 postflight checks; `current_balance` bukan parameter RPC; `git diff --check` bersih; manual Supabase gate belum dijalankan | Jalankan migration → 13 PASS postflight → behavioral test |
| 2026-07-21 | Codex — G2 Customer API/UI | Database gate ditandai complete; API Customer/Category guarded dan UI dua tab dibuat; saldo read-only, Walk-In immutable | User: migration + 13 postflight + behavioral test PASS; Backoffice lint dan production build PASS | Restart Backoffice dan jalankan smoke fase 9 |
| 2026-07-21 | Codex — G2 Customer grouping/UX | Nama UOM user-facing, Escape modal, Customer parent satu tingkat, uniqueness UOM/Warehouse, pre/postflight/test/runbook | Backoffice lint/build PASS; migration checksum recorded; manual DB gate belum dijalankan | Jalankan dan kirim hasil preflight fase 10 |
| 2026-07-21 | Codex — G2 phase 10 preflight result | Preflight ditandai PASS; schema-cache error dikonfirmasi sebagai state sebelum FK migration | User menyatakan seluruh preflight PASS | Jalankan migration `20260722040000` → postflight → behavioral test |
| 2026-07-21 | Codex — G2 phase 10 self-embed fix | Nested PostgREST Customer self-join dihapus; grouping memakai `parent_customer_id` dari list tenant yang sama | User: migration/postflight/test PASS; Backoffice lint/build PASS | Restart dan ulang smoke menu Pelanggan |
| 2026-07-21 | Codex — G2 phase 11 Pricelist preflight | Customer menu smoke dinyatakan baik; empty-state grouping diperjelas; Pricelist SELECT-only preflight/runbook dibuat | Phase-10 DB gates PASS; Customer menu opens; Backoffice lint/build PASS; no Pricelist mutation | Jalankan dan kirim seluruh hasil Pricelist preflight |
| 2026-07-21 | Codex — G2 phase 12 Pricelist foundation | Global/Customer Pricelist, Store assignment, exact Product-UOM rule, immutable rule history, audit, guarded RPC, RLS, default Global backfill, dan nullable Sales pricing snapshot disiapkan | User phase-11 preflight: no blocker dan zero Sales history; checksum `e4ff626...`; 12 postflight checks; `git diff --check` clean; DB execution pending | Migration → 12 PASS postflight → behavioral test → compatibility smoke |
| 2026-07-21 | Codex — G2 phase 13 Pricelist API/UI | Database gate ditutup; guarded API, validation, menu/list/form Pricelist, Store scope, Customer scope, Global tier, dan nama UOM user-facing dibuat | User: migration + 12 postflight + behavioral test PASS; Backoffice lint/build PASS | Restart Backoffice dan jalankan smoke phase 13 |
| 2026-07-21 | Codex — G2 phase 13 default invariant review | Review menemukan default terakhir masih dapat dinonaktifkan; forward guard, atomic default handover + audit, postflight, dan test disiapkan tanpa mengedit migration applied | Phase-12 DB PASS; Phase-13 UI lint/build PASS; forward SQL execution pending | Jalankan `20260722080000` → 6 PASS → behavioral test → UI smoke |
| 2026-07-21 | Codex — G2 phase 13 direct final price UX | Default guard ditutup; form Pricelist diubah agar harga biasa diisi sebagai harga akhir, sementara potongan per UOM hanya tersedia pada quantity tier Global | User: forward migration + 6 postflight + test PASS; Backoffice lint/build PASS | Restart Backoffice dan smoke create/edit Pricelist |
| 2026-07-21 | Codex — G2 phase 14 Payment Method preflight | Pricelist UI smoke ditutup COMPLETE; SELECT-only Payment Method audit dan runbook dibuat tanpa mengubah checkout | User menyatakan Pricelist oke; SQL/docs only; local syntax/diff verification | Jalankan dan kirim seluruh hasil Payment Method preflight |
| 2026-07-22 | Codex — reusable Customer Pricelist correction | Payment preflight diterima bersih; keputusan Pricelist diubah menjadi reusable dan assignment dipindahkan ke Customer; preflight forward-fix dibuat | Payment: no blocker/history, satu expected default backfill; SQL correction masih SELECT-only | Jalankan dan kirim hasil reusable Customer Pricelist preflight |
| 2026-07-22 | Codex — reusable Customer Pricelist implementation | Preflight reusable PASS; forward migration, postflight, behavioral test, guarded RPC, API, dan dropdown Pricelist pada form Customer dibuat; Customer picker di Pricelist dihapus | Preflight live seluruh invariant PASS; lint PASS; production build PASS; `git diff --check` bersih; checksum migration cocok manifest | Migration `20260722100000` → 12 PASS → behavioral test → Customer/Pricelist smoke |
| 2026-07-22 | Codex — G2 phase 14 Payment Method foundation | Reusable Pricelist gate ditutup COMPLETE; Payment Method master, Store assignment, fee validation, default Tunai, audit/versioning, history/default guards, nullable payment snapshot, RLS/RPC, postflight/test/runbook dibuat | User: reusable Pricelist all pass; Payment preflight zero history/no blocker; migration checksum manifest cocok; 13 postflight checks; local static verification | Migration `20260722120000` → 13 PASS → behavioral test → compatibility smoke |
| 2026-07-22 | Codex — G2 phase 14 pending-trigger fix | Rollout pertama gagal dan rollback pada PostgreSQL `55006` karena default backfill meninggalkan deferred trigger event sebelum `ALTER TABLE ... ENABLE RLS`; migration mem-flush constraint event sebelum DDL berikutnya | Root cause cocok dengan urutan SQL; migration tetap unapplied karena satu transaction; checksum baru `5015d6c...`; `git diff --check` bersih | Rerun seluruh migration terbaru → 13 PASS → behavioral test |
| 2026-07-22 | Codex — G2 phase 15 Payment Method API/UI | Fixed DB gate ditutup COMPLETE; guarded GET/POST/PATCH, server validation, menu/list/form user-facing, Store scope, settlement, proof, fee, default, dan Escape modal dibuat tanpa checkout cutover | User: migration + 13 postflight + behavioral test PASS; Backoffice lint/build PASS | Restart dan smoke menu Metode Pembayaran sesuai runbook fase 15 |
| 2026-07-22 | Codex — G2 phase 16 Finance master preflight | Payment Method UI smoke ditutup COMPLETE; SELECT-only Transaction Category + minimum COA readiness audit dan runbook dibuat tanpa mengaktifkan Finance posting | User menyatakan Payment Method aman; 18 aggregate checks; mutation statement scan 0; `git diff --check` bersih | Jalankan dan kirim seluruh hasil phase-16 preflight |
| 2026-07-22 | Codex — G2 phase 16 Finance master foundation | Preflight live bersih; registry, minimum tenant COA, Category/versioned rule, fallback storage, exception queue, audit, nullable snapshots, RLS/RPC, postflight/test/runbook dibuat | 37 functions; 26 events; 36 COA template; 14 postflight checks; checksum `6b4f39b...`; manual DB execution pending | Migration → 14 PASS → behavioral test → compatibility smoke |
| 2026-07-22 | Codex — G2 phase 17 Finance master UI + living README | Root README dan maintenance rule dibuat; guarded Finance API/UI serta menu Kategori & COA ditambahkan; COA read-only dan posting tetap disabled | User: existing menu compatibility smoke aman; Backoffice lint PASS; production build PASS; route Finance master terdeteksi | Restart dan authenticated smoke menu Kategori & COA |
| 2026-07-22 | Codex — G2 phase 18 required Transaction Categories | 26 default categories, future-Company provisioning, immutable event/active/delete guard, pre/postflight/test, learning UI, user guide, runbook, manifest, dan living README dibuat | Live preflight PASS: one Company/26 backfill, one existing category, zero collision/missing event; lint/build PASS | Migration `20260722180000` → 11 PASS → behavioral test → UI smoke |
| 2026-07-22 | Codex — phase 18 postflight expected-count fix | Menukar expected count diagnostic ke nilai DDL yang benar: 2 trigger dan 3 private routine; migration/data tidak diubah | User result membuktikan actual `trigger_rows=2`, `routine_rows=3`; sembilan invariant lain PASS | Rerun postflight terbaru, lalu behavioral test |
| 2026-07-22 | Codex — phase 19 Finance history trigger fix | Root cause PostgreSQL 42703 diperbaiki lewat forward migration dengan table-first branch; postflight/regression test/runbook/manifest dibuat | Phase-18 fixture rollback; error stack membuktikan `NEW.account_type` dibaca pada Category record; checksum `5a713c7...`; static checks clean | Migration `20260722210000` → 5 PASS → phase-19 test → rerun phase-18 test |
| 2026-07-22 | Codex — G2 phase 20 COA/fallback preflight | Phase 18/19 ditutup COMPLETE; SELECT-only audit COA identity/hierarchy/history, compatible candidate, rule/fallback integrity, unresolved required function, RPC state, dan privilege dibuat | User: phase-19 migration + 5 postflight + regression + phase-18 rerun all PASS; diagnostic mutation scan pending | Jalankan dan kirim seluruh hasil phase-20 preflight |
| 2026-07-22 | Codex — G2 phase 20 guarded COA/fallback | Preflight diterima; guarded hierarchical COA, versioned Company fallback, audit/concurrency guard, postflight/test, API/UI, docs, dan manifest dibuat | Live: no blocker, 36 accounts, one valid contra review, 33 explicit resolution backfills; Backoffice lint/build PASS; DB execution pending | Migration `20260722230000` → 8 PASS → behavioral test → UI smoke |
| 2026-07-22 | Codex — G2 phase 21 Tax preflight | Phase 20 ditutup COMPLETE; SELECT-only audit entitlement independen, Tax COA, Product/Category assignment, history, snapshots, dan privileges dibuat | User: phase-20 full rollout/UI smoke all good; Tax diagnostic mutation scan local | Jalankan dan kirim seluruh hasil phase-21 preflight |
| 2026-07-22 | Codex — G2 phase 22 Tax foundation | Preflight Tax ditutup; effective-dated Tax master, entitlement/account/scope guard, nullable assignments/snapshots, audit/RLS/RPC, 14 postflight, test, runbook, dan manifest dibuat | User: phase-21 PASS/INFO only; static transaction/checksum/diff verification; DB execution pending | Migration `20260723010000` → 14 PASS → behavioral test → compatibility smoke |
| 2026-07-22 | Codex — G2 phase 23 Tax Master API/UI | Phase-22 DB gate ditutup COMPLETE; guarded GET/POST/PATCH, server validation, entitlement-aware list/form, effective versioning, akun user-facing, dan Escape modal dibuat | User: phase-22 all pass; Backoffice lint/build PASS; Tax routes terdeteksi | Restart dan smoke menu Aturan Pajak; assignment Product/Category tetap deferred |
| 2026-07-22 | Codex — G2 phase 24 Module Settings API/UI | Super Admin-only Settings per active Company dibuat dari katalog feature existing; toggle via audited `set_company_feature`, config existing dipertahankan, confirmation/Escape tersedia | Backoffice lint/build PASS; dynamic Settings API route terdeteksi; no schema migration | Combined smoke Settings + Aturan Pajak, lalu guarded Product/Category Tax assignment |
| 2026-07-22 | Codex — G2 phase 25 role-aware app shell | Dashboard diganti module launcher; Inventory/Sales/Finance/Team/Platform mengelompokkan submodule sesuai role; sidebar menjadi floating fast link, collapsible, scrollable, dan tidak mendorong content | Backoffice lint/build PASS; browser automation lokal tidak tersedia, authenticated visual smoke pending user | Smoke shell lintas ukuran/role; lanjut Tax assignment; granular user permission tetap fase terpisah |
| 2026-07-22 | Codex — phase 25 Contacts regrouping | Supplier dipindahkan keluar Inventory; Pelanggan, Supplier, dan User & Akses disatukan dalam Kontak; User & Akses tetap Company Admin/Owner/Super Admin only; Sales menjadi Sales & Pricing | UI-only regrouping; canonical API/RLS role boundary tidak diperluas | Rerun lint/build dan smoke launcher |
| 2026-07-22 | Codex — phase 25 Sales/Finance regrouping | Sales difokuskan pada Pricelist dan future Promo/Bundling; Metode Pembayaran serta Aturan Pajak dipindahkan ke Finance bersama Kategori/COA/Jurnal | UI-only regrouping; tidak membuat placeholder atau membuka deferred module | Rerun lint/build dan smoke launcher |
| 2026-07-22 | Codex — G2 phase 26 Tax assignment preflight | Shell/Settings/Tax Master ditutup pada boundary saat ini; SELECT-only audit entitlement, current Tax version, Category/Product assignment, redundant override, RPC state, dan direct write dibuat | SQL aggregate-only; no schema/data mutation; manual Supabase result pending | Jalankan preflight dan kirim seluruh hasil |
| 2026-07-22 | Codex — G2 phase 26 guarded Tax assignment | Preflight live ditutup PASS; effective-version/entitlement trigger diperkuat, Category/Product optimistic assignment RPC, audit, Category column write closure, dan atomic Product-UOM-Tax overload dibuat | Migration checksum manifest cocok; postflight/test/static checks local ready; manual DB execution pending | Migration `20260723040000` → all-PASS postflight → behavioral test |
| 2026-07-22 | Codex — G2 phase 27 Tax assignment API/UI | Phase-26 DB ditutup all pass; endpoint Tax options, guarded Category assignment, Category default UI, Product inheritance/override atomic, entitlement visibility, dan user-facing Tax names dibuat | Backoffice lint PASS; production build PASS; dynamic routes terdeteksi; browser visual automation tidak tersambung pada sesi ini | Restart dan authenticated smoke sesuai runbook phase 27 |
| 2026-07-22 | Codex — Home brand + G2 phase 28 preflight | User menutup Tax assignment smoke sebagai aman; brand KGS POS dijadikan tombol Home; SELECT-only audit resolver/snapshot dibuat tanpa mengaktifkan kalkulasi | Backoffice lint PASS; production build PASS; forbidden SQL mutation 0; `git diff --check` bersih; browser session tidak tersambung; manual Supabase result pending | Smoke brand Home, lalu jalankan phase-28 preflight dan kirim seluruh hasil |
| 2026-07-22 | Codex — G2 phase 28 private Tax resolver/calculator | Live preflight ditutup bersih; private effective-dated resolver dan deterministic IDR PER_LINE/PER_DOCUMENT calculator dibuat tanpa transaction cutover | User preflight: all invariant PASS, zero history/rule, checkout untouched; migration/postflight/test static verification local | Migration `20260723070000` → 7 PASS → behavioral test |
| 2026-07-22 | Codex — G2 phase 29 Import preflight | Phase-28 DB gate ditutup all pass; SELECT-only audit import legacy, ambiguity master, Product-UOM group, protected history, dan Opening Stock eligibility dibuat | User: phase-28 migration/postflight/test all pass; diagnostic aggregate-only, no stock/master mutation | Jalankan phase-29 preflight dan kirim seluruh hasil |
| 2026-07-22 | Codex — G2 phase 30 Import staging foundation | Preflight live bersih selain expected legacy REVIEW; tenant-scoped idempotent job/row/event staging, guarded upload/mapping RPC, RLS, audit, dan legacy quarantine dibuat | Live: zero duplicate/history, canonical Product-UOM PASS, 3 Opening-eligible pair; checksum/11-check/test static local | Migration `20260723100000` → 11 PASS → behavioral test |
| 2026-07-22 | Codex — G2 phase 31 Import identity validator | Phase-30 user rollout ditutup all PASS; validator dry-run tenant-safe untuk Category/UOM/Warehouse/Supplier, diff/warning, duplicate-file, partial row error, retry, postflight/test/runbook dibuat | Checksum manifest, 8 postflight checks, behavioral test static local; manual Supabase pending | Migration `20260723130000` → 8 PASS → behavioral test |
| 2026-07-22 | Codex — G2 phase 32 Import business validator | Phase-31 user rollout ditutup all PASS; forward trigger memperkaya preview UOM/Gudang/Supplier/Kategori sesuai manual CRUD tanpa commit | Checksum manifest, 7 postflight checks, four-master rollback test static local; manual Supabase pending | Migration `20260723160000` → 7 PASS → behavioral test |
| 2026-07-22 | Codex — G2 phase 33 Import partial commit | Phase-32 user rollout ditutup all PASS; guarded commit empat master memakai update confirmation, matched version, partial row subtransaction, audit, terminal retry, dan Product/stock exclusion | User mengonfirmasi migration, 9-check postflight, dan behavioral test seluruhnya PASS | Phase 34 API/UI |
| 2026-07-22 | Codex — G2 phase 34 Import API/UI | Owner/Admin API dan UI CSV untuk Category/UOM/Warehouse/Supplier: template/export, mapping, preview, exact update confirmation, partial result, error download, dan history | Backoffice lint PASS; production build PASS; tiga route terdeteksi; browser visual session tidak tersambung | Restart dan authenticated smoke sesuai runbook Phase 34 |
| 2026-07-23 | Codex — G2 phase 35 full Import/Export preflight | Inventaris seluruh master user-creatable, kontrak CSV fixed/versioned, dependency order, atomic groups, dan SELECT-only readiness audit | Static SQL safety review; dokumentasi contract/runbook/handoff diperbarui; manual Supabase result menunggu | Jalankan Phase-35 preflight dan kirim output lengkap |
| 2026-07-24 | Codex — Phase-35 live result + automatic-code design | Preflight ditutup bersih; UUID dikonfirmasi tetap canonical; user meminta kode teknis selain Product/Customer dihasilkan sistem | User output: seluruh 15 check PASS/INFO, 22 tabel, 12 RPC, zero ambiguity/invalid/nonterminal job | Tutup pengecualian COA/Tax business code lalu buat allocator additive |
| 2026-07-24 | Codex — Phase-36 automatic code preflight | Keputusan hybrid disetujui; delapan target master, prefix, immutable/new-row-only rule, fixed create/update CSV, diagnostic, runbook, README, gate, dan handoff diperbarui | Diagnostic SELECT-only; local static verification pending; manual Supabase result pending | Jalankan Phase-36 preflight dan kirim output lengkap |
| 2026-07-24 | Codex — Phase-36 automatic code foundation | Live preflight ditutup; private atomic counter/reservation, eight-table immutable trigger, five guarded overload, postflight/test/runbook/manifest dibuat tanpa UI cutover | User preflight: all PASS/INFO, 41 legacy preserved, zero job; migration checksum recorded; static verification local | Migration `20260724010000` → 11 PASS → behavioral test |
| 2026-07-24 | Codex — Phase-37 automatic code UI cutover | Database Phase 36 ditutup all PASS; delapan form/list/search dipindahkan ke nama dan API code-less; pengecualian kode bisnis tetap terlihat | User: Phase-36 migration/postflight/test all PASS; Backoffice lint/build PASS; CSV explicit-code lama sengaja dipertahankan | Restart dan authenticated smoke Phase 37, lalu full-import expansion |
| 2026-07-24 | Codex — Phase-38 code-less simple master import | Phase-37 smoke ditutup; public validator wrapper menyiapkan stable server code untuk empat master tanpa mengubah Phase 31/33 applied; validator Gudang menerima `WH-000001`; postflight/test/runbook/manifest dibuat | SQL transaction/delimiter checks dan `git diff --check` PASS; checksum `840a1a50...`; manual Supabase belum dijalankan | Migration `20260724040000` → 7 PASS → behavioral test |
| 2026-07-24 | Codex — Phase-39 code-less Import UI | Phase-38 DB ditutup all good; template create/export/preview empat master menyembunyikan kode; Warehouse Store reference memakai label/nama/kode user-facing dan server tenant resolution | User: Phase-38 all good; Backoffice lint PASS; production build PASS; dynamic Import routes terdeteksi | Restart dan authenticated smoke Phase 39 |
| 2026-07-27 | Codex — Phase-40 simple master import preflight + copy-paste handoff | Phase-39 smoke ditutup COMPLETE; prompt agent pengganti dan SELECT-only audit Customer Category/COA/Transaction Category dibuat | User menyatakan seluruh smoke aman; Phase-40 SQL/docs static verification lokal | Jalankan Phase-40 preflight dan kirim output lengkap |
| 2026-07-27 | Codex — Phase-40 remaining simple master import database gate | Preflight ditutup bersih; additive job type, validator, guarded partial commit, system-row protection, postflight/test/runbook/manifest dibuat | User preflight seluruh invariant PASS; SQL delimiter/parenthesis/diff checks local; Supabase rollout pending | Migration `20260727090000` → 10 PASS → behavioral test → Phase-38 regression |
| 2026-07-27 | Codex — Phase-40 COA UUID aggregate forward fix | Applied migration dipertahankan immutable; unsupported `min(uuid)` diganti secara forward-only menjadi `min(id::text)::uuid` | User error PostgreSQL 42883 tepat pada parent lookup; forward migration/postflight static-ready | Migration `20260727100000` → 4 PASS → rerun Phase-40 test → Phase-38 regression |
| 2026-07-27 | Codex — Phase-41 remaining simple master Import UI | Customer Category, COA, dan Transaction Category ditambahkan ke template/export/mapping/preview; system rows dijelaskan export-only | User menutup Phase-40 DB all success; Backoffice lint/build PASS | Authenticated smoke sesuai runbook Phase 41 |
| 2026-07-27 | Codex — Phase-42 grouped Product Import preflight | Phase-41 smoke ditutup PASS; diagnostic atomic Product/Product-UOM, reference, Tax, history, RPC, dan job readiness dibuat | SELECT-only static review; live Supabase result pending | Jalankan Phase-42 preflight dan kirim seluruh output |
| 2026-07-27 | Codex — Phase-40 forward-fix diagnostic correction | Postflight diubah dari full function-definition pattern menjadi direct `pg_proc.prosrc` inspection tanpa menjalankan validator | User reached step 2 and reported relation `v_parent_id`; forward migration treated applied | Rerun latest 4-check postflight only, then both behavioral tests |
| 2026-07-27 | Codex — Phase-42 grouped Product Import database | Live preflight ditutup PASS; grouped Product/Product-UOM validator, atomic guarded commit, history lock, postflight/test/runbook dibuat | User: preflight all pass; `git diff --check` clean; local SQL structural review; manual DB execution pending | Migration `20260727130000` → 11 PASS → behavioral test → Phase-40/38 regression |
| 2026-07-27 | Codex — Phase-42 create-job whitelist fix | Rollout pertama rollback pada brittle `pg_get_functiondef` text match; migration unapplied. Dynamic rewrite diganti full stable RPC body dengan signature/behavior lama dan tambahan `PRODUCT` | User error `MIGRATION_PRECONDITION_FAILED: create job whitelist changed`; transaction rollback menjaga schema/data lama | Rerun seluruh migration Phase 42 terbaru dari awal |
| 2026-07-27 | Codex — Phase-42 COMPLETE event forward fix | Migration utama applied; behavioral test rollback saat audit memakai event `COMMIT` yang tidak ada dalam constraint canonical | User error PostgreSQL 23514; canonical Phase-33/40 implementation memakai `COMPLETE`; forward migration/postflight local-ready | Migration `20260727140000` → 4 PASS → rerun Phase-42 test → Phase-40/38 regression |
| 2026-07-27 | Codex — Phase-43 grouped Product Import UI | Phase-42 database ditutup COMPLETE; Product ditambahkan ke template/export/mapping, preview dikelompokkan per `product_key`, dan semua referensi operasional memakai nama | User: forward fix/postflight/behavior/regression all pass; Backoffice lint PASS; production build PASS | Restart dan authenticated smoke sesuai runbook Phase 43 |
| 2026-07-27 | Codex — Phase-44 Product-Supplier Import preflight | Diagnostic SELECT-only untuk dependency Phase 42, reference aktif, UOM pembelian, existing relation, preferred uniqueness, guarded RPC, privilege, dan job readiness dibuat | Contract/source/RPC review; SQL aggregate-only; manual Supabase result pending | Jalankan preflight Phase 44 dan kirim seluruh output |
| 2026-07-27 | Codex — Phase-44 Product-Supplier Import database | Live preflight ditutup bersih; additive job type/dispatcher, guarded validator/partial commit, preferred switch ordering, postflight/test/runbook/manifest dibuat | User output seluruh blocker PASS; local checksum/diff/SQL structural checks; manual Supabase pending | Migration `20260727160000` → 11 PASS → behavioral test → Phase-42/40/38 regression |
| 2026-07-27 | Codex — Phase-45 Product-Supplier Import UI | Phase-44 DB ditutup COMPLETE; fixed template/export, SKU/nama references, preferred-switch UX, preview/error labels tanpa UUID ditambahkan | User: seluruh Phase-44 rollout PASS; Backoffice lint PASS; production build PASS | Restart dan authenticated smoke sesuai runbook Phase 45 |
| 2026-07-28 | Codex — Phase-46 Minimum Stock Produk-Gudang preflight | Phase-45 smoke ditutup; kontrak konfigurasi terpisah dari saldo dan diagnostic aggregate-only untuk pair/base UOM/saldo/movement/reference/job/schema dibuat | User melanjutkan setelah Phase-45; SQL tanpa mutation; manual live result pending | Jalankan Phase-46 preflight dan kirim seluruh output |
| 2026-07-28 | Codex — Phase-46 Minimum Stock database | Live preflight ditutup bersih; settings/audit, guarded optimistic RPC, fixed import dispatcher/validator/commit, postflight/test/runbook/manifest dibuat | User: seluruh preflight PASS/INFO, 3 eligible pair, zero balance/movement; checksum manifest recorded; manual rollout pending | Migration `20260728090000` → 12 PASS → behavior → Phase-44/42/40/38 regression |
| 2026-07-28 | Codex — app shell Back + breadcrumb | Phase-46 rollout ditutup dari konfirmasi user; history view internal, tombol Kembali, dan breadcrumb Beranda/Modul/Halaman diterapkan global serta direset saat Home/Company berubah | Backoffice lint PASS; production build PASS (28 static/dynamic app routes); authenticated click smoke menunggu user | Restart Backoffice, smoke navigation, lalu Phase-47 Minimum Stock UI |
| 2026-07-28 | Codex — Phase-47 Minimum Stock API/UI | Guarded API list/create/update, Inventory page, Base-UOM threshold UX, fixed template/export/preview/error guidance, dan runbook dibuat tanpa schema/stock mutation | Backoffice lint PASS; production build PASS (29 pages, dua route Minimum Stock); authenticated smoke pending | Restart dan jalankan smoke Phase 47, lalu audit exit G2 |
| 2026-07-28 | Codex — G3 Phase-1 Opening Stock preflight | SELECT-only audit dependency, Product-Gudang eligibility, saldo/movement/FIFO, Finance readiness, enum, dan missing canonical schema dibuat | Static review against current schema; live Supabase result pending | Jalankan preflight penuh dan kirim seluruh hasil sebelum migration Opening Stock |
| 2026-07-28 | Codex — G3 Phase-1 Opening Stock database | Live preflight ditutup bersih; Draft/Posted schema, guarded save/post RPC, atomic movement-balance-FIFO-HOLD event, audit/idempotency, postflight/test/runbook dibuat | User: 13 invariant PASS, 3 eligible pair, zero stock history; local static/diff checks; manual Supabase pending | Migration `20260728120000` → all postflight PASS → behavior → Phase-46/44/G1 regression |
| 2026-07-28 | Codex — G3 Phase-2 Opening Stock API/UI | User menutup seluruh database gate; guarded Draft/Posting API, Inventory UI, dan detail bukti saldo/movement/FIFO dibuat | DB user all success; Backoffice lint PASS; production build PASS (30 pages); `git diff --check` PASS | Restart Backoffice dan jalankan authenticated smoke runbook Phase 2 |
| 2026-07-28 | Codex — G3 stock actual/minimum alert read model | Gap smoke ditemukan: canonical Product dan Minimum Stock belum membaca saldo hasil Posting; stock overview API, total/per-Gudang display, dan low-stock indicator ditambahkan | Backoffice lint PASS; production build PASS (31 pages) | Restart, pastikan dokumen POSTED, cek Produk & Stok lalu Minimum Stock |
| 2026-07-28 | Codex — G3 Phase-3 Stock Real roadmap alignment | Source-of-truth diaudit ulang; Stock Real dipisahkan dari Product/Minimum config dan dibuat read-only dengan On Hand/Available/FIFO/last movement/filter | Backoffice lint PASS; production build PASS (31 pages); `git diff --check` PASS | Smoke Stock Real; setelah PASS lanjut Kartu Stok, bukan G4/G5 |
| 2026-07-28 | Codex — G3 Phase-4 Stock Movement preflight | Existing ledger dibandingkan dengan minimum Kartu Stok contract; SELECT-only audit dan runbook dibuat tanpa mutation | Static SQL review; live Supabase result pending | Jalankan preflight penuh dan kirim seluruh output |
| 2026-07-28 | Codex — G3 Phase-4 canonical Stock Movement database | Live preflight ditutup bersih; additive snapshot/backfill/enrichment, immutable guard, source uniqueness, postflight/test/runbook dibuat | User: 11 invariant PASS, 1 Opening row/pair/source, zero mismatch; static checks pending | Migration `20260728150000` → postflight → behavior → Phase-1/46/G1 regression |
| 2026-07-28 | Codex — G3 Phase-5 Stock Movement API/UI | User menutup canonical database all good; API tenant-scoped dan read-only Kartu Stok dengan snapshot, nama bisnis, source/actor aman, serta filter dibuat | Backoffice lint PASS; production build PASS (32 pages); authenticated smoke pending | Restart dan jalankan smoke Phase 5; G4/G5 tetap tertutup |
| 2026-07-28 | Codex — G3 Phase-6 Stock Transfer preflight | Kartu Stok smoke ditutup PASS; SELECT-only audit dibuat untuk legacy unsafe RPC, transfer pair/snapshot, balance/FIFO, Base UOM, Finance category, privilege, dan missing canonical document schema | SQL aggregate-only; no mutation; local static/diff checks | Jalankan seluruh preflight dan kirim output; Transfer mutation belum dibuka |
| 2026-07-28 | Codex — G3 Phase-6 canonical Stock Transfer database | Live preflight ditutup bersih; Draft/Posted/Canceled document, atomic Base-UOM balance, FIFO relocation/lineage, paired movement, role/idempotency/audit, legacy RPC retirement, postflight/test/runbook dibuat | User: all blockers PASS, zero Transfer history, 1 positive source/3 warehouses; checksum/static checks local | Migration `20260728180000` → 15 PASS → behavior → Phase-4/1/46/G1 regression |
| 2026-07-28 | Codex — G3 Phase-7 Stock Transfer API/UI | Database gate ditutup all success; guarded create/edit/post/cancel, source balance UX, movement/FIFO proof, role-aware Inventory menu, dan nomor Transfer di Kartu Stok dibuat | User: DB rollout/regression all success; Backoffice lint PASS; production build PASS (33 pages); `git diff --check` PASS | Restart dan authenticated smoke sesuai runbook Phase 7 |
| 2026-07-28 | Codex — G3 Phase-8 Stock Adjustment preflight | Transfer authenticated smoke ditutup; roadmap menempatkan canonical Adjustment sebelum Opname; diagnostic legacy/reason/balance/FIFO/Finance/privilege/schema dibuat | User menyatakan Transfer all success; 16 checks, forbidden mutation 0, dan `git diff --check` PASS | Jalankan preflight Phase 8 dan kirim seluruh output |
| 2026-07-28 | Codex — G3 Phase-8 canonical Stock Adjustment database | Live preflight ditutup bersih; reason master, final-quantity Draft/Posted/Canceled document, FIFO gain/loss, immutable Movement, Finance HOLD, role/idempotency/audit, postflight/test/runbook dibuat | User: seluruh blocker PASS, zero legacy/backfill, 2 positive FIFO layers/pairs; SHA-256 `602259e7...`; delimiter dan `git diff --check` PASS | Migration `20260728210000` → 16 PASS → behavior → Transfer/Movement/Opening/Minimum/G1 regression |
| 2026-07-28 | Codex — G3 Phase-9 Stock Adjustment API/UI | User menutup seluruh database gate; guarded API/UI final-quantity, reason direction, gain-cost override, Draft/Post/Cancel, FIFO/value proof, serta Kartu Stok source dibuat | User: DB all good; Backoffice lint PASS; production build PASS (34 pages); authenticated smoke pending | Restart dan jalankan smoke Phase 9; setelah PASS baru preflight Opname |
| 2026-07-28 | Codex — G3 Phase-10 Stock Opname preflight | User melanjutkan setelah Adjustment smoke; kontrak blind count nonblocking, recount, per-line supersede, dan posting via canonical Adjustment diaudit; diagnostic/runbook dibuat tanpa mutation | 22 aggregate checks; static SQL dan diff verification lokal | Jalankan preflight penuh dan kirim seluruh output; migration Opname belum dibuka |
| 2026-07-28 | Codex — G3 Phase-10 canonical Stock Opname database | Live preflight ditutup bersih; legacy table diperluas dengan blind-safe RPC, movement-window recount, attempt audit, supersede, dan atomic Adjustment posting | User: seluruh invariant PASS, zero legacy/overlap/backfill; checksum `23e50261...`; 14-check postflight dan behavior local-ready | Migration `20260728230000` → 14 PASS → behavior → Phase-8/6/4/1/46/G1 regression |
| 2026-07-28 | Codex — G3 Phase-11 Stock Opname Backoffice API/UI | Database gate ditutup all success; tenant-scoped report/review, recount/post/cancel RPC bridge, attempt timeline, Adjustment proof, role-aware Inventory menu, dan Escape modal dibuat | User: Phase-10 rollout/regression all success; Backoffice lint PASS; production build PASS (35 pages); four Opname routes detected | Restart dan authenticated smoke sesuai runbook Phase 11; POS blind count tetap G4 |
| 2026-07-28 | Codex — G3 Phase-12 Bundle foundation preflight | SO end-to-end smoke dicatat menunggu POS G4; sisa G3 dialihkan ke SELECT-only audit Bundle composition, UOM, virtual stock, privilege, dan guarded RPC gap | Existing Bundle table/RPC/spec audit; diagnostic aggregate-only; no schema/stock/checkout mutation | Jalankan Phase-12 preflight penuh dan kirim seluruh output |
| 2026-07-28 | Codex — G3 Phase-12 canonical Bundle foundation database | Live preflight ditutup bersih; atomic Product+composition, derived weight, immutable type, hard virtual-stock guard, audit/version, private expansion, reviewer availability, postflight/test/runbook dibuat | User: all invariant PASS, zero Bundle/component/backfill/physical stock; checksum `7a5c1fbd...`; local delimiter/diff verification | Migration `20260729010000` → 14 PASS → behavior → Product/Opname/Adjustment/Transfer/Movement/Opening/G1 regression |
| 2026-07-28 | Codex — G3 Phase-13/14 Bundle UI closure dan inventory-core exit preflight | Bundle DB/UI ditutup dari continuation user; SELECT-only reconciliation saldo–Movement–FIFO, source coverage, Bundle/Opname/browser invariant, fixture stress, serta explicit G4/G5 deferral dibuat | User: Bundle all good; diagnostic mutation scan dan diff check lokal | Jalankan Phase-14 preflight penuh dan kirim semua row |
| 2026-07-28 | Codex — G3 Phase-15 inventory-core stress behavior | Phase-14 live preflight ditutup PASS; rollback-safe fixture menguji two-layer FIFO, idempotent retry, 20 repeated Transfer contenders, Adjustment gain, reconciliation, dan Bundle virtual | User: seluruh core invariant PASS; `SETUP` dan G4/G5 `DEFERRED` expected; delimiter/diff check PASS; test SHA-256 `09CEBC17...0742` | Jalankan Phase-15 test, rerun Phase-14 preflight dan G1 closure |
| 2026-07-28 | Codex — G1/G2/G3 regression fixture compatibility fix | Rollback-only synthetic Movement fixtures memakai `PURCHASE`/`PURCHASE_RETURN`; canonical Adjustment hanya boleh berasal dari dokumen Adjustment lengkap; assertion history/RLS/FIFO tetap identik | User mengonfirmasi G1 closure terbaru SUCCESS setelah error PostgreSQL 23514 diperbaiki; audit juga menutup lima regression fixture lama dengan pola sama | Jalankan Phase-15 stress, lalu rerun Phase-14 preflight; tidak ada migration |
| 2026-07-28 | Codex — G3 closure dan G4 Phase-1 POS readiness preflight | Phase-14 rerun ditutup aman; SELECT-only audit dibuat untuk config POS, Session, Product-UOM/Bundle, Payment/Pricelist/Tax, Sale history, runtime snapshot, direct-write, dan legacy checkout authority | User: seluruh G3 core invariant PASS, `SETUP` rollback-expected, G4/G5 `DEFERRED`; diagnostic mutation scan 0 dan `git diff --check` PASS | Jalankan G4 Phase-1 preflight dan kirim seluruh output |
| 2026-07-28 | Codex — G4 Phase-2 canonical Cashier Session foundation | Phase-1 output direview valid; additive Session warehouse/cash/version, one-open guard, opening/closing stock snapshots, guarded open/close RPC, idempotent retry, RLS/audit, postflight/test/runbook dibuat tanpa checkout cutover | User: dependency/config/data PASS; expected blockers hanya legacy checkout/price/runtime; delimiter/mutation scan, manifest hash, dan `git diff --check` PASS; live rollout pending | Migration `20260729040000` → 13 PASS → behavioral test → G3/G1 regression |
| 2026-07-29 | Codex — G4 Phase-3 Atomic Sale runtime preflight | Phase-2 ditutup COMPLETE; diagnostic SELECT-only memetakan Session, legacy authority, pricing/payment/tax, Product-UOM/Bundle, Stock–Movement–FIFO, Finance category, snapshot/allocation, dan Draft/Post RPC gap | User mengonfirmasi Phase-2 all success; SQL static verification lokal | Jalankan Phase-3 preflight penuh dan kirim seluruh output; checkout tetap tertutup |
| 2026-07-29 | Codex — G4 Phase-4 Atomic Sale runtime database | Live preflight ditutup sesuai baseline; server price/Draft/Post, shortage-safe no-effect, FIFO/Bundle, Payment/Tax/rounding, receipt, Finance HOLD, idempotency, postflight/test/runbook dibuat; legacy browser checkout retired | User: seluruh prerequisite/data invariant PASS, expected 2 legacy blocker + 4 setup; migration SHA-256 cocok manifest; delimiter/parenthesis seimbang; postflight SELECT-only 17 checks; behavioral test rollback-safe; `git diff --check` bersih | Migration `20260729070000` → 17 PASS → behavioral test → G4/G3/G2/G1 regression |
| 2026-07-29 | Codex — G4 Phase-5 POS online integration | Phase-4 user gate ditutup clear; PWA mock diganti login/context/Session/real catalog/canonical Draft/Post/shortage/receipt; Backoffice legacy checkout route diganti canonical action dan offline sync dikarantina | PWA lint/build PASS; Backoffice lint/build PASS (36 app routes); active-path scan zero `MOCK_PRODUCTS`/legacy checkout; authenticated smoke pending | Jalankan smoke Phase-5; setelah PASS lanjut Draft lock/list + split payment |
| 2026-07-29 | Codex — G4 Phase-5 PWA tablet/Pricelist/receipt closure | Terminal/Gudang user smoke diterima; PWA tablet-first, reset POSTED, receipt print-tab, Customer Pricelist AUTO/override, guarded wrapper/resolver, postflight/test/runbook dibuat | PWA lint/build PASS; Backoffice lint/build PASS (36 routes); SQL structural/diff check PASS; browser preview connector gagal attach; live DB/UI smoke pending | Migration `20260729100000` → 4 PASS → behavior/regression → hard refresh + tablet smoke |
| 2026-07-29 | Codex — G4 Phase-5 Moka-like tablet hierarchy revision | Redesign pertama ditolak user karena hierarchy/tombol lemah; shell POS dirombak menjadi two-pane high-contrast, numbered checkout stages, solid add/category/actions, dan sticky total/action tanpa dependency baru | PWA lint PASS; production build PASS; browser preview connector tidak dapat attach; authenticated visual smoke pending | Restart/hard refresh PWA dan validasi hierarchy pada tablet sebelum rollout closure dilanjutkan |
| 2026-07-29 | Codex — G4 Phase-6 Sale Draft edit-lock preflight | Phase-5 rollout/PWA smoke ditutup all clear; SELECT-only diagnostic dan runbook dibuat untuk Draft lifecycle, same-Store continuation, stale age, side effects, lock/audit/RPC/schema/privilege | Source-of-truth audit terhadap canonical Sale runtime dan approved Draft contract; local SQL safety verification pending | Jalankan Phase-6 preflight penuh dan kirim seluruh output |
| 2026-07-29 | Codex — G4 Phase-6 Sale Draft edit-lock foundation | Live preflight ditutup bersih; Draft numbering/metadata, same-Store visibility/list, heartbeat lock, confirmed takeover, force release, cancel, guarded Save/Post core boundary, postflight/test/runbook dibuat | User: all data invariant PASS, zero Draft, expected SETUP only; migration checksum/static checks local; manual rollout pending | Migration `20260729120000` → all postflight PASS → behavior → Phase-5/4/Store Manager/G1 regression |
| 2026-07-29 | Codex — G4 Phase-7 Sale Draft PWA UI | User menutup rollout Phase-6 all-good; PWA mendapat daftar Draft per Store, metadata user-facing, resume+server repricing, payment reconfirm, heartbeat, stale takeover, force release, cancel, dan Escape panel | PWA lint PASS; production build PASS; browser visual connector gagal tersambung sehingga authenticated tablet smoke menunggu user | Restart/hard refresh dan jalankan runbook Phase-7; split payment tetap tertutup |
| 2026-07-29 | Codex — G4 Phase-7 custom action dialog | Native browser confirm/prompt dihapus dari PWA; takeover, force release, cancel Draft, transaksi baru, dan tutup sesi memakai modal konsisten dengan textarea alasan tervalidasi dan Escape | Scan `window.confirm/prompt` zero; PWA lint PASS; production build PASS | Hard refresh lalu smoke seluruh modal Phase-7 |
| 2026-07-29 | Codex — G4 Phase-8 Split Payment preflight | User menerima Draft/custom modal; audit SELECT-only dibuat untuk multi-leg server loop, fee per leg, Store eligibility, posted snapshot/total/tender, duplicate method, payment-leg identity, dan privilege | SQL single-statement SELECT-only; no schema/data mutation; user execution pending | Jalankan Phase-8 preflight dan kirim seluruh output |
| 2026-07-29 | Codex — G4 Phase-8 Payment-Leg identity foundation | Live preflight bersih; forward migration menambah stable UUID per leg, legacy normalization, duplicate key/metode guard, unique payment identity, receipt traceability, postflight/test/runbook | User: dependency/runtime/data PASS, 3 active methods, 1 posted Sale/payment, expected identity SETUP only; static SQL/hash verification local | Migration `20260729150000` → 10 PASS → behavior → Phase-6/5/4/G1 regression |
| 2026-07-29 | Codex — Phase-8 behavior fixture correction | Behavior pertama berhenti pada precondition karena Company sintetis hanya mendapat Cash mandatory; fixture sekarang menambah metode `CUSTOM` kedua secara rollback-only dan memilih kedua ID secara deterministik | Error terjadi sebelum assertion/runtime mutation; migration tidak diubah dan tidak perlu direrun; test static/diff check PASS | Rerun behavior Phase-8 terbaru, lalu regression bila PASS |
| 2026-07-29 | Codex — G4 Phase-9 Split Payment PWA UI | User menutup Payment-Leg rollout sukses; PWA memakai stable key per leg, exact base-total split, duplicate-method prevention, Cash tender/change, per-leg proof, fee estimate, dan tablet-friendly summary | PWA lint PASS; production build PASS; browser connector gagal attach sehingga authenticated visual smoke belum diklaim | Restart/hard refresh dan jalankan runbook Phase-9; setelah PASS lanjut online E2E + true concurrent double-post |
| 2026-07-29 | Codex — Phase-9 POS visual correction | User menemukan field overlap, istilah membingungkan, dan icon action tidak center; dua kolom checkout dihapus, input mendapat padding/containment, copy diganti bahasa Kasir, Cash auto-fill, dan seluruh icon-only Keranjang/modal/struk memakai ukuran tetap + grid centering tanpa baseline/transform | PWA lint PASS; production build PASS; browser connector masih gagal attach, jadi visual smoke tetap manual | Restart/hard refresh PWA dan validasi icon Keranjang serta satu/dua cara bayar pada tablet |
| 2026-07-29 | Codex — G4 Phase-10 Online Checkout stress preflight | User meminta lanjut sesuai rundown; diagnostic SELECT-only dibuat untuk server lock/idempotency, identity uniqueness, posted final effect, Payment/Movement/FIFO/stock reconciliation, dan fixture dua Kasir | Parenthesis balanced; mutation scan hanya menemukan kata dalam function definition/index privilege strings; `git diff --check` PASS | Jalankan preflight Phase-10 penuh dan kirim seluruh output |
| 2026-07-29 | Codex — Phase-10 preflight execution-chain correction | Live result menunjukkan false blocker karena diagnostic membaca public wrapper saja; revision membaca wrapper Sale lock + private core stock/FIFO/idempotency dan menghitung Company Owner/Admin/Super Admin sebagai effective POS users | Seluruh live data invariant lain PASS; one Store punya Terminal/payment/stock-FIFO; static balance dan diff check PASS | Rerun preflight terbaru; jangan membuat migration dari false blocker lama |
| 2026-07-29 | Codex — G4 Phase-10 true-concurrent Post harness | User menutup preflight seluruhnya PASS; staging-only CLI mengirim 2–20 Post dengan satu key dan memverifikasi single final effect, Payment identity, Movement, Event, serta audit tanpa service role | `node --check`, PWA lint, production build PASS; harness sengaja belum dieksekusi karena mem-post Draft/stok sungguhan | Buat Draft disposable staging, jalankan runbook, kirim JSON saja, lalu rerun preflight |
| 2026-07-29 | Codex — Phase-10 harness Supabase config fix | Eksekusi pertama gagal sebelum Auth karena script membaca placeholder `pwa/.env`; loader sekarang menolak placeholder dan fallback ke public config `backoffice/.env.local` seperti runtime PWA | Error `ENOTFOUND your-project-id.supabase.co` tidak mencapai Auth/RPC dan tidak membuat mutation; syntax/lint/build diverifikasi ulang | Jalankan ulang command yang sama; tidak perlu membuat ulang Draft akibat error konfigurasi ini |
| 2026-07-29 | Codex — Phase-10 harness Draft payment preparation fix | Instruksi awal keliru mewajibkan Draft sudah mempunyai payment intent, padahal `Simpan Draft` normal mengosongkan Payment; harness sekarang memilih metode non-proof eligible, memprioritaskan Cash, menyimpan payment intent sebesar total, lalu menjalankan Post concurrent | Dua eksekusi user berhenti pada assertion sebelum Save/Post sehingga tidak membuat final effect; contract diselaraskan dengan `handlePostSale` PWA | Jalankan ulang Draft normal yang sama; tidak perlu membayar Draft lewat UI |
| 2026-07-29 | Codex — Phase-10 harness authoritative version fix | Percobaan setelah payment preparation membuat semua Post ditolak `MASTER_VERSION_CONFLICT`; harness tidak lagi mempercayai version response intermediate dan membaca ulang row Draft authoritative setelah Save sebelum fan-out | Semua 20 Post ditolak sebelum final effect; payment intent Draft mungkin sudah tersimpan tetapi Sale/stock/payment final belum dibuat | Jalankan ulang Draft yang sama setelah local syntax/lint/build PASS |
| 2026-07-29 | Codex — Phase-10 stress gate paused | Authoritative reread tetap menghasilkan 20 `MASTER_VERSION_CONFLICT`; repeated user execution dihentikan dan harness tidak lagi diklaim local-ready | Tidak ada response Post sukses, jadi tidak ada final Sale/stock/payment effect dari percobaan ini; root cause orchestration belum terbukti | Jangan rerun; lanjutkan development independen, tetapi blok offline/pilot/deploy sampai concurrency gate diperbaiki |
| 2026-07-29 | Codex — Phase-10 live root-cause audit | Service-role read-only audit membuktikan Draft tetap DRAFT v6 dengan satu payment intent; audit terakhir `STOCK_SHORTAGE`; requirement 7 versus stock 1. Satu shortage response tertutup oleh 19 stale-version errors | Query hanya SELECT; tidak ada data berubah. Harness ditambah stock precheck dan shortage-first reporting | Gunakan fixture baru qty ≤ stok bila gate dilanjutkan; Draft lama jangan direrun |
| 2026-07-29 | Codex — Phase-10 concurrent gate closure | User menambah stok dan harness mencapai final verification; Kasir melihat Event count 0 karena Finance RLS, bukan Event hilang. Server read-only membuktikan POSTED, 1 Movement, 1 Payment, 1 POST audit, 1 SALE_POSTED Event HOLD | Seluruh concurrency assertions sebelum Event sudah lolos; service query SELECT-only; harness Finance assertion dihapus; syntax/lint/build PASS | Jangan rerun Sale POSTED; lanjut gate G4 berikutnya |
| 2026-08-05 | Codex — G4 Phase-58 POS Negative Stock policy foundation | User meminta lanjut sesuai rundown setelah Phase-56 database PASS dan Phase-57 UI local-ready; menambahkan default-OFF entitlement/policy, opt-in Gudang, permission user, config audit, serta future authorization/allocation/replenishment schema tanpa shortage bypass | Migration/postflight/rollback-safe behavior/runbook/manifest dibuat; FK canonical diverifikasi; parenthesis seimbang; SHA-256 `c5d9823b...1bb76`; `git diff --check` bersih; live rollout pending | Migration `20260805190000` → all-PASS postflight → behavior → listed regression → closing postflight; jangan aktifkan operasional sebelum runtime phase berikutnya |
| 2026-08-05 | Codex — G4 Phase-59 POS Negative Stock runtime preflight | User mengonfirmasi seluruh Phase-58 PASS; menambahkan diagnostic SELECT-only untuk configuration chain, tenant permission, provisional cost, current Stock–FIFO–Movement, Movement negative snapshot guard, online allocation gap, Offline/import isolation, serta G5/G6 dependency | Satu statement SELECT-only; expected tiga runtime `SETUP` dan satu cross-gate `DEFERRED`; local parenthesis/diff validation PASS; live output pending | Jalankan seluruh preflight Phase-59 dan kirim semua row; `BLOCKER` wajib nol sebelum runtime foundation |
| 2026-08-05 | Codex — G4 Phase-60 POS Negative Stock online runtime | Phase-59 live output diterima tanpa blocker/review; menambahkan gated online non-Bundle authorization, limit/reason, last-FIFO/Product-COGS provisional cost, negative Sale Movement, outstanding allocation, dan automatic incoming-batch reconciliation | Migration/postflight/rollback-safe behavior/runbook/manifest local-ready; parentheses seimbang; SHA-256 `7e2b56db...6dd9c`; `git diff --check` bersih; live rollout pending | Migration `20260805220000` → all-PASS postflight → behavior → listed regression → closing postflight; konfigurasi live tetap OFF sampai UI phase |
| 2026-08-05 | Codex — Phase-60 Offline reservation guard forward fix | Behavioral test membuktikan guard Phase-11 salah menolak authorized Sale dari stok 1 ke -2 saat reservasi Offline nol; forward migration memisahkan active reservation, exact same-transaction Sale authorization, replenishment, dan negative INSERT | Error terjadi di dalam transaksi rollback test; migration Phase-60 tidak diedit. Forward-fix SHA-256 `6fbd6f8e...26ac7`; postflight, stale-authorization regression, dan `git diff --check` local-ready | Migration `20260805230000` → 4 PASS → rerun behavior Phase-60 → behavior Phase-11 → regression lain → kedua closing postflight |
| 2026-08-05 | Codex — Phase-60 authorization transaction-marker fix | User rerun membuktikan fix pertama masih berhenti pada final guard raise; inferred actor/time/status match diganti marker Sale transaction-local yang dibuat oleh authorization INSERT dan diverifikasi bersama exact stock scope/balance | Eksekusi pertama migration kedua gagal parse sebelum ledger karena alias reserved `authorization`; alias diganti `authz`, checksum baru `76a62871...7034b`, manifest/runbook diselaraskan | Jalankan migration `20260805233000` terkoreksi → 4 PASS postflight → rerun behavior Phase-60 |
| 2026-08-05 | Codex — Phase-60 Offline guard responsibility fix | User membuktikan marker fix tetap ditolak final fallback; desain dikoreksi pada boundary sebenarnya: Offline guard hanya melindungi active reserved quantity dan tidak lagi menduplikasi authorization Sale/Movement | Migration `20260805234500`, four-check postflight, marker cleanup, corrected Phase-60 behavior; SHA-256 `55b6b82e...cb0d92`; static hash/SELECT-only/diff checks local-ready | Jalankan migration → 4 PASS → rerun behavior Phase-60; bila PASS baru Phase-11 reservation regression |
### 2026-08-13 — ACP-5F USER PASS; ACP-5G BUNDLE PREFLIGHT READY

User mengonfirmasi seluruh ACP-5F migration, postflight, behavior, dan ordered
regression PASS. `sales.pricelists` ditutup database-live ENFORCED; authenticated
preset/two-Company smoke tetap closing UAT. Manifest, README, gate, dan role
plan diperbarui agar tidak lagi menulis ACP-5F sebagai local-only.

Gate berikutnya dibuka hanya sebagai SELECT-only ACP-5G. Ditambahkan
`supabase/diagnostics/acp_phase5g_bundle_permission_preflight.sql` dan
`docs/runbooks/ACP5G_BUNDLE_PERMISSION_PREFLIGHT.md`. Diagnostic memetakan
atomic Bundle Product/sales-UOM/composition, VIEW versus MANAGE, composed read,
availability sempit, Product authority split, virtual-stock invariant,
server-side POS component/FIFO allocation, Sales Return snapshot consumer,
generic import exclusion, tenant, privilege, dan override. Tidak ada schema,
grant, function, API, UI, stock, sale, atau Finance runtime yang diubah.

Next safe step: jalankan seluruh ACP-5G preflight dan kirim setiap row
`check_name,status,details`. Berhenti pada `BLOCKER`; `REVIEW` adalah boundary
yang harus dipertahankan dan `SETUP` adalah target enforcement, bukan error.
Jangan membuat migration ACP-5G sebelum output live dinilai.

ACP-6G behavioral run pertama berhenti pada
`PERMISSION_TARGET_ACCESS_DENIED`. Runtime guard bekerja benar: fixture keliru
memanggil workflow admin untuk membatasi user yang sedang mengubah dirinya
sendiri. Test diperbaiki dengan memasang override transaction-local memakai
SQL runner sebelum `SET LOCAL ROLE authenticated`; seluruh perubahan tetap
diakhiri `ROLLBACK`. Migration/runtime tidak berubah dan tidak perlu direrun.

Regression G2 Phase-14 berikutnya berhenti pada `SYSTEM_CODE_IMMUTABLE` karena
test lama hanya menerima guard histori
`PAYMENT_METHOD_CODE_LOCKED_BY_HISTORY`. Sejak Phase-36, trigger automatic-code
yang lebih ketat berjalan lebih dulu. Assertion diperbarui menerima kedua
canonical guard sebagai bukti kode teknis tidak berubah. Tidak ada runtime atau
migration yang diubah.

Audit regresi lanjutan juga menemukan Phase-36 masih mengharapkan hard-coded
`PAY-000001`, sedangkan provisioning Customer Balance sekarang sah memakai
sequence pertama. Test diubah membaca counter PAYMENT_METHOD tenant sebelum
create dan mengharapkan nomor berikutnya. Phase-8 dan ACP-6A diperiksa penuh;
keduanya tidak bergantung pada kode lama/direct read Payment Method dan tidak
memerlukan perubahan.

Rerun G2 Phase-36 kemudian berhenti pada assertion privilege lama. Root cause
terkonfirmasi: test masih mewajibkan `authenticated` EXECUTE pada
`public.save_supplier`, padahal ACP-5B sengaja mengarantina RPC legacy tersebut
dan membuka `public.save_contacts_supplier` yang capability-guarded. Assertion
Phase-36 sekarang mengikuti boundary ACP-5B: allocator private tidak boleh
diakses browser, `anon` ditolak, legacy Supplier RPC ditolak untuk
`authenticated`, dan wrapper Contacts wajib executable. Pemeriksaan gabungan
dipecah menjadi empat error spesifik. Tidak ada migration/runtime/data yang
diubah dan migration ACP-6G tidak perlu dijalankan ulang; hanya rerun file G2
Phase-36 terbaru.

Regression G4 Phase-8 berikutnya berhenti pada assertion runtime gabungan.
Root cause terkonfirmasi bukan payment runtime: test masih mencari
`clientPaymentKey` dan `PAYMENT_LEG_IDENTITY_MAPPING_FAILED` langsung di
`public.post_pos_sale`. Phase-52/56 telah sah memindahkan implementasi tersebut
ke `private.post_pos_sale_phase52_public_core` dan mempertahankan fungsi public
sebagai wrapper. Test sekarang memverifikasi secara terpisah: direct Payment
write tertutup, wrapper public canonical tersedia, Payment-Leg mapping terdapat
pada private execution chain, private core tidak executable oleh browser, dan
public wrapper hanya executable oleh authenticated/service role. Seluruh empat
regression ACP-6G diaudit ulang untuk delimiter/rollback serta nama runtime;
static check PASS. Tidak ada migration/runtime/data yang diubah.

### 2026-08-13 - ACP-6G PAYMENT METHOD ENFORCEMENT LOCAL READY

User mengirim ACP-6G preflight tanpa `BLOCKER`; seluruh invariant utama PASS
dan empat legacy/provisioned method memerlukan audit backfill terukur.
Migration `20260813130000` local-ready: composed Backoffice read, guarded
MANAGE pada dua save overload, CSV EXPORT, open-session POS reference, Expense
POST reference, actor-null `BACKFILL`, immutable audit, dan direct-read closure.
Backoffice API/UI, Data Exchange, Expense return, serta PWA catalog sudah
cutover. Import/system-method generic mutation/Financial Event/Journal tidak
dibuka atau diubah.

Local evidence: Backoffice lint dan production build PASS; PWA oxlint dan
TypeScript/Vite/PWA build PASS. SQL live belum dijalankan. Manual gate:
migration -> restart apps -> postflight -> behavior -> G2 Phase-14 -> G2
Phase-36 -> G4 Phase-8 -> ACP-6A -> postflight ulang. Stop pada error/`FAIL`.

### 2026-08-13 — ACP-6G USER PASS; ACP-7 PREFLIGHT READY

User mengirim closing ACP-6G postflight dengan seluruh check `PASS` dan
inventory `INFO`: permission `ENFORCED`, direct Payment Method table read/write
tertutup, dua save hook aktif, composed/private boundary lengkap, enam current
method seluruhnya memiliki audit, dan Sale Payment snapshot coverage bersih.
Migration, behavior, regression yang telah diselaraskan, serta closing
postflight dianggap database-live PASS. Authenticated role/preset/two-Company
smoke tetap dikonsolidasikan pada ACP-7.

Gate aktif berpindah ke ACP-7 security closure. Ditambahkan one-statement
SELECT-only `supabase/diagnostics/acp_phase7_security_closure_preflight.sql`
dan runbook `docs/runbooks/ACP7_SECURITY_CLOSURE_PREFLIGHT.md`. Diagnostic
memeriksa 24 migration/enforced permission, unexpected enforcement, override
tenant/contract, immutable audit, admin/protected browser boundary, active
Company context, role/two-Company/distinct-override fixture, background work,
Stock/FIFO/Movement dan Journal balance. Browser/build/environment tetap
`REVIEW`/`DEFERRED` secara eksplisit. Static evidence: satu SELECT, zero
forbidden statement, parentheses `215/215`, dan scoped `git diff --check` PASS.

Next safe step: jalankan seluruh ACP-7 preflight dan kirim semua row. Stop pada
`BLOCKER`; `SETUP` hanya melengkapi fixture UAT yang disebutkan. Jangan mulai
Vercel atau modul bisnis baru sebelum output ini dinilai dan ordered closing
matrix dibekukan.

### 2026-08-13 — ACP-7 PREFLIGHT PASS; AUTHENTICATED FIXTURE SETUP

Live ACP-7 preflight diterima dengan zero `BLOCKER`: 24/24 expected permission
`ENFORCED`, tidak ada unexpected enforcement, background work kosong,
protected browser writes tertutup, override/active-context tenant integrity
bersih, Stock–Movement–FIFO reconcile, dan Journal balance PASS. Dua Company
aktif sudah tersedia. `SETUP` hanya tersisa role ACCOUNTING/CASHIER/
COMPANY_ADMIN/WAREHOUSE_ADMIN, satu regular multi-Company identity, dan satu
permission dengan override berbeda pada Company A/B; audit/override inventory
masih nol sehingga keadaan ini konsisten.

Local closure evidence: Backoffice ESLint PASS; Next production build PASS
dengan 65 static pages dan seluruh dynamic routes; PWA oxlint PASS; TypeScript
dan Vite/PWA production build PASS; scan 754 tracked files menemukan zero
suspect secret. PWA memberi non-blocking warning main client chunk 555.37 kB;
tablet/network latency tetap manual ACP-7 evidence.

Runbook `docs/runbooks/ACP7_AUTHENTICATED_CLOSURE_MATRIX.md` membekukan setup
minimal: buat Admin/Warehouse/Cashier A, reuse Admin A sebagai Accounting B
melalui guarded existing-user assignment, lalu beri `inventory.stock_real`
`LIHAT_SAJA` di A dan `TANPA_AKSES` di B. Setelah rerun preflight mengubah tiga
`SETUP` menjadi PASS, jalankan satu consolidated role/preset/navigation/API/RPC
matrix. Tidak ada migration atau regression SQL tambahan pada langkah ini.

### 2026-08-13 — PRD-1 CONSOLIDATED PREFLIGHT + PREVIEW ENV AUDIT

Sambil fixture ACP-7 menunggu UI setup, PRD-1 preflight lama diaudit dan
diselaraskan pasca-ACP. `prd_phase1_predeploy_closing_preflight.sql` sekarang
memerlukan 31 migration, memverifikasi 24 permission `ENFORCED`, override tenant
integrity, dan regular multi-Company distinct-override fixture, selain seluruh
Stock/Sale/Document/Finance invariant existing. Query tetap SELECT-only;
parentheses `234/234`, zero forbidden statement, dan satu final statement.

Environment audit membuktikan Backoffice/PWA local secret file tidak tracked;
PWA `.env.example` tracked dan Backoffice `.env.example` placeholder-only siap
ditrack. Scan tracked content tetap zero suspect secret. Ditemukan
`backoffice/vercel.json` masih menjadwalkan legacy Finance worker setiap menit,
padahal route canonical sudah retired `410` dan hanya mengekspor POST. Menurut
dokumentasi resmi Vercel, Cron memanggil HTTP GET dan hanya aktif pada production;
schedule tersebut dihapus, menyisakan schema-only config. Controlled Finance
queue tidak diotomatisasi. Runbook baru
`PRD1_VERCEL_PREVIEW_ENVIRONMENT_READINESS.md` membekukan dua-project root,
public/server env split, Auth allowlist, secret, branding, PWA, dan no-Cron
evidence.

### 2026-08-13 — PRD-1 LIVE PREFLIGHT ZERO BLOCKER

User menjalankan consolidated PRD-1 terbaru. Seluruh 31 migration, 24 permission
`ENFORCED`, tenant/override integrity, browser critical writes, Stock–Movement–
FIFO, final Sale/Invoice/Delivery/Event, Return ongkir, queue/job, dan Journal
balance PASS. Dua Company dan Super Admin fixture PASS. Finance HOLD tetap
expected `DEFERRED` sebanyak 29 event/sembilan contract; tidak diproses.

Lima `SETUP` murni fixture: satu Company (Company B) belum memiliki minimum
Store/Terminal/sale-source Warehouse serta Product/Customer/Payment Method;
role ACCOUNTING/COMPANY_ADMIN/WAREHOUSE_ADMIN/CASHIER belum tercakup; regular
multi-Company user dengan distinct override belum ada. Runbook ACP-7 diperluas
dengan satu setup final yang me-reuse Admin A sebagai Accounting B dan fixture
multi-Company. Setelah setup, hanya rerun ACP-7 preflight dan PRD-1 preflight;
tidak perlu mengulang behavioral regression historis.
### 2026-08-17 — PAKET TEMPLATE CUTOVER GO-LIVE

User meminta template seluruh data awal kecuali user agar data produksi dapat
disiapkan dari pembukuan manual. Ditambahkan
`docs/templates/go-live-cutover/README.md` beserta 26 CSV bernomor. Sepuluh file
master (`UOM`, Product Category, Warehouse, Supplier, Customer Category, COA,
Transaction Category, Product, Product-Supplier, dan Minimum Stock) cocok persis
dengan `templateHeaders` runtime dan dapat memakai Global Data Exchange aktif.
Company/Toko/Terminal, Tax, Customer, Pricelist, Payment Method, mapping Finance,
dan Bundle ditandai sebagai form setup manual. Opening Stock tetap workflow
khusus per Gudang/tanggal. Opening AR, AP, Customer Deposit, dan GL hanya
data-collection contract karena runtime opening Finance/subledger belum tersedia;
direct SQL atau transaksi palsu tetap dilarang.

Evidence lokal: seluruh 26 CSV memiliki satu header non-kosong; sepuluh header
import aktif dibandingkan exact-string dengan `backoffice/src/lib/master-import.ts`
dan menghasilkan `ACTIVE_IMPORT_HEADERS_MATCH=10`. Tidak ada schema, API, UI,
grant, runtime, atau data database yang berubah. Next safe step adalah user
mengisi paket berdasarkan satu tanggal cut-off; implementasi OB-1 sampai OB-5
harus dibuat sebelum empat template opening Finance dapat di-upload/post.
### 2026-08-17 — ZERO-COMPANY USER RECOVERY LOCAL READY

Bug `TARGET_COMPANY_MEMBERSHIP_NOT_FOUND` pada detail user setelah membership
terakhir dicabut telah dikoreksi tanpa schema/grant baru. Endpoint detail kini
mengizinkan membership aktif kosong hanya untuk Super Admin, memilih membership
aktif deterministik bila masih ada, dan tidak memanggil resolver permission
tanpa Company target. Company Owner/Admin tetap wajib mempunyai target aktif di
Company aktif dan tidak dapat mengambil akun orphan.

Modal detail menampilkan empty-state `Tidak memiliki akses perusahaan`, tetap
terbuka setelah revoke terakhir, menyembunyikan editor role/permission tanpa
Company, dan mempertahankan form reassign Super Admin. Daftar Tim membedakan
membership inactive. Pesan login Backoffice dan PWA diperjelas; kedua aplikasi
tetap tidak memuat navigation, Store, Terminal, atau data tenant bila daftar
Company kosong. Lifecycle audit, inactive membership history, override cleanup,
active-context cleanup, hierarchy, dan last-owner protection tidak berubah.

Evidence lokal: Backoffice ESLint PASS; Next production build PASS dan 67 page/
route entries; PWA oxlint PASS; TypeScript/Vite/PWA production build PASS.
`git diff --check` PASS. Authenticated staging smoke masih manual: revoke last
Company sebagai Super Admin, pastikan modal tetap terbuka dan target login
fail-closed, assign kembali Company, lalu pastikan role/Store/permission serta
login pulih. Tidak ada migration yang perlu dijalankan.

### 2026-08-17 — CONTROLLED COMPANY TRANSACTION RESET LOCAL READY

Ditambahkan controlled operation
`supabase/operations/prd_reset_company_transactional_data.sql` untuk membersihkan
data transaksi/uji coba milik tepat satu Company sebelum opening balance. File
default ke preview-only, memerlukan UUID + nama Company persis, lalu
`execute_reset=TRUE` dan frasa konfirmasi eksplisit. Eksekusi bersifat satu
transaction, mengambil advisory/company lock, mematikan hanya USER trigger pada
target, mengurutkan delete child-first dari live FK graph, dan rollback penuh
jika ada error. Schema drift fail-closed: tabel `company_id` yang belum
diklasifikasikan atau target tanpa `company_id` memblokir eksekusi.

Target mencakup POS/Sale/Return/Delivery, Offline, stok/FIFO/Movement dan semua
dokumen Inventory, Purchase/AP, Expense/kas/setoran/variance, Customer Balance,
Financial Event/jurnal/queue/reconciliation/export history. Cache saldo Customer
direset nol dan snapshot last purchase Product-Supplier dibersihkan. Master,
user/membership/permission, konfigurasi, branding, policy, accounting period,
posting/report definition, master audit/import history, migration ledger, dan
private document counter dipertahankan. Runbook:
`docs/runbooks/PRD_COMPANY_TRANSACTIONAL_DATA_RESET.md`.

Belum ada database mutation yang dijalankan. Next safe step: user mengisi target,
menjalankan preview, dan mengirim result Company + issues + count untuk audit.
Eksekusi hanya setelah backup dan maintenance window.
# 2026-08-19 — Nonterminal Master Import closure operation

- Added `supabase/operations/cancel_nonterminal_master_import_jobs.sql` for the
  rollout blocker encountered before Customer/Product-UOM import migrations.
- The operation refuses to run when a job is genuinely `PROCESSING`; otherwise
  it closes only `UPLOADED`, `MAPPED`, `VALIDATED`, and `READY` jobs as
  `CANCELED`, increments `master_version`, and records a `CANCEL` audit event.
- It preserves all staged rows and previously committed master data. Manual
  gate: run the operation in Supabase SQL Editor, then rerun
  `20260819150000_customer_master_import_export.sql` from the beginning.
# 2026-08-19 — Customer import behavioral test ACP correction

- Corrected `supabase/tests/customer_master_import_export_tests.sql`: storage
  and audit assertions now use the canonical `get_contacts_customers(TRUE)`
  composed RPC instead of forbidden authenticated reads on `customers` and
  `customer_master_audit`.
- This is test-only compatibility with enforced `contacts.customers`; the
  Customer migration/runtime contract was not changed.

### 2026-08-20 - MADS DOCUMENT/PO/TERMINAL UI LOCAL READY

- Invoice dan Surat Jalan Backoffice mempunyai unduhan PDF nyata; filename
  memakai Customer di depan dengan fallback `PELANGGAN-UMUM`, sedangkan UUID
  internal tidak ditampilkan sebagai filename.
- Supplier Order mempunyai XLSX tiga sheet (daftar, detail barang, informasi
  export) melalui capability `purchase.supplier_orders EXPORT` dan guarded RPC.
- Pengaturan Modul mempunyai konfigurasi audited per Terminal untuk
  menyembunyikan tujuh tombol PWA. Ini UI-only; RPC authorization tidak dibuka
  dan Terminal existing tetap menampilkan seluruh fitur.
- Branding visual Backoffice, PWA, manifest, metadata, dan manual menjadi MADS;
  identifier `KGS` pada schema/migration/history tidak diubah.
- Evidence lokal: Backoffice ESLint PASS dan production build PASS (69 page/
  route entries); PWA oxlint PASS dan TypeScript/Vite/PWA build PASS.
- Manual gate: jalankan migration `20260820100000`, postflight, behavioral
  rollback, deploy dua client, lalu smoke PDF/XLSX/Terminal sesuai
  `docs/runbooks/MADS_DOCUMENT_PO_TERMINAL_UI_ROLLOUT.md`. Belum ada database
  production/staging yang diubah oleh pekerjaan lokal ini.

#### Manual gate update

- User menjalankan `mads_po_export_terminal_ui_behavior.sql`; output terakhir
  adalah JWT claim authenticated dan tidak diikuti exception. Behavioral test
  dinyatakan PASS serta berakhir melalui `ROLLBACK`.
- Target lokal Vercel menunjuk `pointofsales-kgs-staging` dan
  `kgs-pos-pwa-staging`, tetapi remote project inspection timeout. Deployment
  tidak dijalankan agar tidak menebak target atau menyentuh production.
- Next safe step: konfirmasi postflight seluruhnya PASS, verifikasi remote
  project/root directory, lalu deploy kedua project staging dan lakukan smoke.

### 2026-08-20 - BULK SURAT JALAN PDF LOCAL READY

- Inventory Surat Jalan kini memiliki checkbox per dokumen, pilih-semua hasil
  filter, progres, dan tombol `Unduh PDF Terpilih`; unduh satuan tetap tersedia.
- Maksimal 50 dokumen, tiga worker fetch/PDF/audit, ZIP level 0 agar PDF yang
  sudah terkompresi tidak membebani CPU. Setiap PDF tetap memakai filename
  Customer-first; kegagalan parsial masuk `GAGAL-DIUNDUH.txt`.
- Tidak ada migration, grant, schema, lifecycle, Stock, Payment, atau Finance
  yang berubah. Existing guarded detail dan print-audit RPC dipakai ulang untuk
  setiap dokumen.
- Evidence lokal: Backoffice ESLint PASS, production build PASS (69 route/page),
  dan `git diff --check` PASS.
- Manual smoke menunggu deployment staging: pilih dua SJ, unduh ZIP, periksa dua
  PDF individual, filename Customer-first, serta tombol unduh satuan.

### 2026-08-20 - DOCUMENT SIGNATURE TEMPLATE LOCAL READY

- Template browser print dan PDF Invoice/Surat Jalan tidak lagi merender nama
  Company pada header. Logo snapshot tetap opsional; identitas Customer, Store,
  nomor, tanggal, dan isi dokumen tidak berubah.
- Tanda tangan kedua dokumen kini empat kolom: Warehouse, Security, Driver, dan
  Customer. Generator Surat Jalan bulk memakai template yang sama.
- Tidak ada perubahan schema, snapshot, audit, permission, atau transaksi.
- Evidence lokal: Backoffice ESLint PASS, production build PASS (69 route/page),
  dan `git diff --check` PASS.
- Manual smoke menunggu staging: print dan unduh masing-masing satu Invoice/SJ,
  lalu periksa header serta empat tanda tangan pada PDF dan print preview.

### 2026-08-20 - COMPANY DOCUMENT LOGO/STAMP VISIBILITY LOCAL READY

- Ditambahkan setting audited per Company `show_logo_on_documents` default
  `TRUE` dan `show_stamp_on_documents` default `FALSE`, beserta guarded
  Owner/Admin RPC dengan optimistic version dan exact retry. File logo tidak
  dihapus ketika kedua setting dimatikan.
- Platform -> Logo Perusahaan mempunyai sakelar **Tampilkan logo pada dokumen**.
  Sakelar kedua menampilkan cap biru-transparan berbasis logo di area Warehouse.
  Keduanya hanya memengaruhi print/PDF Invoice dan Surat Jalan, termasuk bulk
  ZIP; logo navigasi aplikasi dan immutable document snapshot tidak berubah.
- File utama: migration `20260820110000_company_document_logo_visibility.sql`,
  postflight, behavioral rollback test, API branding PATCH, UI branding, serta
  renderer Invoice/Surat Jalan.
- Evidence lokal: Backoffice ESLint PASS; production build PASS (69 route/page);
  `git diff --check` PASS setelah dokumentasi akhir.
- Manual gate: migration -> postflight seluruhnya PASS -> behavioral test tanpa
  exception -> deploy staging -> smoke ON/OFF per Company sesuai
  `docs/runbooks/COMPANY_DOCUMENT_LOGO_VISIBILITY_ROLLOUT.md`.
- Compatibility: Company existing tetap logo ON/stempel OFF; client lama tidak rusak; tidak ada
  deployment atau database production/staging yang disentuh pada pekerjaan ini.
- Next safe step: user menjalankan tiga file SQL sesuai urutan, mengirim hasil
  postflight/behavioral, lalu deploy dan smoke staging.

### 2026-08-20 - PWA NUMERIC WHEEL AND SESSION FOOTER UX LOCAL READY

- Seluruh `input[type=number]` di PWA dilindungi oleh satu capture listener:
  wheel pada field fokus tidak mengubah nilai dan delta scroll dialihkan ke
  ancestor scrollable terdekat atau halaman. Ketik, tombol spinner, keyboard,
  validasi, dan payload transaksi tidak diubah.
- Footer kas penutupan/Tutup Sesi sekarang fixed di bawah viewport selama sesi
  aktif. `pos-main` mendapat safe bottom spacing; layout di bawah 900px menumpuk
  input dan tombol agar tetap terbaca pada tablet/mobile.
- File berubah: `pwa/src/App.tsx`, `pwa/src/App.css`, manual, root README, dan
  handoff ini. Tidak ada migration, database mutation, permission, Stock,
  Payment, Finance, atau lifecycle sesi yang berubah.
- Evidence lokal: PWA oxlint PASS; TypeScript/Vite/PWA production build PASS
  (19 precache entries); `git diff --check` PASS.
- Browser visual automation tidak tersedia pada environment saat verifikasi;
  authenticated staging smoke tetap wajib untuk field Qty, nominal pembayaran,
  modal operasional, footer tablet, dan footer mobile.
- Next safe step: deploy PWA staging, fokuskan field Qty bernilai 1 lalu scroll
  dan pastikan tetap 1; cek panel tetap bergulir; tambah banyak produk dan
  pastikan footer sesi selalu terlihat tanpa menutup action/cart terakhir.

### 2026-08-20 - PWA CLOSE SESSION MODAL AND RUPIAH INPUT LOCAL READY

- Perubahan ini menggantikan keputusan footer fixed pada boundary sebelumnya.
  Penutupan sesi kini tersedia sebagai tombol **Tutup Sesi** pada header hanya
  saat sesi aktif; tombol membuka modal khusus untuk kas fisik, peringatan, Batal,
  dan konfirmasi akhir.
- Komponen `CurrencyInput` menampilkan pemisah ribuan `id-ID` tanpa mengubah
  nilai mentah yang dipakai payload. Cakupan: kas awal/akhir, diskon nominal,
  bagian pembayaran, uang diterima/transfer, ongkir, Expense, penyelesaian
  Expense, saldo kas sesi berikutnya, dan nominal aktual Setor Kas. Qty dan
  persen tetap memakai input numerik sesuai kontrak satuan/decimal precision.
- Tidak ada migration, perubahan schema, RPC, izin, lifecycle sesi, Stock,
  Payment, atau Finance effect.
- Evidence lokal: `pwa` oxlint PASS; TypeScript/Vite/PWA production build PASS
  dengan 19 precache entries. Warning chunk utama lebih dari 500 kB tetap
  warning non-blocking yang sudah ada.
- Manual gate: deploy staging lalu smoke tablet/mobile untuk format ketik/paste,
  split payment, Expense/Setor Kas, tombol header, backdrop/Batal, dan satu kali
  penutupan sesi disposable. Pastikan nilai server sama dengan angka sebelum
  separator display diterapkan.

### 2026-08-20 - PWA AND BACKOFFICE STAGING DEPLOYED

- Commit deployed: `cc3efab` (`main`), working tree bersih sebelum deploy.
- Project staging PWA `kgs-pos-pwa-staging` berhasil build Vite/PWA dan dialias
  ke `https://kgs-pos-pwa-staging.vercel.app`.
- Project staging Backoffice `pointofsales-kgs-staging` berhasil build Next.js
  16.2.10 dan dialias ke `https://pointofsales-kgs-staging.vercel.app`.
- Smoke HTTP publik PASS: kedua alias mengembalikan HTTP 200. Tidak ada database
  mutation, Supabase migration, environment update, atau deployment ke project
  production.
- Manual gate: hard refresh/PWA reload, login staging, lalu cek tombol Tutup
  Sesi, format Rupiah, halaman Backoffice, dan satu flow disposable tanpa
  menggunakan data production.

### 2026-08-20 - COMPANY PROFILE/BANK/INVOICE LOCAL READY

- Migration `20260820120000_company_profile_bank_invoice.sql` menambah detail
  Company, rekening bank tiga-field yang all-or-none, optimistic version,
  immutable audit, dan toggle rekening Invoice default OFF.
- UI **Profil Perusahaan** menggantikan label Logo Perusahaan dan tetap memakai
  active Company. Hanya Owner/Admin dapat mengubah profil serta setting.
- Composed Supplier Payment kini mengembalikan rekening Supplier dan form
  otomatis mengisinya ketika Supplier dipilih; snapshot Draft tetap editable.
- Invoice POSTED baru menyimpan rekening Company dan flag tampilan pada snapshot.
  Backoffice PDF/print serta PWA print menampilkan rekening hanya saat diizinkan;
  Surat Jalan tidak berubah. Invoice historis sengaja tidak dibackfill.
- Evidence lokal: Backoffice targeted ESLint PASS; Next production build PASS
  (70 route/page); PWA oxlint PASS; TypeScript/Vite/PWA build PASS. SQL static:
  delimiter 12, parentheses 220/220, zero direct table grant/secret.
- Full Backoffice `npm run lint` mencapai timeout 120 detik tanpa diagnostic;
  targeted ESLint seluruh file yang berubah kemudian PASS.
- Manual gate menunggu user: migration -> postflight seluruh PASS -> behavioral
  test sukses/ROLLBACK -> deploy staging -> smoke profil, autofill pembayaran,
  Invoice ON/OFF, dan Surat Jalan tetap tanpa rekening. Runbook:
  `docs/runbooks/COMPANY_PROFILE_BANK_INVOICE_ROLLOUT.md`.
- Compatibility: RPC visibility tiga-arg lama dipertahankan; toggle baru OFF;
  tidak ada DB mutation/deploy yang dilakukan oleh pekerjaan lokal ini.
- Postflight portability correction: `num_nonnull(text,text,text)` tidak tersedia
  pada database target. Check integritas rekening diganti dengan penjumlahan
  tiga ekspresi `CASE` PostgreSQL standar. Migration/runtime tidak berubah dan
  tidak perlu dijalankan ulang; hanya postflight yang perlu diulang dari awal.
- User kemudian melaporkan postflight seluruhnya PASS dan behavioral test
  SUCCESS. Database target yang diuji dinyatakan rollout PASS. Environment
  target tidak ditebak di handoff; deployment client dan authenticated smoke
  masih menunggu. Next safe step: deploy Backoffice/PWA ke environment yang
  terhubung ke database tersebut, lalu smoke profil, Invoice ON/OFF, Surat Jalan
  tanpa rekening, dan autofill rekening Supplier Payment.

### 2026-08-21 - CONTROLLED COMPANY FINANCE CONFIG CLONE LOCAL READY

- Ditambahkan operasi SQL preview/apply
  `supabase/operations/clone_company_finance_configuration.sql` untuk clone
  konfigurasi Finance Company sumber ke Company tujuan dengan UUID tenant baru.
- Cakupan: COA/hierarchy, Transaction Category, current ACTIVE transaction
  mapping/fallback, serta current APPROVED posting expressions. Saldo, Journal,
  Financial Event, transaksi, master operasional, identitas, entitlement dan
  policy Store/Warehouse/Terminal tidak disalin.
- Live PREVIEW KGS -> KMS menunjukkan target tanpa Finance history, tetapi
  mempunyai provisioned baseline: 33 Transaction Rules, 3 fallback, 1 Posting
  Rule Set, serta 1 beda kode system-function account. Operation direvisi:
  baseline target ditutup sebagai versi INACTIVE/RETIRED secara audited,
  mapping clone memakai nomor versi berikutnya, dan system account dipetakan
  berdasarkan function sambil mempertahankan identity target.
- APPLY tetap fail-closed bila target sudah mempunyai Finance history, nama
  akun/kategori bentrok, actor tidak berwenang, atau verifikasi hasil tidak
  cocok. Seluruh write berada dalam satu DO block atomik dan dicatat pada
  Finance master/posting-rule audit.
- Runbook:
  `docs/runbooks/COMPANY_FINANCE_CONFIGURATION_CLONE.md`.
- Evidence lokal: delimiter DO berpasangan, parentheses seimbang, dan
  `git diff --check` PASS untuk operation. PostgreSQL parser/runtime belum
  tersedia lokal; PREVIEW Supabase dan APPLY KGS -> KMS masih manual gate.
- Tidak ada database, Vercel, staging, atau production yang disentuh oleh agent.
  Next safe step: jalankan ulang PREVIEW file terbaru. `REPLACE`/`REMAP`
  expected, tetapi seluruh `BLOCKER` wajib nol sebelum APPLY.

### 2026-08-21 - COMPANY MASTER TEMPLATE CLONE PREFLIGHT LOCAL READY

- User meminta Company baru dapat memakai template KGS untuk COA/configuration
  Finance dan seluruh master Product tanpa membawa transaksi.
- Ditambahkan SELECT-only preflight
  `supabase/diagnostics/company_master_template_clone_preflight.sql` serta
  runbook `docs/runbooks/COMPANY_MASTER_TEMPLATE_CLONE.md`.
- Cakupan rencana: Category, UOM, Tax Rule/current version, Product/Product-UOM,
  Bundle, dan Global Pricelist/rules. Finance tetap memakai operasi clone
  Finance yang terpisah dan dijalankan lebih dahulu.
- Boundary: tidak menyalin Stock/FIFO/Opening/Movement, transaksi/Journal,
  Customer/Customer Pricelist, Supplier/Product-Supplier, Store/Warehouse/
  Terminal, user/access, entitlement, atau policy. HTTPS Product image URL
  direferensikan ulang; binary tidak digandakan.
- User menjalankan preflight target aktual: seluruh gate `PASS`; target memiliki
  zero operational history, zero Product master, satu baseline Global Pricelist,
  dan zero Tax. Sumber berisi 1 Category, 2 UOM, 61 Product, 119 Product-UOM,
  tanpa Bundle, active Tax version, atau Pricelist Rule.
- Ditambahkan operasi atomik default-PREVIEW
  `supabase/operations/clone_company_product_master.sql`. ID master diremap,
  baseline Pricelist target direuse berdasarkan normalized code, audit dicatat,
  dan exact count/dependency/zero-stock diverifikasi sebelum commit.
- Tidak ada database yang disentuh agent. Manual gate: isi config operasi,
  jalankan PREVIEW dan pastikan tanpa `BLOCKER`; lalu set `execute_clone=TRUE`
  dengan confirmation `CLONE_PRODUCT_MASTER`. Output wajib memuat
  `clone_result=APPLIED` dengan 1/2/61/119.

### 2026-08-21 - PLATFORM POS STORE/TERMINAL MANAGEMENT LOCAL READY

- Ditambahkan menu `Platform > Point of Sales`, API
  `/api/platform/pos-setup`, dan workspace tambah/edit Toko serta Terminal.
- Migration `20260821120000_platform_pos_store_terminal_management.sql`
  menambah operational version, immutable audit, guarded composed read/save,
  dependency guards, dan menutup direct authenticated write.
- PWA sudah mempunyai selector Company multi-membership yang terkunci ketika
  sesi terbuka, serta selector Terminal berlabel Toko dan Gudang sebelum sesi;
  tidak ada perubahan core PWA yang diperlukan.
- Evidence lokal: Backoffice full ESLint PASS, Next production build PASS (71
  route/page), dan diff check file runtime/SQL PASS.
- Database/deploy belum disentuh. Manual gate: migration -> postflight ->
  behavioral rollback -> staging deploy -> authenticated smoke Backoffice/PWA.
  Runbook: `docs/runbooks/PLATFORM_POS_STORE_TERMINAL_MANAGEMENT_ROLLOUT.md`.
- Behavioral test correction: temporary context table dihapus setelah SQL
  Editor target melaporkan `relation platform_pos_test_context does not exist`.
  Actor, Company, active context, dan JWT claims kini disiapkan dalam satu
  transaction-local DO block sebelum `SET LOCAL ROLE authenticated`; migration
  dan runtime tidak berubah, hanya file behavioral yang perlu dijalankan ulang.
- User menemukan UI bug pada detail User: dropdown Role/Toko panel hijau
  (membership terpilih) dan panel biru (assignment Company baru) memakai state
  React yang sama. `StaffAccessDetailModal.tsx` diperbaiki dengan state dan
  payload API yang sepenuhnya terpisah untuk kedua form. Mengubah Company,
  Role, atau Toko pada panel biru kini tidak mengubah nilai panel hijau.
- Evidence koreksi UI: targeted ESLint PASS, Next production build PASS (71
  route/page), dan diff check PASS. Tidak ada schema, database, atau deploy yang
  berubah; authenticated browser smoke masih perlu setelah client dideploy.
- README dan Manual Pengguna MADS diperbarui untuk menu Platform Point of Sales,
  urutan setup Toko/Terminal/Gudang, perpindahan Company/Toko PWA, serta state
  form membership dan assignment Company yang terpisah.
- Staging deployment 21 Agustus 2026 selesai dari working tree yang sama:
  Backoffice dialias ke `https://pointofsales-kgs-staging.vercel.app` dan PWA ke
  `https://kgs-pos-pwa-staging.vercel.app`. Vercel build Backoffice (71 route)
  dan PWA PASS; warning chunk PWA >500 kB tetap non-blocking yang sudah dikenal.
  Smoke publik: kedua root HTTP 200 HTML dan `/api/platform/pos-setup` tanpa sesi
  HTTP 401 JSON. Tidak ada Supabase mutation, environment change, atau project
  production yang disentuh. Authenticated UI smoke tetap manual.

### 2026-08-21 - REGISTERED USER IDENTITY SQL OPERATIONS

- Ditambahkan SELECT-only `supabase/operations/find_registered_user.sql` untuk
  mencari akun lewat UUID/email/nama sekaligus melihat provider dan membership.
- Ditambahkan `supabase/operations/update_registered_user_identity.sql` untuk
  sinkronisasi atomik email `auth.users`, `public.profiles`, email
  `auth.identities`, dan nama metadata/profile. Default PREVIEW; APPLY memerlukan
  `execute_change=TRUE` serta confirmation `UPDATE_REGISTERED_USER`.
- Operasi menolak target nol/ambigu, email invalid/duplikat, dan final state yang
  tidak sinkron. Password, role, Company/Store membership, permission, active
  context, dan histori transaksi tidak disentuh. Perubahan email SQL langsung
  dianggap confirmed dan user harus login ulang dengan email baru.
- Tidak ada database/deployment yang dilakukan. Evidence lokal: transaction/DO
  delimiter statik dan `git diff --check` PASS; PostgreSQL runtime tetap manual.
- UX correction: user menolak keharusan memasukkan UUID untuk melihat akun.
  `find_registered_user.sql` kini langsung menampilkan seluruh akun beserta
  Company/role/status; `search_text` kosong adalah default dan filter nama/email
  hanya opsional. Update cukup memakai `current_email`; UUID hanya fallback.

### 2026-08-25 - POS LIVE PRICELIST PREVIEW LOCAL READY

- User meminta bug nomor 5 diperbaiki lebih dahulu: POS menampilkan harga umum
  sampai transaksi disimpan sebagai Draft, lalu baru menampilkan Pricelist.
- Root cause pada `pwa/src/App.tsx`: perubahan Customer/Pricelist/cart menghapus
  `resolvedLines`; kartu Product selalu membaca `fallbackPrice`, sedangkan
  resolver server baru dijalankan oleh Save Draft.
- Migration additive `20260825100000_pos_live_pricelist_preview.sql` menambah
  RPC `preview_pos_sale_prices`. RPC wajib auth + active Company + open Cashier
  session milik actor, memvalidasi Customer tenant, membatasi payload, dan
  memanggil `private.resolve_pos_sale_price`; tidak ada Draft/table mutation.
- PWA memanggil preview dengan debounce 200 ms dan chunk 250 Product-UOM.
  Quantity Product yang sudah berada di cart ikut dikirim sehingga perubahan
  quantity tier langsung terlihat. Stale response diabaikan dengan request ID.
- Kartu Product dan cart sekarang memakai harga preview; fallback hanya dipakai
  selama preview belum tersedia/gagal. Save Draft/Post, Offline snapshot,
  discount, tax, payment, stock, dan Finance core tidak diubah.
- File verifikasi:
  `supabase/tests/pos_live_pricelist_preview_postflight.sql` dan
  `supabase/tests/pos_live_pricelist_preview_behavior.sql`; runbook:
  `docs/runbooks/POS_LIVE_PRICELIST_PREVIEW_ROLLOUT.md`.
- Evidence lokal: `pwa/npm.cmd run lint` PASS; `pwa/npm.cmd run build` PASS
  (Vite/PWA, warning chunk >500 kB tetap warning lama non-blocking).
- Manual gate: migration -> postflight seluruh PASS -> pastikan open Session lalu
  behavior rollback PASS -> deploy PWA target -> smoke Customer default,
  override Global, quantity tier, Save Draft parity, dan Offline regression.
- Tidak ada database atau deployment yang dilakukan. Next safe step adalah
  menjalankan rollout pada database target, bukan mengubah resolver Save/Post.
- Behavioral test forward-fix: pencarian Customer lintas Company dipindahkan ke
  fixture sebelum `SET LOCAL ROLE authenticated`. Versi awal salah melakukan
  direct SELECT `customers` setelah pergantian role dan terkena boundary ACP;
  runtime migration/RPC tidak berubah. Jalankan ulang behavioral file dari awal.

### 2026-08-25 - POS LAPTOP TWO-PANEL WORKSPACE LOCAL READY

- Atas instruksi user, UI transaksi PWA diubah tanpa perubahan schema maupun
  business function: panel kiri sekarang berisi searchable Product dropdown dan
  keranjang, sedangkan panel kanan berisi seluruh detail transaksi/pembayaran.
- Product picker mencari nama, SKU, barcode, dan UOM, mempertahankan filter
  kategori, serta menampilkan harga preview Pricelist dan stok. Pemilihan tetap
  memanggil `addToCart`; Product-UOM yang sama tetap menaikkan quantity existing.
- Pada laptop/desktop, kedua panel mengikuti tinggi viewport. Cart dan checkout
  detail scroll secara independen; action Draft/Post tetap berada pada checkout
  form existing. Mobile kembali ke susunan satu kolom dan picker memakai panel
  layar yang dibatasi viewport.
- File runtime berubah: `pwa/src/App.tsx`, `pwa/src/App.css`. Dokumentasi berubah:
  `README.md`, `docs/POS_DEVELOPMENT_NOTES.md`,
  `docs/MANUAL_PENGGUNA_KGS_POS.md`, dan handoff ini.
- Evidence lokal: `pwa/npm.cmd run lint` PASS; `pwa/npm.cmd run build` PASS.
  Warning chunk utama >500 kB adalah warning lama non-blocking.
- Tidak ada migration, database mutation, atau deployment. Authenticated smoke
  yang masih wajib: tambah Product melalui nama/SKU, kategori, harga Pricelist,
  duplicate quantity, edit/remove cart, scroll kedua panel, Save Draft, reload
  Draft, checkout Cash/Transfer/TEMPO, serta responsive mobile.
- Koreksi requirement pada turn berikutnya: user menegaskan Compact adalah UI
  alternatif, bukan pengganti. Runtime kemudian diperbaiki agar mode `Katalog`
  lama tetap default, tombol `Katalog/Compact` tersedia selama sesi, pilihan
  disimpan di `localStorage`, dan pergantian mode tidak mereset cart/Draft.
- Switcher selanjutnya dipindahkan dari workspace ke header sebagai satu
  segmented group. Perubahan jumlah menu Terminal hanya membuat action header
  wrap sebagai unit; pada viewport sempit label switcher disembunyikan, tetapi
  ikon, title, dan `aria-pressed` tetap tersedia. Shell desktop menghitung area
  kerja dari sisa tinggi setelah header dinamis sehingga baris switcher tidak
  lagi mengurangi workspace.
- Compact Product picker dirapikan setelah visual review user: selector input
  kini hanya memiliki satu focus border dengan jarak ikon/placeholder konsisten;
  kategori memakai chip kecil yang wrap dan tidak lagi menampilkan scrollbar
  horizontal. Tidak ada handler atau business contract yang berubah.
### 2026-08-26 — POS TEMPO BACKDATED ORDER/DELIVERY LOCAL READY

- User membuka scope agar order TEMPO yang terlambat input dapat memakai tanggal
  efektif lampau dan rencana kirim juga boleh lampau.
- Migration lokal `20260826100000_pos_tempo_backdated_order_delivery.sql`
  menambah metadata actor/waktu pemilihan tanggal, validator periode terbuka,
  guard ulang pada atomic Post, dan mengarahkan `SALE_POSTED.event_date` ke
  `sales_headers.transaction_date`. `created_at`, `posted_at`, Stock Movement,
  dan status pengiriman tetap aktual/tidak otomatis.
- PWA mengirim `transactionAt`, membuka field hanya pada TEMPO, memberi batas
  masa depan, menurunkan due date otomatis dari tanggal baru, serta membatasi
  rencana kirim agar tidak sebelum order.
- SQL manual: preflight -> migration -> postflight -> behavioral sesuai
  `docs/runbooks/POS_TEMPO_BACKDATED_ORDER_DELIVERY_ROLLOUT.md`. Tidak ada DB
  atau deployment yang disentuh agent.
- Evidence lokal: PWA lint PASS; TypeScript/Vite/PWA production build PASS
  (19 precache entries); `git diff --check` PASS. Warning chunk >500 kB tetap
  warning lama non-blocking. PostgreSQL runtime tetap manual gate user.
- Next safe step: user menjalankan rollout SQL dan mengirim postflight sebelum
  deploy PWA staging/production.
- Postflight correction: check `posted_sale_financial_event_effective_date`
  awalnya salah mencakup seluruh Sale historis `SERVER_CREATED`, sehingga 20
  event lama yang memang memakai waktu posting dilaporkan `FAIL`. Check sekarang
  hanya menguji Sale `CASHIER_SELECTED`; migration/runtime dan data historis
  tidak diubah. User cukup menjalankan ulang postflight terbaru.

### 2026-08-26 — PRODUCT POTENTIAL ANALYTICS DESIGN RECORDED

- Atas instruksi user, desain future optional submodule `Report > Potensi
  Produk` dicatat pada `docs/PRODUCT_POTENTIAL_ANALYTICS_SPEC.md`; implementasi
  sengaja belum dilakukan.
- Model memakai Sale/Return POSTED, immutable UOM snapshot, configurable
  driver/yield/portion/target, version effective date, optional dated backfill,
  async idempotent calculation run, dan report snapshot tenant-scoped.
- Boundary disetujui: analytics read-only terhadap source operational, tidak
  membuat/mengubah Sale, Return, Stock, Purchasing, Pricelist, Payment,
  Financial Event, atau Journal; kegagalan worker tidak boleh memblokir POS.
- Requirement index mendapat `RPT-001`, docs router dan root README sudah
  menunjuk spec. Status tetap approved design / implementation not started.
- Sebelum POT-1, sembilan keputusan terbuka pada section 12 wajib diselesaikan,
  terutama arti yield 80%, daftar driver SKU, dan atribusi periode Return.

### 2026-08-26 — COMPANY COGS-ONLY UPDATE LOCAL READY

- User meminta update COGS dari `Price List Distributor 26082026.xlsx` untuk
  Company `LSM`, `SMS`, dan `KMS`; eksekusi database tetap dilakukan manual
  oleh user.
- Workbook dibaca read-only: `Sheet1` mempunyai 45 baris SKU+COGS valid, tanpa
  COGS invalid atau duplicate SKU. SHA-256 sumber
  `c3d3385935a3b6270c22d43dc9aae2844bc35b837f50ad19e028f99617f33218`.
- Operasi local-ready:
  `supabase/operations/update_company_product_cogs_from_20260826_pricelist.sql`.
  Default PREVIEW, satu Company per run, APPLY memakai confirmation
  `UPDATE_COMPANY_COGS_20260826`, Product/PACK conflict memblokir, dan SKU yang
  tidak ditemukan dilaporkan `SKIPPED`.
- Contract write sengaja sempit: `products.cogs` menjadi harga base-UOM dari
  COGS PACK dan `product_uoms.purchase_price` hanya untuk UOM aktif. Retail,
  `sale_price`, Pricelist, UOM nonaktif, Stock, FIFO, transaksi, Financial
  Event, dan Journal tidak disentuh; Product yang berubah diaudit.
- SELECT-only verification tersedia pada
  `supabase/diagnostics/company_product_cogs_20260826_postflight.sql`; runbook
  pada `docs/runbooks/COMPANY_COGS_UPDATE_20260826.md`.
- Evidence lokal: source workbook dan payload SQL sama persis untuk 45 SKU
  (`MISMATCH_ROWS=0`, total COGS `890470`), duplicate 0; operation/postflight
  quote serta parenthesis balance 0; targeted mutation scan hanya menemukan
  Product, Product-UOM, dan Product audit; `git diff --check` PASS. Tidak ada
  SQL yang dijalankan ke staging/production.
- Next safe step: user menjalankan PREVIEW LSM lalu APPLY; ulangi SMS dan KMS;
  setelah itu jalankan postflight dan kirim seluruh output PASS/FAIL/INFO.

### 2026-08-27 — F2 CUSTOMER RECEIPT FOUNDATION PASS; UI + JOURNAL LOCAL READY

- User mengonfirmasi seluruh F2 foundation postflight PASS: tiga relation,
  empat RPC, browser write boundary, permission ENFORCED, allocation
  reconciliation, dan event coverage bersih. Runtime inventory masih nol dan
  tidak ada fixture transaksi yang dibuat.
- Backoffice ditambah menu `Finance > Penerimaan Customer`, API server, dan UI
  untuk satu Customer ke banyak invoice tempo, partial allocation, Draft resume,
  Post, serta Cancel Draft. File utama:
  `backoffice/src/components/CustomerReceiptView.tsx`,
  `backoffice/src/app/api/finance/customer-receipts/route.ts`, navigation dan
  page shell.
- Migration forward-only `20260827110000_finance_customer_receipt_posting_runtime.sql`
  menambah posting core `SALE_PAYMENT`, dispatcher route, dan wrapper Post
  atomik. Journal: debit receipt-account snapshot, kredit AR snapshot, Customer
  dimension, exact event identity, source/amount verification dan period rule.
- Evidence lokal: targeted ESLint PASS; Backoffice production build PASS, 74
  route. SQL tidak dijalankan agent ke database.
- Manual gate menunggu user: posting preflight -> migration 110000 -> posting
  postflight; lalu authenticated smoke memakai invoice tempo nyata Rp133.500.
  Jangan membuat fixture palsu. Next safe step setelah PASS adalah F3 aging dan
  AR statement/reporting.

### 2026-08-27 — F2 POSTING PASS; F3 PREFLIGHT LOCAL READY

- User mengonfirmasi migration `20260827110000` dan seluruh posting postflight
  PASS. Inventory nol berarti belum ada receipt nyata; bukan pelanggaran.
- F2 dinyatakan database PASS. Backoffice UI tetap local-ready dan authenticated
  transaction smoke menunggu receipt nyata.
- F3 dibuka hanya sebagai SELECT-only preflight:
  `supabase/diagnostics/finance_historical_collection_advance_preflight.sql`.
  Diagnostic membedakan receipt historis terhadap invoice existing dari advance
  sebelum invoice ada, mengaudit Customer Balance policy/category/liability
  account, ledger source gap, temporal integrity dan browser boundary.
- Belum ada migration F3 atau perubahan data. Next safe step: user menjalankan
  preflight F3 dan mengirim semua status; migration baru disusun dari state itu.

### 2026-08-27 — F3 MIGRATION + BACKOFFICE LOCAL READY

- User mengonfirmasi F3 preflight tanpa blocker: lima policy Customer Balance
  `DISABLED`, nol Customer Receipt existing, satu invoice tempo terbuka sebesar
  Rp133.500, temporal/allocation integrity dan browser boundary PASS.
- Migration `20260827120000_finance_historical_collection_customer_advance.sql`
  menambah received/unapplied snapshot dan dua disposition eksklusif. `NONE`
  wajib seluruhnya dialokasikan ke invoice; `CUSTOMER_BALANCE` wajib murni
  unallocated, policy `ACTIVE`, dan tidak boleh dicampur dalam satu dokumen.
- Advance posting atomik membuat ledger Customer Balance, update cache Customer,
  event source-linked, dan jurnal `Dr Cash/Bank; Cr Customer Balance Liability`.
  Lima policy disabled tidak diaktifkan atau diubah migration.
- API/UI Penerimaan Customer mendukung tanggal pembayaran aktual lampau,
  allocation biasa, dan pilihan advance yang disabled saat policy Company tidak
  aktif. Existing allocated-only RPC tetap kompatibel.
- Evidence lokal: targeted ESLint PASS, TypeScript noEmit PASS, Backoffice
  production build PASS (74 route), SQL parentheses seimbang dan diff check
  bersih. Tidak ada DB/deployment mutation oleh agent.
- Manual gate: jalankan migration 120000 lalu postflight F3. Setelah PASS,
  authenticated smoke utama memakai invoice tempo Rp133.500; advance smoke
  hanya dilakukan pada Company yang sengaja diaktifkan Customer Balance.

### 2026-08-27 — F3 POSTFLIGHT PASS; F4A PREFLIGHT LOCAL READY

- User mengonfirmasi seluruh F3 postflight PASS: schema/routine/source guard,
  policy preservation, temporal integrity, ledger/cache reconciliation, browser
  boundary dan event/journal coverage bersih. Runtime inventory masih nol.
- F4 dipecah menjadi F4A reporting lalu F4B posting policy/regression. Preflight
  F4A tersedia di `supabase/diagnostics/finance_ar_reporting_preflight.sql`.
- Diagnostic menutup risiko penting: waktu input backorder boleh terlambat,
  tetapi tanggal bisnis harus tetap `order <= payment <= actual input`.
  Ia juga mengaudit negative outstanding, Customer allocation, timezone, report
  RPC gap dan source inventory.
- Belum ada migration/report UI baru pada F4A. Next safe step: user menjalankan
  F4A preflight dan mengirim seluruh hasil sebelum runtime dibuat.

### 2026-08-27 — F4A AR REPORTING LOCAL READY

- User mengonfirmasi F4A preflight tanpa blocker: dependency F1/F2/F3,
  timezone, allocation/customer integrity, future receipt, negative outstanding,
  dan payment-before-order seluruhnya PASS. Terdapat satu invoice TEMPO terbuka
  dengan outstanding Rp133.500 dan belum ada Customer Receipt POSTED.
- Migration `20260827130000_finance_ar_reporting_runtime.sql` local-ready.
  Tiga RPC read-only menyediakan AR aging as-of, Customer Statement dengan
  opening/running/ending balance, serta explicit EXPORT dataset. Allocation
  mendapat trigger yang menolak tanggal bisnis pembayaran sebelum order.
- Backoffice menu Penerimaan Customer kini memuat filter as-of/rentang,
  ringkasan outstanding/overdue, detail aging, statement per Customer, dan
  download workbook Excel aging/statement sesuai capability EXPORT.
- Evidence lokal: targeted ESLint PASS; TypeScript noEmit PASS; production
  build PASS dengan 76 route; SQL delimiter/parentheses dan `git diff --check`
  PASS. Tidak ada DB/deployment mutation oleh agent.
- Manual gate: migration → postflight → behavioral test → authenticated smoke
  laporan dan kedua download Excel. F4B posting policy dan closing regression
  belum dimulai.
- Behavioral test pertama gagal hanya pada fixture discovery karena memaksa
  Super Admin memiliki `company_memberships`. Test dikoreksi agar memilih
  linked Super Admin lintas Company terlebih dahulu, dengan fallback membership
  Owner/Admin/Finance/Accounting yang benar-benar memiliki VIEW+EXPORT. Runtime
  migration dan data tidak diubah oleh koreksi ini.
- Behavioral run berikutnya menemukan defect runtime pada cabang Receipt
  Customer Statement: `receipt_rows` kehilangan `store_id/store_name`, sehingga
  UNION memiliki 8 versus 10 kolom. Fresh migration 130000 dikoreksi dan
  forward-fix `20260827131000` disediakan untuk database yang sudah terpasang;
  hanya definisi report function yang diganti, tanpa data write.
- User kemudian mengonfirmasi forward-fix, postflight, dan behavioral F4A
  seluruhnya sukses. F4A database dinyatakan PASS; authenticated browser smoke
  report/export masih digabung pada smoke akhir.
- Gate aktif berpindah ke F4B posting policy dan AR closure. Preflight
  SELECT-only tersedia di
  `supabase/diagnostics/finance_ar_posting_policy_closure_preflight.sql`;
  migration belum dibuka sampai event/queue/exception/policy live dinilai.
- F4B preflight pertama gagal sebelum menghasilkan output karena diagnostic
  membandingkan enum `event_status` dengan literal `FAILED` yang tidak tersedia
  pada enum live. CTE dikoreksi mengubah status ke TEXT; ini diagnostic-only dan
  tidak memerlukan migration/data rollback.
- User menjalankan ulang F4B preflight: 31 event/jurnal canonical tertutup,
  9 event final masih `HOLD`, 1 event `CANCELED`, 5 Company `CONTROLLED`, tanpa
  active queue, exception, duplicate, balance, coverage, atau AR blocker.
- Migration `20260827140000_finance_posting_policy_closure.sql` local-ready.
  Ia tidak memposting data saat rollout; queue umum diperluas menjadi
  `ALL_SUPPORTED`, approval/process memakai capability efektif, zero-effect
  tetap `CANCELED/SKIPPED`, policy posting hanya Owner/Admin/Super Admin,
  dan mode otomatis memakai deferred trigger serta retryable exception.
- Backoffice Finance Posting Queue sekarang memuat selector Controlled/Otomatis
  dan guarded backlog processor. API hanya memanggil RPC; direct event/journal/
  policy write tetap tertutup. Backoffice ESLint dan production build 76 route
  PASS.
- Manual gate berikutnya: migration 140000 -> postflight (BACKFILL 9 HOLD masih
  expected) -> behavioral rollback test -> Backoffice controlled preview/
  approve/process -> postflight ulang wajib `supported_hold_backfill_scope=PASS`
  dan tanpa exception -> authenticated policy/queue/report smoke. Jangan aktifkan
  otomatis sebelum controlled backlog bersih.

### 2026-08-27 — F4B CONTROLLED QUEUE MENEMUKAN GAP TEMPO; FORWARD-FIX LOCAL READY

- User mengonfirmasi behavioral F4B PASS dan menjalankan controlled queue KGS.
  Hasil live: 8 dari 9 event POSTED; satu `SALE_POSTED` tanggal 1 Agustus 2026
  gagal `FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH`.
- Diagnosis SELECT-only membuktikan grand total Rp133.500, FIFO/COGS Rp121.000,
  dan net sales cocok. Payment aktual nol sedangkan Rp133.500 adalah piutang;
  runtime G6 lama salah memaksa Payment penuh dan tidak membuat debit AR.
- Ditambahkan preflight, forward migration
  `20260827141000_finance_tempo_sale_posting_fix.sql`, postflight, behavioral
  rollback test, dan runbook. Runtime baru memvalidasi Payment + receivable,
  membuat satu debit `CUSTOMER_RECEIVABLE` dengan Customer dimension, balance,
  source link, dan exact retry. Cash/split/Return dipertahankan.
- Verifikasi lokal: delimiter transaksi/function seimbang dan `git diff --check`
  PASS. SQL belum dijalankan agent ke database; live migration/postflight/test
  masih manual.
- Next safe step: preflight fix -> migration 141000 -> postflight (satu BACKFILL
  expected) -> behavioral -> queue Controlled baru berisi satu event ->
  postflight fix + F4B ulang. Jangan aktifkan AUTOMATIC sebelum HOLD dan open
  exception nol.
- Preflight pertama forward-fix menemukan satu mapping AR historis belum efektif.
  File kemudian diperketat: status menjadi BACKFILL hanya bila account candidate
  tunggal valid; migration membuat fallback interval historis baru dan audit,
  tanpa memutasi mapping aktif yang lebih baru. User perlu menjalankan ulang
  preflight terbaru sebelum migration.

### 2026-08-27 — F4B + TEMPO DATABASE CLOSURE PASS

- User menjalankan forward-fix, behavioral rollback, dan controlled retry satu
  Sale TEMPO. Final postflight F4B serta TEMPO seluruhnya PASS/INFO.
- Evidence live: 40 event POSTED, 40 jurnal POSTED, 1 TEMPO receivable coverage,
  supported HOLD 0, open exception 0, duplicate 0, dan journal imbalance 0.
- Database closure F4B dinyatakan PASS. Lima Company tetap `CONTROLLED`; belum
  ada Company yang diubah ke `AUTOMATIC`.
- Next safe step: authenticated smoke Cash, unpaid/partial TEMPO, Customer
  Receipt, AR report/export, period guard, exact retry, lalu uji Automatic hanya
  pada Company dummy. Jangan memakai Company operasional untuk smoke Automatic.

### 2026-08-27 — INVOICE DATE DISPLAY POLICY LOCAL-READY

- User menyetujui pilihan tanggal Invoice per Company: `ORDER_DATE` untuk
  tanggal bisnis/backorder dan `POSTED_DATE` untuk tanggal POST aktual. Output
  hanya tanggal lokal Company tanpa jam; Surat Jalan tidak berubah.
- Ditambahkan preflight, migration `20260827150000`, postflight, behavioral
  rollback, dan runbook. Default `ORDER_DATE` menjaga compatibility; signature
  RPC empat parameter tetap tersedia sebagai wrapper, sedangkan client baru
  memakai signature lima parameter.
- `private.build_sales_invoice_snapshot` menyimpan
  `branding.invoiceDateDisplayMode` pada Invoice baru. Renderer Backoffice PDF,
  Backoffice print, dan PWA print membaca snapshot; Invoice lama tanpa field
  memakai fallback `ORDER_DATE` dan tidak ditulis ulang.
- UI berada di `Platform -> Profil Perusahaan`; hanya Owner/Admin Company dapat
  mengubahnya melalui guarded API/RPC dengan optimistic `master_version` dan
  branding audit.
- Evidence lokal: Backoffice ESLint PASS, Backoffice production build 76 route
  PASS, PWA oxlint PASS, PWA TypeScript/Vite production build PASS.
- Manual gate menunggu user: preflight -> migration -> postflight -> behavioral
  -> postflight ulang -> smoke dua Invoice baru dengan order date lampau serta
  reprint Invoice pertama. Database production/staging belum diubah oleh agent.
- Revisi tampilan lanjutan menghilangkan nama Kasir dan Terminal dari Invoice
  Backoffice/PWA saja. Kedua field tetap berada di snapshot untuk audit; schema,
  struk POS, dan Surat Jalan tidak berubah.
- Revisi berikutnya menghapus seluruh field/garis tanda tangan dari Invoice
  Backoffice print/PDF. Stempel tetap muncul mandiri ketika diaktifkan; empat
  tanda tangan Surat Jalan tidak diubah.

### 2026-08-27 — SALES DOCUMENT TEMPLATE ALIGNMENT LOCAL-READY

- Keputusan terbaru user: Invoice A4 POS harus sama dengan Backoffice; nota
  thermal tetap berbeda. Surat Jalan dapat memilih template Gudang
  (`Warehouse, Security, Driver, Customer`) atau Toko
  (`Kasir, Ekspedisi, Customer`) per Company.
- Migration additive `20260827151000` menambah
  `company_branding_profiles.delivery_signature_template`, guarded RPC enam
  parameter, wrapper compatibility untuk signature lama, dan snapshot branding
  lengkap pada dokumen baru. Default Company adalah `WAREHOUSE`.
- Backoffice Profil Perusahaan memiliki selector template. Renderer Invoice A4
  POS diselaraskan dengan Backoffice; Invoice tetap tanpa tanda tangan. Renderer
  Surat Jalan POS/Backoffice membaca template snapshot dan menempatkan stempel
  pada kolom pertama. Nota thermal tidak disentuh.
- File utama: migration/preflight/postflight/behavior/runbook alignment,
  `CompanyBrandingView.tsx`, branding API/server, serta kedua renderer dokumen.
- Evidence lokal: Backoffice ESLint dan production build PASS (76 route); PWA
  oxlint, TypeScript, dan Vite production build PASS. `git diff --check` PASS.
- Database dan deployment belum diubah agent. Manual gate: preflight -> migration
  151000 -> postflight -> behavioral -> postflight ulang -> authenticated smoke
  Invoice A4 dan kedua template Surat Jalan.

### 2026-08-27 — SALES DELIVERY OPTIONAL CONTACT LOCAL-READY

- Keputusan user terbaru: saat `Perlu dikirim`, hanya nama penerima wajib.
  Telepon, alamat, jadwal, catatan, dan ongkir boleh kosong; Customer master
  tidak boleh dimutasi dan Kasir tidak mendapat authority tambahan.
- Migration additive `20260827152000` melonggarkan nullability serta dua CHECK,
  mengganti finalizer canonical dan fulfillment configurator, dan memusatkan
  validasi nama pada private helper. Online/offline tetap fail-closed bila nama
  kosong dan idempotency Sale/Invoice/SJ tidak berubah.
- UI POS hanya memblokir nama kosong dan menandai telepon/alamat opsional.
  Renderer POS/Backoffice serta Inventory SJ menampilkan snapshot seadanya tanpa
  separator rusak.
- Evidence lokal: Backoffice ESLint dan production build PASS (76 route); PWA
  oxlint, TypeScript, dan Vite production build PASS. Behavioral SQL memakai
  temporary table dan rollback tanpa fixture Company/User/transaksi.
- Manual gate: preflight -> migration 152000 -> postflight -> rollback-safe
  behavior -> postflight ulang -> smoke online/offline Delivery name-only dan
  negative blank-name. Database/deployment belum disentuh agent.
- First postflight attempt failed before checks because alias `constraint` is a
  PostgreSQL keyword. Postflight was corrected to `catalog_constraint`; no
  migration, schema, or data correction is required.

### 2026-08-27 — COMPANY AUTOMATIC DELIVERY DOCUMENT POLICY LOCAL-READY

- Keputusan user terbaru diimplementasikan sebagai policy Company pada
  `Platform -> Profil Perusahaan`: `DELIVERY_ONLY` default atau
  `ALL_POSTED_SALES`. Policy hanya berlaku untuk Sale baru setelah aktif;
  histori tidak dibackfill.
- Migration `20260827153000_company_automatic_delivery_document_policy.sql`
  menambah policy versioned/audited, snapshot `fulfillment_mode` pada Surat
  Jalan, finalizer server-authoritative, dan lifecycle Pickup langsung
  `READY -> DELIVERED`. Delivery tetap wajib `READY -> DISPATCHED -> DELIVERED`.
- Pickup mengambil penerima/telepon/alamat dari snapshot Customer; hanya nama
  yang diberi fallback aman. Master Customer, Stock, Payment, Financial Event,
  Journal, Invoice, dan nota thermal tidak dimutasi oleh policy.
- UI Inventory membedakan `Ambil di toko` versus `Pengiriman`; Pickup memakai
  tombol **Sudah diserahkan**. RPC enam/lima/empat parameter lama tetap
  kompatibel dan mempertahankan policy existing.
- File SQL lengkap: preflight, migration, postflight, behavioral fixture-free,
  serta runbook `COMPANY_AUTOMATIC_DELIVERY_DOCUMENT_POLICY_ROLLOUT.md`.
- Evidence lokal: Backoffice ESLint PASS; Backoffice production build PASS
  (76 route); SQL delimiter/parentheses balance PASS; `git diff --check` PASS.
- Database/deployment tidak disentuh agent. Manual gate: preflight -> migration
  153000 -> postflight -> behavioral -> postflight ulang -> smoke Pickup default,
  Pickup all-Sale, direct handover, Delivery lifecycle, dan exact retry.
- Koreksi diagnostic 27 Agustus: preflight dan postflight awal salah membaca
  `companies.is_active`; schema canonical memakai `companies.status='ACTIVE'`.
  Kedua file sudah diperbaiki. Migration/runtime tidak berubah dan belum perlu
  dijalankan sebelum preflight terbaru menghasilkan output tanpa blocker.
### 2026-08-27 — Automatic Surat Jalan postflight early-run compatibility correction

- Corrected `supabase/tests/company_automatic_delivery_document_policy_postflight.sql` so newly introduced columns are inspected through `to_jsonb(record)` instead of referenced directly.
- Before this correction, running the postflight before migration `20260827153000` was committed raised PostgreSQL `42703` for `sales_delivery_documents.fulfillment_mode` instead of reporting schema and migration checks as `FAIL`.
- Migration/runtime behavior is unchanged. Safe order remains preflight, migration, behavioral test, then postflight.

### 2026-08-27 — Automatic Surat Jalan migration parser correction

- Simplified the `private.ensure_sales_documents` header-SJ synchronization by
  resolving the target `sj_status` into `v_header_sj_status` before its
  comparison and update.
- This removes the inline `IS DISTINCT FROM CASE ... END` expression reported
  by Supabase as an end-of-input parser failure. Business behavior is unchanged.
- The failed attempt was inside the migration transaction and does not authorize
  assuming the ledger/schema was applied; rerun the corrected migration from
  the beginning, then verify through postflight.

### 2026-08-27 — POS automatic delivery UI default LOCAL-READY

- POS bootstrap now reads the active Company's guarded branding policy. When
  `deliveryDocumentCreationPolicy=ALL_POSTED_SALES`, a new transaction defaults
  **Perlu dikirim** to checked; `DELIVERY_ONLY` retains the previous unchecked
  default.
- Existing drafts retain their saved `fulfillmentMode`. Customer delivery data
  is copied when available and missing optional values remain blank. Walk-In
  recipient name remains blank so the existing required-name validation is not
  silently bypassed.
- The policy is retained in the offline operational scope for cold-start
  consistency. This is a PWA/UI bootstrap change only; server posting, Stock,
  Payment, Finance, and the migration chain are unchanged.
- User reported the SQL rollout/checks safe before this UI follow-up. Local
  evidence for the UI follow-up: PWA oxlint PASS, TypeScript/Vite production
  build PASS, and `git diff --check` PASS. Authenticated browser smoke remains
  manual.
# Update 2026-08-27 — Customer CV Master Clean manual Company import prepared

- User meminta import Customer dari workbook
  `PENAMBAHAN CUST CV - MASTER CLEAN (1).xlsx` dijalankan sendiri melalui
  Supabase dan dipisah per Company; tidak ada database yang dimutasi agent.
- Read-only source/production audit:
  - 125 baris memiliki Company valid: KMS 39, LSM 58, SMS 28;
  - 80 pasangan `Company + customer_code` sudah ada dan wajib tetap untouched;
  - 45 Customer belum ada: KMS 20, LSM 16, SMS 9;
  - hanya 13 Customer baru memiliki Kabupaten dan Provinsi lengkap; alamat baru
    dibentuk sebagai `KABUPATEN - PROVINSI`, sisanya `NULL`;
  - C03/H08/H12 berpindah LSM→KMS dan H17 berpindah LSM→SMS. Keempat Customer
    lama tidak memiliki transaksi, saldo, child Customer, atau Customer
    Pricelist pada audit read-only sehingga layak diarsipkan setelah replacement
    tersedia; tidak dilakukan hard delete.
- File baru:
  - `data/import/customer_cv_20260827/customer_import_KMS_20260827.csv`;
  - `data/import/customer_cv_20260827/customer_import_LSM_20260827.csv`;
  - `data/import/customer_cv_20260827/customer_import_SMS_20260827.csv`;
  - `docs/runbooks/CUSTOMER_CV_MASTER_CLEAN_IMPORT_20260827.md`.
- Kontrak import final:
  - memakai Data Exchange `CUSTOMER`, `REFERENCE_BY_NAME`, dan `CREATE_ONLY`;
  - hanya memuat 45 kode yang belum ada; existing target tidak disertakan;
  - KMS/LSM/SMS masing-masing 20/16/9 baris;
  - empat nama `Dedi Supriadi` KMS diberi suffix kode agar memenuhi uniqueness;
  - arsip C03/H08/H12/H17 lama dilakukan manual setelah replacement tersedia.
- Verification lokal:
  - workbook dibaca read-only dan source rows dibandingkan dengan database;
  - ketiga CSV berhasil diparse dengan 13 kolom canonical, source row
    KMS/LSM/SMS = 20/16/9, tanpa invalid required field, duplicate code, atau
    duplicate normalized name;
  - `git diff --check` PASS;
  - tidak ada migration/schema/runtime/frontend yang berubah.
- Manual gate menunggu user:
  1. aktifkan Company sesuai file;
  2. import Customer memakai `Cocokkan berdasarkan nama` dan
     `Hanya buat data baru`;
  3. validasi wajib seluruhnya CREATE dan tanpa UPDATE/ERROR;
  4. setelah target tersedia, arsipkan manual C03/H08/H12/H17 lama di LSM bila
     pemeriksaan history saat itu tetap bersih.

- Koreksi setelah manual KMS pertama:
  - versi awal memakai beberapa statement dan `CREATE TEMP TABLE ... ON COMMIT
    DROP`; Supabase SQL Editor menghilangkan temp relation sebelum blok konsumsi
    sehingga menghasilkan `relation customer_cv_control does not exist`;
  - statement gagal sebelum mutation dan tidak meninggalkan data parsial;
  - percobaan single-statement berikutnya tetap berbenturan dengan constraint
    nama unik karena empat kode memakai nama `Dedi Supriadi`; statement APPLY
    rollback dan tidak meninggalkan mutation parsial;
  - atas instruksi user, jalur direct SQL dihentikan dan ketiga operation SQL
    dihapus. Deliverable final adalah tiga CSV guarded melalui preview Data
  Exchange; database tetap tidak dimutasi agent.

### 2026-08-28 — ODR-4B PASS; ODR-4C LOCAL-READY

- User mengonfirmasi closing postflight ODR-4B seluruhnya PASS: tujuh routine,
  hook confirm/cancel/close, private boundary, demand/header reconciliation,
  dan browser table boundary bersih. Runtime inventory demand masih nol;
  21 Stock Request, dua Draft PO, dan 17 PO final legacy tidak berubah.
- Migration `20260828170000_odr_phase4c_session_stock_request_projection.sql`
  local-ready. Saat sesi ditutup, shortage demand dibentuk menjadi satu Stock
  Request `SUBMITTED`, digabung per Product/base UOM, lalu demand line ditautkan
  ke request line. Sebelum sesi ditutup tidak ada Stock Request baru.
- Compatibility: source manual dan `NEGATIVE_STOCK_SESSION_CLOSE` tetap ada;
  source baru `SALES_ORDER_RESERVATION` unik per sesi dan tidak dapat dibatalkan
  manual. Fase ini tidak menyentuh Supplier Order, Stock/FIFO/Movement, event,
  atau jurnal.
- Evidence lokal: delimiter SQL seimbang, forbidden mutation scan bersih, dan
  `git diff --check` tidak menemukan whitespace error. Database belum dimutasi
  agent.
- Manual gate: migration 170000 -> postflight -> behavioral rollback ->
  postflight ulang -> smoke dua Order shortage satu sesi lalu tutup sesi.
- Next safe step setelah PASS: ODR-4D menyinkronkan hanya Draft PO dan membuat
  delta/amendment untuk PO final; jangan mengubah PO final in-place.

### 2026-08-28 — ODR-4C PASS; ODR-4D PREFLIGHT LOCAL-READY

- User mengonfirmasi ODR-4C closing postflight seluruhnya PASS: tiga routine,
  close hook, source/identity/quantity contract, demand-request lineage, dan
  private boundary bersih. Dua Draft PO dan 17 PO final legacy tetap utuh.
- Runtime inventory ODR-4C nol adalah expected karena belum ada sesi ODR dengan
  shortage yang ditutup.
- Preflight SELECT-only ODR-4D tersedia di
  `supabase/diagnostics/odr_phase4d_draft_po_sync_preflight.sql`. Audit membedakan
  Draft PO allocation-backed, quantity manual/campuran, target Draft ambigu,
  serta allocation pada PO final.
- Tidak ada migration/runtime/PO mutation pada langkah ini. Manual gate:
  jalankan preflight dan kirim seluruh output. `BLOCKER` wajib ditangani;
  `REVIEW` adalah inventaris desain.

### 2026-08-28 — ODR-4D PREFLIGHT PASS; AMENDMENT FOUNDATION LOCAL-READY

- User mengonfirmasi preflight ODR-4D tanpa blocker. Seluruh managed request,
  managed Draft/final allocation, ambiguity, over-allocation, dan cross-product
  scope nol. Dua Draft PO legacy mempunyai 18 line yang semuanya
  allocation-backed; karena bukan source ODR, migration tidak menyentuhnya.
- Migration `20260828180000_odr_phase4d_amendment_foundation.sql` local-ready.
  Ia menambah notice delta/amendment dan audit immutable, tenant FK, partial
  unique open notice, RLS, serta browser closure dengan zero backfill.
- Tidak ada Stock Request/PO/Stock/FIFO/Finance mutation. Manual gate:
  migration 180000 -> postflight -> behavioral rollback -> postflight ulang.
- Next safe step setelah PASS: runtime reconciliation yang hanya mengubah
  allocation-backed Draft PO tunggal; target ambigu/manual/final menghasilkan
  notice dan tidak dimutasi.

### 2026-08-28 — AMENDMENT FOUNDATION PASS; REQUEST RECONCILIATION LOCAL-READY

- User mengonfirmasi amendment foundation migration/postflight/behavior aman:
  dua relation RLS, dua trigger, browser boundary, zero backfill, dan legacy
  21 Request/dua Draft PO/17 PO final tetap utuh.
- Migration `20260828190000_odr_phase4d_managed_request_reconciliation.sql`
  local-ready. Ia membungkus refresh demand secara atomik, memperbarui managed
  Stock Request setelah sesi ditutup, menambah/menyegarkan notice, dan menjaga
  exact retry lewat demand audit operation.
- `stock_request_lines.is_active` menjaga lineage baris quantity nol tanpa hard
  delete; composed reader Purchasing hanya mengembalikan baris aktif.
- Runtime ini tidak memutasi Supplier Order, Stock/FIFO/Movement, event, atau
  jurnal. Evidence lokal: delimiter/parentheses seimbang, forbidden mutation
  scan bersih, `git diff --check` bersih.
- Manual gate: migration 190000 -> postflight -> behavioral -> postflight
  ulang. Next setelah PASS adalah eligible single-Draft-PO sync.
- Koreksi manual gate: postflight awal gagal ketika `pg_get_functiondef`
  mencoba mendeparse referensi legacy `public.supplier_order`. Test postflight
  dan behavioral kini membaca `pg_proc.prosrc` serta memeriksa hanya relation
  canonical `supplier_order_documents`, `supplier_order_lines`, dan
  `supplier_order_request_allocations`. Migration 190000 tidak perlu diulang;
  jalankan ulang postflight terkoreksi lalu behavioral dan postflight penutup.

### 2026-08-28 — REQUEST RECONCILIATION PASS; SINGLE DRAFT PO SYNC LOCAL-READY

- User mengonfirmasi migration 190000 closing postflight seluruhnya PASS:
  routine, private boundary, active-line/reconciliation, amendment quantity,
  exact operation, dan no-PO-mutation contract bersih. Dua Draft PO/17 final PO
  tetap utuh dan tidak ada open amendment.
- Migration `20260828200000_odr_phase4e_single_draft_po_sync.sql` local-ready.
  Ia menyinkronkan hanya delta positif pada tepat satu Draft PO line yang fully
  allocation-backed, menjaga precision UOM, optimistic version, audit, dan
  exact retry. UOM tidak presisi tetap menjadi notice review.
- PO final/ambigu/manual, Stock/FIFO/Movement, AP, Financial Event, dan Journal
  tidak dimutasi. Migration zero-backfill dan transactional.
- Evidence lokal: delimiter dan tanda kurung SQL seimbang, test tidak memakai
  fixture/auth user/data transaksi, protected final-effect mutation scan kosong,
  dan `git diff --check` PASS (hanya warning line-ending file existing).
- Manual gate: migration 200000 -> postflight -> behavioral -> postflight ulang
  sesuai `docs/runbooks/ODR4E_SINGLE_DRAFT_PO_SYNC.md`. Next setelah PASS adalah
  ODR-5 Finance Dispatch dan verifikasi Payment; UI tetap menunggu ODR-6.

### 2026-08-28 — ODR-4E PASS; ODR-5 FINANCE PREFLIGHT LOCAL-READY

- User mengonfirmasi ODR-4E seluruhnya PASS: tiga routine, private boundary,
  draft-only audit, UOM review reason, over-allocation, amendment, dan migration
  ledger bersih. Dua Draft PO/17 PO final tetap utuh; open amendment nol.
- ODR-4 database gate selesai. Preflight SELECT-only ODR-5 tersedia di
  `supabase/diagnostics/odr_phase5_finance_dispatch_payment_preflight.sql`
  dengan runbook `docs/runbooks/ODR5_FINANCE_DISPATCH_PAYMENT_PREFLIGHT.md`.
- Audit ODR-5 membedakan final effect Dispatch dari verifikasi Payment,
  memeriksa partial Dispatch, payment intent, accounting period, mapping akun,
  existing event/journal, serta memastikan legacy Sale POSTED tidak diposting
  ulang.
- Belum ada migration/schema/runtime/UI ODR-5. Evidence lokal: file hanya
  menggunakan satu statement `WITH ... SELECT`, tidak mempunyai mutation.
- Manual gate: jalankan preflight dan kirim seluruh output. `BLOCKER` dan
  `BACKFILL` harus ditangani; `SETUP` event/runtime ODR-5 expected. Jangan buat
  migration Finance atau aktifkan automatic posting sebelum hasil live ditinjau.

### 2026-08-28 — ODR-5 PREFLIGHT PASS; FINANCE SOURCE FOUNDATION LOCAL-READY

- User mengonfirmasi ODR-5 preflight tanpa blocker: active Finance queue dan
  nonterminal Offline submission nol; accounting period, payment intent,
  document snapshot, journal balance, serta legacy Sale boundary seluruhnya
  PASS. Belum ada Order, Dispatch operation, atau payment intent ODR live.
- Migration `20260828210000_odr_phase5a_finance_source_foundation.sql`
  local-ready dan zero-backfill. Ia menambah source immutable Dispatch,
  lifecycle request verifikasi Payment, audit append-only, event catalog
  dedicated, fungsi akun uang muka customer, RLS, serta browser closure.
- Fase ini tidak membuat Financial Event/Journal, tidak mengubah Stock/FIFO,
  payment legacy, Sale historis, atau queue posting. Permission verifikasi tetap
  `SHADOW`; mapping COA dan runtime posting masih gate berikutnya.
- Evidence lokal: tipe/FK dibandingkan dengan schema canonical, alias parser
  berisiko dihapus, event/account catalog memiliki conflict guard, delimiter
  dan mutation boundary diperiksa, serta `git diff --check` dijalankan.
- Manual gate: migration 210000 -> postflight -> behavioral fixture-free ->
  postflight ulang. Next safe step setelah seluruhnya PASS adalah preflight
  mapping/runtime ODR-5B; jangan membuka automatic posting atau UI ODR-6.

### 2026-08-28 — ODR-5A PASS; ODR-5B MAPPING/RUNTIME PREFLIGHT LOCAL-READY

- User mengonfirmasi closing postflight ODR-5A seluruhnya PASS: migration
  ledger, empat relation, RLS, browser closure, empat trigger, event catalog,
  permission SHADOW, account function, dan zero-backfill bersih. Inventory
  source/audit tetap nol dan 40 jurnal historis tidak berubah.
- Preflight SELECT-only
  `supabase/diagnostics/odr_phase5b_finance_mapping_runtime_preflight.sql`
  local-ready. Ia memeriksa candidate account dengan prioritas satu system COA
  lalu satu fallback, sehingga tidak menghitung dua jalur sah sebagai ambiguity.
- Audit juga memeriksa Customer Advance code/name collision, category/rule,
  enum compatibility, dispatcher, controlled queue, active Finance queue,
  Offline submission, source zero-runtime, dan jurnal historis.
- Tidak ada mutation/schema/runtime baru pada langkah ini. Manual gate:
  jalankan preflight dan kirim seluruh output. Jangan mengaktifkan automatic
  posting atau membuat event/jurnal ODR sebelum hasil ditinjau.

### 2026-08-28 — ODR-5B INITIAL PREFLIGHT REVIEWED; REUSABLE MAPPING AUDIT

- Initial ODR-5B output tidak memiliki `BLOCKER`. Customer Advance `BACKFILL`
  pada lima Company expected dan kode default `2190` tidak collision.
- Empat Company melaporkan COGS/Inventory/Sales Revenue tanpa system-owned COA
  atau Company fallback; ROUNDING_GAIN juga demikian. Ini belum membuktikan
  account ekonominya hilang karena active transaction rule existing dapat
  menunjuk account valid yang sama.
- Agar tidak menggandakan COA Persediaan/HPP/Penjualan, ditambahkan preflight
  SELECT-only `odr_phase5b_reusable_account_mapping_preflight.sql`. Candidate
  dipilih berurutan dari satu system account, satu reusable active-rule account,
  lalu satu fallback; jumlah lain fail closed.
- Manual gate: jalankan audit reusable dan kirim output. Migration mapping belum
  dibuat; event/jurnal/automatic posting tetap tidak berubah.

- Percobaan awal audit reusable melaporkan 16 ambiguous system-account rows.
  Ini bukan kerusakan jurnal: audit awal salah mendahulukan label master global,
  sedangkan resolver Finance memakai exact event/category rule. File audit
  diperbaiki untuk memilih ACTIVE `SALE_POSTED`/`SALE_PAYMENT` source rule,
  lalu fallback, baru satu system account. Jalankan ulang file yang sama.

### 2026-08-28 — ODR-5B REUSABLE MAPPING PASS; MAPPING FOUNDATION LOCAL-READY

- User mengonfirmasi audit reusable terkoreksi aman. Core dan conditional
  account source seluruhnya `PASS`; queue aktif nol; history 40 jurnal tetap
  balance. Satu-satunya write scope adalah lima akun
  `CUSTOMER_ADVANCE_LIABILITY`, code `2190`, tanpa ambiguity/collision.
- Migration `20260828220000_odr_phase5b_finance_mapping_foundation.sql`
  local-ready. Ia membuat satu akun advance per Company aktif, dua category
  ODR, 17 exact transaction-account mapping, serta dua approved versioned
  Posting Rule Set (18 line) per Company. Existing account dipilih fail-closed
  dari exact source-event rule, Company fallback, lalu sole system account;
  `BANK_RECEIPT` memakai alias BANK yang sudah disetujui G6.
- Dispatch event catalog diperluas secara eksplisit dengan
  `CUSTOMER_ADVANCE_LIABILITY` agar uang muka yang diverifikasi sebelum kirim
  dapat didebit ketika revenue diakui saat Dispatch.
- Migration tidak membuat Financial Event/Journal, tidak mengubah Stock/FIFO,
  Sale/Payment/Delivery, dan tidak memproses queue. Source ODR wajib masih nol.
- Evidence lokal: tiga SQL file mempunyai delimiter dan parentheses seimbang;
  `git diff --check` PASS. PostgreSQL execution tetap manual karena local psql
  tidak tersedia.
- Manual gate: migration 220000 -> postflight -> behavioral rollback ->
  postflight ulang sesuai `docs/runbooks/ODR5B_FINANCE_MAPPING_FOUNDATION.md`.
  Stop pada SQL error/FAIL. Next safe step hanya setelah PASS adalah ODR-5C
  source capture dan controlled dispatcher; automatic posting/UI tetap tutup.
- Percobaan migration pertama ditolak aman oleh canonical trigger
  `POSTING_RULE_SET_MUST_START_DRAFT`. Seluruh statement ter-rollback karena
  migration transactional. File 220000 diperbaiki mengikuti lifecycle G6:
  header dibuat `DRAFT`, line diisi, audit `CREATE` ditulis, baru header diubah
  ke `APPROVED` dan audit `APPROVE` ditulis. Version migration tidak berubah;
  user harus menjalankan ulang file 220000 dari awal.
- Postflight pertama setelah migration menggunakan nama konseptual
  `canonical_journals`, bukan relation fisik `finance_journals`, sehingga gagal
  pada parse tanpa mengubah data. Postflight dan behavioral dikoreksi untuk
  memakai `public.finance_journals`; migration yang sudah sukses tidak boleh
  diulang, cukup jalankan postflight terkoreksi.
- Percobaan postflight berikutnya ditolak parser karena ekspresi `CASE` dipakai
  langsung pada `ORDER BY` compound `UNION`. Query final dikoreksi dengan
  membungkus hasil `checks UNION ALL inventory` sebagai subquery `result`, baru
  mengurutkan kolomnya. Kegagalan SELECT ini juga tidak mengubah data.

### 2026-08-28 — ODR-5B CLOSING PASS; ODR-5C DISPATCH FINANCE PREFLIGHT READY

- User mengonfirmasi output closing postflight setelah behavioral ODR-5B
  seluruhnya PASS: lima Customer Advance account, sepuluh category, 85 exact
  mapping, sepuluh approved Posting Rule Set, audit lengkap, queue nol, serta
  zero ODR Event/Journal effect. Histori 40 jurnal tetap utuh.
- Preflight SELECT-only
  `supabase/diagnostics/odr_phase5c_dispatch_finance_runtime_preflight.sql`
  local-ready. Ia mengaudit dependency 3C/5A/5B, zero source runtime, operasi
  Dispatch existing, Invoice/SJ, allocation/Movement, accounting period, exact
  mapping/rule, enum compatibility, dan current dispatch hook.
- Partial Dispatch tetap memakai satu effect per idempotency key, commercial
  allocation proporsional, actual FIFO/approved negative provisional cost, dan
  residual tax/delivery/surcharge/rounding hanya pada final Dispatch. Payment
  verification tetap boundary ODR-5D.
- Evidence lokal: file hanya satu `WITH ... SELECT`, mutation scan kosong,
  delimiter/parentheses 125/125, forbidden relation/alias scan kosong, dan
  `git diff --check` PASS.
- Manual gate: jalankan preflight ODR-5C dan kirim seluruh output. Stop pada
  `BLOCKER`. Jangan membuat Event/Journal atau membuka automatic posting/UI
  sebelum hasil live ditinjau.

### 2026-08-28 — ODR-5C PREFLIGHT PASS; DISPATCH FINANCE RUNTIME LOCAL-READY

- User mengonfirmasi preflight live ODR-5C tanpa blocker. Queue aktif,
  nonterminal Offline, operation Dispatch lama tanpa source, serta source
  Finance seluruhnya nol. Period, document snapshot, allocation/Movement,
  exact mapping, approved rule, dan jurnal historis aman.
- Migration `20260828230000_odr_phase5c_dispatch_finance_runtime.sql`
  local-ready. Core ODR-3C dipertahankan sebagai private stock core dan
  dibungkus atomik dengan capture Finance; kegagalan capture me-rollback Stock,
  FIFO, Movement, dan reservation pada call yang sama.
- Satu dispatch idempotency key membuat satu immutable effect dan satu event
  `SALE_DISPATCHED` `HOLD`. Partial memakai rasio reservation per commercial
  line; Dispatch final menutup residual Tax, ongkir, surcharge, dan rounding.
  Cost snapshot memisahkan FIFO aktual dan provisional negative-stock total
  yang benar-benar dipakai stock runtime.
- Controlled dispatcher dan `ALL_SUPPORTED` queue mengenali event baru. Mode
  `AUTOMATIC` dijaga server dan tetap ditolak sampai ODR-5D. Payment
  verification, UI, Return cutover, dan historical journal tidak berubah.
- File verifikasi:
  - `supabase/tests/odr_phase5c_dispatch_finance_runtime_postflight.sql`;
  - `supabase/tests/odr_phase5c_dispatch_finance_runtime_behavior.sql`;
  - `docs/runbooks/ODR5C_DISPATCH_FINANCE_RUNTIME.md`.
- Evidence lokal: function delimiter seimbang, private/browser privilege scan
  tertutup dalam postflight, protected runtime source diperiksa, dan
  `git diff --check` PASS. PostgreSQL execution belum dilakukan agent karena
  tidak tersedia local database; rollout tetap manual.
- Manual gate: migration 230000 → postflight → behavioral rollback → postflight
  ulang. Setelah semuanya PASS, lakukan smoke partial/final non-TEMPO dan TEMPO
  pada Company dummy dengan controlled queue. Next safe step adalah ODR-5D
  Payment verification; jangan membuka automatic posting atau UI ODR-6.

### 2026-08-28 — ODR-5C CLOSING PASS; ODR-5D PAYMENT PREFLIGHT READY

- User mengonfirmasi closing postflight ODR-5C seluruhnya PASS: delapan
  routine, atomic Dispatch/Finance wrapper, controlled dispatcher,
  source/Event/settlement/FIFO reconciliation, private boundary, dan automatic
  policy guard valid. Runtime ODR effect/event/journal masih nol; 40 jurnal
  historis tetap utuh.
- Ditambahkan preflight SELECT-only
  `supabase/diagnostics/odr_phase5d_payment_verification_runtime_preflight.sql`
  dan runbook
  `docs/runbooks/ODR5D_PAYMENT_VERIFICATION_RUNTIME_PREFLIGHT.md`.
- Audit menguji dependency 5A/5B/5C, active queue/Offline, source schema dan
  zero-runtime, identity/duplicate/nominal intent, Payment Method/Store/proof,
  total non-TEMPO/TEMPO, exact account mapping, approved rule, enum, permission,
  legacy boundary, serta inventory live.
- Tiga review contract tetap eksplisit: pre-Dispatch receipt masuk Customer
  Advance lalu dipakai proporsional saat Dispatch; post-Dispatch receipt
  melunasi Clearing atau Piutang; Cash fisik harus masuk expected drawer tepat
  sekali tanpa menunggu atau menggandakan Journal Finance.
- Evidence lokal: file hanya `WITH ... SELECT`, mutation dan forbidden-reference
  scan kosong, parentheses seimbang, dan scoped `git diff --check` PASS.
- Manual gate: jalankan preflight ODR-5D dan kirim seluruh output. Stop pada
  `BLOCKER`. Jangan memasang runtime, mengubah Cash drawer/session, membuka
  automatic posting, atau membuat UI ODR-6 sebelum hasil live ditinjau.

### 2026-08-28 — ODR-5D PREFLIGHT PASS; PAYMENT RUNTIME LOCAL-READY

- User mengonfirmasi preflight ODR-5D seluruh hard gate `PASS`: queue aktif dan
  Offline submission nol, exact mapping/rule serta event enum siap, payment
  intent ODR nol, dan 27 Payment/40 Journal legacy tidak masuk cutover.
- Migration `20260828240000_odr_phase5d_payment_verification_runtime.sql`
  local-ready. Confirmed Order menangkap payment intent immutable; Cash masuk
  `cash_drawer_movements` tepat sekali; sesi tidak dapat ditutup jika Cash masih
  `PENDING`; reject Cash membuat reversal hanya ketika sesi masih OPEN.
- Finance composed-read serta verify/reject memakai effective capability,
  maker-checker, optimistic version, dan idempotency key. Verify membuat satu
  `SALE_PAYMENT_VERIFIED` HOLD Event. Controlled dispatcher membuat jurnal
  settlement balance atau menutup event no-effect saat akun debit/kredit sama.
- `CUSTOMER_BALANCE`/`KETUL_OFFSET` tetap memakai liability ledger existing.
  Automatic posting tetap diblok sampai 250000. Verified pre-dispatch advance
  diblok dari Dispatch sampai ODR-5E memasang aplikasi advance proporsional.
- File verifikasi: behavioral
  `supabase/tests/odr_phase5d_payment_verification_runtime_behavior.sql`,
  postflight
  `supabase/tests/odr_phase5d_payment_verification_runtime_postflight.sql`, dan
  runbook `docs/runbooks/ODR5D_PAYMENT_VERIFICATION_RUNTIME.md`.
- Evidence lokal: 11 function body/delimiter seimbang, parentheses 205/205,
  forbidden relation scan kosong, canonical `cashier_sessions.pos_id` dipakai,
  serta scoped `git diff --check` PASS. PostgreSQL execution belum dilakukan
  karena local psql/database tidak tersedia.
- Manual gate: migration 240000 → behavioral rollback → postflight. Stop pada
  SQL error/FAIL. Next safe step setelah seluruhnya PASS adalah ODR-5E advance
  application dan closing reconciliation; jangan membuka automatic atau UI.

### 2026-08-28 — ODR-5D CLOSING PASS; ODR-5E LOCAL-READY

- User mengonfirmasi behavioral dan closing postflight ODR-5D seluruhnya PASS:
  11 routine, enam kolom, permission `ENFORCED`, browser/private boundary,
  Cash once/reversal, Event/Journal coverage, serta migration ledger bersih.
  Request/Event/Journal ODR tetap nol dan automatic Companies nol.
- Migration `20260828250000_odr_phase5e_dispatch_advance_reconciliation.sql`
  local-ready dan mempunyai strict zero-runtime precondition sesuai live state.
  ODR-5C Stock/FIFO core tetap dipakai; sesudah effect dibuat, helper melakukan
  one-time guarded settlement rebalance dalam transaksi Dispatch yang sama.
- Final Dispatch membawa residual payment surcharge dari immutable Order
  payment snapshot. Verified pre-dispatch payment mengurangi Customer Advance;
  residual masuk Payment Clearing untuk non-TEMPO atau Customer Receivable
  untuk TEMPO. Partial Dispatch tidak mengambil fixed surcharge.
- Effect hanya dapat direbalance dari version 0 ke 1 ketika Event `HOLD` dan
  belum memiliki Journal. Event amounts/version dan append-only `REBALANCE`
  audit diperbarui atomik; exact retry membaca result yang sama.
- Verification files:
  `supabase/tests/odr_phase5e_dispatch_advance_reconciliation_behavior.sql`,
  `supabase/tests/odr_phase5e_dispatch_advance_reconciliation_postflight.sql`,
  dan `docs/runbooks/ODR5E_DISPATCH_ADVANCE_RECONCILIATION.md`.
- Static evidence: migration 5 function body/5 terminator, parentheses 96/96;
  behavioral 13/13; postflight 117/117 dan SELECT-only; scoped
  `git diff --check` PASS. Local PostgreSQL execution tidak tersedia.
- Manual gate: migration 250000 → behavioral rollback → postflight. Automatic
  posting tetap memerlukan 260000. Setelah PASS lanjut ODR-5F authenticated
  reconciliation/closure; UI ODR-6 tetap belum dibuka.

### 2026-08-28 — ODR-5E CLOSING PASS; ODR-5F FINANCE CLOSURE LOCAL-READY

- User mengonfirmasi closing postflight ODR-5E seluruhnya PASS: atomic
  rebalance, advance application, surcharge residual, event/effect/audit,
  posting-order guard, private boundary, dan migration ledger valid. Runtime
  source ODR tetap nol dan tidak ada Finance queue aktif.
- Migration `20260828260000_odr_phase5f_finance_runtime_closure.sql`
  local-ready. Canonical dispatcher mempertahankan payment/dispatch routing dan
  advance-before-Dispatch dependency, lalu menormalkan hasil zero-effect
  menjadi `CANCELED` dengan reason `NO_FINANCIAL_EFFECT` agar controlled queue
  dan automatic trigger mempunyai outcome yang sama.
- Guard policy automatic dipindahkan ke ledger ODR-5F. Migration tidak mengubah
  satu pun Company dari `CONTROLLED`; enable automatic tetap tindakan
  Owner/Admin eksplisit dan versioned setelah rollout PASS.
- Verification files:
  `supabase/tests/odr_phase5f_finance_runtime_closure_behavior.sql`,
  `supabase/tests/odr_phase5f_finance_runtime_closure_postflight.sql`, dan
  `docs/runbooks/ODR5F_FINANCE_RUNTIME_CLOSURE.md`.
- Manual gate: migration 260000 → behavioral rollback → postflight. Stop pada
  SQL error/FAIL. Setelah semua PASS, next safe step adalah ODR-6 authenticated
  POS/Inventory/Purchasing/Finance UI dan E2E cutover; jangan mengaktifkan mode
  automatic sebelum controlled smoke dinyatakan bersih.

### 2026-08-28 — ODR-5F CLOSING PASS; ODR-6 PREFLIGHT LOCAL-READY

- User mengonfirmasi closing postflight ODR-5F seluruhnya PASS: migration chain
  enam versi, parity controlled/automatic, policy guard, private boundary,
  source/event/journal, Advance ordering, queue dan exception seluruhnya aman.
  Lima Company tetap `CONTROLLED`; runtime ODR masih nol.
- Audit source lokal menemukan PWA masih memakai
  `post_pos_sale_with_pricelist`, Backoffice Delivery masih memakai
  `update_sales_delivery_status`, dan workspace demand Purchasing serta payment
  verification Finance belum menjadi active UI consumer.
- Ditambahkan preflight SELECT-only
  `supabase/diagnostics/odr_phase6_ui_e2e_cutover_preflight.sql` dan runbook
  `docs/runbooks/ODR6_UI_E2E_CUTOVER_PREFLIGHT.md`. Audit mencakup dependency,
  sembilan public RPC canonical, protected-table privileges, active queue/
  exception/Offline, reservation/Dispatch/Finance reconciliation, permission,
  legacy consumer boundary, dan authenticated UAT scope.
- Tidak ada frontend, database runtime, policy, transaction, stock, event, atau
  journal yang diubah. Next safe step: user menjalankan preflight dan mengirim
  seluruh output. Stop pada `BLOCKER`; setelah bersih mulai ODR-6A POS cutover.

### 2026-08-28 — ODR-6 PREFLIGHT PASS; ODR-6A POS CUTOVER LOCAL-READY

- User mengonfirmasi preflight ODR-6 tanpa blocker: sembilan RPC canonical,
  migration dependency, protected table, queue/exception, reservation,
  Dispatch, Finance, dan Offline boundary bersih. Review consumer cutover dan
  authenticated UAT adalah scope yang diharapkan.
- PWA online sekarang memakai `confirm_pos_sales_order`,
  `get_pos_sales_orders`, dan `cancel_pos_sales_order`. Order aktif dan
  terjadwal berada di panel Order, bukan daftar Draft; Invoice/SJ snapshot tetap
  dapat dicetak. Checkout Offline baru fail-closed, sedangkan antrean historis
  tetap kompatibel.
- Migration `20260828270000_odr_phase6a_pos_order_cutover_guard.sql` memblokir
  cancel bila Payment verification masih `PENDING`/`VERIFIED`, lalu mendelegasi
  cancel aman ke composition ODR-4B untuk release Reservation, cancel Delivery,
  dan refresh procurement demand. Tidak ada Company policy yang diubah.
- File verifikasi: guard behavioral rollback, guard postflight SELECT-only,
  closing POS postflight SELECT-only, dan runbook
  `docs/runbooks/ODR6A_POS_ORDER_CUTOVER.md`.
- Evidence lokal final: PWA `oxlint` PASS, TypeScript/Vite production build
  PASS, SQL delimiter/parenthesis seimbang, dua postflight SELECT-only, dan
  `git diff --check` PASS. Bundle aktif memuat Confirm/List Order serta Offline
  fail-closed dan tidak memuat `post_pos_sale_with_pricelist`. Manual gate:
  migration 270000 → guard behavioral → guard postflight → deploy/run PWA →
  authenticated smoke → closing POS postflight. Jangan mulai ODR-6B sebelum
  seluruh output PASS/INFO.

### 2026-08-29 — ODR-6A INVOICE IDENTITY DEFECT; FORWARD-FIX LOCAL-READY

- Authenticated smoke berhasil membuat Reservation/Invoice/SJ, tetapi nomor
  Invoice pada kedua template masih `DRAFT-<UUID>`. Diagnosis source memastikan
  draft save memang membuat nomor sementara dan ODR Confirm belum menjalankan
  alokasi `INV-*` yang sebelumnya hanya berada di final-post legacy.
- Ditambahkan diagnostic SELECT-only, migration
  `20260828280000_odr_phase6a_invoice_identity_forward_fix.sql`, fixture-free
  behavioral, serta SELECT-only postflight. Runtime baru menjalankan urutan:
  confirm Reservation → alokasi `INV-*` atomik/exact-retry → buat snapshot
  Invoice/SJ → demand → payment capture.
- Backfill hanya menyentuh snapshot provenance `ORDER_CONFIRM` dengan identitas
  `DRAFT-*`. Invoice snapshot version dinaikkan, payload Invoice/SJ dan header
  diselaraskan, dan audit `REPAIR_IDENTITY` ditambahkan. Trigger immutable
  dimatikan hanya di dalam transaction migration lalu wajib aktif kembali.
- Tidak ada perubahan Stock, FIFO, Reservation quantity, Payment, Event,
  Journal, atau Company policy. Static evidence: parentheses seimbang,
  diagnostic/postflight SELECT-only, dan `git diff --check` PASS. PostgreSQL
  live execution masih manual.
- Gate: preflight → migration 280000 → behavioral → postflight → ulang smoke
  Invoice/SJ → closing ODR-6A. Stop pada `BLOCKER`, SQL error, atau `FAIL`.

### 2026-08-29 — ODR-6B.1 RESERVED STOCK READ MODEL LOCAL-READY

- User menunjukkan Reservation backend sudah `OPEN`, tetapi Inventory Stock
  Real masih menampilkan hard-coded `Reserved: Belum aktif` dan Available sama
  dengan On Hand. Diagnosis memastikan RPC ACP-4D belum membawa Reservation dan
  komponen `StockRealView` memang placeholder.
- Migration `20260829090000_odr_phase6b_reservation_stock_read_model.sql`
  mengganti RPC guarded Stock Real secara additive. Pair tanpa baris
  `product_stocks` tetap ditampilkan bila mempunyai Reservation aktif. Reserved
  adalah remaining quantity pada header `OPEN/PARTIALLY_DISPATCHED`; Available
  selalu On Hand minus Reserved.
- Backoffice sekarang membutuhkan `reservationReadModelVersion=1`, menampilkan
  Reserved aktual dan Available negatif dengan penanda merah. Placeholder dan
  penjelasan roadmap lama dihapus. Tidak ada direct table read baru.
- Verification: preflight SELECT-only, fixture-free behavior, postflight
  SELECT-only, Backoffice ESLint PASS, Next.js production build PASS, SQL
  parentheses/delimiter seimbang, `git diff --check` PASS.
- Manual gate: preflight → migration 090000 → behavior → postflight → deploy/
  restart Backoffice → hard refresh Stock Real. Stop pada `BLOCKER` atau `FAIL`.
  Atomic partial/full Dispatch dan Received tetap pekerjaan ODR-6B berikutnya.

### 2026-08-29 — ODR-6B.1 STEP 1 AUDIT HARDENED; LIVE ROLLOUT PENDING

- Audit ulang menemukan katalog PWA masih membaca `product_stocks.stock_qty`
  langsung. Itu dapat menampilkan On Hand sebagai Available dan mengabaikan
  Reservation Store lain pada Gudang bersama. Consumer tersebut sudah diganti
  dengan RPC `get_pos_stock_availability(store, warehouse)`.
- RPC baru memerlukan sesi kasir `OPEN` milik `auth.uid()` dengan Company,
  Store, dan `sales_warehouse_id` yang sama. Reserved dihitung dari seluruh
  Reservation `OPEN/PARTIALLY_DISPATCHED` pada Gudang, bukan dari filter Store
  kiriman browser. Server Confirm Order tetap menjadi guard final concurrency.
- Stock Real Backoffice tetap guarded oleh `inventory.stock_real VIEW`, memakai
  read-model version 1, menampilkan On Hand/Reserved/Available, dan mencakup
  pasangan Product/Gudang yang hanya memiliki Reservation.
- Evidence lokal terbaru: Backoffice ESLint PASS dan Next production build
  PASS; PWA oxlint PASS dan Vite/TypeScript production build PASS; SQL delimiter
  dan parentheses seimbang; diagnostic/postflight tetap SELECT-only; scoped
  `git diff --check` tidak menemukan whitespace error.
- Status belum live/complete. Manual gate wajib: preflight -> migration 090000
  -> behavioral rollback -> postflight -> deploy Backoffice/PWA -> authenticated
  smoke pada sesi kasir aktif. Stop pada SQL error, `BLOCKER`, atau `FAIL`.
- Next safe step setelah gate tersebut PASS adalah ODR-6B Step 2 Dispatch UI.
  Jangan mengubah Delivery/Dispatch, Stock/FIFO, atau Finance pada Step 1 ini.

### 2026-08-29 — ODR-6B.1 APPLIED-MIGRATION DRIFT CORRECTED

- Behavioral live berhenti karena ledger `20260829090000` sudah ada tetapi RPC
  `get_pos_stock_availability(uuid,uuid)` belum ada. Ini membuktikan database
  telah menerima versi Stock Real sebelum consumer POS ditambahkan.
- Migration `090000` dikembalikan ke kontrak applied aslinya. RPC POS dipindah
  ke forward-fix baru `20260829100000`; applied migration tidak lagi ditimpa.
- Ditambahkan forward-fix preflight SELECT-only. Behavioral sekarang memeriksa
  kedua ledger dan existence RPC terlebih dahulu, sehingga dependency hilang
  menghasilkan `TEST_PRECONDITION_FAILED` yang eksplisit, bukan cast
  `regprocedure` mentah.
- Next manual step untuk database yang melaporkan error tersebut: forward-fix
  preflight -> migration 100000 -> behavioral -> combined postflight. Jangan
  menjalankan 090000 ulang dan jangan deploy PWA sebelum 100000 PASS.

### 2026-08-29 — ODR-6D RETURN/AR/COLLECTION COMPATIBILITY LOCAL-READY

- Closure preflight user menghasilkan tepat tiga blocker: Sales Return,
  AR Aging/Statement, dan TEMPO Customer Receipt masih legacy-`POSTED` only;
  invariant Reservation/Dispatch/Finance lain PASS.
- Migration `20260829110000` menambahkan boundary quantity Return dari immutable
  `sales_dispatch_allocations` untuk list POS, Draft cumulative guard, Post,
  dan full-return delivery-fee guard; Sale legacy tetap kompatibel.
- Migration `20260829120000` membuat receivable dari
  `sales_dispatch_financial_effects`, mengurangi verified post-Dispatch AR
  payment, serta memperbarui Customer Receipt workspace/save/post, AR Aging,
  dan Customer Statement. Pre-Dispatch payment tetap Customer Advance.
- Added combined SELECT-only postflight, read-only data-adaptive behavior, dan
  `docs/runbooks/ODR6D_CONSUMER_COMPATIBILITY_ROLLOUT.md`. Closure chain sekarang
  mengharapkan 19 migration.
- Tidak ada DB/deploy dijalankan agent dan tidak ada backfill Stock/FIFO/Return/
  Receipt/Event/Journal/policy. Core patch transactional dan abort bila active
  function definition drift.
- Manual gate: migration 110000 -> migration 120000 -> postflight -> behavior ->
  closure preflight -> authenticated UAT. Stop pada SQL error/FAIL/BLOCKER.

### 2026-08-29 — BACKOFFICE INVOICE DETAIL HTML-404 FORWARD FIX

- Invoice list tetap berhasil, tetapi tombol Detail menerima halaman HTML 404
  dari `/api/sales/documents/[salesId]`; komponen lalu memanggil `response.json()`
  dan menampilkan `Unexpected token '<'`.
- Detail Invoice dan audit Print/Unduh sekarang memakai endpoint collection
  `/api/sales/documents` yang sudah aktif: `GET ?salesId=...` dan `POST` dengan
  `salesId`. Route dinamis lama dipertahankan untuk compatibility.
- Parser respons Invoice sekarang memverifikasi `content-type` sebelum JSON,
  sehingga HTML proxy/404 tidak lagi bocor sebagai pesan parsing mentah.
- Evidence: scoped ESLint PASS; request tanpa token ke endpoint detail baru
  menghasilkan JSON `401 AUTHENTICATION_REQUIRED`, bukan HTML 404.
- Production build belum menjadi evidence pada sesi ini karena cache generated
  `.next/dev/types/routes.d.ts` milik dev server lokal sudah korup sebelum patch.
  Next safe step: hard refresh dan authenticated smoke Detail, Unduh PDF, serta
  Print Invoice. Jika HMR tidak mengambil patch, restart `npm run dev` Backoffice;
  bersihkan `.next` hanya setelah dev server dihentikan lalu jalankan build ulang.

### 2026-08-29 — POS SINGLE-PAYMENT ZERO-STATE RACE FIX

- POS dapat menampilkan `PAYMENT_LEG_AMOUNT_REQUIRED` walaupun hanya memakai
  satu metode pembayaran otomatis. State nominal sempat menjadi string `"0"`
  sebelum repricing Draft selesai; normalisasi lama hanya memulihkan string
  kosong dan memperlakukan `"0"` sebagai input final.
- Normalisasi Confirm sekarang memakai total final hasil repricing untuk satu
  payment leg read-only yang masih kosong/nonpositif. Tender ikut diselaraskan
  hanya bila sebelumnya memang mengikuti nominal payment leg.
- Boundary tidak dilonggarkan untuk split payment: setiap leg tetap harus
  positif, metode tetap unik, total leg wajib sama dengan grand total, dan
  tender Cash/Transfer tetap tidak boleh kurang.
- Evidence lokal: PWA `npm run lint` PASS; PWA `npm run build` PASS. Tidak ada
  schema, migration, database, atau deployment yang diubah.
- Manual smoke: transaksi non-TEMPO satu metode pembayaran tanpa menyentuh
  field Bagian Tagihan; lalu split payment dengan satu leg kosong harus tetap
  ditolak.

### 2026-08-29 — POS RESUMED-DRAFT LOCK RENEWAL FIX

- Konfirmasi Draft yang dilanjutkan dapat gagal dengan
  `SALE_DRAFT_EDIT_LOCK_REQUIRED` saat lock lima menit milik sesi aktif kosong
  atau heartbeat terlewat karena tab sleep/diam.
- `persistDraft` sekarang melakukan guarded acquire/renew lock untuk Draft lama
  tepat sebelum mutation. Lock kasir/sesi lain tetap ditolak oleh RPC server;
  tidak ada takeover otomatis dan tidak ada pelemahan optimistic concurrency.
- Perubahan berlaku untuk Simpan Draft dan rangkaian Confirm yang sama-sama
  melewati `persistDraft`; Draft baru tetap mengikuti jalur creation lama.
- Evidence lokal: PWA `npm run lint` PASS dan `npm run build` PASS. Tidak ada
  schema, migration, database, atau deployment yang diubah.
- Manual smoke: buka Draft lama dari sesi aktif, edit, tunggu/reload bila perlu,
  lalu Confirm; lakukan juga negative test dengan Draft yang sedang dikunci
  sesi lain dan pastikan tetap ditolak.

### 2026-08-29 — CASH SESSION CLOSE ASYNC FINANCE FORWARD-FIX LOCAL-READY

- Live PWA menolak Tutup Sesi dengan `PENDING_CASH_PAYMENT_VERIFICATION`.
  Guard tersebut memaksa Finance standby memverifikasi tiap Cash payment dan
  tidak berasal dari keputusan operasional user.
- Forward migration `20260829130000` menghapus hanya dependency real-time itu.
  Wrapper tetap memanggil private close chain ODR-5D/ODR-4C sehingga close
  count, expected/difference, Demand, dan Stock Request sesi tetap berjalan.
- Cash drawer movement `SALE_PAYMENT_INTENT`, pending verification, audit,
  controlled posting, Event, Journal, serta histori tidak dihapus atau diubah.
  Hasil close hanya ditambah metadata jumlah verification yang ditunda.
- Ditambahkan SELECT-only preflight/postflight dan runbook
  `CASH_SESSION_CLOSE_ASYNC_PAYMENT_VERIFICATION.md`. Tidak ada database atau
  deployment dijalankan agent.
- Manual gate: preflight -> migration 130000 -> postflight -> hard refresh PWA
  -> transaksi Cash -> Tutup Sesi tanpa tindakan Finance -> cek expected/actual/
  difference dan Stock Request -> cek payment tetap tersedia untuk review
  Finance kemudian. Stop pada BLOCKER/FAIL/SQL error.

### 2026-08-30 — SALES ORDER CANCELLATION / INVOICE SYNC LOCAL-READY

- Defect: cancel Order dari POS sudah melepaskan Reservation dan membatalkan SJ,
  tetapi Invoice Backoffice tetap terlihat aktif karena read model hanya membaca
  immutable snapshot tanpa lifecycle Order. Backoffice juga belum mempunyai
  tindakan cancel.
- Forward migration `20260830110000` membuat POS dan Backoffice memanggil
  cancellation composition yang sama. Pending non-Cash dibatalkan; pending Cash
  pada sesi OPEN mendapat satu reversal drawer idempotent. Payment VERIFIED,
  Cash dari sesi tertutup, dan Dispatch yang sudah dimulai tetap fail-closed.
- `get_sales_documents`, detail, dan export kini membawa status/alasan/aktor/
  waktu cancel. Snapshot Invoice tidak ditulis ulang atau dihapus. Backoffice
  menambah filter status, modal alasan cancel, dan watermark `DIBATALKAN` pada
  PDF/print.
- Files: diagnostic/migration/postflight bertema
  `sales_order_cancellation_invoice_sync`, API collection Sales Document,
  `SalesDocumentView`, renderer print, PWA friendly errors, spec/runbook/router,
  implementation gate, root README, dan handoff ini.
- Evidence lokal: Backoffice ESLint PASS; Next.js production build PASS; PWA
  oxlint PASS; Vite/TypeScript production build PASS; `git diff --check` PASS
  setelah whitespace fix. PostgreSQL live tidak tersedia/dijalankan agent.
- Manual gate: preflight -> migration 110000 -> postflight -> deploy/restart
  Backoffice dan PWA -> hard refresh -> authenticated smoke Cash cancel dari
  kedua channel, Reservation/SJ/Invoice/drawer, exact retry, Dispatch denial,
  verified-payment denial, dan closed-session Cash denial.
- Compatibility: final/legacy Invoice tetap aktif; print audit tetap memakai
  endpoint yang sama; tidak ada deletion/backfill Stock/FIFO/Event/Journal.
- Next safe step: user menjalankan gate dan mengirim seluruh output. Jangan
  deploy Production atau mengubah verified payment history sebelum postflight
  dan smoke bersih.

### 2026-08-31 — NEGATIVE STOCK FIFO/FINANCE COST SETTLEMENT NSC-0 LOCAL-READY

- Audit read-only menemukan runtime replenishment sudah menutup shortage pada
  layer FIFO, tetapi `negative_stock_replenishment_allocations.cost_variance_total`
  belum menjadi sumber jurnal. Supplier Invoice juga masih membebankan seluruh
  price variance ke `PURCHASE_PRICE_VARIANCE` dan belum merevaluasi quantity
  batch yang masih tersisa.
- Keputusan user dikunci di
  `docs/runbooks/NEGATIVE_STOCK_FIFO_FINANCE_COST_SETTLEMENT.md`: Dispatch tetap
  provisional, Goods Receipt menyelesaikan selisih provisional-versus-estimasi,
  Supplier Invoice membagi variance ke Inventory/HPP, dan jurnal `POSTED` hanya
  dikoreksi dengan adjustment append-only.
- Ditambahkan preflight SELECT-only
  `supabase/diagnostics/negative_stock_fifo_finance_cost_settlement_preflight.sql`.
  Diagnostic mengklasifikasikan queue, dependency, open negative cost,
  replenishment `HOLD/POSTED`, invoice `HOLD/POSTED`, mapping tiga fungsi akun,
  dan schema foundation.
- Belum ada schema/runtime/database yang diubah. Next safe step: user
  menjalankan NSC-0 preflight dan mengirim seluruh output. Stop pada `BLOCKER`.
  `BACKFILL` harus ditangani adjustment event pada NSC-1/NSC-2; jangan menulis
  ulang jurnal historis atau `product_batches.cogs_unit` secara terpisah.
### 2026-08-31 — NEGATIVE STOCK FIFO/FINANCE NSC-1..3 LOCAL-READY

- User menjalankan NSC-0 pada live DB: queue aktif 0, dependency dan mapping
  awal PASS, historical replenishment variance 0, historical Supplier Invoice
  price variance 0. Open negative allocation 49 / shortage 1.279 base qty
  masih provisional dan belum direplenish.
- Ditambahkan migration `20260831120000` (private cost source dan Invoice-to-
  batch allocation foundation) serta `20260831130000` (Goods Receipt cost
  settlement, zero-value receipt accounting wrapper, Supplier Invoice FIFO
  revaluation, dan Inventory/COGS journal split).
- Existing jurnal `POSTED` tidak ditulis ulang. Migration runtime fail-closed
  bila menemukan historical `POSTED` variance nonnol atau queue aktif.
- Supplier Invoice nonrecoverable tax mempertahankan akun PPV existing; hanya
  purchase price variance yang dibagi ke Inventory dan COGS berdasarkan batch
  remaining/sold. Revaluation batch dan jurnal berada dalam transaksi posting
  yang sama.
- Evidence lokal: schema/column/FK cross-check terhadap migration canonical,
  delimiter/parenthesis scan bersih, dan `git diff --check` bersih selain
  warning line-ending. PostgreSQL parser/live execution belum dilakukan agent.
- Behavioral pertama gagal hanya pada result transport karena temporary table
  `ON COMMIT DROP` hilang di boundary SQL Editor. Test diperbaiki tanpa temp
  table; seluruh mutation tetap berada dalam `BEGIN`/`ROLLBACK`.
- Manual gate: rerun preflight terbaru (menambah SI `COGS` mapping), migration
  120000, foundation postflight, migration 130000, behavioral rollback,
  runtime postflight, lalu authenticated negative Dispatch → partial/final GR
  → queue → Invoice price variance → queue reconciliation. Stop pada SQL error,
  `BLOCKER`, `BACKFILL`, atau `FAIL`.
- User kemudian mengonfirmasi foundation dan runtime postflight seluruhnya
  `PASS`: 10 routine, 5 trigger, private execution boundary, zero-value receipt
  wrapper, dan seluruh structural reconciliation bersih. Runtime source/plan
  masih nol dengan 49 negative allocation terbuka, sehingga next safe step
  adalah authenticated operational smoke; jangan menandai NSC closure sebelum
  source, batch revaluation, queue Journal, serta FIFO–GL hasil smoke cocok.
