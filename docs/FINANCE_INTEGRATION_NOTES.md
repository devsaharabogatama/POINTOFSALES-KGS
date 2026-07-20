# Catatan Integrasi Finance KGS

**Status:** Integration Note; Finance Core mulai dibahas  
**Tanggal:** 2026-07-14  
**Fase aktif saat dokumen dibuat:** Produk dan Stok  
**Fase desain Finance sudah berjalan, tetapi dokumen ini bukan izin implementasi accounting atau perubahan schema production.**

---

## 1. Tujuan

Dokumen ini menyimpan keputusan dan pekerjaan keuangan yang muncul saat perancangan Produk dan Inventory agar tidak terlewat ketika sistem masuk ke fase Finance.

Catatan terpisah untuk Modal Pemilik dan Aset Tetap tersedia pada `docs/CAPITAL_AND_ASSET_NOTES.md`. Scope tersebut masih deferred dan tidak boleh dianggap sudah siap diimplementasikan.

Fondasi Finance Core, COA, Journal, dan accounting period berada pada `docs/FINANCE_CORE_ACCOUNTING_SPEC.md`. Dokumen ini tetap menjadi sumber mapping event dari POS, Inventory, Purchasing, Customer, Ketul, dan Expense.

Dokumen ini wajib dibaca bersama:

```text
docs/PRODUCT_STOCK_MASTERDATA_SPEC.md
KGS_MINI_ERP_MIGRATION_BLUEPRINT.md
KGS_MULTI_COMPANY_DATA_STRUCTURE_SPEC.md
```

AI agent berikutnya tidak boleh menganggap field COA kosong sebagai keputusan bahwa accounting tidak dibutuhkan. Field tersebut sengaja ditunda sampai desain Finance dibahas secara khusus.

---

## 2. Keputusan yang Sudah Dikonfirmasi

1. Master Kategori Produk disiapkan untuk memiliki referensi COA.
2. Referensi COA kategori boleh kosong selama fase Produk dan Stok.
3. Ketika fase Finance aktif, mapping COA yang dibutuhkan akan menjadi wajib.
4. Aturan atau kategori transaksi menentukan pencatatan utama ke akun mana.
5. Mapping COA pada Kategori Produk hanya menjadi fallback ketika mapping transaksi tidak tersedia.
6. Produk tidak memiliki override COA sendiri pada scope saat ini.
7. Sistem tidak boleh menebak akun apabila mapping utama dan fallback sama-sama kosong.
8. Posting tanpa akun yang dapat di-resolve harus ditahan atau berstatus `ERROR` sampai mapping diperbaiki.
9. Sistem memakai accrual accounting: revenue/AR dan purchase/AP diakui saat business event posted, bukan menunggu payment.
10. Setiap company memperoleh template COA retail dasar; Finance/Company Admin dapat menambah atau menonaktifkan akun.
11. Kode COA diinput manual dan unik dalam company.
12. Jurnal operasional dibuat otomatis dari source document; jurnal posted immutable dan correction memakai reversal/replacement.
13. Manual Journal hanya dapat dibuat Finance, Company Admin, atau Super Admin serta wajib description dan evidence opsional.
14. Satu company memakai satu ledger; store dan warehouse adalah reporting dimension.
15. Currency scope awal hanya IDR.
16. Accounting period bulanan dapat dikunci Finance dan hanya dibuka kembali Company Admin/Super Admin dengan alasan/audit.
17. Account type memakai kelompok standar; prefix template `1xxx-8xxx` dapat diubah per company dan hierarchy awal maksimal tiga tingkat.
18. Normal balance otomatis dari account type tetapi dapat dioverride Finance/Company Admin/Super Admin dengan warning/audit.
19. Akun terpakai tidak dapat dihapus/diubah type; kode/nama masih editable dengan audit.
20. Opening Balance manual/Excel dibuat Finance dan di-approve Company Admin sebelum posting.
21. Automatic Journal valid langsung posted; Manual Journal approval configurable dengan maker-checker bila aktif.
22. Finance melihat journal balance dan melakukan full/partial reconciliation per COA tanpa mengubah jurnal posted.
23. Default reconciliation aktif untuk Kas, Bank, AR, AP, payment clearing, Customer Balance, dan Piutang Vendor Ketul.
24. Reconciliation mendukung many-to-many/partial dengan suggestion yang selalu dikonfirmasi Finance.
25. Mutasi Bank dapat diimport CSV/Excel melalui preview/mapping kolom, partial success, dan duplicate protection.
26. Biaya bank memakai adjustment journal; unreconcile hanya pada period terbuka atau setelah reopen berwenang.
27. Laporan minimum: Trial Balance, GL, Neraca, P&L, Cash/Bank Ledger, AR/AP Aging, dan Reconciliation Outstanding.
28. Accounting date memakai waktu business event posted; Stock Opname memakai tanggal posting Adjustment dan menyimpan counted_at terpisah.
29. Backdated hanya ke period open; event dari period locked masuk next open period sebagai PRIOR_PERIOD_ADJUSTMENT kecuali period direopen resmi.
30. Reopen diajukan Finance dan disetujui Company Admin/Super Admin; Manual Journal tidak melewati lock.
31. Pajak bersifat optional entitlement independen per company/modul (`SALES_TAX`, `PURCHASE_TAX`), hanya ditoggle Super Admin; Finance/Company Admin mengatur modul yang aktif.
32. Template COA dibuat lengkap dan akun yang tidak dipakai dapat dinonaktifkan.
33. Template leaf mencakup Kas/Bank/clearing, AR/AP, Customer Balance, Inventory, Equity, Sales/HPP, Expense, variance, rounding, bad debt/recovery, dan optional tax.
34. Kode/nama akun dapat diubah per company; system key/account type/function terkunci setelah digunakan.
35. Clearing Setor Kas memakai Aset Kas dalam Perjalanan, bukan akun Kewajiban.

---

## 3. Prioritas Resolusi COA

Urutan resolusi akun target:

```text
LEVEL 1 — Transaction Rule / Transaction Category
    ↓ jika mapping tidak tersedia
LEVEL 2 — Product Category COA Fallback
    ↓ jika mapping tidak tersedia
LEVEL 3 — Explicit Company Fallback yang compatible
    ↓ jika mapping tidak tersedia
LEVEL 4 — Posting ERROR / HOLD
```

Contoh konseptual:

```text
Transaksi penjualan Produk A
-> cek rule SALE_POSTED + kategori/metode transaksi
-> jika akun lengkap, gunakan mapping transaksi
-> jika akun tertentu tidak ada, cek fallback kategori Produk A
-> jika tetap tidak ditemukan, jangan post jurnal
```

Fallback company wajib dikonfigurasi eksplisit; sistem tidak boleh menebak akun. Missing/invalid required function menahan seluruh jurnal dan harus terlihat oleh Finance/Admin.

Taxonomy system key, account function, resolver, versioning, validation, dan retry queue mengikuti `TRANSACTION_CATEGORY_ACCOUNT_MAPPING_SPEC.md`.

---

## 4. Kandidat Mapping COA pada Kategori Produk

Daftar ini belum final dan harus dibahas kembali pada fase Finance:

```text
inventory_valuation_coa_id
cogs_coa_id
sales_income_coa_id
sales_return_coa_id
purchase_return_coa_id
stock_input_coa_id
stock_output_coa_id
stock_gain_coa_id
stock_loss_coa_id
```

Makna awal:

| Mapping | Penggunaan awal |
|---|---|
| Inventory Valuation | Nilai persediaan/aset inventory |
| COGS/HPP | Beban pokok penjualan |
| Sales Income | Pendapatan penjualan |
| Sales Return | Retur/pengurang penjualan |
| Purchase Return | Retur pembelian/persediaan |
| Stock Input | Barang diterima tetapi proses purchase/accounting belum final, bila dibutuhkan |
| Stock Output | Barang keluar sementara, bila dibutuhkan |
| Stock Gain | Selisih stok lebih dari opname/adjustment |
| Stock Loss | Selisih stok kurang, rusak, atau hilang |

Agent dilarang membuat seluruh field ini hanya berdasarkan daftar kandidat. Daftar final harus mengikuti flow transaksi dan chart of accounts yang disetujui.

---

## 5. Kandidat Transaction Rules

Transaction rule berpotensi dibedakan berdasarkan event berikut:

```text
SALE_POSTED
PAYMENT_RECEIVED
SALE_RETURN
PURCHASE_RECEIVED
PURCHASE_RETURN
STOCK_ADJUSTMENT_GAIN
STOCK_ADJUSTMENT_LOSS
STOCK_OPNAME_GAIN
STOCK_OPNAME_LOSS
TRANSFER_STOCK
OPENING_BALANCE
```

Catatan awal:

- Transfer antar gudang dalam company yang sama mungkin tidak mengubah total nilai persediaan, tetapi dapat membutuhkan pencatatan antar lokasi bila valuation per warehouse digunakan.
- Opening balance membutuhkan akun lawan yang ditentukan saat migrasi/onboarding.
- Penjualan membutuhkan mapping tambahan berdasarkan metode pembayaran: kas, bank/transfer, QRIS clearing, piutang, atau saldo pelanggan.
- Purchase receipt dan invoice fisik tidak selalu diproses bersamaan. Keputusan user adalah mengakui `AP Provisional` saat receipt, bukan menunggu pembayaran; detail subaccount dan rekonsiliasinya dibahas pada fase Finance.
- Adjustment dan opname gain/loss harus menyimpan alasan agar Finance dapat memilih rule yang benar bila diperlukan.

Daftar event di atas tetap berkembang, tetapi mapping POS dasar pada bagian berikut sudah berstatus `APPROVED`.

### 5.1 Mapping Jurnal POS Dasar yang Disetujui

Mapping berikut adalah template Transaction Rule per company, bukan pasangan account ID yang hard-coded. Finance, Company Admin, dan Super Admin dapat memilih akun lain yang valid. Setiap perubahan rule wajib versioned, diaudit, hanya berlaku untuk event baru, dan tidak mengubah jurnal historis.

| Source event | Debit default | Kredit default | Catatan |
|---|---|---|---|
| Sale Cash posted | Kas Laci | Penjualan | Hanya nominal Cash yang benar-benar diterima |
| Sale electronic belum verified | QRIS/Card/Transfer Clearing | Penjualan | Tetap outstanding untuk reconciliation |
| Electronic payment verified | Bank | QRIS/Card/Transfer Clearing | Jika verified sejak awal, Transaction Rule boleh langsung Debit Bank pada sale |
| Sale Tempo posted | Piutang Customer | Penjualan | Pelunasan/Invoice final tidak mem-posting revenue ulang |
| Tempo payment Cash | Kas Laci | Piutang Customer | Payment berikutnya menjadi source event terpisah |
| Tempo payment electronic belum verified | QRIS/Card/Transfer Clearing | Piutang Customer | Dipindahkan ke Bank setelah verified |
| HPP sale | HPP Penjualan | Persediaan Barang | Nilai berasal dari batch/FIFO aktual |
| Customer Balance digunakan | Customer Balance | Piutang Customer atau bagian settlement sale | Mengurangi liability, bukan diskon/revenue |
| Ketul Offset digunakan | Utang Ketul kepada Customer | Piutang Customer atau bagian settlement sale | Mengurangi utang Ketul, bukan diskon |

Satu sale dengan mixed payment boleh menghasilkan beberapa baris Debit untuk Cash, Bank/Clearing, Customer Balance, Ketul Offset, dan sisa Piutang. Nilai Kredit Penjualan dan jurnal HPP hanya dibuat satu kali dalam source journal yang sama. Pembayaran Tempo setelah sale memakai source journal terpisah.

Master metode pembayaran, store assignment, effective-dated fee, split payment, offline snapshot, dan reconciliation mengikuti `docs/PAYMENT_METHOD_MASTERDATA_SPEC.md`.

Gateway fee:

```text
Fee ditanggung company saat settlement:
Debit  Bank (net)
Debit  Biaya Administrasi Bank/Payment Gateway (actual fee)
Credit Payment Clearing (gross)

Fee dibebankan kepada Customer saat sale/payment:
Debit  Payment Clearing (nilai transaksi + surcharge)
Credit Penjualan/Piutang (nilai transaksi)
Credit Pendapatan Penggantian Biaya Pembayaran (surcharge)

Settlement customer-borne fee:
Debit  Bank (net)
Debit  Biaya Administrasi Bank/Payment Gateway (actual fee)
Credit Payment Clearing (gross)
```

- Fee dihitung per payment leg dan tidak mengubah HPP.
- Expected fee berasal dari snapshot rule; jurnal settlement memakai actual fee provider.
- Selisih expected/actual/gross/net menjadi reconciliation exception. Finance menyelesaikan melalui correction/reclassification append-only dan sistem tidak otomatis menganggapnya gain/loss.

Pricing dan diskon:

- Resolved Pricelist price adalah harga jual transaksi, bukan diskon akuntansi.
- Selisih Product fallback price terhadap resolved Pricelist disimpan untuk analitik, tetapi tidak otomatis didebit ke akun Potongan Penjualan.
- Diskon manual line/transaksi dicatat sebagai Debit Retur dan Potongan Penjualan, sedangkan Penjualan dikredit sebesar nilai sebelum diskon manual.
- Rounding naik dikredit ke Selisih Pembulatan Untung; rounding turun didebit ke Selisih Pembulatan Rugi.

Ketul intake:

```text
Debit  Persediaan Ketul
Kredit Utang Ketul kepada Customer
```

Utang Ketul kemudian diselesaikan melalui Cash, Transfer, konversi Customer Balance, atau `KETUL_OFFSET`. Sale tidak menghasilkan tax line ketika `SALES_TAX` nonaktif; ketika aktif, mapping tax-inclusive dipecah memakai Tax Rule yang berlaku.

Guardrail konfigurasi:

- Finance tidak boleh memilih akun dari company lain atau akun inactive.
- Fungsi settlement/asset/liability/revenue/COGS/inventory dibatasi ke account type yang kompatibel.
- Rule tidak lengkap atau menghasilkan jurnal unbalanced masuk `HOLD/ERROR`, bukan dipaksakan posted.
- Source document menyimpan rule version dan account snapshot yang digunakan.

---

## 6. Hubungan dengan Produk, UOM, dan Bundle

### 6.1 Produk stock

- Transaksi menyimpan harga, quantity, UOM, faktor konversi, base quantity, dan HPP sebagai snapshot.
- Perubahan harga atau kategori produk tidak boleh mengubah jurnal historis.
- Mapping COA historis harus dapat ditelusuri dari snapshot/rule version yang digunakan saat posting.
- Produk-Supplier menyimpan harga beli terakhir per UOM pembelian sebagai referensi Supplier Order.
- Harga beli awal pada Master Produk adalah nilai manual/fallback sebelum ada histori. UI membedakannya dari harga beli terakhir supplier utama.
- Harga referensi tersebut bukan HPP transaksi. Goods Receipt membentuk batch FIFO provisional dari snapshot order, kemudian invoice aktual mengoreksi valuation batch.
- HPP penjualan mengambil cost batch/FIFO yang dikonsumsi dan tidak membaca ulang harga master terbaru.

### 6.2 Harga per UOM

- Harga beli dan harga jual dapat berbeda untuk setiap UOM.
- Harga jual pada Produk-UOM adalah fallback. Pricelist Customer Eksklusif melewati Global; customer biasa memakai Global sebelum fallback produk, lalu diskon manual POS.
- Urutan nilai penjualan: resolved pricelist price -> line discount -> allocated transaction discount -> rounding.
- Transaksi wajib menyimpan snapshot base price, pricelist/rule, resolved price, diskon line, alokasi diskon transaksi, dan total final.
- Harga POS bersifat tax-inclusive ketika `SALES_TAX` aktif. Entitlement ini hanya dapat ditoggle Super Admin; Finance/Company Admin mengatur rule/rate/account setelah aktif. `PURCHASE_TAX` diatur independen. Resolver, calculation scope, inclusive/exclusive behavior, snapshot, return, dan Tempo mengikuti `docs/TAX_ENGINE_SPEC.md`.
- Jurnal menggunakan nilai transaksi aktual, bukan menghitung harga UOM besar dari harga UOM kecil.
- Quantity untuk valuation dikonversi ke base UOM, sedangkan nilai transaksi mengikuti harga UOM yang dipilih.
- Precision quantity, direct conversion snapshot, FIFO unit cost, weight boundary, dan valuation rounding mengikuti `docs/UOM_WEIGHT_VALUATION_SPEC.md`.
- Rounding POS berlaku pada grand total nilai penjualan, bukan quantity inventory.
- Rounding bersifat opsional untuk semua metode pembayaran dan menggunakan kelipatan Rp100.
- Pilihan transaksi adalah `NONE`, `DOWN`, atau `UP`; tidak ada policy arah paksa per store pada scope awal.
- Quantity, stock movement, dan HPP tetap memakai quantity transaksi yang valid sesuai precision UOM.
- Sales/payment menyimpan grand total sebelum/sesudah rounding, arah, increment, adjustment, dan actor agar selisih dapat diaudit.
- Selisih rounding tidak boleh tersembunyi; laporan Store Manager dan Finance menampilkan total DOWN, UP, serta net difference.
- Rounding naik memakai akun Selisih Pembulatan Untung dan rounding turun memakai Selisih Pembulatan Rugi; account ID aktual tetap configurable melalui Transaction Rule company.
- Full refund membalik nilai final dan rounding adjustment transaksi asal.
- Partial refund dapat memiliki rounding Rp100 tersendiri dan wajib menyimpan relasi ke sale asal.
- Laporan Finance membedakan rounding `SALE` dan `REFUND`; cumulative refund tidak boleh melebihi refundable balance.
- Refund dapat dibayar melalui Cash atau Transfer walaupun berbeda dari metode pembayaran asal; kedua metode wajib disimpan.
- Refund transfer menyimpan data tujuan/rekening dan referensi yang tersedia; bukti transfer bersifat opsional pada scope awal.
- Barang SALEABLE/DAMAGED yang kembali membuat stock-in dan reversal HPP sesuai cost asal. Barang DAMAGED masuk location/status DAMAGED; disposal berikutnya memakai Stock Adjustment terpisah.
- `NO_PHYSICAL_RETURN` tidak menambah stok dan tidak membalik HPP karena barang fisik tidak kembali.

### 6.3 Refund, Sales Return, dan Cancellation

- Sale `DRAFT/HOLD` dapat dibatalkan tanpa journal atau stock movement karena belum pernah posted.
- Sale yang sudah `POSTED` tidak boleh dihapus atau diedit menjadi unposted. Full cancellation menggunakan reversal yang mereferensikan source sale, payment, stock movement, HPP, tax, discount, dan rounding asal.
- Sales Return menggunakan Credit Note append-only. Return posted tidak mengubah snapshot invoice/sale asli.
- Untuk barang `SALEABLE` atau `DAMAGED` yang kembali, nilai stock-in dan reversal HPP memakai cost/FIFO snapshot transaksi asal.
- Untuk `NO_PHYSICAL_RETURN`, hanya sisi Credit Note/refund yang bekerja; tidak ada stock-in atau reversal HPP.

Mapping default Credit Note:

```text
Debit  Retur dan Potongan Penjualan
Kredit Piutang Customer             -- bila sale Tempo masih outstanding
   atau Utang Refund Customer       -- bila nilai sudah harus dikembalikan
```

Jika `SALES_TAX` aktif, Credit Note juga membalik Pajak Keluaran berdasarkan tax snapshot transaksi asal. Jika entitlement Sales mati, tax line tidak dibuat.

Realisasi Utang Refund:

| Settlement refund | Debit | Kredit |
|---|---|---|
| Cash | Utang Refund Customer | Kas Laci |
| Transfer verified | Utang Refund Customer | Bank |
| Transfer belum verified | Utang Refund Customer | Payment/Transfer Clearing sesuai rule company |
| Menjadi saldo | Utang Refund Customer | Customer Balance |

Retur Tempo mengurangi Piutang Customer terlebih dahulu. Jika nilai Credit Note melebihi outstanding, hanya selisihnya menjadi Utang Refund Customer untuk diselesaikan melalui Cash, Transfer, atau Customer Balance.

Full refund membalik diskon manual, rounding, tax bila aktif, revenue, stock, dan HPP sesuai snapshot transaksi asal. Partial refund dihitung per line/quantity yang diretur; refund rounding Rp100 boleh dibuat sebagai adjustment tersendiri, tetapi cumulative refund tidak boleh melebihi refundable balance.

Account ID aktual tetap configurable oleh Finance/Company Admin/Super Admin melalui Transaction Rule per company dengan guardrail type, balance, company scope, version, dan audit yang sama seperti sale.

Semua koreksi nilai dokumen posted mengikuti `DEBIT_CREDIT_NOTE_SPEC.md`. Note tidak mengubah stock; quantity hanya berubah melalui Sales Return/Purchase Return.

Reminder POS Expense/arus kas non-penjualan:

- Expense dan Cash In/Out harus menjadi event terpisah dari Sale/Refund.
- Cash Advance tidak digunakan sebagai jenis bisnis terpisah. Uang muka operasional dicatat melalui satu Expense dengan requested/disbursed amount, actual expense, returned amount, dan outstanding.
- Event posted akan memengaruhi cash drawer/Ringkasan Sesi, tetapi tidak membuat stock movement.
- Approval configurable: Company Admin mengatur default company, Store Manager dapat override store, dan Super Admin memiliki seluruh authority. Approval nonaktif auto-approve; jika aktif, Cash baru keluar setelah approval.
- Transfer/Bank baru dianggap dibayar setelah Finance/Company Admin/Super Admin mengonfirmasi eksekusi. Cashier mengisi actual/return dan Store Manager/Finance mereview settlement.
- Expense outstanding tidak memblokir tutup sesi dan tetap dibawa sebagai dokumen terbuka dengan reference sesi asal.
- Kategori Expense menentukan akun biaya; payment method menentukan sisi Kas/Bank. COA category boleh kosong sementara tetapi wajib valid sebelum financial posting aktif, dan snapshot rule disimpan pada transaksi.
- Scope awal tidak memakai approval nominal bertingkat. Additional disbursement/settlement/return memakai event append-only dan responsible party wajib disimpan.
- Return Cash boleh masuk sesi berikutnya dengan reference Expense/sesi asal. Offline Cash Expense hanya `PENDING_SYNC` saat approval nonaktif; approval aktif/Transfer hanya Draft.
- Cancel hanya sebelum disbursement. Full return tanpa biaya menjadi `SETTLED_NO_EXPENSE`; correction settled memakai reversal + replacement yang dibuat Finance dari request Store Manager.
- Settlement due date opsional dan overdue hanya warning. Outstanding report/export tetap tersedia lintas sesi.
- Cash In tidak membutuhkan approval; shortage top-up mempertahankan original shortage dan menampilkan residual variance.
- Exceptional Customer Balance settlement memakai kategori khusus dan mandatory Finance/Company Admin approval walaupun approval umum nonaktif.

Mapping Expense:

```text
Saat dana dicairkan sebelum actual expense final:
Debit  Outstanding Expense Operasional
Credit Kas Laci / Bank

Saat actual expense diselesaikan:
Debit  Expense sesuai Kategori Expense
Credit Outstanding Expense Operasional

Saat sisa dana dikembalikan:
Debit  Kas Laci / Bank
Credit Outstanding Expense Operasional
```

- Nominal disbursement memakai `disbursed_amount`; nilai Expense hanya `actual_expense`.
- Jika expense langsung diketahui dan dibayar sekaligus, Transaction Rule boleh meringkas menjadi Debit Expense dan Kredit Kas/Bank sambil tetap menyimpan requested/disbursed/actual snapshot.
- Additional disbursement menambah Debit Outstanding Expense dan Kredit Kas/Bank dalam Expense yang sama.
- Expense `SETTLED_NO_EXPENSE` harus menghasilkan pengembalian penuh sehingga outstanding menjadi nol tanpa Expense line.
- Account ID aktual configurable oleh Finance/Company Admin/Super Admin per company; kategori menentukan sisi Expense dan metode menentukan Kas/Bank.

