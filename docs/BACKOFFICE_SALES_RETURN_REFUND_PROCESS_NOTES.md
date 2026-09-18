# Backoffice Sales Return & Refund — Process Notes

## Status

**BUSINESS FLOW APPROVED - STEP 4/5 REFUND SETTLEMENT LOCAL READY.**

Dokumen ini mencatat keputusan user untuk Retur dan Refund pada bisnis proses
Backoffice Sales. Fondasi Draft/Submit/Approve/Cancel sudah disiapkan lokal.
Step 2 Customer Return Receipt, disposition dan restorasi FIFO sudah database
live serta user-confirmed PASS. Step 3 Invoice reconciliation, Credit Note, AR
dan Journal sudah disiapkan lokal. Refund settlement Step 4 dan client UI Step 5
belum diaktifkan dan tidak boleh diasumsikan dari runtime Retail yang sudah ada.

## Tujuan

- Customer dapat mengembalikan barang setelah barang diterima.
- Dokumen SO, DO/SJ, Invoice, pembayaran, Return, Credit Note, dan Refund tetap
  dapat ditelusuri tanpa mengubah atau menghapus histori final.
- Gudang menentukan hasil fisik barang retur.
- Finance hanya mengembalikan uang yang benar-benar menjadi kelebihan pembayaran
  Customer setelah koreksi tagihan.

## Keputusan grouping yang disetujui

### 1. Satu fitur Sales: Retur & Refund Penjualan

Sales mempunyai satu fitur induk **Retur & Refund Penjualan**. Retur barang dan
refund uang berada dalam satu rangkaian yang saling terhubung, tetapi mempunyai
status terpisah:

- status retur barang;
- status koreksi tagihan/Credit Note;
- status refund.

Daftar dapat dikelompokkan sebagai:

1. Pengajuan;
2. Proses Barang;
3. Proses Refund;
4. Selesai;
5. Dibatalkan.

SO dan Invoice hanya menampilkan indikator ringkas serta link ke dokumen Retur &
Refund. Retur bukan status pengganti status final SO/Invoice.

### 2. Aksi pada Sales Order

- Sebelum pengiriman/penerimaan Customer mencapai boundary final, aturan cancel
  existing tetap berlaku sesuai status dokumen.
- Setelah barang diterima Customer, aksi pembatalan SO diganti menjadi
  **Buat Retur**.
- Tombol **Buat Retur** memulai proses barang. Refund tidak dijanjikan pada saat
  tombol ditekan karena hasilnya bergantung pada Invoice, Credit Note, dan
  pembayaran yang sudah dialokasikan.
- Satu SO dapat mempunyai lebih dari satu Return parsial. SO asli tetap final dan
  menyimpan link ke semua Return terkait.

### 3. Satu area Inventory, dua jenis penerimaan

Inventory tetap menjadi tempat penerimaan fisik, dengan pemisahan jelas:

```text
Penerimaan Barang
├── Dari Supplier
└── Retur Customer
```

Keduanya boleh berada dalam satu halaman induk dengan dua tab, tetapi tidak
boleh dicampur sebagai jenis dokumen yang sama. Penerimaan Supplier tetap
bersumber dari PO dan tidak boleh terpicu oleh Return Customer.

Dokumen **Penerimaan Retur Customer** terkait ke Return, SO, DO/SJ, Customer,
dan Invoice sumber. Inventory tidak menentukan harga, nilai Credit Note, metode
refund, atau keputusan Finance.

### 4. Disposition fisik ditentukan Gudang

Ketika barang retur diterima dan diperiksa, Gudang menentukan disposition:

- **Masuk stok**; atau
- **Dihancurkan**.

Keputusan ini wajib disimpan sebagai histori penerimaan dan menjadi dasar efek
stok berikutnya. Disposition dipilih per line dan satu Product boleh dipecah.
Pilihan **Dihancurkan** wajib mempunyai catatan operasional, tetapi tidak
memerlukan foto maupun approval kedua.

### 5. Invoice, Credit Note, dan Refund

- Invoice Draft/belum diterbitkan boleh disesuaikan berdasarkan quantity bersih
  setelah Return dan tetap dapat diedit manual sebelum posting.
- Invoice yang sudah posted/diterbitkan tidak boleh diedit atau ditimpa.
- Return terhadap Invoice posted menghasilkan Credit Note/pengurang tagihan.
- Jika belum ada pembayaran, proses finansial berhenti pada pengurangan piutang;
  tidak ada pengembalian uang Customer.
- Jika sudah ada pembayaran, Credit Note lebih dahulu mengurangi outstanding.
  Hanya kelebihan pembayaran setelah koreksi yang menjadi nilai refund.
