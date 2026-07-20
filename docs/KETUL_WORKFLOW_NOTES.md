# Catatan Workflow Ketul KGS

**Status:** Business Workflow Draft 0.8 — Detail Ketul selesai; siap review lintas dokumen  
**Tanggal:** 2026-07-15  
**Scope:** Fitur opsional penerimaan Ketul dari Customer, stok Ketul, dan penyerahan Ketul ke Vendor  

---

## 1. Pemahaman Awal

Ketul adalah tiang kebab yang tersisa dari kegiatan customer yang menjual daging kebab. Ketul diproses toko dengan dua arah:

```text
Customer -> menyerahkan Ketul ke Toko
Toko -> memberi nilai Ketul sebagai pengurang/offset nilai yang harus dibayar Customer
Toko -> menyimpan Ketul sebagai stock
Toko -> menyerahkan/menjual kembali Ketul ke Vendor
Vendor -> memberi nilai balik kepada Toko
```

Fitur ini merupakan entitlement opsional per company. Hanya Super Admin yang dapat mengaktifkan atau menonaktifkan entitlement Ketul. Jika masih ada transit, result, return, atau outstanding settlement, penonaktifan memakai `WIND_DOWN`: intake/dispatch baru diblokir tetapi dokumen lama tetap dapat diselesaikan. Setelah seluruh workflow lama selesai, status otomatis `DISABLED`; UI transaksi baru dan mutation API/RPC disembunyikan/diblokir tanpa menghapus histori.

---

## 2. Mengapa Harus Dipisahkan

Ketul tidak boleh langsung dianggap sebagai:

- diskon penjualan biasa;
- Sales Return biasa;
- Purchase Return Supplier biasa;
- stock adjustment tanpa dokumen.

Secara ekonomi, toko menerima barang dari Customer dan memberikan nilai. Nilai tersebut dapat terlihat sebagai potongan di POS, tetapi kemungkinan merupakan acquisition/offset terpisah agar revenue penjualan, nilai stock Ketul, kewajiban/credit Customer, dan hasil dari Vendor tetap dapat diaudit.

Klasifikasi operasional sudah dipisahkan menjadi Customer Ketul Intake dan Vendor Ketul Sale. Dispatch memindahkan stock ke `TRANSIT`. Vendor Result confirmed mengakui stock-out/HPP serta Piutang/Penjualan Ketul secara accrual; konfirmasi penerimaan dana menjadi payment event terpisah.

---

## 3. Flow Customer ke Toko

```text
Cashier memilih Customer
-> memilih Produk pada kategori Ketul
-> input quantity PCS dan harga beli manual per PCS
-> sistem menghitung total nilai Ketul
-> Customer mengonfirmasi penyerahan
-> Ketul menambah stock gudang toko aktif
-> nilai Ketul mengurangi pembayaran transaksi atau menjadi saldo/utang ke Customer
```

Dokumen kandidat wajib menyimpan:

```text
company/store/session/cashier
customer
ketul product/category
quantity PCS integer
manual unit acquisition value
total value
linked sale nullable
stock destination
status
created/posted/canceled actor dan waktu
```

---

Ketul dapat diterima tanpa transaksi penjualan aktif dan tanpa referensi invoice lama. Dokumen penerimaan tetap wajib terkait Customer terdaftar.

Nilai Ketul dapat:

- meng-offset nilai yang harus dibayar pada transaksi Customer;
- dibayarkan kepada Customer;
- disimpan sebagai Customer Balance;
- memakai kombinasi/split `CASH`, `TRANSFER`, dan `CUSTOMER_BALANCE`.

Harga acquisition manual boleh `0` dan tidak membutuhkan alasan wajib. Actor dan waktu input tetap disimpan.

Jika penerimaan Ketul dilakukan bersamaan dengan penjualan:

