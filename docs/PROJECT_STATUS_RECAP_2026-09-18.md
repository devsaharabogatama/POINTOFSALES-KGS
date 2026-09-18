# Rekap Status Proyek MADS / KGS POS

**Tanggal snapshot:** 18 September 2026  
**Branch:** `main`  
**Commit aplikasi terakhir yang tercatat:** `031b619` — `feat: complete backoffice sales return and refund workflow`

Dokumen ini merangkum rencana awal POS v1, perluasan bisnis proses Office dan
Purchase yang disetujui setelahnya, pekerjaan yang sudah tersedia, serta bagian
yang masih harus diselesaikan.

## Cara Membaca Status

| Status | Arti |
|---|---|
| **SELESAI TERBUKTI** | Kode, database, client, smoke, dan UAT yang relevan mempunyai bukti penutupan. |
| **OPERASIONAL / SEBAGIAN TERBUKTI** | Sudah digunakan atau sebagian alur sudah dites, tetapi matriks smoke/UAT penuh belum ditutup. |
| **DATABASE PASS** | Migration dan test database sudah PASS, tetapi belum otomatis berarti client sudah dideploy atau alur user sudah UAT. |
| **LOCAL READY** | Kode/migration/test sudah tersedia di repository, tetapi rollout atau smoke target belum terbukti lengkap. |
| **BELUM DIKERJAKAN** | Belum ada implementasi yang disetujui atau implementasinya memang ditunda. |
| **DEFERRED** | Sengaja berada di luar scope aktif dan tidak boleh dianggap sebagai kekurangan implementasi saat ini. |

## Ringkasan Eksekutif

1. Fondasi POS v1—tenant, master data, inventory, POS Retail, Purchase, dan
   Finance—sudah dibangun dalam rangkaian migration dan client yang panjang.
2. Perluasan bisnis proses **Retail dan Office** sudah mencakup Quotation, Sales
   Order, Reservation, Surat Jalan, penerimaan Customer, Invoice setelah barang
   diterima, pembayaran, serta perpindahan proses Retail ↔ Office.
3. Purchase sudah mencakup mode Manual, AUTO_RO, dan AUTO_PO; RO/PO, Receipt,
   Bill, dan Payment menggunakan dokumen terpisah sesuai tanggung jawab user.
4. Retur & Refund Backoffice sudah tersedia di commit aplikasi terakhir, tetapi
   penutupan production E2E lintas Sales–Gudang–Finance masih menjadi gate utama.
5. Proyek **belum boleh disebut selesai 100%** karena masih ada rollout terbaru,
   authenticated smoke, role/multi-Company UAT, scheduler operasional, dan
   audit pesan error yang belum ditutup secara menyeluruh.

Audit dokumen ini tidak melakukan query langsung ke Production atau Vercel.
Status Production di bawah memakai hasil yang sebelumnya diberikan user dan
evidence repository; bagian yang targetnya tidak tercatat jelas ditandai
sebagai belum terverifikasi, bukan ditebak.

---

## A. Rencana Awal POS v1

### 1. Tenant, Company, User, Role, dan Feature

**Yang sudah dikerjakan**

- Data operasional memakai batas `company_id` dan active Company eksplisit.
- Super Admin, Company Admin, Store Manager, Warehouse Admin, Finance, Sales,
  Sales Admin, dan Cashier mempunyai baseline capability.
- Feature entitlement dan pengaturan modul Company tersedia.
- Custom permission per submodul sudah mempunyai database enforcement untuk
  area Inventory, Contacts, Purchase, Sales, dan Finance.
- Store, POS Terminal, Warehouse, Company branding, logo, serta pengaturan
  dokumen tersedia.
- Lifecycle membership user per Company, revoke guard, last-owner protection,
  dan audit tersedia.

**Status:** **OPERASIONAL / SEBAGIAN TERBUKTI**.

**Yang masih tersisa**

