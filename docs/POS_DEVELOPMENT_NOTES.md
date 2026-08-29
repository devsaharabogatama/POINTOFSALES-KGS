# Catatan Pengembangan POS KGS

**Status:** Active Design Draft 1.7 — Workflow bisnis Ketul selesai untuk review lintas dokumen  
**Tanggal:** 2026-07-14  
**Fase aktif saat dokumen dibuat:** Produk dan Stok  
**Dokumen ini menyimpan kebutuhan POS untuk pembahasan lanjutan dan bukan izin implementasi UI/backend POS.**

---

## 1. Tujuan

Dokumen ini mencegah kebutuhan POS yang muncul saat perancangan Master Data dan Inventory terlewat ketika pengembangan POS dilanjutkan.

Wajib dibaca bersama:

```text
docs/PRODUCT_STOCK_MASTERDATA_SPEC.md
docs/FINANCE_INTEGRATION_NOTES.md
KGS_MINI_ERP_MIGRATION_BLUEPRINT.md
```

---

## 2. Boundary POS

POS adalah channel operasional store untuk:

- penjualan;
- pengecekan stok sesuai akses store;
- Stock Request kebutuhan barang;
- Goods Receipt dari supplier;
- Stock Opname blind count;
- penyimpanan transaksi draft ketika stok tidak mencukupi;
- offline queue/sync sesuai desain offline-first.

POS bukan channel untuk:

- CRUD Master Produk/Kategori/UOM/Gudang/Supplier;
- mengubah Stock Movement;
- posting Adjustment manual;
- invoice matching supplier;
- menentukan COA;
- membayar AP;
- mengedit jurnal.

---

## 3. Context Wajib POS

Setiap sesi POS harus memiliki context:

```text
authenticated_user_id
company_id
store_id
pos_terminal_id
default_sales_warehouse_id
active_cashier_session_id
role/membership
```

POS tidak boleh menerima `company_id`, `store_id`, atau warehouse hanya dari input browser tanpa validasi membership server/RLS.

---

## 4. Penjualan dan Stok Tidak Cukup

Keputusan:

- Saldo stok disimpan dalam base UOM terkecil.
- POS dapat menjual UOM lain yang aktif pada produk.
- Quantity penjualan dikonversi ke base UOM.
- Harga mengikuti harga manual UOM terpilih, bukan perkalian harga UOM kecil.
- Bundle mengurangi stok komponen dan menggunakan berat/HPP komponen.
- Stok negatif tidak diizinkan.
- Jika satu line kekurangan stok, seluruh transaksi menjadi `DRAFT`.
- Draft tidak membuat stock movement, payment final, financial event, atau jurnal.
- UI menampilkan requested, available, dan shortage dalam UOM transaksi serta base UOM.
- Barcode opsional per UOM dapat digunakan untuk mencari/menambahkan produk; pencarian nama/SKU tetap tersedia bila barcode kosong.
- Scan exact menambah quantity `1` pada UOM barcode. Scan berulang menaikkan quantity line produk-UOM yang sama, dan Cashier tetap dapat mengedit quantity manual.
- Barcode produk sama dengan UOM berbeda menghasilkan line berbeda. Barcode tidak dikenal hanya menampilkan notice tanpa auto-create.
- Bundle hanya berisi komponen `STOCK`; POS tidak memproses nested bundle.
- Quantity mengikuti aturan UOM: unit/kemasan bulat, sedangkan UOM yang mengizinkan decimal memakai precision yang dikonfigurasi.

### 4.1 Stock Keluar Sesi dan Sisa Stock

Cashier dapat melihat informasi stok per produk untuk sesi aktif:

```text
opening_stock_snapshot
gross_sold_qty
sales_return_or_reversal_qty
net_stock_out_qty
current_stock_on_hand
closing_stock_snapshot nullable
display_uom
last_stock_updated_at
```

Definisi awal:

- **Stock Awal Sesi** adalah snapshot seluruh produk aktif pada gudang ketika sesi Cashier dibuka. Produk baru setelah pembukaan memakai stock awal `0` pada laporan sesi.
- **Terjual Kotor** adalah base quantity movement penjualan posted yang terkait `active_cashier_session_id` sebelum dikurangi retur.
- Transaksi `DRAFT`, canceled, atau gagal tidak dihitung.
- **Retur/Reversal** posted ditampilkan terpisah. Retur dari invoice/sesi lama masuk ke sesi yang mengeksekusi retur dan menyimpan referensi invoice serta sesi asal.
- **Net Keluar** = Terjual Kotor - Retur/Reversal posted.
- **Sisa Stock Saat Ini** membaca saldo live `product_stocks` untuk gudang penjualan aktif dan mencakup seluruh movement sah, termasuk movement dari user/proses lain.
- Goods Receipt posted segera memperbarui sisa stok di POS tanpa membuka sesi baru.
- Checkout draft/tertahan karena shortage dapat dicoba kembali setelah receipt masuk; posting selalu mengulang pemeriksaan dan lock saldo pada server.
- Karena saldo sisa bersifat live, nilainya tidak dihitung hanya dari stok awal sesi dikurangi penjualan Cashier tersebut.
- **Movement Lain** dipisahkan sebagai Penerimaan, Transfer Masuk, Transfer Keluar, Adjustment Masuk/Keluar, Opname, dan non-sale lain.
- Ketika sesi ditutup, sistem menyimpan closing stock snapshot per produk agar laporan sesi tidak berubah setelah ada movement baru.
- Angka internal tetap base UOM; UI dapat menampilkan konversi ke UOM yang sedang dipilih.
- Untuk bundle, POS menampilkan jumlah bundle yang terjual pada sesi dan available bundle live yang dihitung dari komponen pembatas.
- Cashier tidak melihat HPP, cost batch, atau nilai persediaan.
- Query wajib tenant/store/warehouse scoped dan tidak boleh membuka stok company/store lain.
- Product card hanya menampilkan **Sisa Stock Saat Ini**. Detail Stock Awal, Terjual, Retur, Net Keluar, dan Movement Lain tampil pada panel/detail produk.
- Detail stok per produk dimasukkan ke Ringkasan Tutup Sesi dan laporan Store Manager sebagai bagian yang dapat dibuka, bukan memenuhi struk/ringkasan utama.

### 4.2 Notice Minimum Stock

- Minimum stock opsional dikonfigurasi per produk-gudang di Backoffice.
- Ketika on-hand mencapai/di bawah threshold, POS memberi notice non-blocking kepada Cashier pada gudang tersebut.
- Notice tidak otomatis membuat Stock Request atau Supplier Order.
- Cashier dapat memilih **Buat Stock Request** dari notice; quantity tetap dikonfirmasi manual.
- POS menampilkan satu badge seperti **7 produk stok menipis**; daftar produk baru muncul ketika badge dibuka dan tidak membuat toast berulang per produk.

### 4.3 Rounding Grand Total Penjualan

Rounding digunakan untuk grand total harga penjualan yang menjadi pecahan akibat quantity berat dikali harga.

```text
grand_total_before_rounding
rounding_applied
rounding_direction: NONE / DOWN / UP
rounding_increment: 100
rounding_adjustment
grand_total_after_rounding
rounding_selected_by
```

Aturan UX dan data:

- Quantity tetap mengikuti precision UOM; input quantity yang terlalu presisi ditolak dan tidak dibulatkan oleh fitur ini.
- Rounding bersifat opsional untuk semua metode pembayaran.
- Cashier memilih **Tanpa Pembulatan**, **Bulatkan ke Bawah**, atau **Bulatkan ke Atas** pada layar pembayaran.
- DOWN/UP menggunakan kelipatan tetap Rp100; jika total sudah kelipatan Rp100 maka adjustment `0`.
- Tidak ada policy paksa Store Manager pada scope awal.
- Preview menampilkan grand total awal, selisih rounding, dan total pembayaran akhir.
- Quantity, berat, stock movement, dan HPP tidak berubah akibat rounding nilai penjualan.
- Sales header/payment menyimpan direction, increment, adjustment, total sebelum/sesudah, dan actor.
- Total payment wajib mengikuti `grand_total_after_rounding`; jika Cashier memilih NONE maka total akhir sama dengan total awal.
- Struk menampilkan **Total Sebelum Pembulatan**, **Pembulatan**, dan **Total Akhir** ketika rounding dipakai.
- Laporan Store Manager menampilkan detail per transaksi dan ringkasan total rounding DOWN, UP, serta net difference.

### 4.4 Refund dan Rounding

- Config `refund_approval_mode` mendukung:
  - `REQUIRED`: Cashier membuat draft; Store Manager atau Company Admin/Super Admin mengotorisasi/posting.
  - `OPTIONAL`: Cashier dapat posting langsung dan tetap masuk laporan Store Manager.
- Config memiliki company default dan dapat mempunyai store override.
- Company Owner/Admin mengatur default company. Store Manager hanya dapat mengatur override untuk store dalam scope penugasannya; store override menang terhadap company default.
- Pada mode `REQUIRED`, Cashier menyimpan refund sebagai `DRAFT` dan Store Manager atau Company Admin/Super Admin memeriksa/posting melalui Backoffice. Approval tidak dilakukan melalui POS.
- Full refund mengembalikan persis total akhir yang dibayar setelah rounding dan membalik adjustment transaksi asal.
- Partial refund dihitung dari snapshot line/discount transaksi asal dan boleh memakai rounding Rp100 baru: `NONE`, `DOWN`, atau `UP`.
- Rounding refund disimpan terpisah dari rounding sale asal.
- Cumulative refund tidak boleh melebihi refundable balance transaksi asal.
- Refund menyimpan invoice/sesi asal serta sesi Cashier yang mengeksekusi refund.
- Refund method dipilih sesuai kondisi lapangan: `CASH`, `TRANSFER`, atau `CUSTOMER_BALANCE`; sistem tetap menyimpan metode pembayaran asal.
- Jika transaksi asal memakai Customer Balance, bagian refund yang bersumber dari saldo dikembalikan lebih dahulu. Sisa refund dapat memakai Cash, Transfer, atau Customer Balance sesuai pilihan Customer.
- Jika credit Customer Balance dari transaksi asal sudah dipakai oleh transaksi lain, cancellation langsung diblokir dan wajib melalui correction/reversal workflow.
- Untuk refund `TRANSFER`, data tujuan/rekening, nomor referensi, dan field link bukti Google Drive/HTTPS disediakan. File tidak di-upload ke aplikasi; Finance membuka link sesuai `EXTERNAL_EVIDENCE_LINK_POLICY.md`.
- Setiap return line memilih `SALEABLE`, `DAMAGED`, atau `NO_PHYSICAL_RETURN`.
- `SALEABLE` menambah stok gudang STORE, `DAMAGED` menambah gudang DAMAGED, dan `NO_PHYSICAL_RETURN` tidak membuat stock-in.
- Laporan Store Manager memisahkan dokumen `SALE` dan `REFUND` dengan kolom waktu, nomor dokumen, Cashier, metode pembayaran, total awal, direction, adjustment, dan total akhir.

### 4.5 Gambar dan Bukti Free-Tier Friendly

- Satu gambar utama opsional per produk.
- Scope awal memakai URL Google Drive/external HTTPS untuk gambar Produk, bukti pembayaran, dan foto operasional; binary tidak disimpan di Supabase Storage/PostgreSQL.
- Server/Vercel tidak mengunduh atau mem-proxy file eksternal. Aplikasi hanya menyimpan URL, label, actor, timestamp, dan audit perubahan.
- Product grid memakai placeholder; preview eksternal hanya bila browser dapat mengakses URL tanpa proxy. Aksi utama tetap **Buka Link**.
- Frontend dilarang memakai service role key atau meminta kredensial Google Drive.
- Fitur dapat dimatikan; POS tetap berfungsi penuh tanpa gambar.
- Galeri dan import gambar massal ditunda.
- Migrasi ke Storage internal memerlukan keputusan, capacity model, private bucket/RLS, retention, rollout, dan rollback baru.

### 4.6 Barcode Timbangan — Ditunda

- Fase awal hanya mendukung barcode biasa yang memetakan satu Produk-UOM.
- Barcode yang menyimpan encoded weight/price dari timbangan ditunda sampai format perangkat dan kebutuhan toko dibahas.

### 4.7 Expense dan Arus Kas Non-Penjualan

Detail business workflow berada pada `docs/POS_EXPENSE_CASH_FLOW_SPEC.md`.

