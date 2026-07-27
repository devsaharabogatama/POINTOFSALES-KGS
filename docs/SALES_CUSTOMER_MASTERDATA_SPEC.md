# Spesifikasi Master Customer KGS

**Status:** Active Design Draft 0.3 — reusable Pricelist assignment telah dikonfirmasi
**Tanggal:** 2026-07-22
**Scope aktif:** Identitas Customer retail, akses POS/Backoffice, Pricelist, dan batas awal saldo/piutang

---

## 1. Tujuan

Dokumen ini menjadi kontrak bisnis untuk Master Customer sebelum schema, RLS, import, API, atau UI diubah.

Customer berada pada:

```text
Sales
└── Master Data
    └── Customer
```

Master Customer dimiliki company dan dapat dipakai POS, Sales, Pricelist, laporan, refund, serta Finance sesuai keputusan yang disetujui kemudian.

---

## 2. Fakta Project Saat Ini

Berdasarkan `supabase/schema.sql` dan migration multi-company:

```text
customers.id
customers.company_id
customers.code
customers.name
customers.phone
customers.address
customers.current_balance
customers.credit_limit
customers.created_at
```

Kondisi penting:

- Migration sudah mengubah uniqueness kode menjadi `(company_id, code)`.
- Backoffice aktif saat ini membaca dan menampilkan kode, nama, telepon, serta saldo.
- Dokumen checklist lama menyebut Customer CRUD/Pricelist selesai, tetapi jalur UI aktif yang diaudit baru menunjukkan daftar read-only; status implementasi final perlu diverifikasi ketika fase coding dimulai.
- `current_balance` dan `credit_limit` sudah ada, tetapi rule deposit/piutang dan jurnal belum boleh diasumsikan final.

---

## 3. Relasi dengan Pricelist

- Customer dapat memiliki maksimal satu Pricelist Eksklusif default aktif.
- Customer tanpa Pricelist Eksklusif menggunakan Pricelist Global yang eligible untuk store.
- Customer umum/walk-in memakai Pricelist Global default.
- Cashier dapat memilih Pricelist eligible lain secara opsional; override disimpan pada transaksi dan tidak mengubah default Customer.
- Pricelist eksklusif milik customer lain tidak boleh digunakan.
- Detail rule berada pada `docs/SALES_PRICELIST_NOTES.md`.

---

## 4. Kandidat Field Master Customer

Field berikut belum final dan akan dikonfirmasi bertahap:

```text
id
company_id
code
name
customer_category_id
phone nullable
email nullable
address nullable
customer_type nullable
default_pricelist_id nullable
credit_limit
credit_term_days nullable
current_balance
is_active
notes nullable
created_at/by
updated_at/by
```

Kandidat lanjutan yang belum masuk scope awal:

- NPWP/NIK dan identitas pajak;
- beberapa alamat pengiriman/tagihan;
- contact person perusahaan;
- loyalty point/member tier;
- customer deposit, credit terms, dan aging piutang;
- dokumen/attachment customer.

---

## 5. Guardrail Awal

- Semua Customer wajib tenant-scoped menggunakan `company_id`.
- Code hanya unik di dalam company dan boleh sama pada company lain.
- Nama Customer wajib unik secara case-insensitive setelah normalisasi spasi dalam company. Cabang/gerobak berbeda harus memakai nama pembeda yang jelas.
- Nomor telepon dan email boleh sama pada beberapa Customer dan tidak menjadi hard block.
- POS tidak boleh mempercayai `customer_id` tanpa validasi company/store context.
- Customer inactive tetap muncul pada histori tetapi tidak dapat dipilih untuk transaksi baru. Customer tidak boleh dihapus permanen selama masih mempunyai saldo, hutang toko kepada Customer, hutang Customer kepada toko, transaksi, atau ledger terkait.
- Perubahan Customer/Pricelist tidak mengubah snapshot transaksi historis.
- `current_balance` tidak boleh diedit langsung dari form Customer; saldo harus berasal dari event deposit/piutang/payment yang sah setelah workflow Finance disetujui.
- Service-role key tidak boleh digunakan di frontend.