- Authenticated role/preset/two-Company UAT final untuk seluruh capability.
- Penutupan PRD-1 pada empat role minimum dan distinct override dua Company.
- **Multi-role untuk satu user dalam Company yang sama belum dibuat**. Runtime
  saat ini tetap memakai satu role baseline per membership, ditambah custom
  permission yang tidak boleh memperluas batas role.

### 2. Master Data

**Yang sudah dikerjakan**

- Product, Product Category, UOM dan konversi satu tingkat.
- Warehouse dan Store.
- Supplier serta Product–Supplier dan preferred Supplier.
- Customer, Customer Category, Walk-In Customer, dan grouping Customer.
- Pricelist Global/Customer dan harga per UOM.
- Payment Method, Transaction Category, COA minimum, Tax Rule Sales, serta
  assignment Product/Category.
- Import/export simple master, Product, Product–Supplier, dan Minimum Stock.
- Global Data Exchange Center dan export laporan/dokumen yang telah dibuka.
- Searchable combobox untuk dropdown dengan minimal 10 pilihan sudah
  **LOCAL READY** pada Backoffice dan PWA; dropdown kecil tetap native.

**Status:** core master **SELESAI TERBUKTI** pada database; beberapa client flow
masih **OPERASIONAL / SEBAGIAN TERBUKTI**.

**Yang masih tersisa**

- Closing authenticated smoke untuk beberapa import, Data Exchange, branding,
  dan konfigurasi Company lintas role.
- Deployment dan authenticated visual smoke searchable dropdown pada kedua
  client.
- Opening Stock, transaksi, Company, dan Staff/password tetap menggunakan
  workflow khusus dan tidak boleh dimasukkan ke generic import.
- Purchase Tax dan seluruh efek jurnal terkait perlu tetap diverifikasi pada
  alur Purchase final, bukan hanya dari Tax master.

### 3. Inventory dan Stock

**Yang sudah dikerjakan**

- Stock Real dalam base UOM per Product–Warehouse.
- Immutable Stock Movement dengan source document.
- Opening Stock, Adjustment, Transfer, Stock Opname, Minimum Stock.
- FIFO, HPP, Product Batch, dan Bundle tanpa nested Bundle.
- Reservation, Transit, Dispatch, Goods Receipt, Return Supplier, serta kartu
  stok dan valuasi.
- Kebijakan stok minus berpusat pada Gudang; inbound positif dapat memulihkan
  saldo minus tanpa meminta otorisasi penjualan lagi.
- Receipt otomatis dapat dilanjutkan operator Gudang berwenang yang berbeda
  dari pembuat dokumen, dengan operator aktual tetap teraudit.

**Status:** core Inventory **SELESAI TERBUKTI**; dua forward-fix terakhir masih
memerlukan bukti rollout/smoke target yang konsisten.

**Yang masih tersisa**

- Pastikan migration **Negative Stock Inbound Recovery** benar-benar live pada
  Production dan ulang smoke Goods Receipt yang berakhir masih minus.
- Pastikan migration **Generated Goods Receipt Operator Handoff** live dan
  smoke lintas operator Gudang PASS.
- Closing multi-Company dan stale-version smoke untuk seluruh mutation Stock.

### 4. POS Retail

**Yang sudah dikerjakan**

- Cashier Session: buka/tutup sesi, expected cash, dan reconciliation.
- Checkout online server-authoritative.
- Checkout offline dengan allowance, queue, retry, acknowledgement, dan
  idempotency.
- Split payment, fee, bukti eksternal, rounding, TEMPO, due date, dan receipt.
- Customer Pricelist, Tax, Bundle, stock shortage, dan optional stock minus.
- Draft terjadwal dan revisi Order.
- Return Retail, Expense, Setor Kas, Deposit Variance, dan Customer Balance.
- Order Reservation/Dispatch memisahkan Reserved Out dari Stock Movement final.

**Status:** core online/offline dan transaksi utama **SELESAI TERBUKTI**;
beberapa UI/policy tambahan masih **OPERASIONAL / SEBAGIAN TERBUKTI**.

**Yang masih tersisa**

- Closing tablet/authenticated smoke untuk Customer Balance dan beberapa
  konfigurasi terminal.
