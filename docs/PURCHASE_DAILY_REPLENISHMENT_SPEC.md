# Purchase Daily Negative-On-Hand Replenishment

## 2026-09-16 - saved Receipt compatibility repair

Existing Draft receipt lines are authoritative for resuming that Receipt, even
if a legacy PO line has null destination or remaining qty subsequently changes.
The UI must not drop saved qty/UOM/dispositions/SJ/notes because of PO warehouse
filtering. Unsaved lines retain the exact receiving Warehouse/positive remaining
boundary. Single/bulk use one builder; no source/stock/Finance mutation or access
guard change. Local12-line regression/lint/tsc PASS, client deployment and
authenticated Production Save/Post smoke pending. No schema migration required.

**Status:** Business decision approved; Step 1–6C database/behavior/postflight user-confirmed PASS; authenticated smoke/UAT pending  
**Scope:** Company Purchase mode, daily grouping, negative On Hand, Supplier priority, RO/PO/Receipt boundary  
**Out of scope Step 1:** scheduler, RO/PO generation, Goods Receipt posting, Supplier Bill, Payment, Stock/FIFO/AP/Journal mutation

## 1. Mode per Company

Setiap Company memilih tepat satu mode:

- `MANUAL` (default): user membuat RO, mengonfirmasi menjadi PO, Gudang menerima, Finance membuat Bill, lalu Payment/Post.
- `AUTO_RO`: sistem merekap kebutuhan harian menjadi RO; user tetap mengonfirmasi RO menjadi PO.
- `AUTO_PO`: sistem langsung membuat PO harian siap diterima; tidak ada konfirmasi RO.

Perubahan mode hanya dilakukan Super Admin melalui Pengaturan Modul > Purchase dan wajib audited serta optimistic-versioned.

## 2. Sumber Quantity Otomatis

- Cutoff tetap pukul `23:59` menurut timezone Company dan business date lokal.
- Sumber hanya `product_stocks.stock_qty < 0` per Product-Warehouse.
- Reserved, Transit, future order, dan proyeksi pengiriman tidak dihitung.
- Target proyeksi adalah On Hand `0`; Stock real tidak berubah sebelum Goods Receipt diposting Gudang.
- Kebutuhan baru adalah nilai absolut On Hand negatif dikurangi quantity pembelian aktif yang belum diterima untuk Product-Warehouse yang sama.
- Hasil nol atau negatif tidak dibuat menjadi line baru.
- Satu Company hanya boleh memiliki satu batch untuk satu business date. Retry wajib mengembalikan batch yang sama.

## 3. Dokumen

- Satu batch induk internal per Company per hari menggabungkan seluruh Gudang.
- Pada mode `AUTO_RO`, batch induk tersebut adalah RO internal Company dan tidak
  memakai Store/POS/Cashier Session palsu. Konfirmasi menghasilkan PO per
  Supplier serta satu kelompok `SUPPLIER_PENDING`; split satu line ke beberapa
  Supplier disimpan sebagai allocation lineage.
- Setiap line tetap menyimpan Gudang tujuan dan snapshot Product/Base UOM/On Hand/outstanding purchase.
- `Gudang sumber` adalah lokasi On Hand negatif dan tidak berubah. `Gudang penerimaan`
  adalah tujuan Receipt per line: otomatis memakai Gudang sumber bila Gudang tersebut
  diizinkan menerima pembelian, lalu fallback ke default penerimaan Company.
- Qty kebutuhan dan Gudang penerimaan terisi otomatis tetapi dapat diubah user pada
  Draft RO/PO sebelum Receipt pertama. Jika tujuan berbeda dari sumber, line diberi
  penanda `Perlu Transfer`; perpindahan setelah Receipt tetap memakai dokumen Transfer.
- Jika tidak ada tujuan valid, candidate tetap terlihat dengan status
  `WAREHOUSE_SETUP_REQUIRED` dan user diarahkan membuat atau mengaktifkan Gudang
  penerimaan. Sistem tidak membuat master Gudang secara diam-diam.
- Pesanan eksternal dipecah per Supplier; satu Product yang dibagi kepada dua Supplier menghasilkan dua dokumen Supplier.
- Supplier default adalah relasi Product-Supplier aktif dengan `selection_priority` terkecil jika user tidak memilih Supplier.
- Tanpa Supplier, line berstatus `SUPPLIER_PENDING`. Barang tetap dapat diterima, tetapi Supplier Bill belum boleh dibuat.
- Penetapan Supplier setelah receipt harus append-only/audited dan tidak mengedit histori receipt posted.
- Goods Receipt tetap dikonfirmasi per Gudang. Hanya posting Receipt yang menambah Stock/FIFO.