### 5.1 Master Kategori Customer

- Kategori Customer adalah master reusable per company untuk grouping bidang usaha, misalnya `GEROBAK`, `WARUNG`, `TOKO`, atau `RESTAURANT`.
- Form Customer memilih kategori melalui dropdown, bukan teks bebas.
- Satu Customer memiliki satu kategori utama pada scope awal.
- Kategori yang sudah dipakai tidak dihapus; gunakan status inactive.

### 5.1A Customer Induk dan Customer Cabang

- Satu Customer induk dapat mempunyai banyak Customer cabang/toko.
- Hierarki v1 dibatasi satu tingkat: Customer cabang tidak dapat menjadi induk
  Customer lain dan relasi cycle wajib ditolak server-side.
- Customer induk dan setiap Customer cabang tetap mempunyai `customer_id`,
  kode, nama, transaksi, saldo, limit, dan histori sendiri.
- Dokumen transaksi selalu menyimpan Customer yang benar-benar bertransaksi;
  sistem tidak memindahkan transaksi cabang ke Customer induk.
- Laporan dapat melakukan roll-up dengan
  `COALESCE(parent_customer_id, id)` agar seluruh cabang dapat dilihat sebagai
  satu grup tanpa menghilangkan rincian per toko.
- Parent wajib berada pada Company yang sama, aktif, bukan Walk-In, dan bukan
  Customer cabang.
- Customer yang sudah memiliki cabang tidak dapat dijadikan cabang sebelum
  seluruh relasi anak dilepas.

### 5.2 Kode, Scope, dan Quick Create

- Kode dibuat otomatis dengan sequence company, misalnya `CUST-000001`.
- Company Admin/Store Manager dapat mengubah kode selama tetap unik dalam company.
- Customer bersifat company-wide dan dapat digunakan seluruh store pada company yang sama.
- Cashier dapat quick-create Customer dari POS dengan minimum nama, kategori, dan telepon opsional.
- Quick-create Cashier wajib melalui RPC/API server terkontrol yang memvalidasi membership, company, kategori, normalisasi nama, uniqueness, dan idempotency; Cashier tidak mendapat hak INSERT langsung bebas ke tabel Customer.
- Form lengkap dan pengeditan master dilakukan Company Admin/Store Manager melalui Backoffice sesuai company assignment.

### 5.2.1 Assignment Pricelist Customer

- `default_pricelist_id` dipilih dari menu/form Customer dan hanya boleh
  menunjuk Pricelist `CUSTOMER` aktif pada company yang sama.
- Nilai nullable berarti Customer mengikuti Pricelist Global default.
- Banyak Customer boleh menunjuk Pricelist yang sama; Pricelist bukan dibuat
  ulang per Customer.
- Satu Customer hanya menunjuk maksimal satu Pricelist khusus pada satu waktu.
- Customer Walk-In wajib selalu `NULL` dan memakai Global default.
- Perubahan assignment memengaruhi transaksi baru; transaksi lama tetap memakai
  snapshot Pricelist dan harga yang tersimpan.

### 5.3 Customer Walk-In

- Setiap company memiliki satu row sistem khusus dengan code `WALK-IN`.
- Row ini dipakai saat transaksi tidak memilih customer terdaftar agar laporan dan Pricelist tidak ambigu.
- Customer Walk-In memakai Pricelist Global default yang eligible untuk store.
- Row Walk-In tidak boleh dihapus, dinonaktifkan, atau diberi Pricelist Eksklusif.

### 5.4 Customer Balance