- Regression final setelah seluruh patch Office/Purchase/Return terbaru:
  checkout, offline retry, session close, Return Retail, dan payment.
- Terminal Price Override merupakan post-UAT adjustment dan tidak menjadi
  blocker bisnis proses Office saat ini.

### 5. Purchasing Dasar

**Yang sudah dikerjakan**

- Flow Manual: **RO → PO → Receive → Supplier Bill → Payment/Post**.
- Partial Receipt, penerimaan per Gudang, Supplier Return, provisional AP,
  Supplier Invoice, matching, dan Supplier Payment.
- PO dapat diedit sebelum Receipt/Bill dimulai; setelah itu koreksi mengikuti
  Return/cancel yang sah.
- Dokumen Receipt otomatis dibuat saat PO terbentuk dan diproses dari menu
  **Penerimaan Barang**, bukan dikonfirmasi oleh Purchasing di halaman PO.
- Bulk receive, quantity default dari PO tetapi editable, dan partial success.

**Status:** **OPERASIONAL / SEBAGIAN TERBUKTI**.

**Yang masih tersisa**

- Authenticated E2E final pada Production untuk Manual RO → PO → partial/full
  Receipt → Bill → partial/full Payment → Return/cancel.
- Closing tolerance/matching opsional yang masih dicatat sebagai corrective
  forward-only.
- Regression Receipt lama yang destination Warehouse-nya null setelah client
  deployment terbaru.

### 6. Finance

**Yang sudah dikerjakan**

- Immutable Financial Event dan posting Journal double-entry.
- COA, Transaction Category, resolver account, period lock, reversal, serta
  prior-period adjustment.
- AR, AP, Customer Receipt, Supplier Invoice/Payment, Customer Statement,
  collection partial, dan reconciliation.
- Trial Balance, General Ledger, P&L, Balance Sheet, aging, cash/deposit,
  stock valuation, pending/hold, dan reconciliation foundation.
- Historical Finance closure pernah dilaporkan balance untuk event/journal
  yang diuji, termasuk FIFO–Inventory GL.
- Navigasi Finance menyesuaikan bisnis proses agar fungsi Retail dan Office
  tidak ditampilkan ganda tanpa alasan.

**Status:** core posting/reconciliation **DATABASE PASS** dan sebagian sudah
digunakan; keseluruhan UI/report **OPERASIONAL / SEBAGIAN TERBUKTI**.

**Yang masih tersisa**

- Authenticated cross-role/cross-Company smoke untuk seluruh laporan minimum.
- UAT period lock, reversal, dan source trace pada transaksi Production terbaru.
- Bank matching dan beberapa workflow exceptional tetap di luar scope aktif.

---

## B. Perluasan Bisnis Proses yang Disetujui Setelah Rencana Awal

### 1. Pilihan Proses Penjualan Retail atau Office

**Yang sudah dikerjakan**

- Setting proses per Company: Retail atau Office.
- Preview, Apply, audit, optimistic version, dan lineage perubahan proses.
- Konversi dua arah untuk dokumen yang memenuhi syarat.
- Dokumen dengan blocker tetap berada di proses asal dan dapat direcovery
  melalui jalur terkendali.
- Preservation harga, discount, tax, Pricelist, tempo, ongkir, dan snapshot
  komersial ketika dokumen berpindah proses.
- Existing Retail history dapat dibaca dari workspace Office tanpa menghapus
  transaksi lama.
- Procurement lineage dijaga saat dokumen Office hasil cutover direvisi atau
  dibatalkan sebelum Dispatch.

**Status:** database Production pernah dilaporkan PASS untuk paket 90 file dan
client Production telah dipakai user, tetapi penutupan keseluruhan cutover
masih **OPERASIONAL / SEBAGIAN TERBUKTI**.

**Yang masih tersisa**

- UAT dua arah Retail → Office dan Office → Retail pada Company uji nyata.
- Verifikasi seluruh Order historis yang harus tetap terlihat, termasuk dokumen
  retained karena procurement.
- Regression revisi/cancel, Reservation/DO, Stock Request, RO/PO, Invoice/DP,
  Payment, dan Return setelah switch.