## 4. Finance

- Goods Receipt dengan Supplier membentuk AP Provisional sesuai runtime canonical.
- Receipt `SUPPLIER_PENDING` membutuhkan clearing/unassigned lineage sampai Supplier ditentukan; implementasi accounting-nya adalah gate tersendiri sebelum runtime tanpa Supplier diaktifkan.
- Finance membuat Supplier Bill dari receipt eligible, kemudian matching/posting/payment memakai runtime Purchase/Finance canonical.
- Tidak ada AP Final dari PO dan tidak ada Stock dari Supplier Bill.

## 5. Guardrail

- Tenant, Product, Warehouse, Supplier, UOM, document, dan allocation wajib satu Company.
- Batch generation transactional, concurrency-safe, idempotent, dan audited.
- Outstanding RO/PO/Receipt dihitung dari source line immutable, bukan nama/SKU.
- Dokumen final tidak diubah; perubahan menggunakan delta/amendment atau dokumen koreksi.
- Mode `MANUAL` tidak boleh menjalankan generator otomatis.
- Foundation Step 1 tidak mempunyai generator sehingga tidak dapat membuat RO/PO atau mutation operasional.

## 6. Delivery Gates

1. Foundation setting, priority, dan inert daily ledger.
2. Read-only candidate preview dan exact outstanding-quantity resolver.
3. Atomic `AUTO_RO` generator serta RO ke PO confirmation.
4. Atomic `AUTO_PO` generator dan Supplier split.
5. Multi-Warehouse Receipt dan `SUPPLIER_PENDING` resolution tanpa history rewrite.
6. Supplier Bill/Payment integration, scheduler 23:59, UI/UAT dan production-compatibility closure.

Setiap gate memerlukan preflight, guarded migration, postflight, rollback-only behavior, authenticated smoke, serta update handoff.

### Status implementasi Step 3/6

Migration lokal `20260913120000` menyediakan generator dan konfirmasi atomik,
optimistic version, operation idempotency, immutable audit, exact batch-to-PO
lineage, daily-Draft coverage, dan compatibility shape PO manual. Receipt,
Stock/FIFO/AP, Supplier assignment pasca-Receipt, scheduler, dan UI belum aktif.

### Status implementasi Step 4/6

Migration `20260913130000` sudah user-confirmed migration, behavior, dan
postflight PASS pada isolated Development serta menyediakan generator `AUTO_PO` setelah cutoff.
Line siap langsung menjadi PO confirmed per Supplier atau kelompok
`SUPPLIER_PENDING`. Line tanpa Gudang penerimaan, master/source invalid, request
Gudang ambigu, atau quantity yang tidak exact terhadap UOM pembelian tetap
ditahan dalam batch Draft dan tidak menghentikan line siap. Kelanjutan blocker,
Receipt, Stock/FIFO/AP, Supplier assignment pasca-Receipt, Supplier Bill,
Payment, scheduler, dan UI tetap Step 5–6.

### Status implementasi Step 5/6A

Migration lokal `20260914100000` menyediakan Goods Receipt terpisah per Gudang
untuk PO harian. `SUPPLIER_PENDING` memakai Product COGS sebagai biaya
provisional default yang dapat diedit sebelum Post; biaya nol memerlukan
konfirmasi eksplisit. Post menambah Stock/FIFO dan membuat clearing append-only,
sementara assignment Supplier per line membuat event reklasifikasi tanpa
menulis ulang Receipt posted. Kedua event pending dikeluarkan dari Purchase/AP
queue lama sampai Step 6 menyelesaikan jurnal clearing, Supplier Bill, dan
Payment. PO supplemental untuk blocker tertunda adalah Step 5/6B.

### Status implementasi Step 5/6B dan Step 6/6A

Forward-fix `20260914110000`, `20260914111000`, dan `20260914112000` telah
user-confirmed migration/behavior/postflight PASS pada isolated Development.
AUTO_PO boleh menyimpan Gudang sumber dengan tujuan penerimaan kosong; Gudang
tujuan tetap wajib dipilih dan divalidasi ketika Receipt dibuat.