- Cash Advance dihapus sebagai jenis/menu terpisah agar tidak membingungkan operasional retail.
- Pengeluaran operasional memakai satu flow `POS_EXPENSE`, baik sumber pembayaran Cash maupun Transfer/Bank.
- Expense mendukung requested/disbursed amount, actual expense, uang kembali, dan outstanding dalam satu dokumen.
- `CASH_IN` mencatat uang non-penjualan yang masuk ke drawer, termasuk top-up dan pengembalian Expense Cash.
- `CASH_OUT` adalah dampak/pergerakan uang fisik dari drawer, bukan menu biaya terpisah. Pemindahan uang antar tempat penyimpanan tetap dicatat tetapi bukan Expense.
- Expense Cash mengubah expected cash sesi; Expense Transfer tidak mengubah drawer dan tetap direkap sebagai pengajuan/pembayaran Transfer.
- Approval Expense dapat diaktifkan/dinonaktifkan melalui konfigurasi operasional tanpa menghilangkan audit.
- Company Admin mengatur default approval company, Store Manager dapat override per store, dan Super Admin memiliki seluruh wewenang lintas-company termasuk toggle feature.
- Approval nonaktif menghasilkan auto-approval setelah submit. Jika aktif, Cash baru boleh dikeluarkan setelah approval Store Manager/authority lebih tinggi.
- Transfer/Bank diajukan dari POS dan baru dianggap dibayar setelah Finance/Company Admin/Super Admin mengonfirmasi eksekusi.
- Cashier mengisi actual expense dan uang kembali; Store Manager atau Finance mereview settlement.
- Expense outstanding tidak memblokir tutup sesi, tetapi memberi warning dan tetap terbuka dengan reference sesi asal.
- Scope awal cukup Expense, Cash In, dan Setor Kas; tidak ada menu internal cash transfer.
- Kategori Expense adalah Master Data per company; bukti dapat dikonfigurasi wajib atau opsional per kategori.
- Kategori Expense menentukan routing COA Expense; COA boleh kosong pada fase sekarang tetapi wajib sebelum posting Finance aktif.
- Tidak ada approval nominal bertingkat pada scope awal. Return boleh masuk sesi berbeda, additional disbursement tetap satu dokumen, dan responsible party wajib disimpan.
- Cash In awal mencakup top-up drawer, Expense Return, top-up kekurangan Cashier, serta source lain dengan alasan.
- Offline Expense Cash hanya dapat `PENDING_SYNC` ketika approval nonaktif; approval aktif dan Transfer offline hanya Draft.
- Expense hanya dapat dicancel sebelum disbursed. Full return tanpa biaya menjadi `SETTLED_NO_EXPENSE`; koreksi settled memakai reversal/replacement Finance.
- Settlement date opsional dan overdue hanya warning. Outstanding report mendukung filter responsible party/category/store/status/method/aging serta export Excel/PDF.
- Cash In tidak membutuhkan approval. `CASHIER_SHORTAGE_TOP_UP` tidak menghapus original shortage/variance.
- Exceptional Customer Balance settlement memakai kategori khusus dan approval Finance/Company Admin walaupun approval Expense umum nonaktif.
- Expense bukan penjualan dan tidak membuat stock movement.

Role, timing posting, penyelesaian outstanding, offline behavior, dan mapping jurnal masih dibahas bertahap.

### 4.8 Buka dan Tutup Sesi Kasir

Keputusan operasional:

- Setiap Cashier mengisi `opening_cash_actual` secara manual setiap membuka sesi.
- Satu Cashier hanya boleh memiliki satu sesi berstatus `OPEN` dalam satu waktu. Percobaan membuka sesi kedua harus ditolak server.
- Sesi wajib terikat pada `company_id`, `store_id`, `pos_terminal_id`, `cashier_id`, serta waktu buka/tutup.
- Pada penutupan sesi, sistem menghitung kas yang seharusnya tersedia dari seluruh cash movement posted pada sesi.
- Cashier mengisi `closing_cash_actual` berdasarkan uang fisik yang dihitung.
- Sistem langsung menampilkan expected cash, actual cash, dan selisih agar Cashier dapat memperbaiki kekurangan fisik sebelum menutup sesi, termasuk menambah uang pribadi bila kebijakan lapangan mengharuskannya.
- Nilai yang ditambahkan Cashier untuk menutup kekurangan harus dicatat sebagai cash-in/settlement terpisah dan tidak boleh diam-diam mengubah expected cash historis.
- Pembayaran non-cash seperti Transfer, QR, dan Card dihitung otomatis dari transaksi posted. Cashier tidak menginput ulang total non-cash ketika tutup sesi.
- Tutup sesi menyimpan snapshot final agar laporan historis tidak berubah ketika transaksi atau movement berikutnya terjadi.

Formula operasional minimum:

```text
expected_closing_cash
= opening_cash_actual
+ cash_sale_received
+ ketul_vendor_cash_received
+ posted_cash_in
- cash_refund_paid
- ketul_customer_cash_paid
- posted_cash_out
- posted_cash_expense
```

Expense dan Cash In/Out non-penjualan mengikuti `docs/POS_EXPENSE_CASH_FLOW_SPEC.md`. Cash Ketul Vendor dan payout Cash Customer Intake masuk formula hanya jika terkait sesi aktif; Backoffice Cash Receipt tanpa sesi tidak masuk drawer Kasir. Formula di atas menetapkan tempat dampaknya pada sesi tanpa memutuskan mapping jurnalnya.

### 4.8A Master Metode Pembayaran dan Gateway Fee

- Kontrak lengkap berada pada `docs/PAYMENT_METHOD_MASTERDATA_SPEC.md`.
- POS hanya menampilkan metode aktif yang eligible untuk company/store dan workflow transaksi.
- Cashier dapat memakai Cash, Transfer, QRIS, Card, E-Wallet, Tempo, atau custom method aktif, tetapi tidak dapat mengubah fee/account mapping.
- Fee percent/fixed/gabungan dapat ditanggung company atau Customer dan ditampilkan sebelum konfirmasi.
- Split payment menghitung fee per payment leg; penjualan/HPP tetap diposting satu kali.
- Customer-borne surcharge tampil terpisah dari harga Produk, diskon, pajak, dan rounding.
- Company-borne fee aktual diakui ketika settlement; perbedaan expected/actual fee menjadi reconciliation exception Finance.

### 4.9 Download Excel Flow Keuangan Sesi

- Cashier dapat mengunduh laporan `.xlsx` untuk sesi miliknya sendiri.
- Store Manager dapat mengunduh laporan sesi pada store dalam scope penugasannya.
- File dibuat dari snapshot/data server dan wajib scoped ke company, store, session, dan user yang berhak.
- Export tidak menampilkan HPP, cost batch, COA internal, atau data company lain kepada Cashier.
- Workbook minimum memiliki sheet:
  - `Ringkasan Sesi`: opening cash, cash/non-cash sales, refund, cash movement Ketul, expected cash, actual cash, dan selisih;
  - `Transaksi`: invoice/refund posted, waktu, metode pembayaran, total, dan rounding;
  - `Arus Kas`: opening, cash sale, refund cash, Ketul Vendor cash-in, Ketul Customer cash-out, Cash In/Out, Expense Cash, pengembalian Expense, serta closing;
  - `Setoran`: reserve saldo berikutnya, expected deposit, deposit aktual, selisih, dan status setoran.
- Tombol download tersedia pada Ringkasan Sesi dan tetap dapat digunakan setelah sesi ditutup.

### 4.10 Setor Kas ke Bank Multi-Sesi

- Menu **Setor Kas** menampilkan sesi milik Cashier yang sudah `CLOSED` dan masih mempunyai saldo wajib setor.
- Cashier dapat memilih satu atau beberapa sesi dalam company/store yang sama.
- Setiap sesi menampilkan `actual_closing_cash`, saldo yang ditahan untuk modal sesi berikutnya, setoran yang sudah dialokasikan, dan sisa yang seharusnya disetor.
- Saldo untuk hari/sesi berikutnya ditentukan manual ketika Cashier membuat Setor Kas dan mengurangi nilai yang harus disetor. Saldo tersebut kemudian tetap diinput manual sebagai opening cash pada sesi berikutnya.
- Input opening cash hanya physical count dan tidak membuat jurnal. Tambahan dana dari Brankas harus memakai Cash In `DRAWER_TOP_UP` agar source kas dapat ditelusuri.
- Sistem tidak otomatis menganggap saldo yang ditahan sudah menjadi opening session berikutnya; keduanya disimpan sebagai audit trail terpisah agar dapat direkonsiliasi.
- Formula minimum per sesi:

```text
expected_deposit_remaining
= actual_closing_cash
- next_session_float_reserved
- posted_deposit_allocations
```

- Header setoran menampilkan total expected dari seluruh sesi terpilih dan `actual_deposit_amount` yang diinput Cashier berdasarkan setoran nyata ke bank.
- Sistem menghitung `deposit_difference = actual_deposit_amount - total_expected_deposit` dan menampilkannya sebelum submit.
- Nominal aktual boleh kurang, sama, atau lebih dari expected. Sistem tidak memaksa Cashier menyamakan angka dan tidak membuat siklus partial deposit.
- Dokumen menyimpan sesi terpilih, expected per sesi, total expected, total aktual, selisih, bank/tujuan, waktu setor, Cashier, dan referensi/bukti bila tersedia.
- Status dokumen minimum: `DRAFT`, `SUBMITTED`, `APPROVED`, `REJECTED`, dan `CANCELED`.
- Saat Cashier menekan submit, seluruh sesi terpilih dikunci pada dokumen tersebut dan tidak dapat dipilih pada Setor Kas lain.
- Finance membandingkan setoran dengan mutasi/bukti bank dan dapat `APPROVE` atau `REJECT`. Company Admin/Super Admin mewarisi kewenangan approval tersebut sesuai company scope.
- Ketika Finance menyetujui, seluruh sesi terpilih dianggap selesai disetor walaupun nominal aktual berbeda dari expected. Selisih kurang/lebih menjadi `deposit_variance` dan catatan evaluasi Finance, bukan sisa setoran Cashier.
- Financial event/jurnal Setor Kas hanya dibuat setelah status `APPROVED`. Kas dalam Perjalanan/Kas Besar memakai nominal aktual, Kas Laci dibersihkan sebesar expected deposit, dan perbedaannya masuk akun kontrol selisih.
- Selisih tidak otomatis menjadi kerugian/pendapatan. Finance menyelesaikannya melalui workflow append-only pada `DEPOSIT_VARIANCE_RESOLUTION_SPEC.md` tanpa membuka kembali sesi atau Setor Kas final.
- Setor tujuan Bank memakai Kas dalam Perjalanan sampai mutasi Bank dikonfirmasi. Setor tujuan Brankas langsung memindahkan Kas Laci ke Kas Besar.
- Jika Finance menolak, dokumen tidak membuat jurnal dan sesi dilepas kembali agar dapat diperbaiki atau dibuatkan Setor Kas baru.
- Bukti setoran mengikuti konfigurasi `deposit_proof_mode` (`REQUIRED` atau `OPTIONAL`) dengan company default dan optional store override.
- Satu sesi tidak boleh masuk ke lebih dari satu dokumen aktif/final. Semua submit dan approval wajib atomic serta tenant-scoped.

### 4.11 Draft dan Hold Order

- Semua penjualan `DRAFT` adalah catatan transaksi sementara dan masih dapat diedit sebelum berhasil diposting atau dibatalkan.
- Draft dapat terbentuk otomatis karena `STOCK_SHORTAGE` atau dibuat sengaja melalui tombol **Simpan/Hold Order** walaupun stok mencukupi.
- Keputusan user 2026-08-05 membuka roadmap STK-006 untuk exception Stock minus
  POS yang berizin. Fitur default OFF, online-only, dan tidak mengubah behavior
  Draft `STOCK_SHORTAGE` sampai server policy, Warehouse opt-in, actor
  permission, reason/audit, provisional HPP, replenishment allocation, dan
  regression telah lulus. Offline dan Bundle tetap fail-closed pada tahap awal.