Keputusan operasional sesi dan Setor Kas:

- Opening cash diinput manual oleh Cashier sebagai physical count dan tidak otomatis membuat journal/Cash In.
- Dana tambahan dari Brankas wajib memakai `DRAWER_TOP_UP`: Debit Kas Laci dan Kredit Kas Besar/Brankas.
- Closing membandingkan expected cash dari event posted dengan actual cash fisik yang diinput Cashier dan menampilkan selisih langsung.
- Tambahan uang Cashier untuk menutup kekurangan harus menjadi cash-in/settlement terpisah agar audit selisih tidak hilang.
- Ringkasan metode non-cash berasal dari transaksi posted dan tidak diinput ulang saat closing.
- Cashier dapat mengunduh workbook Excel sesi sendiri, tetapi tidak melihat HPP, cost batch, atau COA internal.
- Setor Kas dapat menggabungkan beberapa sesi `CLOSED` dalam company/store yang sama.
- Expected deposit per sesi adalah actual closing cash dikurangi float sesi berikutnya yang diinput Cashier saat membuat Setor Kas.
- Cashier menginput actual deposit total; sistem menyimpan expected total dan `deposit_variance` tanpa mewajibkan angka sama.
- Submit mengunci seluruh sesi terpilih. Finance approve/reject nominal aktual yang diserahkan/disetor; Company Admin/Super Admin mewarisi kewenangan approval. Store Manager hanya memantau sesuai scope.
- Approval menyelesaikan seluruh sesi terpilih walaupun ada variance. Tidak ada partial-deposit balance; kekurangan/kelebihan menjadi exception Finance.
- Jika tujuan Bank, approval Finance membersihkan Kas Laci sebesar expected deposit, mendebit Kas dalam Perjalanan sebesar nominal aktual, dan membukukan selisih ke akun kontrol. Saat mutasi Bank dikonfirmasi, dibuat Debit Bank dan Kredit Kas dalam Perjalanan sebesar nominal aktual.
- Jika Finance baru meng-approve setelah mutasi Bank cocok, kedua event boleh diposting dalam satu proses atomic tetapi reference clearing tetap disimpan.
- Jika tujuan Brankas, approval mendebit Kas Besar/Brankas sebesar nominal aktual, membersihkan Kas Laci sebesar expected deposit, dan membukukan selisih ke akun kontrol tanpa Bank clearing.
- Under-deposit masuk `Selisih Setoran Kurang dalam Investigasi`; over-deposit masuk `Selisih Kas Lebih Belum Diselesaikan`. Deposit variance tidak otomatis dibukukan sebagai rugi/pendapatan.
- Detail lifecycle, allocation, responsible party, dan resolusi mengikuti `DEPOSIT_VARIANCE_RESOLUTION_SPEC.md`.
- Bukti setoran mengikuti konfigurasi REQUIRED/OPTIONAL per company/store.

Cash variance saat closing:

```text
Shortage diakui:
Debit  Piutang Kekurangan Kasir
Credit Kas Laci

Cashier melakukan top-up:
Debit  Kas Laci
Credit Piutang Kekurangan Kasir

Shortage resmi tidak ditagih:
Debit  Beban Selisih Kas
Credit Piutang Kekurangan Kasir

Overage belum diselesaikan:
Debit  Kas Laci
Credit Selisih Kas Lebih Belum Diselesaikan
```

Finance menyelesaikan overage ke Pendapatan Lain, refund, atau correction source transaction melalui dokumen append-only. Overage tidak otomatis dianggap pendapatan saat sesi ditutup.

Deposit variance saat approval Setor Kas:

```text
Matched:
Debit  Kas dalam Perjalanan / Kas Besar     expected
Credit Kas Laci                             expected

Under-deposit:
Debit  Kas dalam Perjalanan / Kas Besar     actual
Debit  Selisih Setoran Kurang Investigasi   expected - actual
Credit Kas Laci                             expected

Over-deposit:
Debit  Kas dalam Perjalanan / Kas Besar     actual
Credit Kas Laci                             expected
Credit Selisih Kas Lebih Belum Diselesaikan actual - expected
```

Session cash variance membandingkan expected session dengan actual closing, sedangkan deposit variance membandingkan expected deposit dari actual closing yang sudah diterima dengan setoran aktual. Satu selisih tidak boleh diakui pada kedua source event.

Customer Balance:

- Workflow hanya aktif bila entitlement company `customer_balance_enabled = true`, dan hanya Super Admin yang dapat mengubah entitlement tersebut.
- Penonaktifan dengan outstanding liability mengubah entitlement menjadi `WIND_DOWN`: credit/refund-to-balance baru diblokir, sedangkan pemakaian saldo lama, koreksi, dan exceptional settlement tetap berjalan. Setelah liability nol, status otomatis `DISABLED`; ledger historis tetap tersedia untuk audit.
- Customer Balance adalah kewajiban company kepada Customer, berlaku di seluruh store dalam company, tidak kedaluwarsa, dan tetap tersimpan ketika Customer inactive.
- Saldo dapat berasal dari kelebihan Transfer/Cash yang dititipkan, nilai Customer Intake Ketul, refund ke saldo, atau koreksi berwenang.
- Saldo hanya dapat digunakan Customer yang sama sebagai settlement pembelian dan tidak boleh dicairkan langsung melalui menu saldo.
- Seluruh saldo dari source lama wajib diselesaikan pada transaksi berikutnya; credit baru dari transaksi berjalan dicatat sebagai source event baru. Jika saldo lama melebihi amount due, checkout diblokir sampai nilai belanja cukup menyerap seluruh saldo lama; tidak ada negative amount due atau rollover saldo lama.
- Urutan settlement adalah `KETUL_OFFSET -> CUSTOMER_BALANCE -> payment eksternal`; saldo mengurangi amount due tanpa mengubah revenue.
- Setiap mutasi memakai ledger append-only dengan source document dan idempotency key; `current_balance` hanya ringkasan/cache.
- Koreksi memakai reversal dan event pengganti, bukan UPDATE/DELETE ledger lama.
- Cashier mengajukan koreksi dan Finance melakukan approval/reject. Company Admin/Super Admin mewarisi approval sesuai hierarchy; Store Manager tidak menjadi approver koreksi saldo.
- Refund split mengembalikan bagian Customer Balance terlebih dahulu. Sisa refund boleh dibayar Cash, Transfer, atau Customer Balance sesuai pilihan Customer dan tetap mengikuti approval refund.
- Jika source credit yang hendak direversal sudah digunakan transaksi lain, cancellation langsung diblokir dan diselesaikan melalui financial correction/reversal.
- Penyelesaian khusus Customer inactive melalui Produk atau Expense/exceptional settlement wajib mengurangi liability dengan referensi ledger yang jelas. Dokumen dibuat Finance/Store Manager dan di-approve Finance/Company Admin sesuai konfigurasi; Cashier tidak dapat menjalankan. Mapping Cash/Transfer dan Produk sudah disetujui pada bagian berikut.
- Finance melihat Customer Statement, total liability per company, dan aging source credit `0-30`, `31-60`, `61-90`, `>90 hari`. Aging hanya untuk monitoring dan tidak menyebabkan expiry.

Mapping koreksi dan exceptional settlement:

- Penambahan Customer Balance: Kredit Customer Balance dan Debit akun correction/source yang valid.
- Pengurangan Customer Balance: Debit Customer Balance dan Kredit akun correction/source yang valid.
- Cashier mengajukan koreksi dan Finance meng-approve; account correction dipilih Finance dan tidak otomatis menjadi Income/Expense tanpa source/alasan.
- Exceptional Cash/Transfer settlement: Debit Customer Balance dan Kredit Kas/Bank. Ini penyelesaian liability, bukan Expense P&L baru, walaupun memakai dokumen/kategori khusus untuk kontrol approval.
- Exceptional Product settlement memakai Debit Customer Balance, Kredit Penjualan, Debit HPP, dan Kredit Persediaan; stock/FIFO serta harga transaksi berjalan normal.
- Entitlement `WIND_DOWN/DISABLED` tidak menghapus liability, ledger, statement, atau hak menyelesaikan saldo lama melalui workflow berwenang.

Ketul:

- Ketul adalah tiang kebab dengan beberapa Produk STOCK pada category Ketul, UOM PCS, dan gudang toko biasa.
- Cashier menginput harga acquisition Customer dan harga jual Vendor secara manual per transaksi.
- Penerimaan Customer boleh standalone; settlement dapat di-split Cash, Transfer, dan Customer Balance.
- Nilai Ketul dapat meng-offset pembayaran Customer tetapi tidak boleh dicatat sebagai diskon komersial biasa tanpa source document.
- Offset diterapkan setelah sale final price/rounding sehingga revenue sale tidak berubah.
- `KETUL_OFFSET` diperlakukan sebagai settlement/tender non-cash yang menutup sebagian invoice, bukan diskon atau pengurang revenue. Total tender tetap direkonsiliasi ke grand total final.
- Penjualan Ketul ke Vendor memakai Master Supplier existing sebagai counterparty, menghasilkan uang masuk, dan dilaporkan terpisah dari retail sale.
- Customer intake membuat FIFO batch dari manual acquisition value yang boleh nol.
- Customer Intake posted mencatat Debit Persediaan Ketul dan Kredit Utang Ketul kepada Customer berdasarkan manual acquisition value, sekaligus membuat FIFO layer.
- Settlement Utang Ketul mendukung Cash, Transfer, Customer Balance, dan `KETUL_OFFSET`, termasuk split/partial. Cash/Transfer mengkredit Kas/Bank; konversi saldo mengkredit Customer Balance; Offset menjadi tender non-cash pada sale.
- Dispatch memindahkan sent qty dari gudang STORE aktif ke `TRANSIT` dengan FIFO cost tetap dan tanpa revenue/HPP. Cashier atau Finance dapat mencatat beberapa hasil Vendor parsial sebagai Draft.
- Vendor Result hanya posted setelah accepted quantity dan nominal aktual tersedia serta dikonfirmasi Finance/Company Admin/Super Admin. Saat posted, accepted qty menjadi stock-out dan memakai HPP FIFO; rejected qty kembali active/`DAMAGED`, sedangkan pending qty tetap di `TRANSIT`.
- Nilai aktual Vendor mendukung `DOCUMENT_TOTAL` atau `PER_LINE`. Pada mode total dokumen, revenue dialokasikan proporsional berdasarkan estimated accepted line dan disimpan sebagai snapshot.
- Jika seluruh estimated accepted line nol, fallback alokasi memakai proporsi accepted quantity.
- Selisih pembulatan alokasi ditempelkan ke accepted line bernilai terbesar agar total line sama dengan `DOCUMENT_TOTAL`.
- Finance atau Company Admin/Super Admin boleh mengoreksi hasil Vendor yang diinput Cashier sebelum final confirmation. Revision wajib append-only dan menyimpan nilai before/after, actor, waktu, serta alasan opsional.
- Vendor Result posted mencatat Debit Piutang Vendor Ketul, Kredit Penjualan Ketul, Debit HPP Ketul, dan Kredit Persediaan Ketul.
- Pembayaran Cash Vendor masuk drawer sesi Cashier yang menerima uang dan mendebit Kas Laci; Transfer mendebit Bank; keduanya mengkredit Piutang Vendor Ketul.
- Cash payout Customer Intake mengurangi drawer sesi penerima. Customer Balance dan `KETUL_OFFSET` tidak memengaruhi drawer.
- Cash wajib terkait sesi penerima dan source payment document; Transfer wajib terkait referensi rekening/bank.
- Jika tidak ada sesi `OPEN`, Finance atau Company Admin/Super Admin boleh membuat Backoffice Cash Receipt tanpa drawer/sesi palsu. Receipt wajib terkait source Vendor result dan menyimpan actor, waktu, nominal, serta destination cash account.
- Backoffice Cash Receipt buatan Finance langsung confirmed dan tidak membutuhkan approval Finance kedua.
- Bukti Vendor configurable `REQUIRED`/`OPTIONAL` berdasarkan company default dan optional store override.
- Company Admin mengelola default bukti dan Store Manager dapat membuat store override sesuai assignment.
- Payment dan Vendor result berelasi many-to-many: satu pembayaran dapat menyelesaikan beberapa result dan satu result dapat dibayar bertahap. Sisa nominal menjadi outstanding Vendor.
- Finance mengonfirmasi Vendor Result untuk accrual revenue/receivable; konfirmasi payment menjadi event terpisah yang mengurangi Piutang Vendor Ketul. Outstanding memakai due date manual dan aging bucket `Belum Jatuh Tempo`, `1-30`, `31-60`, `61-90`, serta `>90 hari`.
- Result yang baru mengetahui quantity tetapi belum memiliki nominal aktual tetap pending dan tidak membuat journal final.
- Quantity rejected sebelum Result posted hanya kembali ke active/`DAMAGED` dan tidak membuat revenue/HPP reversal.
- Jika Vendor mengembalikan accepted goods setelah Result posted, Credit Note mencatat Debit Retur Penjualan Ketul dan Kredit Piutang Vendor Ketul atau Utang/Kredit Vendor Ketul bila sudah dibayar; stock return mencatat Debit Persediaan Ketul dan Kredit HPP Ketul memakai FIFO/cost asal.
- Utang/Kredit Vendor Ketul diselesaikan melalui Cash/Transfer refund atau offset terhadap Piutang Vendor Ketul berikutnya.
- Setelah confirmation, koreksi nominal tanpa perubahan quantity memakai financial reversal. Koreksi quantity wajib membuat financial reversal dan stock/FIFO reversal yang saling mereferensikan.
- Laporan Finance Ketul memiliki tab Customer Intake, Vendor Dispatch/Result, dan Outstanding/Settlement dengan filter lengkap serta export Excel.
- Cashier tidak dapat melihat HPP/margin dan hanya export transaksinya sendiri; Store Manager mengikuti store scope, sedangkan Finance/Admin mengikuti company scope.
- Dokumen otomatis `CLOSED` setelah seluruh quantity direkonsiliasi, transit kosong, settlement lunas, dan tidak ada workflow lanjutan.
- Cash Ketul yang terkait sesi wajib masuk expected cash, export sesi, dan Setor Kas. Backoffice Cash Receipt tanpa sesi masuk kas Backoffice dan tidak boleh masuk rekonsiliasi drawer Kasir.
- Quantity status dipisahkan dari settlement status. Finance tidak boleh menyimpulkan piutang lunas hanya karena quantity sudah `RECONCILED`.
- Koreksi result yang sudah membuat stock/HPP memakai delta/reversal movement dan financial reversal; histori lama immutable.
- Semua posting memakai idempotency key. Dokumen `CLOSED` immutable dan hanya dikoreksi melalui reversal document.
- Vendor inactive tetap dapat menyelesaikan outstanding lama, tetapi tidak dapat dipakai membuat dispatch baru.