- Satu laporan penutupan Production yang menyebut jumlah dokumen sumber,
  dikonversi, dipertahankan, direcovery, dan link targetnya.

### 2. Backoffice Quotation dan Sales Order

**Yang sudah dikerjakan**

- Quotation Draft, edit, confirm menjadi Sales Order, cancel, dan revisi.
- Pricelist, discount, tax, ongkir, payment term, warehouse, dan commercial
  snapshot.
- Activity log dan hubungan dokumen lama–baru.
- Reservation dan Delivery Order/Surat Jalan.
- Dispatch: Siap Kirim → Dalam Perjalanan → Diterima.
- Partial delivery, discrepancy, shortage, wrong item, overage, Backorder,
  Accepted Short, dan penyelesaian Gudang/komersial.
- Invoice status tampil pada daftar SO dan mengarah ke Invoice terkait.

**Status:** **OPERASIONAL / SEBAGIAN TERBUKTI**.

**Yang masih tersisa**

- Authenticated UAT final seluruh status normal dan discrepancy.
- Deployment/smoke final tombol progresif dan bulk Surat Jalan pada filter.
- Audit pesan blocker yang masih berupa kode teknis di seluruh jalur, bukan
  hanya error Return, Invoice, dan Cutover yang sudah diberi penerjemah.

### 3. Invoice dan Pembayaran Backoffice

**Yang sudah dikerjakan**

- Invoice dibuat dari SO setelah barang diterima Customer.
- Draft Invoice editable sebelum posting.
- Partial quantity dan beberapa Invoice per SO.
- DP, cicilan/payment term, tax breakdown, discount, ongkir, dan rounding.
- Posted Invoice immutable, printable, dan memakai template dokumen existing.
- Status Draft/Posted/Paid terpisah dan histori pembayaran tersedia.
- Partial/full Customer Receipt, reconciliation, AR, dan Journal.

**Status:** **OPERASIONAL / SEBAGIAN TERBUKTI**.

**Yang masih tersisa**

- UAT Production dari SO selesai → Invoice Draft → edit → post → partial/full
  payment → Paid, termasuk retry dan stale version.
- UAT beberapa Invoice untuk satu SO serta DP/cicilan pada data nyata.
- Cross-check bahwa menu Finance dan menu Sales tidak menawarkan mutation ganda
  untuk pembayaran yang sama.

### 4. Purchase Harian Otomatis

**Yang sudah dikerjakan**

- Setting per Company: Manual, AUTO_RO, atau AUTO_PO.
- Kandidat hanya berdasarkan **On Hand negatif**, tanpa menghitung Reserve atau
  Transit sebagai kebutuhan baru.
- Perhitungan mengurangi open purchase agar tidak membuat order ganda.
- Grouping batch per hari lintas Gudang, kemudian dokumen per Supplier.
- Supplier dipilih berdasarkan priority; line tanpa Supplier menjadi
  `SUPPLIER_PENDING` dan belum dapat ditagih.
- Source Warehouse dan destination/receiving Warehouse dipisahkan per line.
- AUTO_RO memerlukan konfirmasi menjadi PO; AUTO_PO langsung membuat PO serta
  dokumen Receipt yang tetap harus dikonfirmasi Gudang.
- Cancel RO/PO mengikuti status Receipt dan Return yang sah.
- Nama/nomor PO membawa identitas tanggal agar mudah dicari dan difilter.

**Status:** migration/client sudah tersedia dan rangkaian database pernah PASS;
operasional scheduler Production masih **BELUM DITUTUP**.

**Yang masih tersisa**

- Menetapkan dan membuktikan scheduler pukul 23:59 pada Production. Audit lama
  mencatat `pg_cron` belum terpasang; bila tetap demikian diperlukan scheduler
  eksternal yang idempotent dan termonitor.
- Bukti dua kali eksekusi untuk tanggal yang sama tidak membuat RO/PO ganda.
- UAT AUTO_RO dan AUTO_PO pada dua hari berbeda, multi-Gudang, multi-Supplier,
  `SUPPLIER_PENDING`, partial Receipt, serta perbaikan Supplier setelah barang
  diterima.