- Draft tidak mereservasi/mengurangi stok, tidak membuat payment final, financial event, atau jurnal.
- Draft menyimpan `created_by`, `created_session_id`, `created_at`, `draft_reason`, serta snapshot line agar histori perubahan dapat diaudit.
- Setiap draft memiliki nomor otomatis. Cashier dapat menambahkan label/nama draft, customer, dan catatan secara opsional agar mudah dicari.
- Cashier lain yang aktif dan memiliki akses ke store yang sama dapat membuka serta melanjutkan draft dari terminal lain.
- Hanya satu user/terminal boleh mengedit draft pada satu waktu. Edit lock memakai heartbeat dan dilepas setelah 5 menit tidak aktif.
- Cashier lain dapat mengambil alih lock yang kedaluwarsa melalui konfirmasi; takeover menyimpan actor, terminal, dan waktu pada audit log. Editor lama kehilangan hak tulis ketika lock diambil alih.
- Store Manager atau Company Admin dapat melakukan force release sebelum 5 menit bila terminal rusak/tidak dapat diakses. Force release membutuhkan konfirmasi dan audit actor, terminal, waktu, serta draft; Cashier biasa tidak memiliki hak ini.
- Draft dapat melewati pergantian sesi. Saat berhasil diposting, sistem menyimpan `posted_by` dan `posted_session_id` terpisah dari pembuat/sesi asal.
- Cashier wajib menekan konfirmasi/retry secara manual setelah stok tersedia. Sistem memeriksa ulang stok, harga, promo, UOM, dan aturan transaksi di server sebelum posting.
- Harga dan promo dihitung ulang mengikuti kondisi saat draft dilanjutkan, bukan otomatis memakai nilai lama. Snapshot awal tetap disimpan untuk audit.
- Jika harga/promo berubah, UI menampilkan nilai lama dan nilai terbaru serta meminta Cashier mengonfirmasi perubahan sebelum checkout.
- Jika harga terbaru naik, Cashier boleh mempertahankan final price lama dengan diskon manual sebesar selisih. Resolver price terbaru, snapshot lama, diskon, actor, dan waktu tetap disimpan.
- Jika harga terbaru turun, POS wajib memakai harga terbaru yang lebih murah dan tidak boleh mempertahankan snapshot lama yang lebih mahal.
- Payment method/nominal yang pernah diinput pada draft hanya catatan sementara dan bukan penerimaan uang. Cashier wajib memilih/mengonfirmasi ulang pembayaran ketika posting.
- Draft lama tidak dihapus otomatis. Setelah 7 hari, draft diberi badge/notice `STALE` dan tetap dapat diedit, diposting, atau dibatalkan.
- `draft_stale_after_days` memiliki company default 7 hari dan dapat mempunyai optional store override.
- Pembatalan draft menyimpan `canceled_by` dan `canceled_at`; alasan pembatalan bersifat opsional.
- Draft canceled tetap tersedia pada audit/history dan tidak dapat diaktifkan kembali tanpa aksi copy/duplicate yang eksplisit.
- Backoffice menyediakan laporan operasional Draft/Hold/Pending/Failed dengan aging, waiting party, last actor/action, counterparty, blocker, dan outcome sesuai `docs/FINANCE_REPORTING_AND_CUTOFF_SPEC.md`. Nilai non-posted tidak masuk laporan keuangan.

### 4.12 Pricelist, Diskon, dan Bundle Promo

- Pricelist dimiliki modul Sales Master Data. Detail kontrak ada pada `docs/SALES_PRICELIST_NOTES.md`.
- Jika customer memiliki Pricelist Eksklusif, resolver memakai rule customer lalu langsung fallback ke harga dasar Produk-UOM; Pricelist Global/tier tidak diterapkan.
- Jika tidak ada Pricelist Customer Eksklusif, resolver memakai Pricelist Global lalu harga dasar Produk-UOM.
- Cashier memilih customer sebelum checkout; perubahan customer memicu resolve ulang seluruh harga.
- Quantity tier hanya berlaku pada Pricelist Global dan dapat memakai basis quantity UOM penjualan atau ekuivalen base UOM per rule produk.
- Potongan nominal tier berlaku per unit.
- Cashier dapat memberi diskon line dan transaksi dalam bentuk nominal atau persentase tanpa limit role pada scope awal.
- Kalkulasi dilakukan server-side dan snapshot pricelist/rule/diskon disimpan pada transaksi.
- Promo 2+1 dan sejenisnya dibuat sebagai produk Bundle dengan SKU khusus yang dipilih/scan eksplisit. POS tidak auto-convert item biasa. Seluruh komponen mengurangi stok dan HPP; harga jual bundle dapat setara jumlah item yang dibayar.
- POS/struk/Invoice tetap menampilkan satu line Bundle. Component revenue/HPP allocation, return basis, dan commercial-vs-component reporting mengikuti `BUNDLE_REVENUE_ALLOCATION_SPEC.md`.
- Company Admin dan Store Manager dapat mengelola Pricelist hanya pada company assignment aktifnya.
- Pricelist Global dapat berlaku pada seluruh store atau store tertentu dalam company yang sama.
- Customer umum memakai Pricelist Global default. Cashier dapat memilih Pricelist aktif lain yang eligible untuk store secara opsional; override tersimpan sebagai snapshot/audit transaksi.
- Diskon manual dapat diterapkan di atas Global maupun Customer Exclusive price.
- Price override per line merupakan kebijakan Terminal/POS opsional dan default
  OFF. Jika aktif, semua Cashier sah pada Terminal tersebut dapat mengisi harga
  final yang mengalahkan Pricelist untuk line itu; tanpa input override, harga
  tetap berasal dari resolver canonical seperti sekarang. Kebijakan wajib
  ditegakkan server-side, versioned, audited, dan tidak mengubah master
  Product-UOM/Pricelist. Scope awal online-only; detail implementasi ada pada
  `docs/POS_TERMINAL_PRICE_OVERRIDE_PLAN.md`.
- Harga yang ditampilkan/dibayar POS bersifat tax-inclusive ketika `SALES_TAX` aktif. Entitlement hanya ditoggle Super Admin; resolver, inclusive extraction, snapshot, rounding, retur, dan jurnal mengikuti `docs/TAX_ENGINE_SPEC.md`.
- Draft yang dilanjutkan selalu memakai hasil resolver terkini dan menampilkan perubahan terhadap snapshot awal.

### 4.13 Customer dan Saldo Kelebihan Transfer

- Customer Balance hanya tersedia bila entitlement company `customer_balance_enabled = true`. Hanya Super Admin dapat mengubah entitlement tersebut.
- Ketika `WIND_DOWN`, server menolak accrual/refund-to-balance baru tetapi tetap mengizinkan pemakaian saldo lama, koreksi, dan exceptional settlement. Setelah seluruh liability nol, status otomatis `DISABLED`, seluruh UI operasional disembunyikan, dan mutation baru ditolak; histori tetap tersedia read-only untuk role berwenang.
- Cashier dapat quick-create Customer company-wide dengan kode otomatis, nama, kategori, dan telepon opsional.
- Quick-create berjalan melalui RPC/API server terkontrol dan idempotent; POS tidak memperoleh hak INSERT tabel Customer secara langsung.
- Nama Customer unik per company; telepon/email boleh sama.
- Customer Walk-In adalah row sistem khusus per company.
- Customer Balance berlaku di seluruh store dalam company yang sama, tidak kedaluwarsa, dan hanya dapat digunakan Customer yang sama melalui payment method khusus.
- Saldo dapat berasal dari kelebihan Transfer/Cash yang dititipkan, nilai Ketul, refund, atau koreksi berwenang; seluruhnya wajib memakai ledger append-only dan source document.
- Setelah grand total final/rounding, POS menerapkan `KETUL_OFFSET`, lalu wajib menggunakan seluruh saldo lama Customer. Cashier tidak boleh memilih pemakaian sebagian; sisanya dibayar Cash/Transfer/QR/Card.
- Credit yang tercipta dari transaksi berjalan menjadi source balance baru sehingga saldo sumber lama tetap dapat ditutup walaupun saldo akhir terisi kembali.
- Jika saldo lama lebih besar daripada amount due, checkout diblokir dan POS menampilkan kekurangan minimum belanja yang harus ditambahkan agar seluruh saldo lama terserap. Amount due tidak boleh negatif dan Cashier tidak boleh membawa sisa saldo lama ke transaksi berikutnya.
- Customer Balance hanya mengurangi amount due dan tidak mengubah harga, diskon, pajak, rounding, atau revenue.
- POS menampilkan indikator saldo saat Customer dipilih. Pada struk, penggunaan saldo boleh berlabel **Potongan Saldo Customer**, tetapi backend wajib menyimpannya sebagai settlement/payment, bukan diskon komersial.
- Cashier hanya membuat permintaan koreksi saldo. Finance melakukan approval/reject dari Backoffice; Company Admin/Super Admin mewarisi authority tersebut.
- Saldo tidak dapat dicairkan langsung dari POS. Customer inactive tetap menyimpan saldo; penyelesaian khusus dibahas melalui Expense/exceptional settlement atau pengiriman Produk pada workflow terpisah.
- Exceptional settlement dapat dibuat Finance/Store Manager dan di-approve Finance/Company Admin sesuai konfigurasi; Cashier tidak dapat menjalankannya.
- Customer Statement dan Backoffice menyediakan histori, saldo berjalan, source document, aging, total liability company, serta export Excel. Aging tidak membuat saldo kedaluwarsa.

### 4.14 Ketul — Fitur Opsional dengan Workflow Bisnis Selesai

- Ketul adalah tiang kebab. Setiap jenis dibuat sebagai Produk STOCK pada category Ketul dengan UOM PCS integer.
- Ketul memiliki flow Customer -> stock gudang toko -> Vendor dan dapat menjadi offset pembayaran Customer.
- Cashier menginput harga manual per transaksi Customer maupun Vendor; Pricelist/harga dasar tidak digunakan.
- Penerimaan Customer boleh standalone tanpa sale/invoice lama dan dapat dibayar atau menjadi Customer Balance.
- Settlement Customer mendukung split Cash, Transfer, dan Customer Balance.
- Jika terkait sale, nilai Ketul mengurangi amount due setelah grand total final/rounding; revenue sale tetap utuh. Dokumen Ketul dan invoice saling mereferensikan.
- `KETUL_OFFSET` menjadi settlement/tender non-cash pada invoice, bukan diskon. Total seluruh tender termasuk offset tetap sama dengan grand total final.
- Harga manual boleh nol. Intake membuat FIFO batch dengan acquisition value tersebut.
- Vendor berasal dari Master Supplier existing. Penjualan Ketul ke Vendor menjadi transaksi uang masuk dan laporan terpisah dari retail sale.
- Satu dokumen Vendor dapat berisi beberapa Produk Ketul. Vendor mengembalikan accepted/rejected qty serta nominal aktual; reject dipilih kembali ke active/damaged stock.
- Dispatch memindahkan sent qty dari gudang STORE aktif ke `TRANSIT`; pending qty tetap di `TRANSIT`.
- Cashier atau Finance dapat mencatat beberapa hasil Vendor parsial. Accepted qty menjadi stock-out dan memakai HPP FIFO saat hasil dicatat; reject dipindah ke active/`DAMAGED`.
- Nilai aktual Vendor mendukung mode `DOCUMENT_TOTAL` atau `PER_LINE`.
- Pada mode `DOCUMENT_TOTAL`, nominal dialokasikan proporsional berdasarkan nilai estimasi accepted line dan disimpan sebagai snapshot.
- Jika seluruh estimasi bernilai nol, fallback alokasi memakai proporsi accepted qty.
- Selisih pembulatan alokasi ditempelkan ke accepted line bernilai terbesar.
- Finance atau Company Admin/Super Admin boleh mengoreksi hasil yang diinput Cashier sebelum confirmation; setiap perubahan menyimpan audit before/after append-only.
- Settlement fleksibel many-to-many: satu pembayaran dapat mencakup beberapa hasil parsial dan satu hasil dapat dibayar bertahap. Kekurangannya menjadi outstanding Vendor.
- Pembayaran Cash Vendor masuk drawer sesi Cashier penerima; Transfer langsung bank dan tidak memengaruhi drawer.
- Cash wajib menyimpan session penerima dan source payment document; Transfer menyimpan referensi bank/rekening.
- Jika tidak ada sesi `OPEN`, Finance atau Company Admin/Super Admin boleh membuat Backoffice Cash Receipt tanpa drawer/sesi palsu selama source Vendor result, actor, waktu, nominal, dan tujuan kas tersimpan jelas.
- Backoffice Cash Receipt buatan Finance langsung confirmed tanpa approval kedua.
- Bukti Vendor configurable `REQUIRED`/`OPTIONAL` dengan company default dan optional store override.
- Company Admin mengatur default bukti; Store Manager dapat membuat store override sesuai assignment.
- Cashier dapat cancel sebelum dana dikonfirmasi oleh Finance atau Company Admin/Super Admin hanya setelah accepted goods diretur fisik. Retur memulihkan FIFO layer/cost asal ke active/`DAMAGED`; setelah confirmation, koreksi memakai reversal.
- Laporan minimum menampilkan qty Customer intake, dispatch, accepted, rejected, pending transit, nilai acquisition/Vendor, HPP, margin, dan status pembayaran.
- Outstanding Vendor memiliki due date manual dan aging bucket `Belum Jatuh Tempo`, `1-30`, `31-60`, `61-90`, `>90 hari`.
- Setelah confirmation, koreksi nominal memakai financial reversal; koreksi quantity memakai financial dan stock/FIFO reversal.
- Laporan dibagi menjadi Customer Intake, Vendor Dispatch/Result, dan Outstanding/Settlement; tersedia filter lengkap dan export Excel.
- Cashier hanya melihat/export transaksi miliknya dan tidak melihat HPP/margin. Store Manager mengikuti store scope; Finance/Admin mengikuti company scope.
- Dokumen otomatis `CLOSED` setelah quantity, transit, settlement, dan workflow lanjutan selesai.
- Quantity status (`DRAFT/DISPATCHED/PARTIAL/RECONCILED/CANCELED`) dipisahkan dari settlement status (`UNPAID/PARTIALLY_PAID/PAID/REVERSED`).
- Koreksi result yang sudah membuat movement memakai delta/reversal baru; movement lama immutable.
- Stok kurang memblokir posting dispatch, tetapi dokumen tetap dapat disimpan `DRAFT`.
- Produk Ketul sama digabung menjadi satu line. Nomor semua dokumen Ketul dibuat otomatis per company/store.
- Seluruh mutation memakai idempotency key. Dokumen `CLOSED` tidak dibuka ulang dan hanya dikoreksi melalui reversal.
- Vendor inactive memblokir dispatch baru, tetapi dokumen/result/outstanding lama tetap dapat diselesaikan.
- Cashier dapat mem-posting kedua arah; Store Manager memantau tanpa approval wajib.
- Entitlement Ketul diaktifkan/dinonaktifkan per company hanya oleh Super Admin. Setelah aktif, Company Admin mengatur category/product dan default operasional; Store Manager hanya mengatur override operasional yang memang diizinkan untuk store assignment.
- Ketul tidak boleh diimplementasikan sebagai diskon biasa atau stock adjustment.
- Jika fitur disabled, seluruh UI Ketul disembunyikan tanpa menghapus histori.
- Detail kontrak final bisnis dan guardrail implementasi ada pada `docs/KETUL_WORKFLOW_NOTES.md`.