- Seluruh workflow dikendalikan feature entitlement `customer_balance_enabled` pada scope company.
- Hanya Super Admin yang dapat mengaktifkan atau menonaktifkan entitlement tersebut. Company Admin, Finance, Store Manager, Warehouse Admin, dan Cashier tidak dapat mengubahnya.
- Saat disabled, POS menyembunyikan indikator, pilihan penyimpanan saldo, penggunaan saldo, dan refund ke saldo. API/RPC wajib menolak pembuatan atau pemakaian Customer Balance walaupun dipanggil langsung.
- Ledger dan dokumen historis tidak boleh dihapus ketika fitur disabled. Finance dan Company Admin tetap dapat melihat liability/history sesuai scope untuk audit.
- Lifecycle entitlement adalah `ACTIVE -> WIND_DOWN -> DISABLED`. Jika penonaktifan diminta ketika masih ada outstanding Customer Balance, status menjadi `WIND_DOWN`: accrual/refund-to-balance baru diblokir, tetapi saldo lama tetap terlihat dan wajib digunakan atau diselesaikan. Setelah seluruh liability nol, status otomatis menjadi `DISABLED` dan UI operasional disembunyikan penuh.
- Customer Balance adalah kewajiban toko kepada Customer dalam satu company, bukan diskon, pendapatan, atau field harga manual.
- Saldo bersifat company-wide dan dapat dipakai oleh Customer yang sama di store mana pun dalam company tersebut.
- Saldo tidak mempunyai masa berlaku dan tetap disimpan walaupun Customer menjadi inactive atau tidak kembali bertransaksi.
- Penggunaan saldo menjadi payment method terpisah `CUSTOMER_BALANCE` untuk mengurangi amount due pembelian Customer. Penggunaan saldo tidak mengubah harga, diskon, pajak, rounding, atau revenue transaksi.
- Pada transaksi pembelian berikutnya, seluruh saldo dari transaksi/sumber lama wajib diselesaikan; Cashier tidak boleh memilih menggunakan sebagian saldo lama.
- Credit baru yang timbul dari transaksi berjalan dicatat sebagai event/source balance baru. Karena itu saldo sumber lama harus menjadi nol walaupun saldo akhir Customer dapat terisi kembali oleh transaksi baru.
- Jika saldo lama lebih besar daripada amount due transaksi, checkout diblokir. POS meminta Cashier menambah belanja sampai grand total yang dapat diselesaikan minimal sama dengan seluruh saldo lama; amount due tidak boleh menjadi negatif dan sisa saldo lama tidak boleh dibawa ke transaksi berikutnya.
- Urutan settlement default adalah `grand_total_final -> KETUL_OFFSET -> CUSTOMER_BALANCE -> Cash/Transfer/QR/Card`.
- Saldo tidak boleh negatif dan tidak dapat diedit langsung pada Master Customer.

Sumber penambahan saldo yang diperbolehkan:

- kelebihan pembayaran Transfer yang sengaja dititipkan;
- kembalian Cash yang sengaja dititipkan;
- nilai Customer Intake Ketul yang dipilih menjadi saldo;
- refund penjualan yang dipilih menjadi saldo;
- koreksi manual melalui workflow berwenang.

Setiap sumber wajib membuat event ledger append-only dengan `source_type`, `source_id`, nominal, actor, waktu, company, store bila relevan, dan idempotency key. Koreksi tidak boleh menimpa event lama; koreksi menggunakan reversal dan event pengganti. `customers.current_balance` hanya cache/ringkasan dari ledger.

Cashier membuat permintaan koreksi saldo. Finance memeriksa dan menyetujui/menolak agar ledger operasional dan catatan keuangan tetap balance; Company Admin/Super Admin mewarisi kewenangan approval sesuai hierarchy. Cashier tidak boleh mem-posting koreksinya sendiri.

Refund atau pembatalan transaksi yang sebelumnya memakai Customer Balance dapat dikembalikan sebagai Cash, Transfer, atau Customer Balance sesuai pilihan Customer dan workflow refund. Untuk split payment, nominal yang berasal dari Customer Balance dikembalikan lebih dahulu; sisa refund dapat dibayar melalui metode yang dipilih. Total cumulative refund tetap tidak boleh melebihi refundable amount transaksi asal.

Jika transaksi yang menghasilkan credit saldo dibatalkan, credit tersebut direversal. Jika credit lama sudah dikonsumsi transaksi lain, pembatalan langsung diblokir dan penyelesaian wajib memakai correction/reversal workflow agar ledger tidak menjadi negatif.