- Monitoring dan prosedur retry apabila scheduler gagal pada satu Company.

### 5. Retur dan Refund Backoffice

**Yang sudah dikerjakan**

- Satu workspace **Sales > Retur & Refund**.
- Draft, Submit, Approve, Cancel, quantity cap, permission, idempotency, dan
  audit commercial Return.
- **Inventory > Penerimaan Retur Customer** terpisah dari Supplier Receipt.
- Gudang memilih **Masuk stok** atau **Dihancurkan** per line; DESTROY wajib
  catatan dan hanya RESTOCK menambah On Hand.
- Finance mengalokasikan quantity fisik secara eksplisit ke belum ditagih,
  Draft Invoice, atau Posted Invoice.
- Draft Invoice disesuaikan dan wajib diperiksa ulang.
- Posted Invoice dikoreksi dengan Credit Note source-linked.
- Credit Note mengurangi AR lebih dahulu; hanya kelebihan pembayaran menjadi
  refund liability.
- Partial Cash/Transfer Refund dan source-linked reversal tersedia tanpa POS
  atau Cashier Session.
- Link dari SO, daftar/status, activity log, dan panduan user tersedia.

**Status evidence per bagian**

| Bagian | Status terakhir yang aman dinyatakan |
|---|---|
| Commercial Return | Dependency terbukti dipakai Step 2/3; target Production belum dicatat terpisah secara konsisten. |
| Penerimaan Retur Customer | **DATABASE PASS** berdasarkan hasil user; authenticated Warehouse smoke/UAT belum ditutup. |
| Credit Note dan AR | **DATABASE PASS** berdasarkan hasil user; authenticated Finance smoke/UAT belum ditutup. |
| Refund dan reversal | User melaporkan test PASS, tetapi handoff resmi masih menandai rollout/smoke target belum lengkap. |
| UI/read-model Step 5 | Commit `031b619` ada di `main`; local lint/typecheck/build PASS. Database/client deploy dan E2E UAT target harus dikonfirmasi. |

**Yang masih tersisa**

- Pastikan ledger migration sampai `20260918100000` ada pada Production.
- Pastikan client Production menjalankan commit `031b619` atau yang lebih baru.
- Jalankan satu authenticated E2E nyata:
  SO diterima → Buat Retur → Ajukan → Setujui → Gudang menerima RESTOCK/DESTROY
  → Finance mengalokasikan → Post Credit Note → partial/full Refund → Reversal.
- Jalankan versi tanpa pembayaran untuk membuktikan proses berhenti pada
  pengurangan piutang dan tidak membuat Refund.
- Jalankan partial Return, multi-Invoice, cross-Company denial, exact retry,
  stale version, dan regression Retur Retail.

### 6. Surat Jalan dan Penerimaan Barang

**Yang sudah dikerjakan**

- Surat Jalan POS dan Office dalam satu workspace Inventory.
- Checkbox mengikuti filter dan bulk selection.
- Tombol progresif: **Mulai pengiriman** lalu **Konfirmasi diterima**.
- Bulk receive hanya untuk penerimaan bersih; discrepancy tetap melalui detail.
- Penerimaan Supplier menampilkan line PO, qty default dari order, edit qty, dan
  bulk receive.

**Status:** code sudah berada di repository; smoke Production terbaru masih
perlu dicatat sebagai evidence penutupan.

---

## C. Pekerjaan yang Belum Dikerjakan atau Sengaja Ditunda

### Belum dikerjakan tetapi sudah pernah diminta/dicatat

1. **Multi-role dalam Company yang sama.**
   - Baru dicatat sebagai kebutuhan.
   - Belum ada perubahan membership, schema, resolver permission, atau UI.
2. **Audit seluruh warning/error aplikasi.**
   - Beberapa area sudah memakai pesan ramah user.
   - Belum ada inventaris dan perbaikan menyeluruh untuk seluruh modul.