- Jika diperlukan Invoice pengganti, Invoice lama tetap ada, Credit Note
  membalik nilai yang relevan, dan sistem membuat Draft Invoice baru yang
  terhubung. Nomor Invoice posted tidak dipakai ulang.

Contoh nilai:

| Invoice | Pembayaran masuk | Credit Note | Hasil |
|---:|---:|---:|---|
| Rp10 juta | Rp0 | Rp3 juta | Piutang tersisa Rp7 juta; refund Rp0 |
| Rp10 juta | Rp5 juta | Rp3 juta | Piutang tersisa Rp2 juta; refund Rp0 |
| Rp10 juta | Rp10 juta | Rp3 juta | Piutang nol; refund Customer Rp3 juta |

### 6. Financial boundary yang sudah dikunci

Keputusan berikut disetujui sebagai fondasi awal dan tidak boleh diubah saat
implementasi tanpa konfirmasi user:

1. Credit Note baru boleh diterbitkan berdasarkan quantity aktual yang sudah
   diterima dan dikonfirmasi Gudang. Quantity yang baru diajukan Customer belum
   menjadi dasar koreksi piutang.
2. Disposition **Dihancurkan** tetap mempunyai dua jejak yang saling terhubung:
   penerimaan fisik Retur Customer ke lokasi/status barang rusak, kemudian
   pemusnahan atau write-off. Implementasi boleh mengonfirmasi keduanya secara
   atomik, tetapi tidak boleh melewati bukti penerimaan fisik.
3. Satu Return master boleh berasal dari satu SO, tetapi quantity dan nilai
   komersial harus dialokasikan ke Invoice sumber. Jika satu SO mempunyai
   beberapa Invoice, setiap Invoice posted menghasilkan Credit Note terpisah;
   sistem tidak boleh menebak urutan Invoice yang dikoreksi.
4. Invoice yang masih Draft ditandai mempunyai Return dan nilai/quantity-nya
   disesuaikan dalam Draft. User tetap wajib memeriksa dan mengonfirmasi Invoice
   tersebut sebelum posting. Invoice posted tidak pernah ditulis ulang.
5. Pembuat/operator Draft adalah Owner, Company Admin, Store Manager, Sales, dan
   Sales Admin. Approver komersial adalah Owner, Company Admin, Store Manager,
   Sales Admin, dan Finance. Finance tidak otomatis menjadi pembuat Draft.
6. Return boleh dimulai setelah ada quantity yang benar-benar diterima Customer,
   baik Invoice belum dibuat, masih Draft, maupun sudah posted.
7. Jika Invoice belum posted, dokumen Invoice final yang dicetak memakai quantity
   bersih setelah Return aktual dan tetap dikonfirmasi user. Jika Invoice sudah
   posted, Invoice asli tetap tersimpan apa adanya; koreksi legalnya adalah
   Invoice asli plus Credit Note yang menunjuk Return sumber, bukan mencetak
   ulang Invoice lama dengan nilai baru.
8. Penerimaan Retur parsial boleh diproses komersial parsial sebesar quantity
   aktual yang sudah dikonfirmasi Gudang. Credit Note wajib menunjuk Return dan
   allocation Invoice sumber secara eksplisit.
9. Disposition dipilih per line dan satu Product boleh dipecah ke beberapa hasil
   fisik, misalnya sebagian Masuk Stok dan sebagian Dihancurkan.

## Flow tingkat tinggi yang disetujui

```text
SO / barang diterima Customer
        ↓
Buat Retur
        ↓
Review / persetujuan Retur
        ↓
Inventory menerima dan memeriksa barang
        ↓
Gudang: Masuk stok atau Dihancurkan
        ↓
Credit Note / pengurangan tagihan
        ↓
Alokasi terhadap outstanding pembayaran
        ↓
Refund hanya untuk kelebihan pembayaran
        ↓
Selesai
```

## Batas modul

| Modul | Tanggung jawab |
|---|---|
| Sales | Pengajuan Return, hubungan SO/DO/Invoice, keputusan komersial dan status proses |
| Inventory | Penerimaan fisik, quantity aktual, kondisi dan disposition stok/pemusnahan |
| Finance | Credit Note, pengurangan AR, rekonsiliasi pembayaran, refund dan posting |

## Compatibility dan invariant wajib

- Runtime Retur Retail existing tidak boleh rusak atau berubah diam-diam.
- Dokumen posted/final bersifat append-only; tidak ada delete atau rewrite
  histori untuk mensimulasikan Return.
- Cumulative returned quantity tidak boleh melebihi quantity yang benar-benar
  diterima Customer setelah memperhitungkan Return sebelumnya.