Customer Balance tidak dapat dicairkan langsung melalui menu saldo. Penyelesaian kewajiban kepada Customer inactive/non-returning dilakukan melalui exceptional settlement terpisah berupa pengiriman Produk atau pengembalian uang melalui Expense sesuai kebijakan company. Dokumen dapat dibuat Finance atau Store Manager dan di-approve Finance atau Company Admin sesuai konfigurasi; Super Admin mewarisi authority, sedangkan Cashier tidak dapat menjalankannya. Workflow wajib mereferensikan ledger Customer Balance dan tidak boleh menghapus histori saldo secara manual.

Exceptional settlement berupa uang memakai kategori Expense khusus dan mandatory approval Finance/Company Admin walaupun approval Expense operasional umum dinonaktifkan. Dokumen wajib menutup/mengurangi source liability Customer Balance melalui reference append-only.

Mapping Finance yang disetujui:

- Cash/Transfer settlement: Debit Customer Balance dan Kredit Kas/Bank; bukan Expense P&L baru.
- Product settlement: Debit Customer Balance, Kredit Penjualan, Debit HPP, dan Kredit Persediaan dengan stock/FIFO normal.
- Koreksi tambah/kurang saldo wajib mempunyai source account valid, alasan, dan approval Finance; sistem tidak otomatis memilih Income/Expense.

Credit limit/piutang Customer berbeda dari saldo positif dan tetap dibahas pada fase Finance.

### 5.5 Laporan dan Bukti Customer Balance

- POS menampilkan indikator saldo ketika Customer dipilih agar Cashier mengetahui saldo tersedia.
- Struk menampilkan mutasi dengan label operasional **Potongan Saldo Customer**; backend tetap menyimpan `CUSTOMER_BALANCE` sebagai settlement, bukan diskon.
- Customer Statement menampilkan saldo awal, seluruh mutasi debit/kredit, source document, store, actor, saldo berjalan, dan saldo akhir.
- Backoffice menyediakan filter Customer, store, tanggal, dan sumber mutasi serta export Excel.
- Dashboard Finance menampilkan total liability Customer Balance per company.
- Aging saldo menggunakan bucket `0-30`, `31-60`, `61-90`, dan `>90 hari` berdasarkan source credit yang masih outstanding. Aging hanya untuk monitoring dan tidak menyebabkan expiry.

### 5.6 Fasilitas TEMPO Customer