Migration `20260914130000` telah user-confirmed migration, behavior, dan
postflight PASS pada isolated Development. Runtime menghubungkan Receipt supplier-pending dan
assignment Supplier append-only ke Antrian Jurnal existing secara berurutan:
Receipt membukukan Dr Inventory / Cr clearing, lalu assignment membukukan Dr
clearing / Cr AP Provisional.
Faktur Supplier serta Pembayaran Supplier tetap memakai runtime canonical yang
sudah ada dan tidak dibuat otomatis. Scheduler, UI operasional, authenticated
smoke, serta UAT tetap gate Step 6 berikutnya.

### Status implementasi Step 6/6B

Paket lokal `20260914140000` menambahkan scheduler Company-local pukul `23:59`
dengan label actor `Sistem Otomatis`. Nomor canonical tetap membawa business
date: `RO-YYYYMMDD-*`, `POB-YYYYMMDD-*`, dan `PO-YYYYMMDD-*`.

RO otomatis hanya dapat dibatalkan sebelum dikonfirmasi menjadi PO. PO dapat
dibatalkan sebelum Receipt Posted. Setelah Receipt Posted, seluruh quantity
stock-bearing yang diterima wajib mempunyai Purchase Return Posted sebelum PO
dapat dibatalkan; cancellation tidak menghapus atau membalik langsung Stock,
FIFO, AP, Event, maupun Journal. UI, authenticated smoke, dan UAT tetap Step
6/6C setelah database gate ini PASS.

Saat behavioral pertama dijalankan, base runtime terbukti tidak memilih
Company pada `23:59:30` karena upper bound bertipe `time` berputar menjadi
`00:00`. Forward-fix additive `20260914141000` mengganti predicate tersebut
dengan interval timestamp lokal lengkap pada tanggal Company. Base migration
yang sudah live tidak diubah. User kemudian mengonfirmasi migration forward-fix,
behavioral, dan postflight seluruhnya PASS pada isolated Development.

### Status implementasi Step 6/6C

Client lokal menyediakan tab Request Order dan Purchase Order. AUTO_RO Draft
dapat dibuka, disesuaikan Qty/Supplier/UOM/harga/Gudang, dibagi ke beberapa
Supplier, lalu dikonfirmasi memakai RPC transactional Step 3. Cancel RO/PO
memakai RPC Step 6B dan tetap tunduk pada full posted Purchase Return setelah
Receipt Posted. Read-model additive `20260914150000` mengekspos UUID relasi
canonical; tidak ada ID yang ditebak dari nama. Migration, behavioral test, dan
postflight `20260914150000` telah user-confirmed PASS pada isolated Development.
Authenticated smoke dan UAT masih pending; production/staging tidak disentuh.

### Status UI daftar RO/PO

Paket lokal `20260914160000` menyamakan shell daftar Purchase dengan
Quotation/Sales Order tanpa mengganti runtime dokumen. RO memakai header Nomor
RO, Supplier Rencana, Tanggal RO, Status RO, dan Estimasi Total. PO memakai
Nomor PO, Supplier, Tanggal PO, Status Penerimaan, Status Bill, dan Total.
Status/link Bill memakai Faktur Supplier existing dan hanya dapat dibuka oleh
user yang mempunyai akses modul tersebut. Read-model, database gate,
authenticated smoke, dan UAT dijelaskan pada
`docs/runbooks/PURCHASE_ORDER_LIST_PARITY_ROLLOUT.md`.
# Purchase Order document runtime

- Daftar Purchase Order membuka halaman dokumen penuh; expanded group bukan UI
  operasional canonical.
- PO harian `CONFIRMED` yang belum mempunyai Goods Receipt atau Supplier Bill
  dapat direvisi oleh permission `EDIT_DRAFT` melalui RPC canonical.
- Field editable: Supplier, expected date, notes, ordered UOM, ordered quantity,
  estimated unit price, dan destination/receiving Warehouse per line.
- Product dan source Warehouse shortage merupakan lineage immutable.
- Ketika RO dikonfirmasi menjadi PO, atau AUTO_PO membentuk PO, sistem langsung
  membuat dokumen Goods Receipt per Gudang penerimaan. Purchasing tidak memulai
  Receipt dari tombol pada PO; Gudang memproses dokumen tersebut melalui menu
  `Penerimaan Barang`.
- `Buat Bill` atau `Lihat Bill` tetap berada pada PO dan membuka Supplier Invoice
  existing setelah minimal satu Receipt diposting dan membentuk quantity
  billable; tidak ada dokumen Bill paralel.
- Revisi memakai optimistic `master_version`, immutable operation/audit,
  idempotent operation UUID, tenant/permission boundary, dan tidak mengubah
  Stock, FIFO, AP, Payment, Journal, Sales, atau POS.