- sales dihitung sampai `grand_total_final` setelah discount, tax-inclusive pricing, dan rounding;
- nilai Ketul diterapkan setelahnya sebagai `ketul_offset_amount` untuk mengurangi jumlah akhir yang harus dibayar Customer;
- `grand_total_final`/revenue penjualan tidak diubah menjadi lebih kecil oleh Ketul;
- dokumen Customer Ketul dan invoice sale tetap terpisah tetapi saling menyimpan reference.
- pada rekonsiliasi pembayaran invoice, `KETUL_OFFSET` diperlakukan sebagai settlement/tender non-cash, bukan diskon. Jumlah Cash/Transfer/QR/Customer Balance/Ketul Offset tetap harus menutup `grand_total_final`.

## 4. Flow Toko ke Vendor

```text
Cashier memilih satu atau beberapa Produk Ketul
-> memilih Vendor dari Master Supplier existing
-> input sent quantity PCS dan harga/nilai estimasi manual per line
-> Ketul dipindahkan dari gudang STORE aktif ke gudang TRANSIT
-> Cashier atau Finance mencatat hasil Vendor secara penuh atau parsial
-> Finance/Company Admin/Super Admin mengonfirmasi accepted quantity dan nominal aktual
-> accepted quantity dikeluarkan dari TRANSIT dan mengakui Piutang/Penjualan serta HPP FIFO
-> rejected quantity dipindahkan dari TRANSIT ke stock aktif atau DAMAGED
-> pending quantity tetap berada di TRANSIT menunggu hasil berikutnya
-> Cash/Transfer Vendor dikonfirmasi sebagai payment terpisah yang mengurangi Piutang
```

Leg ini diklasifikasikan sebagai penjualan Ketul ke Vendor dengan document/event type tersendiri, bukan Purchase Return dan bukan pengurang tagihan Supplier. Vendor memakai Master Supplier existing sebagai counterparty.

Satu dokumen Vendor dapat berisi beberapa jenis Produk Ketul. Nilai aktual Vendor dapat dicatat memakai mode `DOCUMENT_TOTAL` atau `PER_LINE`; pemakaian normal adalah total dokumen, tetapi mode per item tetap tersedia. Metode settlement dapat `CASH`, `TRANSFER`, atau status receivable/pending sampai Finance menerima nominal nyata dari Vendor.

Satu dispatch boleh memiliki beberapa event hasil Vendor pada waktu berbeda. Setiap event menyimpan actor, waktu, accepted/rejected quantity, nilai aktual, dan bukti/note bila diwajibkan konfigurasi. Cashier maupun Finance boleh mencatat Draft hasil Vendor. Finance mengonfirmasi Result untuk accrual journal; Cash/Transfer dan konfirmasi dananya disimpan sebagai payment event terpisah. Company Admin/Super Admin mewarisi kewenangan tersebut.

Jika mode nilai aktual `DOCUMENT_TOTAL`, sistem mengalokasikan nominal aktual ke setiap accepted line secara proporsional berdasarkan nilai estimasi line. Nilai hasil alokasi disimpan sebagai snapshot agar margin per Produk Ketul tetap dapat dilaporkan dan tidak berubah ketika master data diperbarui.

Jika seluruh estimated accepted line bernilai `0`, fallback alokasi `DOCUMENT_TOTAL` memakai proporsi accepted quantity. Sistem tidak boleh membagi dengan nol atau kehilangan nilai dokumen Vendor.

Finance atau Company Admin/Super Admin boleh mengoreksi hasil Vendor yang diinput Cashier selama belum ada payment yang dikonfirmasi. Setiap koreksi wajib membuat revision/audit trail append-only yang menyimpan nilai sebelum, nilai sesudah, actor, waktu, dan alasan opsional; histori lama tidak boleh ditimpa.

Status quantity dan settlement wajib dipisahkan:

```text
quantity_status:
  DRAFT
  DISPATCHED
  PARTIAL
  RECONCILED
  CANCELED

settlement_status:
  UNPAID
  PARTIALLY_PAID
  PAID
  REVERSED
```

`CLOSED` adalah lifecycle status dokumen yang ditetapkan otomatis setelah quantity dan settlement selesai. Status parsial tidak boleh disimpulkan dari satu enum campuran.

Rekonsiliasi quantity minimum:

```text
sent_qty
= accepted_qty
+ rejected_to_active_qty
+ rejected_to_damaged_qty
+ pending_vendor_qty
```