### 4.15 Penjualan Offline, Sync, Retry, dan Struk

- Saat koneksi putus, Cashier tetap dapat membuat transaksi penjualan lokal menggunakan cache Produk/harga terakhir. Transaksi berstatus lokal `PENDING_SYNC` dan belum menjadi invoice server `POSTED`.
- Penyerahan barang dan penerimaan pembayaran offline hanya diperbolehkan untuk line yang memiliki **Offline Stock Allowance** aktif pada terminal/session tersebut.
- Allowance diterbitkan server ketika terminal masih online dan disimpan per company, store, warehouse, terminal, cashier session, product, serta base UOM quantity.
- Besaran default adalah 20% dari stock server yang masih available dan belum direservasi per produk. Company Admin mengatur default company, Store Manager dapat mengatur persentase store, sedangkan Super Admin tetap satu-satunya role yang dapat menampilkan/meniadakan feature offline.
- Untuk base UOM integer, hasil allowance dibulatkan ke bawah; bila hasil nol tetapi unreserved stock masih tersedia, minimum allowance adalah `1`. Untuk base UOM decimal, hasil dibulatkan ke bawah mengikuti precision UOM. Alokasi diproses terhadap sisa unreserved stock sehingga minimum allowance tidak pernah membuat total reservation melebihi stock.
- Store Manager/Company Admin memilih terminal yang boleh menerima allowance. Tidak semua terminal memperoleh allowance otomatis.
- Allowance adalah reservation/available-to-promise, bukan stock movement dan tidak mengubah on-hand. Quantity yang dialokasikan tidak boleh dijual terminal lain sampai allowance dikonsumsi atau dilepas.
- Setiap penjualan offline mengurangi allowance lokal secara atomic. POS memblokir quantity yang melebihi sisa allowance walaupun cache on-hand masih terlihat lebih besar.
- Beberapa terminal boleh mempunyai allowance terpisah, tetapi jumlah seluruh allowance aktif tidak boleh melebihi stock server yang belum dialokasikan.
- Saat sync, server mengunci allowance dan stock, mem-posting sale/movement sebanyak quantity offline, menandai allowance consumed, lalu mengembalikan acknowledgement invoice.
- Terminal tanpa allowance atau dengan allowance tidak cukup hanya boleh menyimpan Draft; barang dan pembayaran belum boleh diserahkan.
- Allowance terikat pada cashier session dan tidak expired otomatis selama terminal masih offline. Sesi tidak boleh ditutup sebelum seluruh queue tersinkron atau allowance dilepas secara resmi.
- Store Manager/Company Admin dapat force revoke allowance terminal rusak/hilang setelah pengecekan fisik. Revoke menyimpan actor, waktu, alasan, allowance tersisa, dan exception audit; queue lama ditandai invalid agar tidak dapat sync diam-diam kemudian.
- UI wajib menampilkan status offline serta timestamp sinkronisasi Produk, harga, dan stock terakhir. Saldo cache tidak boleh disebut saldo server final.
- Offline tidak mengizinkan Customer Balance, Ketul, Refund, Goods Receipt, Adjustment, atau mutation lain yang membutuhkan state server terkini.
- Payload lokal menyimpan `client_transaction_id`, idempotency key, company/store/terminal/session/Cashier, versi Draft, snapshot line, harga, diskon, rounding, payment intent, waktu lokal, dan payload hash.
- Perubahan lokal selalu menaikkan versi Draft. Queue hanya mengirim versi canonical terbaru dan tidak boleh mencampur line dari versi lama.
- Saat online kembali, queue mengirim setiap Draft dengan idempotency key yang sama sampai menerima acknowledgement server. Status per transaksi terlihat sebagai `QUEUED`, `SYNCING`, `NEEDS_CONFIRMATION`, `POSTED`, atau `FAILED`.
- Server memvalidasi ulang membership, entitlement, session, allowance, stock, UOM, Product, payload hash, dan duplicate key. Transaksi fisik yang sudah selesai dalam allowance valid diposting memakai snapshot canonical tanpa meminta konfirmasi ulang hanya karena harga server berubah. Allowance invalid/revoked, scope tenant tidak valid, atau payload rusak masuk `HOLD/FAILED` dan tidak boleh diposting diam-diam.
- Untuk transaksi fisik offline yang sudah dibayar/diserahkan dalam allowance valid, server menghormati snapshot harga offline. Harga terbaru tetap dihitung sebagai **Offline Price Variance** untuk report/audit saja; variance tidak menagih ulang Customer dan tidak membuat jurnal otomatis.
- Product/UOM yang menjadi inactive setelah transaksi fisik offline tetap dapat diposting memakai snapshot valid dan diberi exception audit. Cache berikutnya memblokir penggunaan Product/UOM tersebut untuk transaksi baru.
- Server response wajib mengembalikan reference invoice atau error terstruktur untuk `client_transaction_id` yang sama. Queue baru boleh menghapus payload lokal setelah acknowledgement tersimpan.
- Timeout tombol Bayar tidak membuat transaksi/key baru. POS mengecek status key yang sama: hasil posted membuka invoice, hasil belum diproses melakukan retry key yang sama, dan validation failure mengembalikan transaksi menjadi Draft/exception.
- Slip Offline/Belum Tersinkron boleh dicetak untuk operasional ketika internet mati. Slip wajib memuat watermark/status jelas dan tidak boleh memakai nomor invoice final atau disebut bukti pembayaran final.
- Struk final hanya dapat dicetak setelah server mengembalikan invoice `POSTED`. Reprint selalu memakai snapshot final server.
- Format minimum: thermal 80 mm default, thermal 58 mm opsional, serta A4/PDF dari Backoffice.
- Metode pembayaran offline fleksibel: Cash, Transfer, QRIS, Card, atau metode aktif company dapat dipilih. Payment elektronik yang tidak dapat diverifikasi gateway saat offline disimpan sebagai `PENDING_VERIFICATION` bersama reference yang tersedia dan diverifikasi ketika sync. Customer Balance dan Ketul tetap tidak tersedia offline.
- Cash offline menambah expected cash dan membuat jurnal penjualan/HPP saat sync berhasil dengan snapshot waktu/source transaksi asli. Transfer/QRIS/Card baru dianggap penerimaan rekening setelah verified.
- Jika payment elektronik belum dapat atau gagal diverifikasi setelah barang diserahkan, sale, HPP, dan stock-out tetap `POSTED` karena transaksi fisik sudah terjadi. Sisi penerimaan dicatat sebagai `Piutang Pembayaran Offline`, payment berubah menjadi `OFFLINE_PAYMENT_EXCEPTION`, tidak masuk Kas/Bank, dan memicu notifikasi Store Manager serta Finance.
- Piutang exception boleh mereferensikan Walk-In Customer dan wajib ditelusuri melalui company, store, terminal, session, Cashier, invoice, dan `client_transaction_id`; Customer master tidak wajib dibuat.
- Finance atau Company Admin/Super Admin menyelesaikan exception melalui verifikasi ulang, penerimaan Cash/Transfer pengganti, atau write-off berapproval. Setiap penyelesaian memakai event append-only, mengurangi piutang terkait, dan tidak mengedit payment lama.
- Bukti Transfer offline boleh ditambahkan setelah koneksi kembali karena upload ke Google Drive mungkin tidak tersedia saat offline. Bila konfigurasi bukti `REQUIRED`, URL valid wajib tersedia sebelum Finance memberi status verified; link tetap bukan bukti bahwa payment otomatis valid.
- Local Draft yang belum diselesaikan/dikirim boleh dibatalkan tanpa jurnal. Transaksi fisik final lokal `PENDING_SYNC` tidak boleh dihapus atau dibatalkan final di perangkat; transaksi harus sync dahulu, lalu cancellation/refund mengikuti workflow server dan reversal resmi.
- Receipt final untuk transaksi yang payment-nya belum selesai wajib menampilkan **Pembayaran Belum Terverifikasi** sampai exception ditutup.

### 4.16 Notifikasi Operasional dan Output Dokumen

Dalam dokumen ini, **RO (Request Order)** adalah Stock Request yang dibuat Cashier sebelum diproses menjadi Supplier Order oleh Store Manager/Company Admin.

Notifikasi minimum:

- Store Manager menerima notifikasi untuk Stock Request/RO baru, Purchase Return Draft, Stock Opname `COMPLETED`, `RECOUNT_REQUIRED`, offline sync gagal, `OFFLINE_PAYMENT_EXCEPTION`, dan minimum stock.
- Stock Request/RO yang dibuat Cashier tetapi belum dikonversi menjadi Supplier Order atau belum diproses tetap tampil pada badge **RO Belum Diproses** sampai diproses/ditutup.
- Pending RO tidak membuat notification row baru setiap hari. Sistem menghitung pending/aging dari status dokumen ketika inbox dibuka agar hemat database write dan background job.
- Company Admin melihat seluruh notifikasi company. Finance hanya menerima exception pembayaran, setoran, dan event Finance relevan.
- Low-stock dikelompokkan per store/gudang, bukan satu notification per produk. Klik notification membuka halaman Stock dengan filter warehouse dan daftar Product yang memicu notifikasi.
- Exception transaksi tetap satu notification per source document dan memakai deduplication key agar retry tidak membuat duplikat.

UX notifikasi scope awal:

- inbox/bell di aplikasi, badge unread, dan deep-link ke source/filter;
- status `UNREAD`, `READ`, dan `RESOLVED`;
- resolved tetap ada pada histori dan tidak dihapus permanen;
- refresh saat halaman dibuka dan polling ringan; WhatsApp, email, serta push notification ditunda;
- polling interval dan feature visibility mengikuti konfigurasi, tetapi hak memunculkan/meniadakan feature tetap hanya Super Admin.