- TEMPO berbeda dari Customer Balance: TEMPO adalah piutang Customer kepada toko, sedangkan Customer Balance adalah kewajiban toko kepada Customer.
- Finance mengisi `credit_limit` dan default `credit_term_days` secara manual per Customer. Nilai ini merupakan batas kontrol dan peringatan, bukan hard block checkout.
- Cashier memilih due date aktual pada checkout dengan saran awal berdasarkan default term Customer. Finance dapat override due date setelah posted melalui audit nilai lama/baru, alasan, actor, dan waktu.
- Customer Walk-In tidak boleh memakai TEMPO karena tidak memiliki identitas ledger, limit, dan histori piutang yang dapat ditelusuri.
- POS menampilkan outstanding, sisa limit, due date, overdue, dan warning sebelum Cashier memilih TEMPO.
- Cashier boleh melanjutkan walaupun melewati limit atau overdue tanpa approval Store Manager; acknowledgement dan actor override wajib diaudit.
- Existing outstanding tidak memblokir TEMPO baru. POS menampilkan total piutang dan jumlah Pro Forma terbuka; Cashier menentukan apakah transaksi dilanjutkan dan acknowledgement disimpan.
- Sale TEMPO yang sudah dikonfirmasi online membentuk piutang serta mengurangi stok. Pro Forma tetap outstanding sampai dilunasi melalui cicilan/partial payment.
- DP saat checkout menjadi payment allocation pertama. Pembayaran lanjutan hanya dibuat Cashier melalui menu Pembayaran Tempo di POS; Finance melakukan monitoring, rekonsiliasi, dan koreksi berwenang tanpa jalur input payment paralel.
- Payment dapat mencakup beberapa Pro Forma Customer yang sama. Daftar disarankan oldest-first; dokumen awal dilunasi dan sisa yang tidak cukup pada dokumen berikutnya menjadi cicilan/`PARTIALLY_PAID`.
- Overpayment tidak boleh membuat piutang negatif. Selisih menjadi Customer Balance bila entitlement aktif dan dipilih Customer; selain itu selisih dikembalikan melalui Cash/Transfer.
- Retur posted menggunakan Credit Note untuk mengurangi piutang. Pembatalan penuh hanya setelah barang kembali dan menggunakan reversal append-only, bukan delete/edit histori.
- Customer inactive tidak dapat membuat TEMPO baru, tetapi seluruh piutang, payment history, collection, dan settlement lama tetap tersedia.
- Customer tidak boleh dihapus selama mempunyai piutang terbuka atau histori finansial terkait.
- Invoice final baru diterbitkan ketika outstanding Pro Forma nol. Invoice final mereferensikan seluruh histori pembayaran tanpa membuat ulang sale atau piutang.
- Status penyelesaian (`OPEN/PARTIALLY_PAID/PAID/CANCELED/CREDIT_NOTED/WRITTEN_OFF`) dipisahkan dari status due (`NOT_DUE/OVERDUE`) agar aging dan payment tidak saling menimpa.
- Koreksi harga posted memakai Debit/Credit Note oleh Finance. Write-off diajukan Finance dan memerlukan approval Company Admin; keduanya append-only dan tidak menghapus histori Customer.
- Write-off dapat parsial atau penuh per Pro Forma. Full write-off bukan pelunasan dan tidak menerbitkan Invoice final; payment setelah write-off menjadi Recovery Piutang dengan reference ke histori lama.
- Maker-checker write-off wajib: Finance membuat pengajuan dan Company Admin menyetujui; Company Admin tidak membuat serta menyetujui dokumen yang sama.
- POS hanya menampilkan warning histori write-off kepada Cashier tanpa detail akun, jurnal, atau alasan internal.
- Reminder overdue hanya in-app pada POS/Backoffice; follow-up kepada Customer dilakukan manual oleh Cashier atau Finance.
- Customer Statement TEMPO menampilkan Pro Forma, DP/cicilan, payment allocation, Debit/Credit Note, retur, write-off/recovery, Invoice final, due date, dan saldo berjalan. Filter tersedia per Customer, store, tanggal, settlement status, serta due status; output Excel/PDF.
- Assignment, operational aging `1-7/8-30/31-60/61-90/>90`, append-only follow-up, Promise to Pay, warning acknowledgement, on-demand export, dan retention boundary mengikuti `COLLECTION_AND_CUSTOMER_STATEMENT_SPEC.md`.
- Koreksi dan exceptional settlement memakai nomor dokumen otomatis serta tampil pada statement.

---

## 6. Keputusan yang Sudah Dikonfirmasi

- Pelanggan umum/walk-in menggunakan Pricelist Global default.
- Cashier dapat memilih Pricelist eligible secara opsional untuk transaksi.
- Harga POS bersifat tax-inclusive pada scope awal.
- Master dan transaksi Customer tidak boleh bocor lintas company.
- Kode Customer otomatis dan dapat diedit Admin/Store Manager.
- Nama unik per company; telepon/email boleh sama.
- Customer company-wide dan Cashier boleh quick-create melalui POS.
- Walk-In adalah row sistem khusus per company.
- Kategori Customer menjadi master dropdown reusable.
- Customer Balance berlaku company-wide, tidak kedaluwarsa, dan hanya dapat dipakai Customer yang sama sebagai settlement pembelian.
- Feature entitlement Customer Balance hanya dapat diaktifkan/dinonaktifkan Super Admin per company.
- Ketul Offset dipakai lebih dahulu, lalu Customer Balance, kemudian payment eksternal.
- Saldo dapat berasal dari kelebihan Transfer/Cash, Ketul, refund, atau koreksi berwenang dengan ledger append-only.
- Saldo sumber lama wajib diselesaikan seluruhnya pada transaksi berikutnya; pemakaian sebagian oleh Cashier tidak diperbolehkan.
- Cashier mengajukan koreksi dan Finance melakukan approval; refund dapat dikembalikan sebagai Cash, Transfer, atau Customer Balance.
- Saldo tidak dapat dicairkan langsung; penyelesaian khusus Customer inactive/non-returning menggunakan workflow operasional terpisah.