- Vendor dapat menerima quantity lebih sedikit daripada yang dikirim.
- Saat dispatch, seluruh sent quantity dipindahkan dari gudang STORE aktif ke `TRANSIT`.
- Setiap hasil parsial mengurangi `pending_vendor_qty`; quantity yang belum mendapat hasil tetap berada di `TRANSIT`.
- Koreksi hasil Vendor yang sudah menghasilkan movement wajib membuat delta/reversal movement baru. Stock movement dan FIFO allocation lama tidak boleh diubah atau dihapus.
- Accepted quantity menjadi stock-out dari `TRANSIT` dan mengonsumsi FIFO/HPP ketika Vendor Result dengan nominal aktual dikonfirmasi. Posting tidak menunggu pembayaran, tetapi Result tanpa nominal tetap pending.
- Quantity rejected dipindahkan dari `TRANSIT` ke stock aktif atau gudang `DAMAGED` sesuai disposition.
- Nominal penjualan final menggunakan angka aktual dari Vendor, bukan memaksa sent quantity x harga estimasi.
- Selisih pembulatan alokasi `DOCUMENT_TOTAL` ditempelkan ke accepted line dengan nilai alokasi terbesar agar jumlah seluruh line selalu sama persis dengan total dokumen.
- Pembayaran `CASH` masuk ke cash drawer sesi Cashier yang benar-benar menerima uang. Pembayaran `TRANSFER` langsung masuk bank dan tidak memengaruhi cash drawer.
- Pembayaran Cash kepada Customer atas Customer Intake mengurangi drawer sesi. Nilai yang disimpan sebagai Customer Balance atau dipakai sebagai `KETUL_OFFSET` tidak mengubah cash drawer.
- Bukti/nota hasil Vendor memakai konfigurasi `REQUIRED` atau `OPTIONAL` dengan company default dan optional store override.
- Bukti Transfer/foto memakai field link Google Drive/HTTPS sesuai `EXTERNAL_EVIDENCE_LINK_POLICY.md`; aplikasi tidak meng-upload atau mem-proxy binary.
- Company Admin mengelola default `ketul_vendor_proof_mode`; Store Manager dapat membuat override untuk store dalam company assignment-nya.
- Settlement bersifat fleksibel dan many-to-many: satu pembayaran boleh menyelesaikan beberapa hasil parsial, sedangkan satu hasil parsial dapat dibayar melalui beberapa pembayaran.
- Setiap pembayaran wajib dialokasikan ke source Vendor result/document. Jika total pembayaran belum menutup nominal accepted, sisanya menjadi outstanding Vendor sampai pembayaran berikutnya.
- Pembayaran Cash wajib terkait sesi Cashier yang benar-benar menerima uang dan menyimpan source payment document. Payment Transfer menyimpan referensi rekening/bank tanpa sesi drawer.
- Jika Cash diterima ketika tidak ada sesi Cashier `OPEN`, Finance atau Company Admin/Super Admin boleh membuat Backoffice Cash Receipt tanpa membuat sesi palsu. Receipt wajib menyimpan source Vendor document/result, actor, waktu penerimaan, nominal, dan destination cash account agar asal transaksi tetap jelas.
- Backoffice Cash Receipt yang dibuat oleh role berwenang tersebut langsung dianggap confirmed dan tidak membutuhkan approval kedua.
- Outstanding Vendor memakai due date yang diinput manual per dokumen dan masuk aging report sampai seluruh nominal terselesaikan.
- Aging bucket menggunakan `Belum Jatuh Tempo`, `1-30`, `31-60`, `61-90`, dan `>90 hari`.
- Result Draft boleh dibatalkan setelah seluruh quantity direkonsiliasi kembali ke active/damaged stock dan tidak ada payment confirmed.
- Vendor Return setelah Result posted tidak menghapus dokumen/movement. Credit Note membalik revenue/receivable atau membentuk Utang/Kredit Vendor; stock/FIFO return memulihkan layer dan unit cost asal.
- Setelah Result atau payment posted, koreksi wajib melalui reversal/credit workflow terpisah.
- Setelah payment dikonfirmasi Finance, koreksi nominal tanpa perubahan quantity memakai financial reversal. Koreksi accepted/rejected quantity wajib memakai financial reversal sekaligus stock/FIFO reversal yang saling mereferensikan.
- Dokumen otomatis menjadi `CLOSED` ketika seluruh sent quantity sudah direkonsiliasi, tidak ada pending quantity di `TRANSIT`, seluruh nominal sudah settled, dan tidak ada workflow lanjutan yang masih terbuka.
- Dokumen `CLOSED` bersifat immutable dan tidak boleh dibuka ulang. Koreksi hanya melalui reversal document yang mereferensikan dokumen asal.
- Jika stock aktif tidak cukup saat dispatch, posting diblokir dan tidak membuat stock movement. Dokumen masih boleh disimpan sebagai `DRAFT` untuk diperbaiki.
- Produk Ketul yang sama wajib digabung menjadi satu line dalam satu dispatch.
- Nomor Customer Intake, Vendor Dispatch, Vendor Result, dan Settlement dibuat otomatis dalam scope company/store.
- Seluruh mutation submit/posting wajib memakai idempotency key agar double-click, retry, atau offline replay tidak membuat stock/payment ganda.
- Vendor/Supplier inactive tidak boleh dipakai untuk dispatch baru. Result, return, settlement, dan outstanding dari dokumen lama tetap dapat diselesaikan.