Dokumen yang dapat dicetak/diunduh:

- Slip Offline dan struk penjualan/refund;
- Stock Request/RO;
- Goods Receipt;
- Purchase Return;
- Stock Opname blind count sheet;
- Ringkasan Tutup Sesi;
- bukti Setor Kas;
- dokumen Ketul bila entitlement aktif;
- Pro Forma Invoice untuk payment method `TEMPO`.

Pro Forma Invoice `TEMPO` adalah dokumen tagihan sementara/permintaan pembayaran dan bukan bukti pembayaran lunas. Dokumen menyimpan customer, transaksi/source, item, quantity/UOM, harga/diskon/rounding snapshot, total, limit/term/due date, status, nomor otomatis, serta histori cicilan. Hak menampilkan/meniadakan feature `TEMPO` tetap milik Super Admin.

Aturan output:

- thermal 80/58 mm untuk slip operasional;
- A4/PDF/Excel dari Backoffice untuk laporan lengkap;
- Draft/Pending/Offline memakai watermark status;
- reprint memakai snapshot dokumen, menyimpan actor, waktu, dan jumlah reprint;
- blind count sheet Cashier tidak menampilkan system stock, difference, HPP, atau valuation;
- Pro Forma Invoice memakai label jelas **BUKAN BUKTI PEMBAYARAN LUNAS**.

---

### 4.17 Penjualan TEMPO dan Pro Forma Invoice

- Penjualan `TEMPO` hanya dapat memakai Customer terdaftar; Customer Walk-In tidak memiliki limit/term yang dapat dipantau.
- Cashier boleh memberikan TEMPO tanpa approval Store Manager. Risiko keputusan operasional berada pada Cashier dan harus tersimpan sebagai actor pada audit transaksi.
- Finance mengatur `credit_limit` dan default jangka waktu TEMPO secara manual per Customer. Keduanya dapat berbeda antar-Customer.
- Saat checkout, Cashier memilih due date aktual transaksi. POS menyarankan due date dari default term Customer, tetapi Cashier boleh menggantinya sebelum posting.
- Setelah sale posted, Finance boleh override due date. Override tidak menghapus nilai sebelumnya dan wajib menyimpan due date lama/baru, alasan, actor, serta waktu perubahan.
- Sistem menghitung total piutang terbuka, sisa limit, due date, dan status keterlambatan sebelum checkout.
- Limit terlampaui atau piutang overdue hanya menghasilkan warning yang jelas; sistem tidak memblokir Cashier. Cashier harus mengonfirmasi warning sebelum melanjutkan dan keputusan override disimpan pada transaksi.
- Customer yang masih mempunyai Pro Forma outstanding tetap boleh menerima sale TEMPO baru. POS wajib memperlihatkan jumlah dokumen dan total piutang yang sudah terbuka; keputusan melanjutkan berada pada Cashier dan dicatat sebagai acknowledgement. Sistem tidak memakai hard block karena kebijakan operasional setiap toko dapat berbeda.
- Harga tetap mengikuti resolver Pricelist, diskon, dan rounding penjualan biasa. Transaksi menyimpan seluruh snapshot harga; koreksi berikutnya tidak boleh mengubah Master Produk/Pricelist atau histori secara diam-diam.
- Setelah transaksi TEMPO dikonfirmasi online, barang langsung diserahkan, sale/stock movement/HPP diposting, dan piutang Customer terbentuk sebesar outstanding. Status dokumen customer tetap Pro Forma selama belum lunas.
- Pembayaran boleh parsial/cicilan dan dapat memakai satu atau beberapa metode pembayaran aktif. DP pada checkout menjadi payment allocation pertama dan hanya sisa sesudah DP yang menjadi piutang.
- Seluruh pembayaran TEMPO diinput satu pintu melalui menu **Pembayaran Tempo** pada POS oleh Cashier. Finance tidak membuat sumber pembayaran paralel dari Backoffice; Finance memantau, merekonsiliasi, dan melakukan koreksi/override berwenang terhadap data POS.
- Menu Pembayaran Tempo menampilkan seluruh Pro Forma outstanding Customer, diurutkan dari due date/tanggal tertua. Sistem menyarankan allocation oldest-first, tetapi Cashier boleh memilih satu atau beberapa Pro Forma yang akan dibayar.
- Satu payment dapat dialokasikan ke beberapa Pro Forma. Sistem melunasi dokumen yang dipilih secara berurutan; jika sisa nominal tidak cukup untuk dokumen berikutnya, sisa tersebut menjadi cicilan dan dokumen terakhir berstatus `PARTIALLY_PAID`.
- Setiap pembayaran membuat histori append-only, receipt pembayaran, saldo sebelum/sesudah, actor, waktu, sesi Cashier, dan source Pro Forma.
- Jika pembayaran melebihi outstanding, selisih masuk Customer Balance hanya bila entitlement Customer Balance aktif dan Customer memilih menyimpannya. Bila fitur tidak aktif atau Customer menolak, selisih wajib dikembalikan melalui Cash/Transfer dan dicatat pada payment/refund flow yang sama; Piutang tidak boleh negatif.
- Invoice Penjualan final baru diterbitkan ketika seluruh outstanding lunas. Invoice final mereferensikan Pro Forma dan seluruh histori pembayaran; pelunasan tidak membuat stock movement atau revenue kedua.
- Invoice final menyimpan `transaction_date` dari sale asli serta `issued_at/paid_at` ketika pelunasan terjadi. Nomor Invoice final baru dibuat saat lunas, sedangkan nomor Pro Forma tetap menjadi referensi permanen.
- Retur setelah sale TEMPO posted menggunakan Credit Note append-only yang mengurangi piutang. Jika piutang sudah lunas, nilai retur diselesaikan melalui refund Cash, Transfer, atau Customer Balance sesuai entitlement dan pilihan Customer.
- Pembatalan penuh hanya dapat diproses ketika barang benar-benar kembali. Sistem membuat dokumen reversal untuk sale, stock, HPP, dan piutang; transaksi dan histori pembayaran asli tidak dihapus.
- Koreksi harga setelah sale posted dibuat Finance melalui Debit Note atau Credit Note; Pro Forma dan snapshot harga asli tidak diedit. Note wajib memiliki alasan, reference dokumen, actor, waktu, serta pengaruhnya terhadap outstanding.
- Detail Note mengikuti `DEBIT_CREDIT_NOTE_SPEC.md`: financial-only Note tidak mengubah stock, quantity wajib melalui Sales Return, dan refund/payment merupakan event terpisah.
- Write-off piutang hanya dapat dibuat/diajukan Finance dan hanya diposting setelah Company Admin menyetujui. Maker-checker wajib: Company Admin tidak membuat sekaligus menyetujui write-off sendiri. Write-off dapat parsial atau penuh per Pro Forma dan tidak menghapus Pro Forma, payment history, atau aktivitas penagihan.
- Full write-off mengubah settlement status menjadi `WRITTEN_OFF`, bukan `PAID`, dan tidak menerbitkan Invoice final. Partial write-off mengurangi outstanding dengan write-off allocation yang tetap terlihat pada statement.
- Pembayaran yang diterima setelah write-off dicatat sebagai event **Recovery Piutang** yang mereferensikan Pro Forma dan write-off lama tanpa membuka/mengubah jurnal historis.
- Cashier hanya melihat warning bahwa Customer mempunyai histori write-off saat membuat TEMPO baru. Nominal akun, jurnal, alasan internal, dan approval Finance tidak ditampilkan pada POS.
- Reminder overdue hanya tersedia melalui POS/Backoffice pada tahap awal. Cashier atau Finance menindaklanjuti Customer secara manual; sistem belum mengirim WhatsApp/email otomatis.
- Aging, assignment, append-only follow-up/Promise, warning acknowledgement, write-off candidate, dan Customer Statement on-demand mengikuti `COLLECTION_AND_CUSTOMER_STATEMENT_SPEC.md`; aging tidak membuat reminder row harian.
- TEMPO tidak boleh dijalankan sebagai transaksi fisik offline. Saat offline, entry hanya boleh menjadi Draft/Pending lokal tanpa penyerahan barang, posting stok, posting piutang, atau Pro Forma final. Validasi limit, overdue, customer, harga, dan stock dilakukan ketika online sebelum Cashier mengonfirmasi penyerahan.
- Feature TEMPO mengikuti entitlement per company. Super Admin mengatur tampil/tidaknya feature; Finance mengatur limit/term Customer; Cashier menentukan pemakaian TEMPO pada transaksi.

Invariant utama:

```text
outstanding = grand_total_final - sum(valid_payment_allocations)
outstanding > 0  -> PRO_FORMA / PARTIALLY_PAID
outstanding = 0  -> PAID + FINAL_INVOICE_ISSUED
```

Penerbitan Invoice final tidak boleh mengulang pengakuan Penjualan, HPP, Persediaan, atau Piutang yang sudah terjadi saat sale TEMPO diposting.

Status disimpan dalam dua dimensi agar dokumen dapat sekaligus cicilan dan terlambat:

```text
settlement_status = OPEN | PARTIALLY_PAID | PAID | CANCELED | CREDIT_NOTED | WRITTEN_OFF
due_status        = NOT_DUE | OVERDUE
```

`OVERDUE` dihitung dari due date untuk dokumen yang masih mempunyai outstanding dan bukan pengganti `PARTIALLY_PAID`.

Customer Statement TEMPO tersedia per Customer dan dapat difilter berdasarkan company/store, rentang tanggal, settlement status, serta due status. Statement menampilkan Pro Forma, DP/cicilan, payment allocation, Debit/Credit Note, retur, write-off/recovery, Invoice final, due date, saldo awal/berjalan/akhir, dan source document. Output dapat diekspor ke Excel atau PDF.

---

## 5. Stock Request dari POS

Flow:

```text
Cashier melihat kebutuhan barang
-> membuat Stock Request
-> memilih produk dan quantity/UOM
-> submit
-> Store Manager memproses Supplier Order di Backoffice
```

POS minimum menampilkan:

```text
request number
status
product
requested UOM
requested quantity
notes
created at/by
linked Supplier Order status bila tersedia
received progress
remaining request quantity
closed at/by bila ditutup
```

Stock Request tidak mengubah stok dan tidak membuat Finance event.

Keputusan:

- Cashier existing membuat Stock Request; tidak ada role Sales baru.
- Cashier hanya memilih produk, UOM, quantity, dan catatan; Cashier tidak memilih supplier.
- Store Manager atau Company Admin/Super Admin menentukan ordered quantity final dan boleh berbeda dari requested quantity tanpa alasan wajib.
- Requested quantity tetap terlihat sebagai audit snapshot.
- Satu request dapat dipecah menjadi beberapa Supplier Order.
- Store Manager atau Company Admin/Super Admin memilih supplier per line dan sistem dapat mengelompokkan order per supplier.
- Backoffice menyarankan supplier utama, UOM pembelian, dan harga beli terakhir dari relasi Produk-Supplier.
- Store Manager dapat memilih supplier aktif lain serta mengubah UOM/harga order sebelum konfirmasi.
- Jika relasi Produk-Supplier belum ada, Store Manager dapat memilih **Simpan sebagai Supplier Produk**; relasi tidak dibuat tanpa konfirmasi eksplisit.
- Harga terakhir hanya diperbarui setelah invoice divalidasi Finance, bukan dari order atau receipt POS.
- Sisa requested quantity yang tidak jadi diorder dapat ditutup Store Manager tanpa alasan wajib; actor dan waktu penutupan tetap disimpan.

---

## 6. Goods Receipt Supplier di POS

Keputusan:

- Three-way matching, tolerance, many-to-many allocation, status exception, dan AP Provisional residual mengikuti `docs/PURCHASE_MATCHING_TOLERANCE_SPEC.md`.

- Kasir menerima barang supplier melalui POS tujuan.
- Receipt selalu terkait Supplier Order yang valid.
- Partial receipt didukung.
- Kasir menginput UOM dan quantity aktual diterima.
- Quantity accepted dikonversi ke base UOM.
- Receipt posted menambah stok, FIFO batch, movement, dan sumber AP provisional.
- Harga estimasi tidak perlu ditampilkan sebagai nilai final kepada kasir.
- Finance mencocokkan invoice fisik melalui Backoffice.
- Over-receipt diperbolehkan, menambah accepted stock/AP provisional, dan ditandai sebagai exception Finance.