### 6.3 Bundle

- Harga jual bundle diisi manual.
- Bundle hanya boleh berisi komponen produk `STOCK`; nested bundle tidak didukung.
- HPP bundle berasal dari HPP komponen aktual.
- Pengurangan persediaan terjadi pada produk komponen, bukan produk bundle virtual.
- Snapshot komposisi dan HPP komponen diperlukan agar jurnal historis dapat diaudit.
- Promo 2+1 melalui Bundle tetap mengakui HPP seluruh komponen fisik walaupun revenue bundle setara dua item.
- Pada MVP, revenue journal masuk satu nilai ke category/account Bundle. Component allocation adalah snapshot analitik dan tidak membuat revenue kedua.
- Alokasi komponen memakai standalone resolved selling value, lalu actual HPP, lalu base quantity sebagai fallback. Diskon, tax, dan rounding mengikuti weight yang sama dengan residual deterministik.
- Future component-category journal split bersifat optional/effective-dated per company. Return dan Credit Note selalu memakai original allocation snapshot.
- Detail kontrak mengikuti `BUNDLE_REVENUE_ALLOCATION_SPEC.md`.

---

## 7. Hubungan dengan Inventory Documents

### Purchase receipt / Konfirmasi order

Kontrak tolerance, status matching, allocation many-to-many, dan residual AP Provisional mengikuti `docs/PURCHASE_MATCHING_TOLERANCE_SPEC.md`.

Flow bisnis yang sudah dikonfirmasi:

```text
Stock Request dari POS
-> Supplier Order oleh Store Manager
-> Goods Receipt parsial/penuh oleh Kasir di POS
-> AP provisional
-> Finance mencocokkan invoice fisik
-> Finance menginput nilai aktual
-> AP final
-> Payment
```

Keputusan bisnis:

- Receipt posted langsung menambah accepted stock.
- Receipt posted membentuk AP provisional sebelum pembayaran.
- Nilai provisional menggunakan accepted quantity dan harga estimasi Supplier Order.
- Harga estimasi Supplier Order secara default berasal dari relasi Produk-Supplier, tetapi dapat diubah Store Manager dan wajib disimpan sebagai snapshot.
- Harga aktual dapat berbeda dan diinput Finance berdasarkan invoice fisik.
- Invoice aktual yang sudah divalidasi memperbarui harga beli terakhir pada relasi Produk-Supplier tanpa mengubah snapshot dokumen historis.
- Supplier Order dan Goods Receipt tidak boleh memperbarui field harga beli terakhir; keduanya hanya menyimpan snapshot provisional.
- Selisih nilai harus disimpan sebagai adjustment yang dapat diaudit.
- Pembayaran mengurangi AP final, bukan langsung membebankan purchase menjadi paid.
- Finance menggunakan three-way reconciliation: Supplier Order, surat jalan/Goods Receipt, dan invoice fisik.
- Invoice matching bersifat fleksibel/many-to-many. Satu invoice boleh mencakup beberapa order/receipt, dan satu order/receipt boleh dialokasikan ke beberapa invoice bertahap.
- Matching hanya boleh menggabungkan dokumen dari company dan supplier yang sama. Allocation quantity dan nilai per line wajib disimpan untuk mencegah double matching.
- Over-receipt tetap menambah stok dan AP provisional berdasarkan accepted quantity aktual, lalu ditandai sebagai exception untuk reconciliation.
- Short receipt, damaged quantity, rejected quantity, dan Purchase Return juga terlihat sebagai exception/adjustment pada proses matching.
- Field rusak/ditolak bersifat opsional pada POS. Barang rusak yang diterima masuk stok `DAMAGED` dan AP provisional; barang yang ditolak tidak masuk stok/AP.

Target jurnal konseptual saat receipt posted:

```text
Debit  Persediaan (nilai estimasi receipt)
Credit AP Provisional (nilai estimasi receipt)
```

- Nilai hanya mencakup accepted quantity aktual. Over-receipt yang diterima tetap masuk Persediaan/AP Provisional dan diberi exception flag.
- Barang `DAMAGED` yang diterima masuk inventory location/status DAMAGED serta AP Provisional.
- Barang `REJECTED` tidak menambah stok, FIFO, atau AP.

Saat invoice fisik divalidasi Finance:

```text
Debit  AP Provisional                 -- nilai estimasi receipt yang dialokasikan
Debit/Credit Persediaan               -- variance quantity batch yang masih tersedia
Debit/Credit Selisih Harga Beli/HPP   -- variance quantity yang sudah terjual
Credit AP Final                       -- nilai invoice aktual
```

- Sisa quantity pada FIFO layer direvaluasi secara proporsional berdasarkan harga invoice aktual.
- Bagian quantity yang sudah terjual tidak membuka atau mengubah jurnal sale lama; variance masuk akun Selisih Harga Beli/HPP.
- Allocation invoice ke receipt/batch wajib menyimpan estimated amount, actual amount, remaining quantity, sold quantity, inventory variance, dan HPP variance.
- Akun `5130 Selisih Harga Beli/HPP` adalah template. Finance dapat memilih account lain yang kompatibel melalui Transaction Rule company.

Saat pembayaran:

```text
Debit  AP Final
Credit Bank
```

- Pembayaran mendukung partial, satu payment untuk beberapa invoice, dan satu invoice untuk beberapa payment.
- Allocation payment many-to-many harus append-only dan direkonsiliasi Finance.
- Cash payment supplier tidak menjadi default scope; bila kelak diaktifkan wajib memakai source cash/drawer yang eksplisit.
- Overpayment tidak membuat AP negatif. Selisih didebit ke `Uang Muka Supplier` dan dapat dialokasikan ke invoice berikutnya atau dikembalikan supplier melalui Transfer.

Komponen invoice dan landed cost:

- Invoice menyimpan harga barang, diskon supplier, ongkir/biaya tambahan, pajak, dan grand total secara terpisah.
- Diskon per line mengurangi acquisition cost line terkait. Diskon total invoice dialokasikan proporsional berdasarkan nilai line sebelum diskon; allocation dan rounding disimpan sebagai snapshot.
- Finance memilih treatment ongkir/biaya tambahan: kapitalisasi ke inventory atau Expense.
- Landed cost yang dikapitalisasi dapat dialokasikan berdasarkan `VALUE`, `QUANTITY`, `WEIGHT`, atau `MANUAL_PER_LINE`.
- Allocation berdasarkan berat memakai snapshot berat Produk/UOM pada invoice, bukan membaca ulang master setelah posting.
- Bagian landed cost untuk quantity yang masih tersedia menambah remaining FIFO layer/Persediaan. Bagian quantity yang sudah terjual masuk Selisih Harga Beli/HPP tanpa mengubah sale journal lama.

Pajak pembelian:

- `PURCHASE_TAX` dapat aktif walaupun `SALES_TAX` nonaktif. Entitlement keduanya di-toggle terpisah oleh Super Admin per company.
- Jika `PURCHASE_TAX` nonaktif, invoice tidak membuat tax line khusus; nilai yang tidak dapat dipisahkan menjadi bagian acquisition cost atau Expense sesuai rule Finance.
- Pajak yang dapat dikreditkan didebit ke Pajak Masukan. Pajak non-creditable masuk acquisition cost atau Expense sesuai Tax Rule.
- Invoice menyimpan tax base, amount, rate, rule, recoverability, dan account snapshot.

Approval dan eksekusi Supplier Payment:

- Approval payment configurable per company.
- Bila aktif, Finance menjadi maker dan Company Admin approver; maker tidak boleh approve payment sendiri. Super Admin dapat menjalankan seluruh tahap sesuai scope.
- Bila nonaktif, Finance dapat mengeksekusi payment setelah seluruh validasi lolos.
- Status minimum: `DRAFT -> APPROVED -> PAID`, dengan terminal exception `FAILED` atau `CANCELED` sebelum paid.
- Journal AP payment hanya dibuat saat payment benar-benar `PAID`, bukan saat Draft/Approved.
- Referensi bank wajib. Bukti transfer configurable `REQUIRED` atau `OPTIONAL` per company.

Receipt langsung mengakui AP Provisional, invoice matching fleksibel/many-to-many, alokasi price variance, diskon supplier, landed cost, pajak pembelian modular, serta Supplier Payment sudah disetujui.

Purchase Return:

- Jika invoice belum final, return posted: Debit AP Provisional dan Kredit Persediaan menggunakan FIFO layer receipt asal.
- Jika invoice sudah final tetapi belum dibayar, Supplier Credit Note mengurangi AP Final.
- Jika invoice sudah dibayar atau nilai return melebihi AP terbuka, selisih menjadi `Piutang Refund Supplier`.
- Piutang Refund Supplier diselesaikan melalui Transfer supplier ke Bank atau offset terhadap AP invoice berikutnya.
- Return tidak menghapus receipt/invoice asli; Finance menyimpan reference dan reversal/adjustment.
- Invoice/jurnal final atau sudah dibayar tidak diubah oleh return. Dokumen credit note/refund/offset wajib mereferensikan Purchase Return dan invoice asal.
- Return hanya dapat mengambil line dari Goods Receipt asal. Store Manager atau Company Admin/Super Admin mem-posting ketika barang benar-benar diserahkan kepada supplier.
- Return quantity tidak boleh melebihi net accepted quantity setelah memperhitungkan return sebelumnya.