---

## 5. Master Produk dan Inventory

- Ketul memiliki beberapa jenis. Masing-masing jenis dibuat sebagai Produk `STOCK` tersendiri di bawah satu kategori Produk Ketul.
- Category Ketul tidak boleh dikenali dari nama hardcoded. Konfigurasi menyimpan `ketul_category_id` milik company.
- Produk Ketul memakai SKU/kode dan nama produk biasa.
- Base/sales UOM Ketul adalah `PCS`, `allow_decimal = false`.
- Harga beli dari Customer dan harga jual ke Vendor selalu diinput manual per transaksi karena nilainya fluktuatif. Pricelist dan harga dasar Produk tidak menjadi sumber harga Ketul.
- Stock wajib tenant/store/warehouse scoped dan menggunakan Stock Movement append-only.
- Penerimaan dari Customer membuat stock-in. Dispatch ke Vendor memindahkan stock ke `TRANSIT`; hanya accepted quantity yang membuat stock-out.
- Ketul disimpan pada gudang toko aktif; tidak membutuhkan gudang Ketul khusus.
- Setiap penerimaan Customer membuat FIFO batch dengan unit cost sesuai manual acquisition value, termasuk cost `0` bila memang diinput nol.
- Penjualan Ketul ke Vendor mengonsumsi batch FIFO saat hasil accepted quantity dicatat. Profit Ketul dihitung dari nominal aktual Vendor dikurangi HPP FIFO quantity yang diterima Vendor.
- Quantity rejected tidak mengakui revenue/HPP penjualan Vendor dan dikembalikan ke active/damaged sesuai disposition.

---

## 6. Feature Flag dan Akses

Kandidat konfigurasi:

```text
ketul_enabled
ketul_category_id
ketul_customer_intake_enabled
ketul_vendor_dispatch_enabled
ketul_vendor_proof_mode
```

Company memiliki default konfigurasi dan dapat mempunyai store override. Saat fitur dinyalakan, category Ketul dan minimal satu Produk Ketul aktif wajib dikonfigurasi.

Pengelolaan konfigurasi:

- Super Admin mengatur entitlement `ketul_enabled`, `ketul_customer_intake_enabled`, dan `ketul_vendor_dispatch_enabled` per company.
- Setelah entitlement aktif, Company Admin mengatur category/product Ketul dan default operasional seperti proof mode.
- Store Manager dapat mengatur store override operasional hanya untuk store yang menjadi assignment-nya; Store Manager tidak dapat mengaktifkan entitlement.
- Store tanpa override mengikuti default company.

Role:

- Cashier dapat membuat dan mem-posting penerimaan Ketul dari Customer.
- Cashier dapat membuat dan mem-posting penjualan Ketul ke Vendor.
- Cashier dan Finance dapat mencatat hasil Vendor secara parsial sesuai akses company/store.
- Finance dapat melakukan final fund confirmation; Company Admin/Super Admin mewarisi kewenangan tersebut sesuai company scope.
- Store Manager memantau laporan sesuai company/store scope dan tidak menjadi approval wajib.