POS receipt minimum:

```text
supplier order number
supplier
supplier delivery number optional
ordered lines
previously received
remaining quantity
received UOM
received quantity
notes
submit/post action
over-received warning/quantity
```

Field kondisi barang tidak tampil pada form utama. Aksi opsional **Ada barang rusak/ditolak** membuka:

```text
accepted good quantity
damaged quantity
rejected quantity
```

Jika aksi tersebut tidak digunakan, seluruh received quantity dianggap diterima baik. Barang rusak yang diterima masuk gudang `DAMAGED`; barang ditolak tidak masuk stok/AP.

Guardrail:

- Receipt harus idempotent.
- Kasir hanya dapat menerima order untuk store/gudang penugasannya.
- Product/UOM/supplier/order wajib satu company.
- Accepted stock tidak boleh diposting dua kali.
- Over-receipt tetap dicatat sebagai quantity aktual dan tidak boleh disembunyikan dari Store Manager/Finance.
- Total quantity baik, rusak, dan ditolak harus sama dengan quantity aktual dari surat jalan ketika field kondisi digunakan.

### 6.1 Purchase Return dari POS/Backoffice

Barang yang sudah diterima lalu dikembalikan menggunakan dokumen Purchase Return, bukan mengedit Goods Receipt.

Keputusan:

- Partial return didukung.
- Return mengurangi stok gudang sumber.
- Return membuat movement `PURCHASE_RETURN`.
- Return menyesuaikan sumber AP/credit note melalui proses Finance.
- Return tidak menghapus receipt asli.
- Cashier dapat membuat draft return dari receipt asal melalui POS.
- Produk return hanya dapat dipilih dari line Goods Receipt asal; tidak ada penambahan produk bebas.
- Alasan return menggunakan satu field yang dapat dipilih dari saran umum atau diisi teks bebas.
- Store Manager atau Company Admin/Super Admin dapat mem-posting return melalui Backoffice.
- Posting dilakukan ketika barang benar-benar diserahkan kepada supplier.
- Return berstatus `DRAFT` belum mengubah stok atau AP.
- Data rekening supplier tidak ditampilkan kepada Cashier di POS; referensi tersebut digunakan Finance di Backoffice.

---

## 7. Stock Opname di POS

Keputusan:

- Kasir dapat membuat sesi Stock Opname baru langsung dari POS setiap hari/sesuai kebijakan.
- Satu sesi berlaku untuk satu gudang.
- Scope fleksibel: semua produk, kategori, atau produk terpilih.
- Blind count: kasir tidak melihat system quantity, difference, HPP, atau nilai.
- Kasir dapat edit ketika `DRAFT/COUNTING`.
- Setelah **Selesaikan Penghitungan**, status `COMPLETED` dan angka terkunci.
- Blind count boleh dilakukan offline. Setiap line menyimpan `count_started_at`, `counted_at`, terminal, Cashier, local sequence, device time, dan server time anchor terakhir.
- Ketika online kembali, seluruh penjualan offline dan stock movement queue terminal terkait wajib disinkronkan lebih dahulu; hasil count baru dikirim setelah queue movement memperoleh acknowledgement.
- Server menghitung expected quantity pada `counted_at` menggunakan stock snapshot dan seluruh movement yang sudah direkonsiliasi sampai waktu tersebut.
- Movement terlambat yang ternyata terjadi sebelum/selama count membuat line terkait `RECOUNT_REQUIRED`; sistem tidak mengubah angka hitungan Cashier secara diam-diam.
- POS tetap berjualan selama opname.
- Expected quantity direkonsiliasi menggunakan snapshot, movement, dan `counted_at`.
- Movement selama count window membuat line `RECOUNT_REQUIRED`.
- Store Manager meminta recount; tidak mengedit angka kasir.
- Hitungan terbaru mensupersede line lama produk/gudang sama yang belum diposting.
- Store Manager atau Company Admin/Super Admin membandingkan dan posting di Backoffice.
- Store Manager/Company Admin tidak dapat posting Adjustment selama masih ada queue terminal/gudang terkait yang belum sinkron sampai akhir count window.
- Jika terminal rusak/hilang dan queue tidak dapat dipulihkan, Store Manager/Company Admin membuat exception audit, melakukan physical recount, dan memakai hitungan terbaru. Tidak ada Adjustment otomatis dari count offline.
- Finance dapat memantau tanpa approval wajib.

POS count field:

```text
SKU
product name
count UOM
physical quantity
notes optional
count_started_at
counted_at
```

---

## 8. Offline-First dan Idempotency

Kebutuhan existing menyebut POS offline-first. Untuk fitur inventory baru:

- Stock Request boleh disimpan offline dan disinkronkan dengan `client_request_id` unik.
- Stock Opname boleh disimpan lokal, tetapi `count_started_at`/`counted_at` dan movement reconciliation harus menggunakan aturan waktu yang konsisten.
- Offline count menyimpan server time anchor dan local sequence. Queue sale/movement harus sync sebelum count; late movement memicu `RECOUNT_REQUIRED`.
- Posting Adjustment diblokir sampai queue gudang/terminal relevan selesai atau terminal bermasalah ditutup melalui exception dan physical recount.
- Goods Receipt yang menambah stok sebaiknya membutuhkan koneksi online pada fase pertama, kecuali desain conflict resolution khusus sudah disetujui.
- Penjualan offline disimpan sebagai `PENDING_SYNC`, bukan invoice server final. Detail queue, acknowledgement, retry, dan Slip Offline mengikuti bagian 4.15.
- Offline Stock Allowance mencegah dua terminal memakai stock yang sama. Sync wajib mengonsumsi reservation dan stock secara atomic tanpa membuat stock negatif.
- Tanpa allowance cukup, transaksi tetap Draft dan tidak boleh dianggap penjualan fisik selesai.
- Semua mutation memiliki idempotency key dan status sync yang terlihat user.

---

## 9. Role dan Akses Awal

`COMPANY_ADMIN` mewarisi seluruh action Store Manager, Finance, Warehouse Admin, dan Cashier dalam company membership-nya. `SUPER_ADMIN` dapat melakukan action tersebut lintas company. Pewarisan tidak melewati prasyarat sesi/terminal dan tidak membolehkan edit langsung terhadap dokumen final/ledger.

| Fitur POS | Cashier | Store Manager | Finance |
|---|---:|---:|---:|
| Checkout | Ya | Ya bila menggunakan POS | Tidak |
| Buat/Post Refund | Sesuai config REQUIRED/OPTIONAL | Otorisasi bila REQUIRED; monitor semua | Read-only sesuai scope |
| Lihat Stock Keluar Sesi | Ya, sesi sendiri | Ya, store sesuai scope | Tidak |
| Lihat Sisa Stock Live | Ya, gudang POS aktif | Ya, store sesuai scope | Read-only sesuai scope bila dibutuhkan |
| Terima Notice Minimum Stock | Ya, gudang POS aktif | Ya | Tidak |
| Buat Stock Request | Ya | Ya | Tidak |
| Terima Supplier Order | Ya, store sendiri | Boleh | Tidak |
| Buat Purchase Return | Draft dari POS | Review/post Backoffice | Read-only untuk rekonsiliasi |
| Buat/Input Stock Opname | Ya | Boleh mendampingi | Tidak |
| Lihat system-vs-physical | Tidak | Backoffice | Backoffice read-only |
| Adjustment/Post Opname | Tidak | Backoffice | Tidak |
| Buka/Tutup Sesi | Ya, sesi sendiri | Monitor store | Read-only sesuai scope |
| Download Excel Sesi | Ya, sesi sendiri | Ya, store sesuai scope | Ya, sesuai scope Finance |
| Buat Setor Kas | Ya, sesi sendiri yang eligible | Monitor sesuai scope | Approve/Reject dan rekonsiliasi |

---

## 10. UX Minimum

- Touch-friendly untuk tablet/desktop kasir.
- Pada layar laptop/desktop, mode `Compact` menjadi alternatif dari mode kartu
  `Katalog`, bukan pengganti. Mode Katalog tetap default; pilihan disimpan per
  browser. Switcher berada di header sebagai satu grup responsif agar tidak
  mengurangi tinggi workspace ketika menu Terminal aktif/nonaktif. Compact
  memakai Product picker dan keranjang di kiri serta detail transaksi/pembayaran
  di kanan dengan scroll terpisah.
- Product dipilih melalui dropdown searchable berdasarkan nama, SKU, barcode,
  atau UOM. Hasil tetap menampilkan harga resolver aktif serta stok, dan aksi
  pilih tetap memakai cart handler yang sama dengan katalog sebelumnya.
- Status online/offline terlihat jelas.
- Loading dan double-click protection pada seluruh posting.
- Draft/sync/error state tidak hanya dibedakan dengan warna.
- Notice shortage menjelaskan product, requested, available, dan shortage.
- Product list/detail menyediakan Stock Keluar Sesi, Sisa Stock Saat Ini, dan timestamp saldo tanpa menampilkan HPP.
- Notice minimum stock dapat membuka form Stock Request yang sudah terisi context produk/gudang.
- Receipt menampilkan remaining order setelah partial receipt.
- Opname blind count tidak membocorkan system quantity melalui UI atau response API untuk role Cashier.
- Confirmation screen selalu tampil sebelum mutation yang menambah/mengurangi stok.
- Slip Offline dibedakan jelas dari struk final; struk final hanya berasal dari snapshot invoice `POSTED` server.

---

## 11. Guardrail untuk AI Agent

Agent POS wajib:

1. Membaca dokumen ini dan spesifikasi Produk/Stock.
2. Memeriksa jalur POS aktif, bukan hanya checklist/dokumen lama.
3. Menjaga service-role key server-only.
4. Menggunakan RPC/API transactional untuk perubahan stok.
5. Menjaga RLS dan company/store scope.
6. Tidak menampilkan data blind count kepada Cashier.
7. Tidak mengimplementasikan Finance logic di client POS.
8. Menyimpan idempotency key untuk mutation/offline sync.
9. Memperbarui dokumen ini ketika keputusan POS baru dibuat.

---

## 12. Keputusan Terbuka untuk Fase POS

1. Layout/navigation final POS.
2. Mapping akun jurnal detail TEMPO/write-off/recovery pada fase Finance.

---