3. **Closing dashboard/status operasional deployment.**
   - Belum ada satu halaman atau laporan release yang menunjukkan versi client,
     migration ledger, scheduler, smoke, dan UAT per Company.
4. **Product Potential Analytics.**
   - Spesifikasi sudah dicatat, implementasi tetap opsional/post-pilot.

### Deferred dari scope POS v1

- Manufacture/MRP.
- HR dan payroll.
- Logistics advanced di luar Gudang, Transfer, Receipt, Dispatch, dan delivery
  reference dasar.
- Fixed Asset detail.
- Integrasi e-Faktur/pajak pemerintah.
- Upload file internal selain logo Company; bukti transaksi tetap URL eksternal.
- Bank matching dan offline Expense/Deposit lanjutan.

Deferred bukan blocker untuk presentasi bisnis proses Office/Purchase saat ini.

---

## D. Pekerjaan Operasional yang Masih Harus Ditutup

### Prioritas 0 — Sebelum Presentasi/UAT Final

1. Catat versi Production:
   - commit client yang aktif;
   - migration ledger terakhir;
   - mode Sales tiap Company uji;
   - mode Purchase tiap Company uji.
2. Smoke proses Office normal:
   Quotation → SO → Dispatch → Customer menerima → Invoice → Payment.
3. Smoke Retur & Refund Backoffice lengkap lintas Sales, Gudang, dan Finance.
4. Smoke Purchase Manual lengkap sampai Bill dan Payment.
5. Smoke AUTO_RO/AUTO_PO dan buktikan scheduler/retry tidak membuat duplikat.
6. Regression Retail: online, offline, session, payment, Return Retail, dan
   Customer Balance.
7. Cross-Company dan role denial minimum untuk Sales, Gudang, Finance, dan
   Company Admin.
8. Simpan hasil sebagai laporan UAT dengan nomor dokumen sumber dan hasil akhir.

### Prioritas 1 — Stabilisasi Setelah Presentasi

1. Audit dan perbaiki seluruh pesan blocker/error menjadi bahasa yang menjelaskan
   penyebab serta tindakan user, tanpa menghilangkan kode diagnostik.
2. Selesaikan multi-role design dan impact audit sebelum mengubah schema.
3. Tutup authenticated smoke Global Data Exchange, branding, report Finance,
   dan custom permission dua Company.
4. Tambahkan monitoring scheduler Purchase serta notifikasi kegagalan.
5. Rapikan dokumentasi status lama yang masih menyebut isolated Development
   setelah fitur tertentu sudah dipasang ke Production.

---

## E. Kondisi Repository Saat Snapshot

- Local `main` dan local tracking `origin/main` sama-sama menunjuk commit
  `031b619`. Ini bukan pengganti pengecekan remote terbaru jika belum `fetch`.
- Panduan Retur & Refund baru masih menjadi file lokal yang belum masuk commit
  pada saat snapshot ini.
- Terdapat file lokal lain yang bukan bagian commit Retur & Refund utama,
  termasuk catatan HR, spesifikasi role, paket exact reversal SMS, dan fixture
  development. File tersebut tidak boleh ikut di-commit secara massal tanpa
  review scope.
- Exact reversal SMS adalah operasi koreksi satu dokumen trial, bukan fitur SMS
  atau bagian normal flow Retur & Refund.

## Kesimpulan

Secara fungsi, proyek sudah melewati tahap pembangunan fondasi dan berada pada
tahap **penutupan rollout, regression, dan UAT**. Pekerjaan terbesar yang belum
selesai bukan membuat ulang Retail, Office, Purchase, atau Finance, melainkan:

1. memastikan versi database dan client Production benar-benar sama dengan
   repository terbaru;
2. menutup smoke lintas modul menggunakan role nyata;
3. membuktikan scheduler Purchase otomatis;
4. menutup E2E Retur & Refund Backoffice;
5. menyelesaikan backlog multi-role serta audit seluruh pesan error setelah
   alur transaksi utama stabil.

Project baru boleh disebut selesai penuh setelah seluruh Prioritas 0 mempunyai
bukti dan UAT disetujui user.