Guardrail minimum:

- semua data Ketul eksklusif per company;
- Customer/Vendor/Product/UOM/Warehouse harus berasal dari company yang sama;
- dispatch wajib menyimpan `origin_store_id`. Gudang `TRANSIT` harus terkait store tersebut atau, bila company-level, setiap movement tetap membawa origin store agar pending/reject tidak bercampur antar-store;
- rejected quantity hanya boleh kembali ke gudang active/`DAMAGED` yang valid untuk origin store/company dokumen;
- fitur mati tidak menghapus histori Ketul;
- posting stock dan nilai harus atomic;
- draft tidak mengubah stock/Finance; cancel tidak menghapus histori dan wajib membuat reversal bila movement sudah terjadi.

---

## 7. Integrasi Customer Balance dan POS

- Jika nilai Ketul lebih kecil dari total sale, UI menampilkannya sebagai offset setelah grand total final/rounding.
- Jika nilai Ketul lebih besar atau tidak ada sale, nilai dapat dibayar atau menjadi Customer Balance sesuai pilihan transaksi.
- Jika invoice juga memakai Customer Balance, `KETUL_OFFSET` diterapkan lebih dahulu, kemudian Customer Balance, lalu payment eksternal. Keduanya adalah settlement dan tidak mengubah revenue.
- UI boleh memakai label “Potongan Ketul”, tetapi backend harus menyimpan dokumen Ketul dan payment/offset terpisah agar diskon komersial tidak tercampur.
- Ketul wajib terkait Customer terdaftar, bukan Customer Walk-In, bila nilai/saldo harus digunakan kembali.
- Cash Ketul Vendor yang diterima sesi dan Cash payout Customer Intake wajib masuk formula expected cash, Arus Kas, export sesi, serta Setor Kas. Backoffice Cash Receipt tanpa sesi tidak boleh dimasukkan ke drawer atau setoran sesi Kasir.

---

## 8. Laporan Ketul

Laporan minimum wajib memperlihatkan:

- quantity diterima dari Customer;
- manual acquisition value dan total nilai Customer intake;
- quantity dikirim ke Vendor;
- accepted quantity;
- rejected to active quantity;
- rejected to damaged quantity;
- pending quantity di `TRANSIT`;
- nilai estimasi Vendor;
- nominal aktual Vendor serta alokasi per product line;
- HPP FIFO accepted quantity;
- margin Ketul;
- nominal sudah dibayar dan outstanding Vendor;
- payment method, source payment document, dan sesi penerima Cash bila berlaku;
- status dokumen, status settlement, actor, dan waktu event.

Laporan wajib menjaga keterhubungan Customer Intake -> FIFO Batch -> Vendor Dispatch -> Vendor Result -> Settlement agar audit stock, HPP, dan uang dapat ditelusuri dari ujung ke ujung.

Tampilan laporan dipisahkan menjadi:

1. `Customer Intake`;
2. `Vendor Dispatch & Result`;
3. `Outstanding & Settlement`.

Filter minimum meliputi tanggal, company, store, Cashier, Customer, Vendor, Produk Ketul, status, dan payment method. Seluruh tab wajib mendukung export Excel dengan data mengikuti scope/filter aktif.

Hak laporan:

- Cashier dapat melihat dan export transaksi Ketul miliknya sendiri, tetapi tidak dapat melihat HPP atau margin.
- Store Manager dapat melihat dan export seluruh transaksi dalam store assignment, termasuk HPP dan margin.
- Finance dan Company Admin dapat melihat dan export sesuai company scope, termasuk HPP, margin, settlement, serta aging.
- Super Admin dapat melihat lintas company sesuai mekanisme pemilihan company, tanpa menghilangkan company asal data.

---

## 9. Status Pembahasan

Detail workflow bisnis Ketul yang dibutuhkan untuk review lintas modul telah selesai. Pertanyaan schema fisik, nama tabel/kolom final, mapping COA, dan desain UI tetap mengikuti fase implementasi masing-masing dan tidak mengubah keputusan bisnis dalam dokumen ini.