## 13. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-14 | POS menjadi channel Stock Request, Goods Receipt, dan Stock Opname | APPROVED |
| 2026-07-14 | Kasir menerima partial receipt supplier melalui POS | APPROVED |
| 2026-07-14 | Stock Opname POS menggunakan blind count dan non-blocking reconciliation | APPROVED |
| 2026-07-14 | Draft sale karena shortage belum masuk Finance | APPROVED |
| 2026-07-14 | Detail implementasi POS dibahas pada fase terpisah | APPROVED |
| 2026-07-14 | Cashier existing membuat Stock Request; tidak ada role Sales baru | APPROVED |
| 2026-07-14 | Store Manager atau Company Admin/Super Admin menentukan quantity final dan sistem dapat grouping Supplier Order per supplier | APPROVED |
| 2026-07-14 | Over-receipt tetap masuk stok/AP provisional dan menjadi exception Finance | APPROVED |
| 2026-07-14 | Kondisi barang merupakan field opsional; normal receipt tetap sederhana | APPROVED |
| 2026-07-14 | Cashier membuat draft Purchase Return; Store Manager atau Company Admin/Super Admin mem-posting dari Backoffice | APPROVED, diperbarui 2026-07-15 |
| 2026-07-14 | Return hanya mengambil line receipt asal, memakai alasan pilihan/teks bebas, dan diposting saat barang diserahkan | APPROVED |
| 2026-07-14 | Cashier tidak memilih supplier; Store Manager atau Company Admin/Super Admin memilih supplier dan harga beli saat membuat order | APPROVED |
| 2026-07-14 | Supplier tanpa relasi dapat disimpan sebagai Supplier Produk melalui konfirmasi Store Manager | APPROVED |
| 2026-07-14 | Sisa Stock Request dapat ditutup Store Manager tanpa alasan dengan audit actor/waktu | APPROVED |
| 2026-07-14 | Barcode opsional per UOM, Brand opsional, bundle hanya berisi STOCK, dan UOM dapat mengatur decimal | APPROVED |
| 2026-07-14 | Minimum stock hanya memunculkan notice Cashier dengan aksi manual membuat Stock Request | APPROVED |
| 2026-07-15 | POS menampilkan snapshot seluruh Stock Awal, Terjual Kotor, Retur, Net Keluar, Stock Terkini live, dan snapshot penutupan | APPROVED |
| 2026-07-15 | Card hanya menampilkan stock terkini; detail stock sesi berada di panel dan Ringkasan Tutup Sesi | APPROVED |
| 2026-07-15 | Low-stock notice menggunakan satu badge daftar produk, bukan toast per produk | APPROVED |
| 2026-07-15 | Receipt posted memperbarui stock live dan checkout shortage dapat dicoba kembali dengan pemeriksaan server | APPROVED |
| 2026-07-15 | Retur invoice lama dicatat pada sesi eksekusi dengan referensi invoice/sesi asal | APPROVED |
| 2026-07-15 | Movement lain dipisah menjadi receipt, transfer, adjustment, opname, dan non-sale lain | APPROVED |
| 2026-07-15 | Rounding grand total opsional untuk semua metode; Cashier memilih NONE/DOWN/UP ke kelipatan Rp100 | APPROVED |
| 2026-07-15 | Struk menampilkan total sebelum rounding, adjustment, dan total akhir | APPROVED |
| 2026-07-15 | Full refund membalik total/rounding asal; partial refund boleh rounding Rp100 terpisah | APPROVED |
| 2026-07-15 | Laporan Store Manager menampilkan detail rounding SALE dan REFUND | APPROVED |
| 2026-07-15 | Satu gambar produk opsional dioptimasi untuk Supabase/Vercel free tier | APPROVED |
| 2026-07-15 | Scan barcode exact menambah 1 atau menaikkan quantity line yang sama; quantity tetap editable | APPROVED |
| 2026-07-15 | Approval refund configurable REQUIRED/OPTIONAL per company/store | APPROVED |
| 2026-07-15 | Refund Cash/Transfer fleksibel dan kondisi line menentukan STORE/DAMAGED/no stock-in | APPROVED |
| 2026-07-15 | Gambar produk direncanakan private di Supabase Storage | SUPERSEDED 2026-07-19 oleh external Drive link sementara |
| 2026-07-15 | Barcode timbangan ditunda; barcode Produk-UOM biasa menjadi scope awal | APPROVED |
| 2026-07-15 | Expense dan arus kas non-penjualan dicatat sebagai reminder; detail dibahas pada dokumen terpisah | APPROVED sebagai reminder |
| 2026-07-17 | Cash Advance dihapus sebagai jenis/menu terpisah; kebutuhan uang muka diserap ke Expense requested/actual/returned | APPROVED |
| 2026-07-17 | Approval Expense configurable; Company Admin default company, Store Manager override store, Super Admin semua authority | APPROVED |
| 2026-07-17 | Approval aktif harus selesai sebelum Cash keluar; nonaktif auto-approve dengan audit | APPROVED |
| 2026-07-17 | Transfer Expense dikonfirmasi Finance; settlement direview Manager/Finance dan tidak memblokir tutup sesi | APPROVED |
| 2026-07-17 | Expense memakai responsible party, additional disbursement, dan return lintas sesi melalui event append-only | APPROVED |
| 2026-07-17 | Kategori Expense menentukan COA; Cash In source terbatas dan offline mengikuti approval snapshot | APPROVED |
| 2026-07-17 | Expense cancel/correction, aging report, Cash In, shortage top-up, dan exceptional Customer Balance settlement diselesaikan | APPROVED secara operasional |
| 2026-07-15 | Company Owner/Admin mengatur default refund; Store Manager dapat override hanya untuk store dalam scope | APPROVED |
| 2026-07-15 | Refund REQUIRED diperiksa dan diposting Store Manager melalui Backoffice, bukan POS | APPROVED |
| 2026-07-15 | Bukti refund transfer opsional pada scope awal | APPROVED |
| 2026-07-15 | Cashier mengisi opening cash manual dan hanya boleh memiliki satu sesi OPEN | APPROVED |
| 2026-07-15 | Closing menampilkan expected, actual, dan selisih langsung kepada Cashier; non-cash dihitung otomatis | APPROVED |
| 2026-07-15 | Cashier dapat mengunduh flow keuangan sesi sendiri dalam workbook Excel | APPROVED |
| 2026-07-15 | Setor Kas dapat menggabungkan beberapa sesi dan membandingkan total expected dengan total aktual manual | APPROVED |
| 2026-07-15 | Setoran boleh kurang/lebih; seluruh sesi selesai ketika Finance approve dan variance menjadi exception Finance | APPROVED |
| 2026-07-15 | Finance atau Company Admin/Super Admin dapat approve Setor Kas; tujuan kas memakai nominal aktual dan Kas Laci dibersihkan sebesar expected dengan akun kontrol variance | APPROVED, diperbarui 2026-07-20 |
| 2026-07-20 | Deposit variance diselesaikan partial/append-only dengan responsible party, aging, dan evidence URL tanpa membuka dokumen final | APPROVED |
| 2026-07-15 | Saldo sesi berikutnya diinput saat membuat Setor Kas; bukti mengikuti konfigurasi REQUIRED/OPTIONAL company/store | APPROVED |
| 2026-07-15 | Semua draft tetap editable; Hold Order dapat dibuat manual walaupun stok cukup | APPROVED |
| 2026-07-15 | Draft dapat dilanjutkan Cashier/terminal lain dalam store yang sama dengan single-editor lock | APPROVED |
| 2026-07-15 | Draft dikonfirmasi ulang manual, tidak mereservasi stok, dan dapat melewati pergantian sesi | APPROVED |
| 2026-07-15 | Draft lama hanya mendapat stale notice dan tidak dihapus otomatis; alasan pembatalan opsional | APPROVED |
| 2026-07-15 | Stale notice default 7 hari dengan optional store override | APPROVED |
| 2026-07-15 | Harga/promo Draft dihitung ulang ketika dilanjutkan dan perubahan wajib ditampilkan untuk konfirmasi | APPROVED |
| 2026-07-15 | Edit lock kedaluwarsa setelah 5 menit tidak aktif dan dapat diambil alih dengan konfirmasi/audit | APPROVED |
| 2026-07-15 | Nomor draft otomatis; label, customer, dan catatan opsional | APPROVED |
| 2026-07-15 | Informasi pembayaran pada draft hanya catatan dan wajib dikonfirmasi ulang ketika posting | APPROVED |
| 2026-07-15 | Pricelist merupakan Sales Master Data; customer-specific mengalahkan global dan product price menjadi fallback | APPROVED |
| 2026-07-15 | Diskon line/transaksi mendukung nominal/persentase tanpa limit role awal | APPROVED |
| 2026-07-15 | Promo quantity gratis dibuat sebagai Bundle dengan harga manual dan seluruh komponen mengurangi stok/HPP | APPROVED |
| 2026-07-15 | Pricelist Customer Eksklusif melewati seluruh Global tier dan fallback langsung ke harga dasar produk | APPROVED |
| 2026-07-15 | Tier hanya Global; basis SALES_UOM/BASE_UOM configurable per rule dan potongan nominal berlaku per unit | APPROVED |
| 2026-07-15 | Bundle promo memakai SKU khusus dan dipilih/scan eksplisit tanpa auto-convert | APPROVED |
| 2026-07-20 | Bundle tampil satu line komersial; allocation komponen analitik tidak membuat revenue duplicate dan return memakai snapshot asal | APPROVED |
| 2026-07-15 | Company Admin/Store Manager mengelola Pricelist sesuai company assignment aktif | APPROVED |
| 2026-07-15 | Global Pricelist dapat company-wide atau dibatasi per store dalam company | APPROVED |
| 2026-07-15 | Customer umum memakai default Global dan Cashier dapat memilih Pricelist eligible lain secara opsional | APPROVED |
| 2026-07-15 | Diskon manual dapat ditumpuk di atas Pricelist; harga POS tax-inclusive | APPROVED |
| 2026-07-17 | Tax feature tax-inclusive bersifat optional per company dan hanya ditoggle Super Admin | APPROVED; Tax Engine resolved 2026-07-20 |
| 2026-07-15 | Customer code otomatis, kategori reusable, company-wide, quick-create POS, nama unik, dan Walk-In row | APPROVED |
| 2026-07-15 | Kelebihan transfer dapat disimpan sebagai saldo Customer untuk transaksi berikutnya | APPROVED; liability mapping resolved 2026-07-17 |
| 2026-07-15 | Ketul adalah tiang kebab dengan beberapa Produk STOCK category Ketul, UOM PCS, harga manual, dan gudang toko | APPROVED |
| 2026-07-15 | Penerimaan Customer boleh standalone; nilai dibayar/saldo; Vendor sale memakai Supplier existing dan laporan terpisah | APPROVED secara operasional |
| 2026-07-15 | Cashier posting dua arah; Store Manager monitor; feature company default dengan store override | APPROVED |
| 2026-07-15 | Ketul Customer settlement mendukung Cash/Transfer/Balance split dan offset setelah final price/rounding | APPROVED |
| 2026-07-15 | Intake membuat FIFO batch; Vendor result memakai qty accepted/rejected dan nominal aktual | APPROVED |
| 2026-07-15 | Reject kembali active/damaged; cancel sebelum Finance confirm, setelahnya reversal | APPROVED |
| 2026-07-15 | Dispatch Ketul memindahkan stock STORE ke TRANSIT; hasil parsial dapat dicatat Cashier/Finance | APPROVED |
| 2026-07-15 | Accepted qty stock-out/HPP saat hasil Vendor; nilai aktual total/per-line | APPROVED |
| 2026-07-15 | Cash Vendor masuk drawer sesi penerima, Transfer masuk bank, dan bukti configurable | APPROVED |
| 2026-07-15 | Cancel pra-confirmation hanya setelah barang accepted diretur fisik Vendor | APPROVED |
| 2026-07-15 | DOCUMENT_TOTAL dialokasikan proporsional; Finance atau Company Admin/Super Admin dapat mengoreksi hasil Cashier dengan audit append-only | APPROVED |
| 2026-07-15 | Settlement Ketul many-to-many dan kekurangan pembayaran menjadi outstanding Vendor | APPROVED |
| 2026-07-15 | Cash terkait sesi/source document; proof default Admin dan store override Store Manager | APPROVED |
| 2026-07-15 | Retur pembatalan memulihkan FIFO asal; laporan Ketul mencakup stock, HPP, margin, dan settlement | APPROVED |
| 2026-07-15 | Fallback alokasi nilai nol memakai accepted qty; outstanding Vendor memiliki due date/aging | APPROVED |
| 2026-07-15 | Cash tanpa sesi OPEN dapat memakai Backoffice Cash Receipt dengan source yang jelas | APPROVED |
| 2026-07-15 | Koreksi pasca-confirmation memakai financial atau financial plus stock reversal sesuai dampaknya | APPROVED |
| 2026-07-15 | Laporan Ketul tiga tab, filter lengkap, dan export Excel | APPROVED |
| 2026-07-15 | Rounding allocation masuk line terbesar; due date manual dan aging bucket standar | APPROVED |
| 2026-07-15 | Cashier tidak melihat HPP/margin dan hanya export miliknya; role lain mengikuti scope | APPROVED |
| 2026-07-15 | Backoffice Cash Receipt Finance langsung confirmed; dokumen selesai otomatis CLOSED | APPROVED |
| 2026-07-15 | Company Admin mewarisi seluruh kewenangan role bawahan dalam company; Super Admin lintas company | APPROVED |
| 2026-07-15 | Status quantity/settlement dipisah; correction memakai immutable delta/reversal movement | APPROVED |
| 2026-07-15 | Dispatch shortage diblokir, dokumen tetap draft; duplicate product line digabung | APPROVED |
| 2026-07-15 | Nomor otomatis, idempotency wajib, CLOSED immutable, dan Vendor inactive hanya memblokir dispatch baru | APPROVED |
| 2026-07-16 | Seluruh saldo Customer lama wajib dipakai pada transaksi berikutnya; Cashier tidak dapat memilih sebagian | APPROVED |
| 2026-07-16 | Koreksi saldo diajukan Cashier dan di-approve Finance; refund fleksibel Cash/Transfer/Customer Balance | APPROVED |
| 2026-07-16 | POS menampilkan indikator saldo dan struk boleh memakai label Potongan Saldo Customer, sementara backend tetap settlement | APPROVED |
| 2026-07-16 | Customer Balance memiliki statement, aging non-expiry, export Excel, dan exceptional settlement terkontrol | APPROVED |
| 2026-07-16 | Checkout diblokir jika saldo lama melebihi amount due dan POS meminta tambahan minimum belanja | APPROVED |
| 2026-07-16 | Customer Balance dan Ketul merupakan entitlement company yang toggle-nya hanya dimiliki Super Admin | APPROVED |
| 2026-07-16 | Customer Balance memakai lifecycle ACTIVE/WIND_DOWN/DISABLED agar liability lama selesai sebelum fitur hilang penuh | APPROVED |
| 2026-07-16 | Draft selalu resolve harga terbaru; kenaikan dapat ditutup diskon manual ke harga lama, sedangkan penurunan wajib memakai harga terbaru | APPROVED |
| 2026-07-16 | Penjualan offline disimpan lokal sebagai PENDING_SYNC dan baru menjadi invoice final setelah validasi/acknowledgement server | APPROVED |
| 2026-07-16 | Sync memakai payload version/hash, client transaction ID, idempotency key yang sama, status queue, dan server acknowledgement | APPROVED |
| 2026-07-16 | Timeout melakukan status check/retry dengan key sama; tidak membuat transaksi duplikat | APPROVED |
| 2026-07-16 | Slip Offline boleh dicetak tetapi bukan bukti final; struk final hanya dari invoice POSTED | APPROVED |
| 2026-07-16 | Thermal 80 mm default, 58 mm opsional, dan A4/PDF Backoffice | APPROVED |
| 2026-07-16 | Store Manager/Company Admin dapat force release lock aktif dengan konfirmasi dan audit | APPROVED |
| 2026-07-16 | Penjualan fisik offline memakai Offline Stock Allowance per terminal/session agar tidak terjadi oversell antar-terminal | APPROVED |
| 2026-07-16 | Allowance adalah reservation base UOM, bukan movement; sync mengonsumsi allowance dan stock secara atomic | APPROVED |
| 2026-07-16 | Tanpa allowance cukup, transaksi hanya Draft dan barang/pembayaran tidak boleh diserahkan | APPROVED |
| 2026-07-16 | Allowance default 20% dari available unreserved stock; terminal dipilih Store Manager/Company Admin | APPROVED |
| 2026-07-16 | Allowance terikat sesi tanpa auto-expiry; sesi tidak dapat ditutup sebelum queue sync/release | APPROVED |
| 2026-07-16 | Terminal rusak/hilang memakai force revoke ter-audit dan queue lama diinvalidasi | APPROVED |
| 2026-07-16 | Harga offline dan Product/UOM snapshot tetap dihormati; perubahan terbaru menjadi variance/exception audit | APPROVED |
| 2026-07-16 | Payment offline fleksibel; metode elektronik tanpa verifikasi langsung berstatus PENDING_VERIFICATION | APPROVED |
| 2026-07-16 | Allowance integer dibulatkan turun dengan minimum 1 bila tersedia; decimal mengikuti precision tanpa melebihi unreserved stock | APPROVED |
| 2026-07-16 | Payment elektronik gagal menjadi OFFLINE_PAYMENT_EXCEPTION; sale/stock tetap posted dan Finance menyelesaikan secara append-only | APPROVED |
| 2026-07-16 | Stock Opname blind count dapat offline dengan time anchor/local sequence dan movement queue harus sync lebih dahulu | APPROVED |
| 2026-07-16 | Late movement memicu RECOUNT_REQUIRED; Adjustment diblokir sampai queue relevan selesai | APPROVED |
| 2026-07-16 | Terminal hilang memakai exception audit dan physical recount; tidak ada Adjustment otomatis | APPROVED |
| 2026-07-17 | In-app notification untuk request/return/opname/offline/payment/low-stock dengan role scope dan deep-link | APPROVED |
| 2026-07-17 | RO belum diproses memakai pending badge/query status tanpa membuat reminder row harian | APPROVED |
| 2026-07-17 | Low-stock notification membuka halaman Stock dengan filter warehouse/product terkait | APPROVED |
| 2026-07-17 | Notification memakai UNREAD/READ/RESOLVED dan histori tidak dihapus | APPROVED |
| 2026-07-17 | Dokumen non-sale mendukung thermal/A4/PDF/Excel, watermark status, snapshot reprint, dan audit | APPROVED |
| 2026-07-17 | Payment TEMPO membutuhkan Pro Forma Invoice; detail credit/AR dibahas pada fase Finance | APPROVED sebagai requirement |
| 2026-07-17 | Cashier boleh memberi TEMPO tanpa approval; limit/overdue hanya warning dan override diaudit | APPROVED |
| 2026-07-17 | Finance mengatur limit dan term manual per Customer; pembayaran TEMPO boleh parsial/multi-metode | APPROVED |
| 2026-07-17 | Sale TEMPO online langsung posting stock, sale, HPP, dan piutang; Invoice final baru terbit saat lunas tanpa posting ulang | APPROVED |
| 2026-07-17 | TEMPO offline hanya Draft/Pending tanpa penyerahan barang atau posting hingga validasi online | APPROVED |
| 2026-07-17 | Finance menentukan default term; Cashier memilih due date transaksi dan Finance dapat override dengan audit | APPROVED |
| 2026-07-17 | Pembayaran TEMPO satu pintu dari POS oleh Cashier; Finance memantau, rekonsiliasi, dan koreksi berwenang | APPROVED |
| 2026-07-17 | DP menjadi payment pertama; pembayaran berlebih menjadi Customer Balance bila aktif atau dikembalikan Cash/Transfer | APPROVED |
| 2026-07-17 | Retur TEMPO memakai Credit Note; pembatalan penuh memakai reversal hanya ketika barang kembali | APPROVED |
| 2026-07-17 | Invoice final memakai tanggal transaksi asli dan tanggal pelunasan/terbit serta tetap mereferensikan Pro Forma | APPROVED |
| 2026-07-17 | Outstanding lama tidak memblokir TEMPO baru; POS memberi warning dan Cashier menentukan dengan audit | APPROVED |
| 2026-07-17 | Satu payment dapat melunasi beberapa Pro Forma oldest-first; sisa pada dokumen berikutnya menjadi cicilan | APPROVED |
| 2026-07-17 | Settlement status dipisahkan dari due status agar PARTIALLY_PAID dapat sekaligus OVERDUE | APPROVED |
| 2026-07-17 | Reminder hanya in-app; Cashier/Finance melakukan follow-up manual | APPROVED |
| 2026-07-20 | Collection TEMPO memakai derived aging, assignment, append-only follow-up/Promise, dan on-demand Statement tanpa daily reminder row | APPROVED |
| 2026-07-17 | Koreksi harga posted memakai Debit/Credit Note oleh Finance tanpa mengubah snapshot asli | APPROVED |
| 2026-07-20 | Debit/Credit Note tidak mengubah stock, memakai source/tax snapshot asal, dan refund/payment diproses terpisah | APPROVED |
| 2026-07-17 | Write-off diajukan Finance dan memerlukan approval Company Admin | APPROVED; mapping resolved 2026-07-19 |
| 2026-07-17 | Customer Statement TEMPO mendukung filter Customer/store/tanggal/status dan export Excel/PDF | APPROVED |
| 2026-08-25 | Price override per line dapat diaktifkan per Terminal/POS; berlaku bagi semua kasir Terminal, mengalahkan Pricelist hanya bila dipakai, default tetap harga canonical, dan wajib server-guarded/audited | IMPLEMENTED LOCAL; ROLLOUT/SMOKE PENDING |
| 2026-08-25 | POS mempertahankan mode Katalog sebagai default dan menambah mode Compact alternatif: searchable Product dropdown dan keranjang di kiri, detail transaksi/pembayaran di kanan; pilihan disimpan per browser dan tidak mengubah checkout contract | IMPLEMENTED LOCAL; SMOKE PENDING |
| 2026-08-25 | Koreksi akhir UI POS: mode Katalog memakai kembali struktur sebelum Compact, dengan keranjang berupa baris horizontal nama + quantity + indikator perubahan + Edit dan tiga Product terlihat sebelum scroll; Compact tetap grid 3–4 kartu | IMPLEMENTED LOCAL; SMOKE PENDING |
| 2026-08-25 | Cutover UOM PACK-only dilakukan per Company melalui operasi PREVIEW/APPLY; PACK aktif untuk beli/jual, DUS hanya dipertahankan pada histori dan dinonaktifkan dari transaksi baru | OPERATION READY; COMPANY PREVIEW PENDING |
| 2026-07-17 | Write-off dapat parsial/penuh per Pro Forma; full write-off menjadi WRITTEN_OFF dan tidak menerbitkan Invoice final | APPROVED |
| 2026-07-17 | Recovery setelah write-off menjadi event baru yang mereferensikan histori tanpa membuka jurnal lama | APPROVED; mapping resolved 2026-07-19 |
| 2026-07-17 | Finance wajib menjadi maker write-off dan Company Admin menjadi approver terpisah | APPROVED |
| 2026-07-17 | Cashier hanya melihat warning histori write-off tanpa detail akun/jurnal | APPROVED |
| 2026-07-19 | Bukti Transfer Cashier dan foto memakai Google Drive/external link; Finance melihat link di Backoffice | APPROVED |
| 2026-07-19 | Supabase Storage/file proxy ditunda; aplikasi hanya menyimpan URL/metadata | APPROVED |
| 2026-07-20 | Cash offline diposting saat sync memakai snapshot transaksi; electronic unverified memakai Piutang Pembayaran Offline | APPROVED |
| 2026-07-20 | Offline Price Variance hanya report/audit dan tidak membuat jurnal atau menagih ulang Customer | APPROVED |
| 2026-07-20 | Bukti Transfer offline boleh ditambahkan setelah online dan wajib sebelum verification bila configured REQUIRED | APPROVED |
| 2026-07-20 | Draft lokal boleh dibatalkan; transaksi fisik PENDING_SYNC wajib sync sebelum cancellation/refund server | APPROVED |
| 2026-07-20 | Payment Method menjadi Master Data company/store; fee configurable dan split payment menghitung per leg | APPROVED |
| 2026-07-20 | Fee dapat ditanggung company/Customer; settlement variance ditangani Finance melalui reconciliation exception | APPROVED |
| 2026-07-20 | Tax Engine memakai Product Category default/Product override, Sales inclusive, snapshot, dan configurable calculation scope | APPROVED |
| 2026-07-20 | Purchase three-way matching mendukung partial/many-to-many, configurable over-receipt approval, dan invoice over-receipt HOLD | APPROVED |
| 2026-07-20 | Draft/Hold/Pending dapat dianalisis terpisah berdasarkan waiting party, user/counterparty, blocker, dan aging | APPROVED |
## Addendum 2026-08-26 — Tanggal Efektif Order TEMPO