Authority dan immutability:

- Finance melakukan three-way matching dan memvalidasi invoice fisik. Company Admin/Super Admin memiliki authority lebih tinggi sesuai scope.
- Invoice final dan journal posted immutable. Koreksi memakai Supplier Debit Note, Supplier Credit Note, atau reversal/replacement dengan reference dokumen asli.
- Allocation, original tax snapshot, approval, dan guard nilai Supplier Note mengikuti `DEBIT_CREDIT_NOTE_SPEC.md`.
- Transaction Rule account tetap configurable per company dan perubahan hanya berlaku untuk event baru.

Referensi pembayaran supplier:

- Master Supplier menyimpan satu rekening utama: nama bank, nomor rekening, dan nama pemilik rekening.
- Finance dapat menyalin nomor rekening tersebut dari layar invoice/payment tanpa mencari ulang di luar sistem.
- Rekening supplier adalah referensi, bukan bukti bahwa pembayaran telah dilakukan. Payment tetap memerlukan pencatatan transaksi dan kontrol Finance.
- Perubahan rekening supplier wajib diaudit; kebutuhan approval perubahan rekening dibahas pada fase Finance/security.

### Sale

Saat sale posted, sistem berpotensi menghasilkan dua kelompok:

```text
Debit  Kas/Bank/QRIS/Piutang
Credit Penjualan

Debit  HPP
Credit Persediaan
```

Mapping pembayaran berasal dari rule transaksi/metode pembayaran. Mapping pendapatan, HPP, dan persediaan dapat menggunakan fallback kategori produk jika rule transaksi tidak menyediakan akun tersebut.

Keputusan dari fase Inventory:

- Stok negatif tidak diizinkan.
- Jika satu atau lebih line kekurangan stok, seluruh penjualan disimpan sebagai `DRAFT`.
- Penjualan `DRAFT` tidak membuat stock movement dan tidak boleh membuat jurnal final.
- Draft akibat shortage maupun Hold Order manual tetap berupa catatan sementara, tidak mereservasi stok, dan tidak membuat financial event/jurnal sampai berhasil diposting.
- Metode/nominal pembayaran pada draft bukan penerimaan uang dan wajib dikonfirmasi ulang saat posting; Finance hanya menerima transaksi/payment final yang berhasil diposting.
- Payment final tidak dibuat selama penjualan masih `DRAFT`. Data pembayaran yang sudah diinput hanya boleh tersimpan sebagai data draft checkout.
- Penjualan `DRAFT` tidak membuat financial event dan tidak masuk laporan keuangan sebagai transaksi posted.
- Jurnal hanya dibuat setelah transaksi berhasil dikonfirmasi/diposting secara atomic bersama perubahan stok.

#### Sale TEMPO, Pro Forma, dan Piutang

- Cashier boleh memilih TEMPO untuk Customer terdaftar tanpa approval Store Manager. Keputusan, warning, dan actor dicatat untuk audit serta evaluasi Finance.
- Finance mengatur limit kredit dan default term secara manual per Customer. Cashier memilih due date aktual pada checkout; Finance dapat override due date setelah posted dengan audit nilai lama/baru, alasan, actor, dan waktu. Limit terlampaui atau overdue menghasilkan warning, bukan hard block.
- Existing outstanding tidak memblokir sale TEMPO baru. POS memperlihatkan jumlah dokumen dan total piutang terbuka; Cashier dapat melanjutkan dengan acknowledgement yang diaudit.
- Saat sale TEMPO online diposting dan barang diserahkan, sistem langsung mengakui Penjualan, HPP, Persediaan, dan Piutang walaupun dokumen customer masih bernama Pro Forma.
- Pro Forma berfungsi sebagai tagihan sementara dan statement outstanding, bukan bukti lunas dan bukan penunda pengakuan transaksi yang sudah terjadi.
- Payment dapat parsial/cicilan dan split method. DP pada checkout adalah allocation pertama dan hanya sisanya membentuk piutang.
- Semua payment TEMPO bersumber dari menu Pembayaran Tempo POS dan diinput Cashier. Finance tidak memiliki jalur payment paralel; Finance memantau, merekonsiliasi, serta membuat correction/override berwenang dengan reference ke payment POS.
- Satu payment dapat dialokasikan ke beberapa Pro Forma Customer yang sama. Sistem menyarankan oldest-first; dokumen awal menjadi `PAID`, sedangkan nominal tersisa yang tidak cukup pada dokumen berikutnya menjadi cicilan dan menghasilkan `PARTIALLY_PAID`.
- Setiap allocation payment mengurangi piutang secara append-only serta menyimpan source Pro Forma, receipt, sesi Cashier, actor, waktu, dan saldo outstanding.
- Overpayment tidak membuat saldo piutang negatif. Selisih masuk Customer Balance bila entitlement aktif dan dipilih Customer; selain itu selisih dikembalikan Cash/Transfer serta direkonsiliasi pada sesi/metode terkait.
- Invoice Penjualan final hanya diterbitkan saat outstanding nol. Event penerbitan Invoice final tidak boleh mencatat Penjualan/HPP/Persediaan/Piutang kedua kali.
- Invoice final menyimpan tanggal transaksi asli serta tanggal pelunasan/penerbitan. Nomor Pro Forma tetap menjadi referensi historis setelah nomor Invoice final dibuat.
- Retur sale TEMPO posted membuat Credit Note yang mengurangi piutang. Jika sudah lunas, nilai retur menjadi refund Cash/Transfer/Customer Balance. Pembatalan penuh hanya setelah barang kembali dan memakai reversal sale, stok, HPP, serta piutang tanpa menghapus dokumen lama.
- Koreksi harga posted menggunakan Debit Note/Credit Note oleh Finance dan tidak mengubah Pro Forma atau snapshot harga asli.
- Customer Debit/Credit Note memakai posted source, allocation append-only, dan original tax snapshot sesuai `DEBIT_CREDIT_NOTE_SPEC.md`; refund/payment tetap event terpisah.
- Write-off hanya dibuat/diajukan Finance dan diposting setelah approval Company Admin. Maker-checker wajib; Company Admin tidak boleh membuat sekaligus menyetujui dokumen yang sama.
- Write-off dapat parsial atau penuh per Pro Forma. Full write-off memakai status `WRITTEN_OFF`, bukan `PAID`, dan tidak menerbitkan Invoice final. Partial write-off mengurangi outstanding melalui allocation append-only.
- Payment sesudah write-off menjadi event Recovery Piutang yang mereferensikan Pro Forma/write-off lama tanpa membuka atau mengubah jurnal historis.
- POS hanya menampilkan warning histori write-off kepada Cashier; detail akun, alasan internal, dan approval hanya tersedia untuk role Finance/Company Admin sesuai scope.
- Reminder overdue tersedia in-app pada POS/Backoffice; Cashier atau Finance melakukan follow-up manual tanpa WhatsApp/email otomatis pada scope awal.
- Collection assignment, bucket operasional, Promise to Pay, due-date correction, write-off candidate, Statement, dan retention/export boundary mengikuti `COLLECTION_AND_CUSTOMER_STATEMENT_SPEC.md`.
- Settlement status (`OPEN/PARTIALLY_PAID/PAID/CANCELED/CREDIT_NOTED`) disimpan terpisah dari due status (`NOT_DUE/OVERDUE`). Aging membaca outstanding dan due date, bukan mengganti settlement status.
- Customer Statement dapat difilter per Customer, store, tanggal, settlement status, dan due status. Isinya mencakup Pro Forma, DP/cicilan, allocation, Debit/Credit Note, retur, write-off/recovery, Invoice final, due date, serta saldo awal/berjalan/akhir; output Excel/PDF.

Mapping write-off/recovery:

```text
Write-off parsial/penuh:
Debit  Beban Piutang Tak Tertagih
Credit Piutang Customer

Recovery setelah write-off:
Debit  Kas / Bank / Payment Clearing
Credit Recovery Piutang Write-off
```

- Finance menjadi maker dan Company Admin approver; maker-checker wajib dan tidak mengikuti approval umum. Super Admin memiliki seluruh authority sesuai scope.
- Recovery adalah event baru, tidak membuka AR atau journal write-off lama, dan tidak boleh melebihi remaining written-off amount.
- Kelebihan Recovery dikembalikan atau menjadi Customer Balance bila entitlement aktif dan dipilih Customer; tidak boleh dikredit seluruhnya sebagai Recovery Income.
- Tax adjustment atas bad debt tidak otomatis dibuat. Fitur tersebut membutuhkan workflow Finance/compliance baru walaupun Tax Engine dasar sudah tersedia.

### Bukti Transfer/Foto Eksternal

Seluruh modul mengikuti `docs/EXTERNAL_EVIDENCE_LINK_POLICY.md`. Cashier mengisi link Google Drive/external HTTPS untuk bukti Transfer; Finance melihat link dari Backoffice. Aplikasi hanya menyimpan URL/metadata dan tidak mengunggah binary ke Supabase Storage, mem-proxy lewat Vercel, atau menganggap link sebagai payment verification.

### Penjualan dan Payment Offline

Transaksi fisik yang sudah selesai memakai Offline Stock Allowance valid dihormati memakai snapshot canonical dan baru membuat financial event ketika sync server berhasil.

```text
Cash offline saat sync:
Debit  Kas Laci
Credit Penjualan

Debit  HPP
Credit Persediaan

Electronic payment verified saat sync:
Debit  Bank / Payment Clearing
Credit Penjualan

Debit  HPP
Credit Persediaan

Electronic payment belum/gagal verified saat sync:
Debit  Piutang Pembayaran Offline
Credit Penjualan

Debit  HPP
Credit Persediaan
```

Penyelesaian exception:

```text
Verified atau pembayaran pengganti diterima:
Debit  Kas / Bank / Payment Clearing
Credit Piutang Pembayaran Offline

Write-off berapproval:
Debit  Beban Piutang Tak Tertagih
Credit Piutang Pembayaran Offline
```

- `Piutang Pembayaran Offline` adalah reconcilable control account terpisah dari Piutang Customer biasa dan dapat mereferensikan Walk-In Customer melalui invoice, terminal, session, Cashier, serta `client_transaction_id`.
- Sale/HPP tidak diposting ulang ketika exception diselesaikan. Reference/metode pengganti dan write-off menjadi event append-only.
- Offline Price Variance adalah selisih analitik antara snapshot yang benar-benar ditagihkan dan harga server ketika sync. Variance tampil pada report Store Manager/Finance, tetapi tidak membuat jurnal karena snapshot sale adalah consideration aktual Customer.
- Price change saja tidak menahan transaksi fisik yang allowance-nya valid. Allowance invalid/revoked, tenant/auth invalid, payload rusak, atau duplicate conflict masuk `HOLD/FAILED` untuk resolusi dan tidak diposting diam-diam.
- Link bukti Transfer boleh ditambahkan setelah online. Jika configured `REQUIRED`, Finance tidak boleh memverifikasi payment sebelum URL valid tersedia; link tidak pernah menjadi verifikasi otomatis.
- Local Draft dapat dibatalkan tanpa journal. Transaksi fisik `PENDING_SYNC` wajib sync dahulu sebelum cancellation/refund/reversal dijalankan di server.
- TEMPO offline hanya Draft/Pending tanpa penyerahan barang, stock movement, AR, revenue, HPP, atau dokumen final sampai validasi online berhasil.
- Harga sale TEMPO mengikuti resolver Pricelist/diskon/rounding yang sama dengan sale biasa dan seluruh snapshot pricing disimpan saat posting.

Gambaran event awal:

```text
Saat sale TEMPO posted:
Debit  Piutang Customer
Credit Penjualan

Debit  HPP
Credit Persediaan

Saat cicilan/payment valid:
Debit  Kas/Bank/QRIS Clearing sesuai metode
Credit Piutang Customer

Saat lunas:
Terbitkan Invoice final dari snapshot + payment history
Tanpa jurnal Penjualan/HPP/Persediaan/Piutang baru
```

Nama akun final, clearing elektronik, pajak, write-off, reversal, dan koreksi tetap mengikuti keputusan Finance berikutnya.

### Opening Stock, Adjustment, dan Opname

Opening Stock posted:

```text
Debit  Persediaan Barang
Credit Opening Balance Clearing
```

- Nilai Opening Stock = quantity base UOM x unit cost base yang diinput manual.
- Posting membuat stock movement dan FIFO layer awal secara atomic.
- Opening Stock hanya valid untuk kombinasi Produk-Gudang yang belum pernah memiliki stock movement.
- Store Manager atau Finance dapat menyiapkan Draft/import. Company Admin melakukan posting; Super Admin dapat menjalankan seluruh proses sesuai company scope.
- Unit cost `0` diperbolehkan dengan warning dan alasan wajib untuk kasus seperti barang bonus, sample, atau nilai historis yang tidak tersedia.
- Setelah movement pertama tersedia, perubahan saldo wajib memakai Adjustment, bukan Opening Stock ulang.

Adjustment dan Opname memakai Transaction Rule yang sama; source document dan audit reference membedakan Adjustment manual dengan Adjustment hasil Opname.

Selisih lebih:

```text
Debit  Persediaan
Credit Pendapatan/Selisih Stok Lebih
```

Selisih kurang:

```text
Debit  Beban/Selisih Stok Kurang
Credit Persediaan
```

Keputusan bisnis dari fase Inventory:

- Selisih negatif diklasifikasikan sebagai `STOCK_LOSS`/kerugian persediaan.
- Selisih positif diklasifikasikan sebagai `STOCK_GAIN`/selisih stok lebih atau pendapatan lain-lain.
- Stock Gain tidak dicatat sebagai pendapatan penjualan.

Target jurnal konseptual:

```text
Selisih lebih:
Debit  Persediaan
Credit Selisih Stok Lebih / Pendapatan Lain-lain

Selisih kurang:
Debit  Kerugian Persediaan / Selisih Stok Kurang
Credit Persediaan
```

Account ID aktual tetap configurable oleh Finance/Company Admin/Super Admin per company. Template default memakai Persediaan Barang, Pendapatan/Selisih Stok Lebih, serta Kerugian/Rusak/Selisih Stok.

Valuation:

- Stock Gain memakai harga beli terakhir yang sudah divalidasi Finance sebagai suggested cost.
- Finance dapat mengganti cost Stock Gain sebelum posting dengan alasan wajib dan audit; perubahan tidak mengubah master harga atau batch lama.
- Stock Loss mengonsumsi FIFO layer aktual. Nilai kerugian tidak membaca harga beli master terbaru.
- Perpindahan `SALEABLE -> DAMAGED` mempertahankan cost dan belum mencatat kerugian. Disposal/penghapusan berikutnya memakai Stock Adjustment Loss terpisah.
- Transfer antar-location/warehouse dalam company tidak mengubah total nilai aset. Jika dimension accounting digunakan, sistem boleh membuat Debit Persediaan dimension tujuan dan Kredit Persediaan dimension asal.
- Adjustment posted immutable. Reversal memulihkan quantity serta FIFO layer/cost asal; koreksi lanjutan dibuat sebagai Adjustment pengganti.

Flow operasional Stock Opname:

- Kasir membuat sesi dan menginput hitungan fisik melalui POS menggunakan blind count.
- Store Manager atau Company Admin/Super Admin membandingkan hasil dan melakukan posting melalui Backoffice.
- Finance dapat memantau/review dari Backoffice, tetapi bukan approval wajib.
- Tidak ada event/jurnal saat status masih `DRAFT`, `COUNTING`, atau `COMPLETED`.
- Financial event untuk gain/loss hanya dibuat ketika Store Manager atau Company Admin/Super Admin mem-posting hasil dan Adjustment berhasil dibuat.
- Tanggal akuntansi Stock Opname adalah tanggal posting Adjustment. `counted_at` tetap tersimpan terpisah untuk audit/perhitungan stock. Jika period asal locked, posting mengikuti PRIOR_PERIOD_ADJUSTMENT pada period terbuka berikutnya kecuali period direopen resmi.

---

## 8. Finance Readiness Gate

Authorization Finance mengikuti hierarchy: Company Admin memiliki seluruh kewenangan Finance/Accounting dalam company membership-nya, dan Super Admin lintas company. Kewenangan penuh tetap menggunakan workflow posting/reversal resmi dan tidak berarti UPDATE/DELETE langsung pada jurnal final.

Sebelum modul Finance dinyatakan aktif, minimum berikut harus selesai:

- Master Chart of Accounts tersedia per company.
- COA memiliki kode unik, nama, tipe, normal balance, dan status aktif.
- Transaction category/rule didefinisikan dengan jelas.
- Mapping event dan metode pembayaran disetujui.
- Mapping fallback Kategori Produk disetujui.
- Seluruh kategori aktif yang dipakai transaksi memenuhi mapping wajib.
- Aturan purchase receipt versus supplier invoice diputuskan.
- Aturan valuation/costing diputuskan.
- Opening balance account diputuskan.
- Jurnal double-entry, reversal, idempotency, dan reconciliation diuji.
- Error queue untuk missing mapping tersedia.
- Laporan missing mapping tersedia sebelum enforcement diaktifkan.

Aktivasi enforcement harus dilakukan bertahap:

```text
1. Tambahkan field nullable
2. Isi Master COA
3. Isi transaction rules
4. Isi fallback kategori
5. Jalankan laporan missing mapping
6. Perbaiki seluruh gap
7. Aktifkan validasi wajib
8. Aktifkan posting Finance
```

Jangan langsung membuat field COA `NOT NULL` sebelum data existing selesai dibackfill dan divalidasi.

---

## 9. Guardrail untuk AI Agent

Agent yang mengerjakan Produk/Inventory saat ini wajib:

- Menjaga field COA nullable.
- Tidak membuat chart of accounts secara asumsi.
- Tidak membuat mapping akun default tanpa keputusan user.
- Tidak mengaktifkan posting jurnal baru hanya karena field COA tersedia.
- Menjaga event/source/reference agar transaksi inventory dapat dihubungkan ke Finance nanti.
- Menyimpan snapshot nilai transaksi yang diperlukan untuk jurnal historis.
- Menambahkan catatan ke dokumen ini jika menemukan keputusan Finance baru.

Agent yang mulai mengerjakan Finance nanti wajib:

- Membaca dokumen ini terlebih dahulu.
- Memvalidasi seluruh asumsi terhadap schema production aktual.
- Menanyakan keputusan terbuka kepada user.
- Memperbarui status setiap keputusan dari `NEEDS_FINANCE_DECISION` menjadi `APPROVED` sebelum implementasi.
- Membuat migration, test, rollout, dan rollback plan terpisah.

---

## 10. Keputusan Terbuka untuk Fase Finance

1. Integrasi faktur pajak resmi/e-Faktur, tax identity/numbering, serta bad-debt tax adjustment bila scope compliance dibuka.
2. Modal dan Aset Tetap tetap deferred pada `CAPITAL_AND_ASSET_NOTES.md`.

---