---

## 10. Instruksi untuk AI Agent

- Jangan implementasikan Ketul sebagai diskon biasa sebelum klasifikasi final.
- Jangan memakai Stock Adjustment untuk penerimaan/pengeluaran Ketul normal.
- Jangan menggabungkan Customer leg dan Vendor leg dalam satu movement tanpa dua source document yang dapat diaudit.
- Jangan membuat jurnal sebelum event, pihak lawan, rate, dan settlement dikonfirmasi.
- Jangan mengaktifkan fitur pada company/store yang tidak memilih Ketul.

---

## 11. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-15 | Ketul adalah fitur stock opsional dengan leg Customer -> Toko -> Vendor | APPROVED secara konsep |
| 2026-07-15 | Nilai Ketul dapat menjadi pengurang/offset transaksi Customer | APPROVED secara konsep |
| 2026-07-15 | Detail dokumen, valuation, settlement, role, dan feature flag | PARTIALLY APPROVED; detail lanjutan masih terbuka |
| 2026-07-15 | Ketul adalah tiang kebab; beberapa jenis dimodelkan sebagai Produk STOCK dalam category Ketul | APPROVED |
| 2026-07-15 | UOM Ketul PCS integer dan harga Customer/Vendor diinput manual per transaksi | APPROVED |
| 2026-07-15 | Penerimaan Customer boleh standalone; nilainya dapat dibayar atau menjadi Customer Balance | APPROVED |
| 2026-07-15 | Vendor memakai Master Supplier existing dan transaksi Ketul menghasilkan uang masuk/laporan tersendiri | APPROVED |
| 2026-07-15 | Ketul memakai gudang toko biasa; Cashier mem-posting dua arah dan Store Manager memantau | APPROVED |
| 2026-07-15 | Feature flag company default dengan store override dan membutuhkan konfigurasi category/product Ketul | APPROVED |
| 2026-07-15 | Settlement Customer mendukung Cash/Transfer/Balance split; offset diterapkan setelah final price/rounding | APPROVED |
| 2026-07-15 | Dokumen Ketul dan sale terpisah tetapi saling mereferensikan; manual value boleh nol | APPROVED |
| 2026-07-15 | Customer intake membuat FIFO batch dari acquisition value dan Vendor sale memakai HPP FIFO | APPROVED |
| 2026-07-15 | Vendor result memakai accepted/rejected qty dan nominal aktual; reject kembali active/damaged | APPROVED |
| 2026-07-15 | Cashier dapat cancel sebelum Finance confirm; setelah confirm wajib reversal | APPROVED |
| 2026-07-15 | Dispatch memindahkan sent quantity dari STORE ke TRANSIT; pending quantity tetap di TRANSIT | APPROVED |
| 2026-07-15 | Cashier atau Finance dapat mencatat beberapa hasil Vendor parsial; Result dan payment dikonfirmasi terpisah oleh Finance/Company Admin/Super Admin | APPROVED; diperjelas 2026-07-19 |
| 2026-07-15 | Accepted quantity stock-out dan memakai HPP FIFO saat Vendor Result bernominal dikonfirmasi | APPROVED; diperjelas 2026-07-19 |
| 2026-07-15 | Nilai aktual mendukung DOCUMENT_TOTAL atau PER_LINE | APPROVED |
| 2026-07-15 | Cash Vendor masuk drawer sesi penerima; Transfer langsung bank | APPROVED |
| 2026-07-15 | Bukti Vendor configurable REQUIRED/OPTIONAL | APPROVED |
| 2026-07-15 | Result Draft dapat cancel setelah quantity kembali; Result posted memakai return/reversal | APPROVED; diperjelas 2026-07-19 |
| 2026-07-15 | DOCUMENT_TOTAL dialokasikan proporsional berdasarkan estimasi line untuk menjaga laporan margin per produk | APPROVED |
| 2026-07-15 | Finance atau Company Admin/Super Admin boleh mengoreksi input hasil Cashier sebelum confirmation dengan audit before/after append-only | APPROVED |
| 2026-07-15 | Settlement many-to-many; beberapa hasil parsial boleh digabung dan satu hasil boleh dibayar bertahap | APPROVED |
| 2026-07-15 | Kekurangan pembayaran menjadi outstanding Vendor sampai settlement berikutnya | APPROVED |
| 2026-07-15 | Cash terkait sesi penerima dan source payment document; Transfer terkait rekening/bank | APPROVED |
| 2026-07-15 | Company Admin mengatur proof default dan Store Manager dapat membuat store override | APPROVED |
| 2026-07-15 | Retur pembatalan memulihkan FIFO layer/cost asal ke active atau DAMAGED | APPROVED |
| 2026-07-15 | Laporan Ketul mencakup quantity, nilai, transit, HPP, margin, dan status settlement | APPROVED secara garis besar |
| 2026-07-15 | Estimated value nol memakai accepted quantity sebagai fallback alokasi DOCUMENT_TOTAL | APPROVED |
| 2026-07-15 | Cash tanpa sesi OPEN dapat dicatat Finance sebagai Backoffice Cash Receipt dengan source yang jelas | APPROVED |
| 2026-07-15 | Outstanding Vendor mempunyai due date dan aging | APPROVED |
| 2026-07-15 | Koreksi pasca-confirmation: nominal memakai financial reversal; quantity memakai financial plus stock/FIFO reversal | APPROVED |
| 2026-07-15 | Laporan dipisah menjadi tiga tab, memiliki filter lengkap, dan mendukung export Excel | APPROVED |
| 2026-07-15 | Selisih pembulatan alokasi ditempelkan ke line bernilai terbesar | APPROVED |
| 2026-07-15 | Due date outstanding diinput manual dan aging memakai bucket umum sampai >90 hari | APPROVED |
| 2026-07-15 | Cashier tidak melihat HPP/margin; export milik sendiri, sedangkan role lain mengikuti store/company scope | APPROVED |
| 2026-07-15 | Backoffice Cash Receipt buatan Finance langsung confirmed tanpa approval kedua | APPROVED |
| 2026-07-15 | Dokumen otomatis CLOSED ketika quantity, transit, settlement, dan workflow lanjutan sudah selesai | APPROVED |
| 2026-07-15 | Quantity status dan settlement status dipisahkan agar kondisi parsial tidak ambigu | APPROVED |
| 2026-07-15 | Koreksi result memakai delta/reversal movement; ledger lama immutable | APPROVED |
| 2026-07-15 | Stok kurang memblokir dispatch posting tetapi dokumen tetap dapat disimpan DRAFT | APPROVED |
| 2026-07-15 | Produk sama digabung satu line dan seluruh nomor dokumen dibuat otomatis per company/store | APPROVED |
| 2026-07-15 | Semua mutation memakai idempotency key dan dokumen CLOSED hanya dikoreksi melalui reversal | APPROVED |
| 2026-07-15 | Vendor inactive memblokir dispatch baru tetapi dokumen lama tetap dapat diselesaikan | APPROVED |
| 2026-07-15 | Company Admin mewarisi seluruh kewenangan Store Manager/Finance/Warehouse/Cashier dalam company | APPROVED |
| 2026-07-16 | Entitlement Ketul hanya dapat diaktifkan/dinonaktifkan Super Admin per company; Company Admin mengatur operasional setelah aktif | APPROVED |
| 2026-07-16 | Ketul memakai WIND_DOWN untuk menyelesaikan transit/result/settlement lama sebelum auto-DISABLED | APPROVED |
| 2026-07-19 | Customer Intake posted mengakui Inventory dan Utang Ketul Customer; settlement split mendukung Cash/Transfer/Balance/Offset | APPROVED |
| 2026-07-19 | Vendor Result confirmed mengakui Piutang/Penjualan serta FIFO HPP; payment Vendor menjadi event terpisah | APPROVED |
| 2026-07-19 | Vendor Return setelah Result memakai Credit Note Retur Ketul dan memulihkan FIFO/cost asal | APPROVED |
| 2026-07-19 | Bukti Transfer/foto Ketul memakai external Drive link dan tetap diverifikasi melalui workflow Finance | APPROVED |