- POS online mengizinkan kasir memilih tanggal transaksi/order lampau khusus
  TEMPO. Server menolak masa depan, periode yang tidak `OPEN/REOPENED`, jatuh
  tempo sebelum order, dan rencana kirim sebelum order.
- `transaction_date` adalah tanggal efektif bisnis; `created_at`, `posted_at`,
  Stock Movement, dan audit tetap menggunakan waktu kejadian aktual.
- Financial Event Sale memakai tanggal efektif agar jurnal/AR masuk periode yang
  dipilih. Rencana kirim bukan bukti barang telah dikirim dan tidak mengubah
  lifecycle Surat Jalan secara otomatis.
- Compatibility: client lama tanpa `transactionAt` tetap memakai waktu Draft
  dari server; Cash/Transfer dan Offline tidak memperoleh kewenangan backdate.
# Scheduled TEMPO Order (2026-08-27)

- Order bertanggal mendatang disimpan sebagai Draft TEMPO `SCHEDULED`.
- Status aktif diturunkan saat read dari `planned_order_date` dan tanggal bisnis
  Company; tidak ada cron, auto-Post, atau mutasi final otomatis.
- Sebelum Post, order tidak menghasilkan Stock Movement, Payment, AR, Invoice,
  Surat Jalan, Financial Event, atau Journal.
- Server menolak Post sebelum tanggal rencana. Pada Post manual, Finance memakai
  timestamp aktual dan tanggal rencana tetap tersimpan sebagai referensi order.
- Due date dan tanggal kirim harus sama atau sesudah tanggal rencana.
- Draft dapat dilanjutkan oleh sesi kasir baru hanya pada Store yang sama melalui
  lock, repricing, optimistic version, dan audit canonical.