- Credit Note/refund kumulatif tidak boleh melebihi nilai yang dapat dikoreksi.
- Stock hanya berubah melalui disposition Gudang yang sah; refund tidak boleh
  mengubah stock untuk kedua kalinya.
- Company, role, permission, optimistic version, idempotency, retry, audit, dan
  concurrency wajib ditegakkan server-side.
- Return parsial, multi-Invoice per SO, pembayaran parsial, dan retry harus
  menjadi test wajib.

## Impact map sebelum implementasi

### Direct impact

- Sales Order dan Backoffice Invoice UI;
- daftar dan detail Retur & Refund;
- Inventory Penerimaan Retur Customer;
- dokumen Return, receipt, Credit Note, refund, audit dan lineage.

### Downstream impact

- On Hand, FIFO/cost lineage, Stock Movement dan pemusnahan;
- AR, Customer Receipt allocation, Credit Note, refund liability dan Journal;
- tax/discount/delivery fee/rounding snapshot;
- customer statement, aging, laporan Sales, Inventory dan Finance.

### Regression risk

- Retur Retail existing;
- cancel/revision SO;
- partial/multiple Invoice;
- discrepancy DO sebelum Customer acceptance;
- Customer Balance dan metode Cash/Transfer;
- multi-Company dan permission Finance/Inventory/Sales.

## Decision gate Step 3 - RESOLVED

1. Finance membagi setiap quantity fisik yang sudah diterima secara eksplisit
   ke `UNINVOICED`, `DRAFT_INVOICE`, atau `POSTED_INVOICE`; sistem tidak menebak
   Invoice mana yang dikoreksi.
2. Draft Invoice yang dipilih disesuaikan otomatis dan ditandai wajib diperiksa
   serta dikonfirmasi ulang sebelum posting.
3. Setiap Invoice posted menghasilkan Credit Note terpisah. Harga, discount dan
   pajak dihitung proporsional dari snapshot line Invoice; allocation terakhir
   pada source line menyerap residual pembulatan line.
4. Ongkir tidak direfund otomatis. Finance boleh mengubah ongkir pada Draft
   Credit Note, dengan batas kumulatif sebesar ongkir Invoice sumber.
5. Draft Invoice pengganti hanya dibuat manual jika diperlukan; tidak ada
   pembuatan otomatis setelah Credit Note.
6. Credit Note mengurangi outstanding AR terlebih dahulu. Sisa nilai setelah AR
   nol menjadi `CUSTOMER_REFUND_LIABILITY`; pembayaran refund tetap Step 4.
7. Closed period menggunakan open/reopened period berikutnya sebagai prior
   period adjustment dan tetap menyimpan tanggal dokumen asal.

Step 3 migration, behavioral dan postflight sudah user-confirmed PASS pada
database target. Authenticated UI smoke dan UAT masih menunggu. Paket tidak
membuka cancel/reallocation Credit Note karena
policy koreksi source allocation belum disetujui.

## Decision gate Step 4 - RESOLVED; DEVELOPMENT PAUSED

1. Refund boleh memakai metode pembayaran aktif yang sama dengan penerimaan
   Customer, termasuk Cash dan Transfer Bank.
2. Finance boleh membuat sekaligus mem-post Refund; separation of duties antara
   pembuat dan approver tidak diwajibkan pada tahap ini.
3. Partial Refund diperbolehkan.
4. Bukti pembayaran mengikuti konfigurasi Payment Method: hanya wajib jika
   metode tersebut memang mewajibkan bukti.
5. Refund posted tidak boleh dibatalkan atau diedit langsung; koreksi wajib
   melalui reversal yang source-linked dan dapat ditelusuri.

Step 4 sekarang local-ready melalui migration `20260917150000`. Finance dapat
mem-post partial Cash/Transfer Refund langsung dari liability Credit Note;
Cash tidak memakai POS atau Cashier Session. Posting membuat Journal balance,
Customer Statement source-linked, exact retry dan cumulative cap. Refund final
immutable dan koreksi memakai reversal yang membalik Journal sumber. Database
rollout, authenticated smoke dan UAT masih manual; UI terpadu tetap Step 5.
Forward-fix `20260917151000` diperlukan setelah behavioral pertama membuktikan
guard Finance lama menolak sumber Automatic/Prior Period. Pengecualian baru
hanya berlaku jika jurnal sumber dan reversal sama-sama memakai system event
`BACKOFFICE_CUSTOMER_REFUND`; flow Finance lain tidak dilonggarkan.

## Task lanjutan setelah Step 3

Audit seluruh warning/error aplikasi dan ubah pesan blocker menjadi bahasa yang
menjelaskan penyebab serta tindakan user. Task ini dicatat terpisah dan tidak
boleh mengubah business rule atau menyamarkan error server.