## 11. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-14 | COA kategori boleh kosong selama fase Produk dan Stok | APPROVED |
| 2026-07-14 | Mapping COA akan menjadi wajib ketika fase Finance diaktifkan | APPROVED; required function contract diselesaikan 2026-07-20 |
| 2026-07-14 | Aturan/kategori transaksi menentukan pencatatan utama | APPROVED |
| 2026-07-14 | COA kategori produk hanya fallback apabila mapping transaksi tidak tersedia | APPROVED |
| 2026-07-14 | Missing mapping pada semua level harus menahan seluruh posting tanpa partial journal | APPROVED; resolver contract diselesaikan 2026-07-20 |
| 2026-07-20 | Permanent system key, flexible company category, required account function, versioned mapping, explicit fallback, dan server-side validation | APPROVED; detail pada `TRANSACTION_CATEGORY_ACCOUNT_MAPPING_SPEC.md` |
| 2026-07-14 | Penjualan dengan stok tidak cukup tetap DRAFT dan tidak membuat jurnal final | APPROVED |
| 2026-07-14 | Draft tidak membuat payment final, financial event, atau pencatatan laporan keuangan | APPROVED |
| 2026-07-14 | Selisih negatif diklasifikasikan Stock Loss dan selisih positif Stock Gain, bukan penjualan | APPROVED secara konsep; mapping akun belum final |
| 2026-07-14 | Opname belum masuk Finance sebelum hasil diposting dan Adjustment berhasil dibuat | APPROVED |
| 2026-07-14 | Tanggal jurnal opname yang diposting beberapa hari kemudian | RESOLVED 2026-07-17: accounting date mengikuti posting Adjustment, counted_at tetap diaudit |
| 2026-07-14 | Receipt posted membentuk AP provisional berdasarkan accepted quantity dan harga estimasi | APPROVED secara konsep |
| 2026-07-14 | Finance mencocokkan invoice fisik dan mengubah nilai estimasi menjadi AP final | APPROVED secara konsep |
| 2026-07-14 | Selisih harga aktual dialokasikan ke Inventory/HPP/Price Variance | RESOLVED 2026-07-17: remaining FIFO ke Inventory, sold qty ke HPP variance |
| 2026-07-14 | Finance memakai three-way reconciliation Supplier Order vs Receipt/Surat Jalan vs Invoice | APPROVED |
| 2026-07-14 | Over-receipt menambah stok/AP provisional dan ditandai sebagai exception Finance | APPROVED |
| 2026-07-14 | Invoice matching fleksibel/many-to-many dengan allocation per line untuk company dan supplier yang sama | APPROVED secara konsep; schema Finance tertunda |
| 2026-07-14 | Field kondisi receipt opsional; rusak yang diterima masuk DAMAGED/AP provisional, sedangkan ditolak tidak masuk stok/AP | APPROVED |
| 2026-07-14 | Return sebelum invoice final mengurangi AP provisional; setelah final/dibayar memakai credit note/refund/offset tanpa mengubah jurnal lama | APPROVED |
| 2026-07-14 | Master Supplier menyimpan satu rekening utama sebagai referensi pembayaran Finance | APPROVED; approval perubahan rekening dibahas pada fase Finance |
| 2026-07-14 | Harga Produk-Supplier menjadi referensi order; HPP transaksi berasal dari batch/FIFO dan harga invoice aktual | APPROVED secara konsep; alokasi price variance masih terbuka |
| 2026-07-14 | Harga beli terakhir Produk-Supplier hanya berubah setelah invoice divalidasi Finance | APPROVED |
| 2026-07-14 | Bundle hanya terdiri dari produk STOCK; HPP tetap berasal dari batch komponen aktual | APPROVED |
| 2026-07-15 | Rounding grand total opsional untuk semua metode dengan pilihan NONE/DOWN/UP ke kelipatan Rp100 | APPROVED; mapping gain/loss resolved 2026-07-17 |
| 2026-07-15 | Full refund membalik rounding asal; partial refund boleh rounding Rp100 terpisah dengan audit | APPROVED; mapping refund resolved 2026-07-17 |
| 2026-07-15 | Refund method dapat Cash/Transfer; stock effect mengikuti SALEABLE/DAMAGED/NO_PHYSICAL_RETURN | APPROVED; mapping resolved 2026-07-17 |
| 2026-07-15 | Expense dan Cash In/Out dicatat sebagai event non-sale untuk pembahasan fase POS/Finance | APPROVED sebagai reminder |
| 2026-07-15 | Bukti refund transfer opsional pada scope awal; rekening/tujuan dan referensi yang tersedia tetap disimpan | APPROVED; external link policy resolved 2026-07-19 |
| 2026-07-15 | Opening/closing cash sesi, Excel sesi Cashier, dan Setor Kas multi-sesi | APPROVED secara operasional |
| 2026-07-15 | Setor Kas boleh berbeda dari expected; Finance atau Company Admin/Super Admin approve/reject, tujuan kas memakai aktual, dan expected Kas Laci dibersihkan dengan akun kontrol variance | APPROVED; diperjelas 2026-07-20 |
| 2026-07-15 | Sesi terpilih selesai saat approval meskipun variance; bukti REQUIRED/OPTIONAL per company/store | APPROVED |
| 2026-07-20 | Under/over-deposit memakai akun kontrol, partial resolution, aging, dan workflow append-only tanpa membuka Session/Setor Kas final | APPROVED; detail pada `DEPOSIT_VARIANCE_RESOLUTION_SPEC.md` |
| 2026-07-15 | Draft/Hold Order tidak membuat financial event/jurnal sampai transaksi berhasil diposting | APPROVED |
| 2026-07-15 | Payment pada Draft/Hold hanya catatan sementara dan bukan penerimaan uang | APPROVED |
| 2026-07-15 | Harga transaksi memakai customer/global Pricelist dengan product base fallback dan snapshot rule/diskon | APPROVED; mapping diskon resolved 2026-07-17 |
| 2026-07-15 | Promo 2+1 menggunakan Bundle; HPP berasal dari seluruh komponen aktual | APPROVED |
| 2026-07-20 | Bundle satu line komersial; MVP revenue ke account Bundle dan allocation komponen analitik memakai price/HPP/qty fallback serta original snapshot | APPROVED; detail pada `BUNDLE_REVENUE_ALLOCATION_SPEC.md` |
| 2026-07-15 | Customer exclusive pricing melewati Global tier; tier Global memiliki basis quantity configurable dan nominal discount per unit | APPROVED |
| 2026-07-15 | Diskon manual dapat ditumpuk di atas Pricelist dan harga POS bersifat tax-inclusive | APPROVED; Tax Engine resolved 2026-07-20 |
| 2026-07-15 | Kelebihan pembayaran dapat menjadi Customer Balance berbasis ledger untuk transaksi berikutnya | APPROVED; mapping liability resolved 2026-07-17 |
| 2026-07-16 | Customer Balance company-wide, tidak kedaluwarsa, dan merupakan liability Customer | APPROVED; mapping COA resolved 2026-07-17 |
| 2026-07-16 | Ketul Offset dipakai sebelum Customer Balance; saldo hanya mengurangi amount due dan tidak mengubah revenue | APPROVED |
| 2026-07-16 | Saldo tidak dicairkan langsung; exceptional settlement Customer inactive memakai workflow Produk atau Expense terkontrol | APPROVED; mapping/approval resolved 2026-07-19 |
| 2026-07-17 | Cash Advance dihapus sebagai jenis terpisah; requested/disbursed/actual/returned/outstanding digabung dalam flow Expense | APPROVED; mapping resolved 2026-07-19 |
| 2026-07-17 | Approval Expense configurable; Cash hanya keluar setelah approval bila aktif dan auto-approved bila nonaktif | APPROVED secara operasional |
| 2026-07-17 | Transfer Expense dikonfirmasi Finance; outstanding tidak memblokir tutup sesi | APPROVED; mapping resolved 2026-07-19 |
| 2026-07-17 | Kategori Expense menentukan COA; additional disbursement/return lintas sesi memakai ledger append-only | APPROVED secara operasional; akun detail tertunda |
| 2026-07-17 | Offline Expense Cash hanya PENDING_SYNC bila approval nonaktif; approval aktif dan Transfer hanya Draft | APPROVED secara operasional |
| 2026-07-17 | Expense cancel/correction, SETTLED_NO_EXPENSE, overdue report, Cash In, dan shortage top-up disetujui | APPROVED; base mapping resolved 2026-07-19 |
| 2026-07-17 | Exceptional Customer Balance settlement selalu memakai kategori khusus dan approval Finance/Company Admin | APPROVED; mapping resolved 2026-07-19 |
| 2026-07-16 | Seluruh saldo source lama wajib diselesaikan pada transaksi berikutnya; source credit baru tetap terpisah | APPROVED |
| 2026-07-16 | Koreksi saldo diajukan Cashier dan di-approve Finance; Store Manager bukan approver | APPROVED secara operasional |
| 2026-07-16 | Refund mengembalikan komponen saldo lebih dahulu dan sisanya fleksibel Cash/Transfer/Balance | APPROVED; mapping resolved 2026-07-17 |
| 2026-07-16 | Exceptional settlement terkontrol, statement, total liability, dan aging Customer Balance | APPROVED; mapping resolved 2026-07-19 |
| 2026-07-16 | Checkout diblokir bila saldo lama melebihi amount due; tidak ada negative due atau rollover saldo lama | APPROVED |
| 2026-07-16 | Customer Balance entitlement hanya dapat ditoggle Super Admin; disabled tidak menghapus liability/history | APPROVED |
| 2026-07-16 | WIND_DOWN menghentikan credit baru sambil menyelesaikan liability lama sebelum auto-DISABLED | APPROVED |
| 2026-07-16 | Draft resolve harga terbaru; diskon manual dapat menjaga harga lama yang lebih murah dan seluruh selisih disimpan untuk audit | APPROVED; explicit manual discount mapping resolved 2026-07-17 |
| 2026-07-16 | Offline sale dalam allowance memakai snapshot harga; Offline Price Variance hanya report/audit | APPROVED; mapping resolved 2026-07-20 |
| 2026-07-16 | Payment elektronik offline dicatat PENDING_VERIFICATION sampai diverifikasi saat sync | APPROVED; mapping resolved 2026-07-20 |
| 2026-07-16 | Payment elektronik gagal menjadi OFFLINE_PAYMENT_EXCEPTION; sale/HPP tetap posted dan payment tidak masuk kas/bank | APPROVED; mapping resolved 2026-07-20 |
| 2026-07-16 | Finance menyelesaikan offline payment exception dengan verifikasi ulang, pembayaran pengganti, atau write-off | APPROVED; mapping resolved 2026-07-20 |
| 2026-07-20 | Offline electronic exception memakai Piutang Pembayaran Offline; penyelesaian tidak repost sale/HPP | APPROVED |
| 2026-07-20 | Walk-In Customer boleh memiliki offline payment receivable berbasis source transaction/terminal/session/Cashier | APPROVED |
| 2026-07-20 | Link bukti offline dapat ditambahkan setelah online dan wajib sebelum verification jika configured REQUIRED | APPROVED |
| 2026-07-20 | Draft lokal dapat dibatalkan; physical PENDING_SYNC harus sync sebelum cancellation/refund server | APPROVED |
| 2026-07-20 | Payment Method menjadi Master Data company/store dan Cashier hanya memilih metode eligible | APPROVED |
| 2026-07-20 | Gateway fee effective-dated dapat percent/fixed/gabungan dan ditanggung company/Customer | APPROVED |
| 2026-07-20 | Split payment menghitung fee per leg; settlement variance masuk reconciliation exception | APPROVED |
| 2026-07-20 | Tax Engine memakai effective-dated Sales/Purchase rule, Category default/Product override, serta snapshot | APPROVED |
| 2026-07-20 | Sales inclusive; Purchase inclusive/exclusive; PER_DOCUMENT default atau PER_LINE configurable | APPROVED |
| 2026-07-20 | Return/reversal memakai original tax snapshot; Tempo payment tidak repost tax | APPROVED |
| 2026-07-20 | Purchase matching mendukung partial/many-to-many, company/Supplier tolerance, dan status exception | APPROVED |
| 2026-07-20 | Invoice quantity di atas accepted receipt HOLD; residual AP Provisional menunggu invoice/controlled close | APPROVED |
| 2026-07-20 | UOM valuation memakai direct base snapshot, high-precision FIFO, dan document-boundary IDR rounding | APPROVED |
| 2026-07-20 | Berat hanya estimasi logistik dan tidak otomatis mengubah quantity/HPP | APPROVED |
| 2026-07-20 | Finance formula/cut-off mengikuti posted ledger; non-final status masuk operational pending analysis terpisah | APPROVED |
| 2026-07-17 | Payment method TEMPO menghasilkan Pro Forma sampai lunas; Invoice final terbit setelah outstanding nol | APPROVED |
| 2026-07-17 | Cashier boleh memberi TEMPO tanpa approval; limit/overdue hanya warning dan override diaudit | APPROVED secara operasional |
| 2026-07-17 | Finance menetapkan limit dan term manual per Customer; payment boleh parsial dan split method | APPROVED secara operasional |
| 2026-07-17 | Sale TEMPO posted langsung mengakui stock-out, sale, HPP, dan piutang; pelunasan/invoice final tidak posting ulang | APPROVED; mapping resolved 2026-07-17 |
| 2026-07-17 | TEMPO offline hanya Draft/Pending tanpa penyerahan barang atau financial posting sampai validasi online | APPROVED |
| 2026-07-17 | Finance menetapkan default term; Cashier memilih due date dan Finance dapat override secara audited | APPROVED |
| 2026-07-17 | Payment TEMPO satu pintu dari POS oleh Cashier; Finance hanya monitoring, rekonsiliasi, dan correction berwenang | APPROVED secara operasional |
| 2026-07-17 | DP menjadi payment pertama; overpayment masuk Customer Balance bila aktif atau dikembalikan Cash/Transfer | APPROVED secara operasional |
| 2026-07-17 | Retur memakai Credit Note; cancel penuh memakai reversal setelah barang kembali tanpa menghapus histori | APPROVED; mapping resolved 2026-07-17 |
| 2026-07-17 | Existing outstanding tidak memblokir TEMPO baru; warning dan acknowledgement Cashier wajib diaudit | APPROVED secara operasional |
| 2026-07-17 | Payment dapat dialokasikan ke beberapa Pro Forma oldest-first dan sisanya menjadi cicilan | APPROVED |
| 2026-07-17 | Settlement status dipisah dari due status; reminder in-app ditindaklanjuti manual Cashier/Finance | APPROVED secara operasional |
| 2026-07-17 | Koreksi harga memakai Debit/Credit Note Finance; write-off diajukan Finance dan disetujui Company Admin | APPROVED; Note contract diselesaikan 2026-07-20 |
| 2026-07-20 | Empat jenis Debit/Credit Note wajib source posted, tidak mengubah stock, memakai original tax snapshot, dan mendukung partial/many-to-many allocation | APPROVED; detail pada `DEBIT_CREDIT_NOTE_SPEC.md` |
| 2026-07-17 | Customer Statement TEMPO lengkap dengan filter dan export Excel/PDF | APPROVED |
| 2026-07-20 | Collection memakai derived aging, assignment, append-only follow-up/Promise, warning acknowledgement, dan on-demand export tanpa daily reminder row | APPROVED; detail pada `COLLECTION_AND_CUSTOMER_STATEMENT_SPEC.md` |
| 2026-07-17 | Write-off parsial/penuh per Pro Forma; WRITTEN_OFF bukan PAID dan tidak menerbitkan Invoice final | APPROVED; mapping resolved 2026-07-19 |
| 2026-07-17 | Recovery Piutang menjadi event baru tanpa membuka jurnal write-off lama | APPROVED; mapping resolved 2026-07-19 |
| 2026-07-17 | Finance menjadi maker dan Company Admin menjadi approver write-off terpisah | APPROVED |
| 2026-07-17 | Cashier hanya melihat warning histori write-off tanpa detail akun/jurnal | APPROVED |
| 2026-07-15 | Ketul adalah Produk STOCK PCS; Customer intake dan Vendor sale memakai harga manual serta source document terpisah | APPROVED secara operasional; timing jurnal terbuka |
| 2026-07-15 | Ketul settlement split, offset setelah final sale, FIFO acquisition, dan Vendor accepted/rejected reconciliation | APPROVED secara operasional; timing jurnal terbuka |
| 2026-07-15 | Ketul dispatch pindah STORE ke TRANSIT; accepted qty stock-out/HPP saat hasil Vendor dicatat | APPROVED secara operasional |
| 2026-07-15 | Hasil Vendor dapat parsial dan dicatat Cashier/Finance; final fund confirmation tetap Finance | APPROVED secara operasional |
| 2026-07-15 | Cash Vendor masuk drawer sesi penerima; Transfer masuk bank; bukti configurable | APPROVED secara operasional |
| 2026-07-15 | DOCUMENT_TOTAL dialokasikan proporsional per estimated accepted line | APPROVED secara operasional |
| 2026-07-15 | Finance atau Company Admin/Super Admin dapat mengoreksi hasil Cashier sebelum confirmation dengan immutable revision audit | APPROVED secara operasional |
| 2026-07-15 | Settlement result/payment many-to-many; unpaid balance menjadi outstanding Vendor | APPROVED; mapping Piutang Vendor resolved 2026-07-19 |
| 2026-07-15 | Retur pembatalan memulihkan FIFO layer/cost asal agar stock valuation dan jurnal balance | APPROVED secara operasional |
| 2026-07-15 | Estimated Ketul nol memakai accepted qty sebagai fallback alokasi DOCUMENT_TOTAL | APPROVED secara operasional |
| 2026-07-15 | Cash tanpa sesi OPEN boleh menjadi Backoffice Cash Receipt dengan source Vendor yang jelas | APPROVED; Debit Main Cash/Credit Vendor AR resolved 2026-07-19 |
| 2026-07-15 | Outstanding Vendor memiliki due date/aging; detail default dan bucket tertunda | APPROVED secara konsep |
| 2026-07-15 | Koreksi quantity pasca-confirmation memakai stock/FIFO dan financial reversal; nominal-only memakai financial reversal | APPROVED secara operasional |
| 2026-07-15 | Modal Pemilik dan Aset Tetap dicatat sebagai scope deferred terpisah | APPROVED sebagai reminder |
| 2026-07-15 | Rounding allocation masuk line terbesar; due date manual dan aging bucket standar | APPROVED secara operasional |
| 2026-07-15 | Cashier tidak melihat HPP/margin; report/export dibatasi berdasarkan role scope | APPROVED secara operasional |
| 2026-07-15 | Backoffice Cash Receipt Finance langsung confirmed dan dokumen Ketul auto-close ketika seluruh flow selesai | APPROVED secara operasional |
| 2026-07-15 | Quantity/settlement status Ketul dipisah; movement dan financial correction append-only | APPROVED secara operasional |
| 2026-07-15 | Idempotency wajib, CLOSED immutable, dan Vendor inactive tetap dapat menyelesaikan outstanding lama | APPROVED secara operasional |
| 2026-07-15 | Company Admin mewarisi seluruh kewenangan Finance dalam company; Super Admin lintas company | APPROVED |
| 2026-07-17 | Finance Core memakai accrual accounting dan satu ledger IDR per company dengan store/warehouse dimension | APPROVED |
| 2026-07-17 | Setiap company memperoleh template COA retail; kode akun manual dan unik per company | APPROVED |
| 2026-07-17 | Automatic Journal berasal dari source document; posted immutable dan correction memakai reversal/replacement | APPROVED |
| 2026-07-17 | Manual Journal hanya Finance/Company Admin/Super Admin dengan description wajib dan evidence opsional | APPROVED |
| 2026-07-17 | Period bulanan dikunci Finance dan hanya Company Admin/Super Admin dapat reopen dengan alasan/audit | APPROVED |
| 2026-07-17 | Account type standar, prefix COA editable, hierarchy tiga tingkat, dan normal balance otomatis/manual audited | APPROVED |
| 2026-07-17 | Akun terpakai tidak dapat dihapus/diubah type; nama/kode editable dengan audit | APPROVED |
| 2026-07-17 | Opening Balance manual/Excel dibuat Finance dan di-approve Company Admin | APPROVED |
| 2026-07-17 | Automatic Journal langsung posted bila valid; Manual Journal approval configurable maker-checker | APPROVED |
| 2026-07-17 | Finance dapat melihat balance dan merekonsiliasi full/partial per COA tanpa mengubah jurnal | APPROVED |
| 2026-07-17 | Reconciliation many-to-many memakai suggestion manual-confirm dan default control accounts | APPROVED |
| 2026-07-17 | Bank statement import CSV/Excel memakai preview/mapping/partial success/duplicate protection | APPROVED |
| 2026-07-17 | Bank fee memakai adjustment dan unreconcile hanya pada period terbuka/reopened | APPROVED |
| 2026-07-17 | Minimum Finance reports ditetapkan: Trial Balance, GL, Neraca, P&L, Cash/Bank, AR/AP Aging, Outstanding | APPROVED |
| 2026-07-17 | Accounting date memakai posted event; Stock Opname memakai posting Adjustment dan counted_at tetap tersimpan | APPROVED |
| 2026-07-17 | Backdated hanya period open; period locked memakai PRIOR_PERIOD_ADJUSTMENT atau official reopen | APPROVED |
| 2026-07-17 | Pajak menjadi optional entitlement per company dengan toggle Super Admin | APPROVED sebagai boundary; diperluas per modul 2026-07-19 |
| 2026-07-17 | Template COA lengkap; akun tidak terpakai dapat dinonaktifkan | APPROVED |
| 2026-07-17 | Template leaf retail default disetujui; kode/nama editable dan system function/type terkunci setelah dipakai | APPROVED |
| 2026-07-17 | Clearing Setor Kas memakai Aset Kas dalam Perjalanan; optional tax account mengikuti entitlement modul terkait | APPROVED; diperjelas 2026-07-19 |
| 2026-07-17 | POS Cash, electronic clearing/Bank, Tempo, payment AR, dan HPP/FIFO memiliki template mapping dasar | APPROVED; account ID configurable per company |
| 2026-07-17 | Finance/Company Admin/Super Admin dapat mengubah Transaction Rule POS secara versioned tanpa mengubah histori | APPROVED |
| 2026-07-17 | Mixed payment menjadi beberapa settlement debit dalam satu sale journal; payment Tempo berikutnya memakai journal terpisah | APPROVED |
| 2026-07-17 | Resolved Pricelist adalah harga jual; hanya diskon manual masuk contra revenue Potongan Penjualan | APPROVED |
| 2026-07-17 | Rounding UP masuk gain dan DOWN masuk loss; mapping account tetap configurable | APPROVED |
| 2026-07-17 | Ketul intake mengakui Persediaan terhadap Utang Ketul Customer sebelum settlement | APPROVED |
| 2026-07-17 | Draft/Hold cancel tanpa journal; sale posted hanya dibatalkan melalui reversal append-only | APPROVED |
| 2026-07-17 | Credit Note mengurangi AR lebih dahulu atau membentuk Utang Refund Customer bila harus dikembalikan | APPROVED |
| 2026-07-17 | Refund Cash/Transfer/Customer Balance menyelesaikan Utang Refund; account mapping configurable per company | APPROVED |
| 2026-07-17 | SALEABLE/DAMAGED membalik stock/HPP cost asal; NO_PHYSICAL_RETURN tidak mengubah stock/HPP | APPROVED |
| 2026-07-17 | Full refund membalik snapshot asal; partial refund per line dengan cumulative refundable guard | APPROVED |
| 2026-07-17 | Opening Stock Debit Inventory/Credit Opening Clearing dan membuat FIFO layer awal | APPROVED; account ID configurable |
| 2026-07-17 | Opening Stock disiapkan Store Manager/Finance dan diposting Company Admin; hanya sebelum movement pertama | APPROVED |
| 2026-07-17 | Zero-cost Opening Stock boleh dengan warning dan alasan wajib | APPROVED |
| 2026-07-17 | Stock Gain memakai validated last purchase cost suggestion; Finance dapat override sebelum posting dengan audit | APPROVED |
| 2026-07-17 | Stock Loss memakai FIFO layer aktual; Adjustment manual dan hasil Opname memakai mapping yang sama | APPROVED |
| 2026-07-17 | SALEABLE ke DAMAGED mempertahankan cost; disposal mencatat loss melalui Adjustment terpisah | APPROVED |
| 2026-07-17 | Adjustment reversal memulihkan quantity dan FIFO layer/cost asal | APPROVED |
| 2026-07-17 | Goods Receipt accepted mengakui Inventory/AP Provisional; DAMAGED diterima dan REJECTED dikecualikan | APPROVED |
| 2026-07-17 | Invoice aktual merevaluasi sisa FIFO dan memasukkan bagian terjual ke Selisih Harga Beli/HPP | APPROVED |
| 2026-07-17 | AP Final payment mendukung partial/many-to-many allocation dan reconciliation Finance | APPROVED |
| 2026-07-17 | Purchase Return mengurangi AP Provisional/AP Final atau membentuk Piutang Refund Supplier | APPROVED |
| 2026-07-17 | Finance memvalidasi invoice; koreksi final memakai Debit/Credit Note atau reversal, bukan edit | APPROVED |
| 2026-07-19 | Invoice memisahkan harga, diskon, landed cost, pajak, dan grand total; snapshot allocation wajib | APPROVED |
| 2026-07-19 | Landed cost dapat dialokasikan VALUE/QUANTITY/WEIGHT/MANUAL atau langsung Expense | APPROVED |
| 2026-07-19 | Landed cost tersisa masuk FIFO Inventory dan bagian terjual masuk Selisih Harga Beli/HPP | APPROVED |
| 2026-07-19 | SALES_TAX dan PURCHASE_TAX merupakan entitlement independen per company yang hanya ditoggle Super Admin | APPROVED |
| 2026-07-19 | Supplier Payment approval configurable; journal hanya saat PAID dan bukti transfer configurable | APPROVED |
| 2026-07-19 | Supplier overpayment masuk Uang Muka Supplier, bukan AP negatif | APPROVED |
| 2026-07-19 | Expense disbursement memakai Outstanding Expense; actual menjadi Expense dan return mengurangi outstanding | APPROVED |
| 2026-07-19 | Opening cash hanya physical count; DRAWER_TOP_UP wajib memakai movement Kas Laci/Kas Besar | APPROVED |
| 2026-07-19 | Shortage menjadi Piutang Kasir dan top-up menyelesaikannya; write-off memakai Beban Selisih Kas | APPROVED |
| 2026-07-19 | Overage masuk liability sementara sampai Finance menyelesaikan ke income/refund/correction | APPROVED |
| 2026-07-19 | Setor Bank memakai Kas dalam Perjalanan lalu Bank; Setor Brankas langsung antar akun kas | APPROVED |
| 2026-07-19 | Customer Intake Ketul mencatat Inventory terhadap Utang Ketul dan settlement mendukung split Cash/Transfer/Balance/Offset | APPROVED |
| 2026-07-19 | Dispatch Ketul hanya transfer STORE-TRANSIT; Vendor Result confirmed mencatat AR/Revenue dan FIFO HPP/Inventory | APPROVED |
| 2026-07-19 | Payment Vendor Cash/Backoffice/Transfer mengurangi Piutang Vendor Ketul dan mendukung partial/many-to-many | APPROVED |
| 2026-07-19 | Rejected quantity kembali tanpa reversal; return setelah Result memakai Retur Ketul dan Utang/Kredit Vendor bila diperlukan | APPROVED |
| 2026-07-19 | Write-off Debit Bad Debt/Credit AR; Recovery menjadi event Cash/Bank terhadap Recovery Income tanpa membuka AR lama | APPROVED |
| 2026-07-19 | Recovery dibatasi remaining write-off; excess direfund atau menjadi Customer Balance | APPROVED |
| 2026-07-19 | Koreksi Customer Balance wajib source/account valid dan approval Finance | APPROVED |
| 2026-07-19 | Exceptional Cash/Transfer settlement mengurangi Customer Balance; Product settlement memakai Sale/HPP/FIFO normal | APPROVED |
| 2026-07-19 | Bukti Transfer Cashier memakai link Drive/HTTPS; aplikasi tidak menyimpan atau mem-proxy binary | APPROVED |