---

## 7. Keputusan Terbuka — Batch Berikutnya

1. Detail tax/legal exception write-off; mapping dasar Bad Debt/AR dan Recovery Income sudah disetujui.

---

## 8. Instruksi untuk AI Agent

- Jangan mengimplementasikan schema/UI sebelum keputusan batch Customer disetujui.
- Jangan memakai `current_balance` sebagai angka manual tanpa ledger/event.
- Jangan membuat Customer global lintas company.
- Jangan menganggap checklist lama membuktikan CRUD aktif sudah lengkap.
- Jangan mencampur Pricelist Customer dengan harga beli Supplier.
- Selalu simpan snapshot customer/pricelist yang diperlukan pada transaksi.

---

## 9. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-15 | Customer ditempatkan pada Sales Master Data | APPROVED |
| 2026-07-15 | Pelanggan umum memakai default Global Pricelist | APPROVED |
| 2026-07-15 | Cashier dapat memilih Pricelist eligible lain secara opsional | APPROVED |
| 2026-07-15 | Kode otomatis editable Admin/Manager; Customer company-wide; quick-create tersedia di POS | APPROVED |
| 2026-07-15 | Kategori Customer merupakan master reusable bidang usaha dan dipilih melalui dropdown | APPROVED |
| 2026-07-15 | Nama unik per company; telepon/email boleh sama | APPROVED |
| 2026-07-15 | Walk-In menjadi row sistem khusus per company | APPROVED |
| 2026-07-15 | Kelebihan transfer dapat disimpan sebagai saldo dan dipakai transaksi berikutnya oleh Customer yang sama | APPROVED; mapping liability resolved 2026-07-17 |
| 2026-07-15 | Nilai Ketul dapat dibayar atau masuk Customer Balance dengan ledger reference Ketul | APPROVED; mapping Utang Ketul/Balance resolved 2026-07-19 |
| 2026-07-15 | Settlement Ketul mendukung Cash/Transfer/Balance split dan offset setelah final price | APPROVED |
| 2026-07-16 | Customer Balance company-wide dan tidak kedaluwarsa | APPROVED |
| 2026-07-16 | Urutan settlement: Ketul Offset, Customer Balance, lalu payment eksternal | APPROVED |
| 2026-07-16 | Saldo dapat berasal dari kelebihan Transfer/Cash, Ketul, refund, dan koreksi berwenang melalui ledger append-only | APPROVED secara operasional; detail approval berikutnya |
| 2026-07-16 | Customer Balance tidak dapat dicairkan langsung; kewajiban Customer inactive tetap disimpan dan diselesaikan melalui workflow Expense/operasional terpisah | APPROVED secara konsep; detail Expense ditunda |
| 2026-07-17 | Exceptional Customer Balance settlement via Expense memakai kategori khusus dan mandatory approval Finance/Company Admin | APPROVED; mapping liability settlement resolved 2026-07-19 |
| 2026-07-16 | Seluruh saldo sumber lama wajib diselesaikan pada transaksi berikutnya; credit baru tetap menjadi source event baru | APPROVED |
| 2026-07-16 | Cashier mengajukan koreksi Customer Balance dan Finance melakukan approval agar ledger tetap balance | APPROVED; Company Admin/Super Admin tetap mewarisi authority |
| 2026-07-16 | Refund split mengembalikan bagian Customer Balance lebih dahulu; sisanya fleksibel Cash/Transfer/Balance | APPROVED |
| 2026-07-16 | Mutasi saldo tampil di struk sebagai potongan/penggunaan saldo, tetapi backend tetap settlement | APPROVED |
| 2026-07-16 | Exceptional settlement dibuat Finance/Store Manager, di-approve Finance/Company Admin sesuai konfigurasi, dan tidak dapat dijalankan Cashier | APPROVED secara operasional |
| 2026-07-16 | Statement, export Excel, liability company, dan aging saldo tersedia; aging tidak menyebabkan expiry | APPROVED |
| 2026-07-16 | Koreksi dan exceptional settlement memakai nomor dokumen otomatis | APPROVED |
| 2026-07-16 | Checkout diblokir bila saldo lama melebihi amount due; belanja harus ditambah sampai seluruh saldo lama terserap | APPROVED |
| 2026-07-16 | Customer Balance menjadi feature entitlement per company yang hanya dapat diaktifkan/dinonaktifkan Super Admin | APPROVED |
| 2026-07-16 | Disabled menyembunyikan UI dan memblokir mutation API/RPC tanpa menghapus ledger/history | APPROVED |
| 2026-07-16 | Penonaktifan dengan outstanding balance memakai WIND_DOWN; credit baru diblokir dan fitur menjadi DISABLED otomatis setelah liability nol | APPROVED |
| 2026-07-17 | Finance mengatur credit limit dan term manual per Customer; limit/overdue hanya warning | APPROVED |
| 2026-07-17 | Cashier boleh memberi TEMPO tanpa approval Store Manager; override limit/overdue wajib diaudit | APPROVED |
| 2026-07-17 | Payment TEMPO dapat parsial/multi-metode dan Invoice final baru terbit setelah lunas | APPROVED |
| 2026-07-17 | TEMPO offline hanya Draft/Pending dan wajib divalidasi online sebelum penyerahan barang/posting | APPROVED |
| 2026-07-17 | Finance menetapkan default term, Cashier memilih due date transaksi, dan Finance dapat override secara audited | APPROVED |
| 2026-07-17 | Payment TEMPO hanya diinput Cashier melalui POS; Finance memantau, rekonsiliasi, dan mengoreksi secara berwenang | APPROVED |
| 2026-07-17 | DP menjadi payment pertama; overpayment masuk Customer Balance bila aktif atau dikembalikan Cash/Transfer | APPROVED |
| 2026-07-17 | Retur memakai Credit Note dan pembatalan penuh memakai reversal hanya setelah barang kembali | APPROVED |
| 2026-07-17 | Existing outstanding tidak memblokir TEMPO baru; Cashier menentukan setelah melihat warning | APPROVED |
| 2026-07-17 | Payment multi-Pro Forma memakai saran oldest-first; kekurangan pada dokumen berikutnya menjadi cicilan | APPROVED |
| 2026-07-17 | Settlement status dan due status dipisahkan; reminder hanya in-app dengan follow-up manual | APPROVED |
| 2026-07-17 | Koreksi harga memakai Debit/Credit Note Finance; write-off membutuhkan approval Company Admin | APPROVED secara konsep |
| 2026-07-17 | Customer Statement TEMPO lengkap dengan filter dan export Excel/PDF | APPROVED |
| 2026-07-20 | Collection memakai in-app derived aging, assigned manual follow-up, immutable Promise log, warning acknowledgement, dan on-demand Statement export | APPROVED |
| 2026-07-17 | Write-off fleksibel parsial/penuh per Pro Forma; WRITTEN_OFF bukan PAID dan tidak menerbitkan Invoice final | APPROVED |
| 2026-07-17 | Payment setelah write-off dicatat sebagai Recovery Piutang tanpa mengubah jurnal lama | APPROVED secara konsep |
| 2026-07-17 | Finance menjadi maker dan Company Admin menjadi approver write-off terpisah | APPROVED |
| 2026-07-17 | Cashier hanya melihat warning histori write-off tanpa detail Finance | APPROVED |
| 2026-07-19 | Write-off Debit Bad Debt/Credit AR dan Recovery Cash/Bank terhadap Recovery Income | APPROVED |
| 2026-07-19 | Recovery tidak boleh melebihi remaining write-off; excess direfund atau menjadi Customer Balance | APPROVED |
| 2026-07-19 | Exceptional Cash/Transfer mengurangi liability; Product settlement memakai Sale/HPP/FIFO normal | APPROVED |
