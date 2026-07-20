# Spesifikasi Finance Core, COA, Jurnal, dan Accounting Period

**Status:** Pembahasan business workflow aktif  
**Tanggal pembukaan:** 2026-07-17  
**Boundary:** Dokumentasi dahulu; jangan membuat schema, posting engine, migration, atau UI sebelum keputusan Finance cukup lengkap dan mapping source event diverifikasi.

---

## 1. Tujuan dan Scope

Dokumen ini menjadi sumber utama untuk fondasi accounting lintas modul:

- Chart of Accounts per company;
- double-entry journal;
- automatic dan manual journal;
- accrual accounting;
- accounting period serta lock/reopen;
- currency dan reporting dimension;
- onboarding template dan opening balance.

Mapping setiap source event tetap dirinci pada `FINANCE_INTEGRATION_NOTES.md`. Modal/Aset tetap berada pada `CAPITAL_AND_ASSET_NOTES.md` sampai fase tersebut dibuka.

Koreksi nilai dokumen posted mengikuti `DEBIT_CREDIT_NOTE_SPEC.md`; Note tidak boleh mengubah stock/FIFO atau menggantikan Payment, Refund, maupun Manual Journal.

---

## 2. Prinsip Accounting yang Disetujui

- Sistem menggunakan accrual accounting.
- Sale posted mengakui revenue, HPP, persediaan, serta Kas/Bank/Piutang sesuai settlement tanpa menunggu seluruh pembayaran.
- Goods Receipt mengakui inventory dan AP provisional sesuai workflow Purchasing; invoice aktual melakukan reconciliation/adjustment.
- Payment hanya menyelesaikan Kas/Bank/Piutang/AP terkait dan tidak mengulang revenue, expense, atau inventory event.
- Semua jurnal wajib balanced: total debit sama dengan total credit.
- Jurnal posted tidak dapat diubah/dihapus. Correction memakai reversal dan replacement journal.
- Source document historis, snapshot rule, actor, dan waktu posting wajib dapat ditelusuri.

---

## 3. Company Ledger dan Currency

- Satu company mempunyai satu accounting ledger.
- Store, warehouse, POS terminal, Cashier Session, customer, supplier, product category, dan source document menjadi dimension/reference laporan, bukan ledger terpisah.
- Semua query, journal, account, period, dan report tenant-scoped dengan `company_id`.
- Currency awal hanya IDR. Multi-currency, exchange rate, dan foreign exchange gain/loss ditunda.
- Amount accounting memakai precision NUMERIC yang aman; UI dapat menampilkan Rupiah sesuai kebutuhan operasional tanpa floating-point JavaScript sebagai sumber final.

---

## 4. Master Chart of Accounts

Setiap company memperoleh template COA retail dasar saat Finance feature diaktifkan/onboarding. Finance dan Company Admin dapat menambah atau menonaktifkan akun dalam company; Super Admin memiliki seluruh authority lintas-company.

Template dibuat cukup lengkap untuk source event POS, Inventory, Purchasing, Customer, Ketul, Expense, clearing, rounding, serta correction yang sudah disetujui. Akun yang tidak digunakan company dapat dinonaktifkan tanpa menghapus struktur/histori.

Candidate field:

```text
id
company_id
code                         -- manual, unique per company
name
system_key nullable
account_type
normal_balance
parent_account_id nullable
is_system_account
allow_manual_posting
allow_reconciliation
is_active
created_by/at
updated_by/at
```

Guardrail:

- Kode COA diinput manual dan unik dalam company, tetapi boleh sama pada company lain.
- Template awal memakai prefix default `1xxx` Aset, `2xxx` Kewajiban, `3xxx` Ekuitas, `4xxx` Pendapatan, `5xxx` HPP, `6xxx` Beban, `7xxx` Pendapatan Lain, dan `8xxx` Beban Lain. Kode tetap dapat diubah/ditambah sesuai kebijakan company.
- Account type awal: `ASSET`, `LIABILITY`, `EQUITY`, `REVENUE`, `COGS`, `EXPENSE`, `OTHER_INCOME`, dan `OTHER_EXPENSE`.
- Hierarchy dibatasi maksimal tiga tingkat pada fase awal: group utama -> subgroup -> posting account. Parent/group tidak menerima posting; journal hanya memakai leaf account.
- Normal balance otomatis dari account type: Aset/HPP/Beban normal Debit dan Kewajiban/Ekuitas/Pendapatan normal Credit.
- Finance/Company Admin/Super Admin boleh menyesuaikan normal balance manual dengan warning serta audit before/after. Override tidak boleh menyembunyikan journal yang unbalanced.
- Akun inactive tetap terlihat pada histori dan tidak boleh dipakai posting baru.
- Akun yang pernah dipakai jurnal tidak boleh dihapus permanen.
- Account type akun yang pernah dipakai tidak boleh diubah. Nama/kode masih dapat diperbarui dengan audit; journal tetap mereferensikan account ID dan snapshot.
- Sistem tidak menebak akun. Missing transaction rule/fallback menghasilkan posting `HOLD/ERROR`.
- Detail akun leaf pada template masih dibahas pada batch berikutnya.

### 4.1 Template COA Retail Default

Seluruh kode/nama berikut adalah default awal dan dapat diubah per company. `system_key` menjaga fungsi mapping walaupun kode/nama berubah. Account type dan fungsi system mapping dikunci setelah akun digunakan.

#### Aset

| Default | Nama | Catatan |
|---|---|---|
| `1110` | Kas Laci | Reconciliation aktif; store/session menjadi dimension |
| `1120` | Kas Besar/Brankas | Reconciliation aktif |
| `1130` | Bank | Parent/subgroup; company dapat menambah leaf per rekening |
| `1140` | QRIS/Card/Transfer Clearing | Reconciliation aktif |
| `1150` | Kas dalam Perjalanan/Setoran | Clearing Setor Kas; Aset, bukan Kewajiban |
| `1160` | Pajak Masukan | Optional dan inactive ketika `PURCHASE_TAX` mati |
| `1210` | Piutang Customer | Reconciliation aktif |
| `1220` | Piutang Vendor Ketul | Reconciliation aktif |
| `1230` | Outstanding Expense Operasional | Dana dicairkan tetapi belum settled |
| `1240` | Piutang Kekurangan Kasir | Menelusuri shortage sebelum top-up/settlement |
| `1250` | Piutang Refund Supplier | Purchase Return/credit supplier yang melebihi AP terbuka atau belum dikembalikan supplier; reconciliation aktif |
| `1260` | Uang Muka Supplier | Kelebihan pembayaran supplier yang belum dialokasikan ke invoice atau dikembalikan; reconciliation aktif |
| `1270` | Piutang Pembayaran Offline | Pembayaran elektronik offline yang belum/ gagal diverifikasi setelah sale fisik diposting; reconciliation aktif per transaksi |
| `1280` | Selisih Setoran Kurang dalam Investigasi | Akun kontrol Aset untuk under-deposit sebelum responsible party ditetapkan; reconciliation aktif |
| `1310` | Persediaan Barang | Inventory valuation FIFO |

#### Kewajiban

| Default | Nama | Catatan |
|---|---|---|
| `2110` | Utang Supplier Provisional | Goods Receipt sebelum invoice final; reconciliation aktif |
| `2120` | Utang Supplier Final | Invoice Supplier; reconciliation aktif |
| `2130` | Customer Balance | Liability toko kepada Customer; reconciliation aktif |
| `2140` | Utang Ketul kepada Customer | Nilai Ketul yang sudah diterima tetapi belum dibayar, dikonversi menjadi Customer Balance, atau dipakai sebagai Ketul Offset; reconciliation aktif |
| `2150` | Pajak Keluaran/Utang Pajak | Optional dan inactive ketika `SALES_TAX` mati |
| `2160` | Utang Refund Customer | Credit Note/refund yang sudah diakui tetapi belum dibayarkan atau dikonversi menjadi Customer Balance; reconciliation aktif |
| `2170` | Selisih Kas Lebih Belum Diselesaikan | Kelebihan fisik kas yang masih menunggu investigasi/keputusan Finance; reconciliation aktif |
| `2180` | Utang/Kredit Vendor Ketul | Overpayment atau kewajiban refund kepada Vendor setelah retur Penjualan Ketul; reconciliation aktif |

#### Ekuitas

| Default | Nama | Catatan |
|---|---|---|
| `3110` | Modal Pemilik | Detail Modal dibahas terpisah |
| `3210` | Laba Ditahan | Closing result |
| `3310` | Opening Balance Clearing | Akun transisi onboarding/opening balance |

#### Pendapatan dan HPP

| Default | Nama | Type/normal |
|---|---|---|
| `4110` | Penjualan | Revenue/Credit |
| `4120` | Retur dan Potongan Penjualan | Contra Revenue/Debit override |
| `4130` | Penjualan Ketul | Revenue/Credit |
| `4140` | Retur Penjualan Ketul | Contra Revenue/Debit override; dipisahkan dari retur retail |
| `5110` | HPP Penjualan | COGS/Debit |
| `5120` | HPP Ketul | COGS/Debit |
| `5130` | Selisih Harga Beli/HPP | Koreksi harga invoice aktual untuk quantity yang sudah terjual; dapat Debit atau Kredit sesuai variance |

#### Beban

| Default | Nama | Catatan |
|---|---|---|
| `6110` | Beban Operasional Umum | Parent/default; Expense Category dapat memakai leaf tambahan |
| `6120` | Biaya Administrasi Bank | Untuk selisih reconciliation bank yang valid |
| `6130` | Kerugian/Rusak/Selisih Stok | Stock loss/damage |
| `6140` | Beban Piutang Tak Tertagih | Write-off AR |
| `6150` | Selisih Pembulatan Rugi | Rounding loss |
| `6160` | Beban Selisih Kas | Shortage yang diputuskan tidak ditagih atau koreksi kas resmi |

#### Pendapatan Lain

| Default | Nama | Catatan |
|---|---|---|
| `7110` | Pendapatan/Selisih Stok Lebih | Stock gain |
| `7120` | Selisih Pembulatan Untung | Rounding gain |
| `7130` | Recovery Piutang Write-off | Payment setelah write-off |
| `7140` | Pendapatan Lain-lain | Fallback yang tetap memerlukan source/rule jelas |
| `7150` | Pendapatan Penggantian Biaya Pembayaran | Customer-borne payment surcharge; dipisahkan dari revenue Produk |

#### Beban Lain

Parent `8xxx` disediakan agar company dapat menambah akun leaf lain tanpa mencampurnya dengan Beban Operasional `6xxx`. Template awal tidak memaksa leaf tambahan sebelum kebutuhan transaksi nyata tersedia.

Aturan template:

- Pajak Masukan inactive/tidak wajib dipetakan ketika `PURCHASE_TAX` mati; Pajak Keluaran mengikuti status `SALES_TAX` secara independen.
- Company dapat menambah leaf account di bawah parent yang sesuai.
- Akun template yang tidak dipakai dapat dinonaktifkan, bukan dihapus.
- Sistem menyimpan reference berdasarkan account ID/system key, bukan mengandalkan kode/nama hard-coded.
- Mapping default Kas/Bank/Clearing, Penjualan, Piutang, HPP, dan Persediaan adalah template awal, bukan pasangan akun yang hard-coded.
- Finance, Company Admin, dan Super Admin dapat mengatur Transaction Rule per company. Perubahan wajib versioned, diaudit, dan hanya berlaku untuk source event baru.
- Sistem tetap memvalidasi company scope, fungsi/system key, account type yang diizinkan, period, dan keseimbangan debit/kredit. Mapping yang tidak valid tidak boleh diposting.

---

## 5. Resolusi Akun

Urutan yang sudah disetujui:

```text
Transaction Rule / Transaction Category
-> fallback Product/Expense Category bila mapping event mengizinkan
-> explicit Company fallback yang compatible
-> HOLD/ERROR jika akun wajib tidak ditemukan
```

- Expense Category menentukan akun biaya; payment method menentukan sisi Kas/Bank.
- Product Category hanya fallback untuk revenue/HPP/inventory mapping yang belum tersedia pada transaction rule.
- Company fallback wajib dikonfigurasi eksplisit dan tidak boleh menjadi tebakan sistem.
- Transaksi menyimpan account/rule snapshot agar perubahan Master COA/rule tidak mengubah histori.
- COA boleh nullable selama fase persiapan/backfill, tetapi semua mapping wajib valid sebelum Finance posting diaktifkan.
- Taxonomy, required account function, versioning, resolver, dan posting-error queue mengikuti `TRANSACTION_CATEGORY_ACCOUNT_MAPPING_SPEC.md`.

---

## 6. Automatic Journal

- Jurnal operasional dibuat server-side dari source document posted.
- Browser/POS tidak boleh mengirim pasangan debit/kredit final sebagai authority.
- Posting menggunakan idempotency key/source tuple agar retry tidak membuat jurnal ganda.
- Automatic Journal hanya posted ketika source event valid, period terbuka, seluruh account ter-resolve, dan debit/credit balanced.
- Automatic Journal valid langsung `POSTED` tanpa approval Finance per transaksi. Finance memantau melalui ledger, reconciliation, dan exception queue.
- Missing mapping, period locked, atau unbalanced journal masuk `HOLD/ERROR` yang terlihat Finance/Admin.
- Reprocessing memakai source/idempotency yang sama dan tidak menggandakan stock/payment/journal event.

Candidate header/line:

```text
journal_entry
  id, company_id, journal_no, accounting_date, currency=IDR
  source_type, source_id, event_type, status
  store_id nullable, warehouse_id nullable
  reversal_of_id nullable, description, posted_by/at

journal_line
  id, journal_entry_id, account_id
  debit, credit
  store_id nullable, warehouse_id nullable
  customer_id nullable, supplier_id nullable
  product_category_id nullable
  description
```

---

## 7. Manual Journal

- Manual Journal hanya dapat dibuat Finance, Company Admin, dan Super Admin.
- Description wajib; evidence/attachment opsional pada scope awal dan mengikuti `EXTERNAL_EVIDENCE_LINK_POLICY.md` sebagai URL eksternal, bukan file upload aplikasi.
- Manual Journal tidak boleh digunakan untuk mengganti workflow operasional yang sudah memiliki source document resmi.
- Manual Journal wajib balanced dan mengikuti accounting period lock.
- Posted Manual Journal immutable dan correction memakai reversal/replacement.
- Approval Manual Journal configurable aktif/nonaktif per company. Jika aktif, maker tidak boleh approve jurnalnya sendiri; Company Admin/Super Admin dapat menjadi approver sesuai scope. Jika nonaktif, submit langsung posted setelah validasi dan config snapshot disimpan.

### 7.1 Opening Balance

- Opening Balance dapat diinput manual atau melalui import Excel.
- Finance menyiapkan Draft per company dan tanggal saldo awal; Company Admin melakukan approval/posting. Super Admin dapat menjalankan seluruh proses lintas-company.
- Import wajib melakukan preview, validasi account code/ID, debit/credit, duplicate row, dan total balance sebelum submit.
- Opening Balance tidak boleh posted bila total Debit tidak sama dengan total Credit.
- Setelah posted, koreksi memakai reversal/replacement Opening Balance, bukan edit row lama.
- Opening Stock inventory menjadi source document terpisah tetapi terhubung ke periode onboarding yang sama: Debit Persediaan dan Kredit Opening Balance Clearing. Store Manager/Finance dapat menyiapkan Draft dan Company Admin mem-posting.

### 7.2 Balance Check dan Account Reconciliation

**Balance check** dan **reconciliation** adalah dua kontrol berbeda:

- Journal balanced bila total Debit sama dengan total Credit. Unbalanced journal tidak boleh `POSTED`.
- Account reconciled bila debit/credit pada akun yang sama sudah dicocokkan ke source/payment/statement terkait.

Finance workspace wajib menampilkan:

```text
total_debit
total_credit
difference
posting_status
reconciliation_status
open_residual
source/reference
```

Guardrail reconciliation awal:

- Finance memilih COA yang `allow_reconciliation = true`.
- Template mengaktifkan reconciliation secara default untuk Kas, Bank, Piutang Customer, Utang Supplier, QRIS/Card/Transfer Clearing, Customer Balance, dan Piutang Vendor Ketul. Finance dapat mengaktifkannya pada akun lain dalam company.
- Reconciliation membuat group/link append-only antar journal lines dan tidak mengubah nilai jurnal posted.
- Full dan partial reconciliation didukung; residual tetap outstanding sampai dicocokkan berikutnya.
- Satu reconciliation dapat mencocokkan banyak Debit dengan banyak Credit pada account yang sama, termasuk satu payment untuk beberapa Pro Forma/invoice.
- Semua line wajib berasal dari company, account, dan currency IDR yang sama.
- Salah account diselesaikan melalui reclassification/reversal journal, bukan dipaksa reconcile lintas-account.
- Finance dapat melihat COA yang balanced secara ledger, reconciled, partially reconciled, atau masih mempunyai open items.
- Sistem memberi matching suggestion berdasarkan source document, customer/supplier, nominal, tanggal, dan reference. Suggestion tidak boleh melakukan reconciliation otomatis tanpa konfirmasi Finance.
- Selisih seperti biaya administrasi bank tidak dipaksakan reconcile. Finance membuat adjustment/manual journal pada akun biaya terkait, lalu mencocokkan seluruh baris yang sudah lengkap.
- Finance boleh `UNRECONCILE` selama accounting period masih terbuka dengan alasan dan audit. Period locked harus direopen Company Admin/Super Admin sebelum unreconcile.

### 7.3 Import Mutasi Bank

- Mutasi Bank dapat diimport melalui CSV atau Excel.
- Flow mengikuti pola import Odoo: upload -> preview -> pilih/mapping kolom -> validasi -> import -> reconciliation workspace.
- Mapping minimum: tanggal, amount atau debit/credit, reference, dan description. Kolom rekening/account source juga dipilih bila file mencakup beberapa rekening.
- Import menyimpan file/reference hash, actor, waktu, row status, duplicate detection, dan error per baris.
- Import mutasi tidak membuat reconciliation otomatis. Finance tetap memilih/menyetujui suggestion.
- Row sukses diproses, row gagal dilaporkan untuk koreksi/re-import tanpa menggandakan row berhasil.

---

## 8. Accounting Period

- Accounting period memakai periode bulanan per company.
- Finance dapat mengunci period setelah reconciliation selesai.
- Company Admin dan Super Admin dapat membuka kembali period dengan alasan wajib serta audit actor/waktu/before-after.
- Finance tidak membuka kembali period yang sudah locked tanpa authority lebih tinggi.
- Source document baru tidak boleh mem-posting ke period locked; perlakuan backdated transaction dan adjustment period berikutnya dibahas pada batch lanjutan.
- Transaction POS, payment, Goods Receipt, Expense, dan source operasional lain memakai tanggal ketika business event benar-benar `POSTED`, bukan tanggal Draft dibuat.
- Backdated posting hanya diizinkan jika target accounting period masih `OPEN`.
- Event dengan original date pada period `LOCKED` tidak membuka period otomatis. Journal masuk period terbuka berikutnya sebagai `PRIOR_PERIOD_ADJUSTMENT` dan menyimpan `original_event_date` serta source/reference.
- Finance dapat mengajukan reopen period untuk koreksi periode lama; Company Admin/Super Admin menyetujui dengan alasan dan audit.
- Manual Journal mengikuti aturan date/lock yang sama dan tidak boleh digunakan untuk melewati period lock.

Candidate status:

```text
OPEN -> LOCKED -> REOPENED -> LOCKED
```

### 8.1 Laporan Finance Minimum

Scope laporan awal:

- Trial Balance;
- General Ledger;
- Balance Sheet/Neraca;
- Profit & Loss/Laba Rugi;
- Cash/Bank Ledger;
- AR Aging;
- AP Aging;
- Reconciliation Outstanding.

Semua laporan tenant-scoped dan dapat difilter minimal berdasarkan accounting period/date, company, store, account, serta dimension terkait bila relevan. Finance, Company Admin, dan Super Admin melihat laporan sesuai company scope. Formula, cut-off, operational pending analysis, cache, dan export mengikuti `docs/FINANCE_REPORTING_AND_CUTOFF_SPEC.md`.

### 8.2 Accounting Date untuk Delayed Posting

- Stock Opname memakai tanggal posting Adjustment sebagai `accounting_date`. Waktu hitung fisik tetap disimpan sebagai `counted_at` untuk audit dan perhitungan expected stock.
- Dokumen delayed lain memakai `posted_at` sebagai accounting date kecuali Finance secara resmi memilih backdated date pada period yang masih open.
- `business_event_at`, `original_event_date`, `posted_at`, dan `accounting_date` disimpan terpisah bila berbeda.
- Prior-period adjustment wajib terlihat pada GL/report dan tidak boleh menyamarkan bahwa source event berasal dari periode terkunci.

### 8.3 Pajak Opsional per Company dan Modul

- Entitlement pajak diaktifkan independen per company dan modul, minimum `SALES_TAX` dan `PURCHASE_TAX`. Company boleh menyalakan Pajak Pembelian tanpa Pajak Penjualan, atau sebaliknya.
- Hanya Super Admin dapat menampilkan/meniadakan entitlement pajak setiap modul.
- Setelah entitlement modul aktif, Finance/Company Admin mengatur tax rule, rate, account, inclusive/exclusive behavior yang didukung, dan penerapan operasional dalam company.
- Harga POS tetap tax-inclusive ketika `SALES_TAX` aktif sesuai keputusan operasional.
- Jika entitlement suatu modul nonaktif, transaksi modul tersebut tetap berjalan tanpa tax line atau kewajiban mapping akun pajak. UI pajaknya disembunyikan dan snapshot tax boleh null/nol.
- Jika entitlement pernah aktif lalu dimatikan, histori dan tax snapshot lama tetap tersedia; disable hanya memengaruhi transaksi baru pada modul tersebut.
- Pajak Masukan dapat aktif ketika `PURCHASE_TAX` aktif walaupun Pajak Keluaran inactive karena `SALES_TAX` mati, dan sebaliknya.
- Field tax base/amount/rate/rule/account snapshot disiapkan nullable agar tax engine dapat ditambahkan tanpa mengubah histori.
- Detail resolver, inclusive/exclusive calculation, rounding, snapshot, return/reversal, dan Tempo mengikuti `docs/TAX_ENGINE_SPEC.md`.
- Integrasi faktur pajak resmi/e-Faktur, identitas pajak counterparty, dan pelaporan pemerintah tetap membutuhkan spesifikasi compliance terpisah.

---

## 9. Role Boundary

| Tindakan | Finance | Company Admin | Super Admin |
|---|---:|---:|---:|
| Kelola COA company | Ya | Ya | Ya, semua company |
| Buat Manual Journal | Ya | Ya | Ya |
| Posting/reverse sesuai workflow | Ya | Ya | Ya |
| Lock accounting period | Ya | Ya | Ya |
| Reopen locked period | Tidak | Ya | Ya |
| Lihat seluruh laporan company | Ya | Ya | Ya |

Company Admin memiliki seluruh wewenang Finance di company-nya. Super Admin memiliki seluruh wewenang lintas-company dan tidak dibatasi role bawahan. Keduanya tetap memakai official posting/reversal/audit workflow, bukan direct UPDATE/DELETE jurnal final.

---

## 10. Keputusan yang Sudah Dikonfirmasi

- Accrual accounting digunakan.
- Template COA retail dasar dibuat per company.
- Kode COA manual dan unik per company.
- Prefix nomor template hanya default dan dapat diubah per company.
- Account type standar dan hierarchy maksimal tiga tingkat; posting hanya ke leaf account.
- Normal balance otomatis tetapi dapat dioverride role berwenang dengan warning/audit.
- Akun terpakai tidak dapat dihapus/diubah type; nama/kode dapat diubah dengan audit.
- Automatic Journal berasal dari source document; posted journal immutable.
- Automatic Journal valid langsung posted; error masuk HOLD/ERROR.
- Manual Journal hanya Finance/Company Admin/Super Admin dengan description wajib dan evidence opsional.
- Manual Journal approval configurable dan maker-checker berlaku bila aktif.
- Opening Balance manual/Excel dibuat Finance dan di-approve Company Admin sebelum posting.
- Finance dapat melihat balance dan melakukan full/partial reconciliation pada COA yang dipilih.
- Reconciliation many-to-many memakai suggestion tetapi selalu memerlukan konfirmasi Finance.
- Bank statement dapat diimport CSV/Excel dengan mapping kolom, preview, partial success, dan duplicate protection.
- Finance dapat unreconcile pada period terbuka; locked period wajib direopen authority lebih tinggi.
- Laporan minimum mencakup Trial Balance, GL, Neraca, P&L, Cash/Bank, AR/AP Aging, dan outstanding reconciliation.
- Satu ledger per company; store/warehouse menjadi dimension.
- Scope currency awal hanya IDR.
- Period bulanan dapat dikunci Finance dan dibuka kembali Company Admin/Super Admin dengan alasan/audit.
- Accounting date memakai posted business event; Stock Opname memakai tanggal posting Adjustment dan menyimpan counted_at terpisah.
- Backdated hanya ke period open; event period locked masuk next open period sebagai PRIOR_PERIOD_ADJUSTMENT kecuali period direopen secara resmi.
- Entitlement pajak opsional dan independen per company/module; hanya Super Admin yang men-toggle, lalu Finance/Company Admin mengatur modul yang aktif.
- Template COA dibuat cukup lengkap dan akun tidak terpakai dapat dinonaktifkan.
- Template leaf mencakup Kas/Bank/clearing, AR/AP, Customer Balance, Inventory, Equity, Sales/HPP, Expense, stock variance, rounding, bad debt/recovery, serta optional tax accounts.
- Template mencakup Utang Ketul kepada Customer sebagai akun terpisah dari Customer Balance.
- Template mencakup Utang Refund Customer agar Credit Note dan realisasi pembayaran refund dapat direkonsiliasi terpisah.
- Template mencakup Piutang Refund Supplier serta Selisih Harga Beli/HPP untuk Purchase Return dan koreksi harga invoice aktual.
- Template mencakup Aset Selisih Setoran Kurang dalam Investigasi, liability Selisih Kas Lebih Belum Diselesaikan, dan Beban Selisih Kas agar variance drawer/deposit tidak langsung disamarkan sebagai pendapatan/beban tanpa review.
- Template mencakup Retur Penjualan Ketul dan Utang/Kredit Vendor Ketul agar retur/overpayment Vendor tidak bercampur dengan customer retail.
- Clearing Setoran Kas menggunakan akun Aset Kas dalam Perjalanan, bukan Kewajiban.
- Finance dapat mengubah mapping Transaction Rule POS per company tanpa mengubah jurnal historis; sistem menjaga validasi type/function, balance, scope, dan audit version.

---

## 11. Keputusan Terbuka — Batch Berikutnya

1. Integrasi faktur pajak resmi/e-Faktur dan compliance bila scope dibuka.
2. Mapping debit/kredit source event yang masih ditandai terbuka pada `FINANCE_INTEGRATION_NOTES.md`.

---

## 12. Instruksi untuk AI Agent

- Baca dokumen ini untuk Finance Core dan `FINANCE_INTEGRATION_NOTES.md` hanya untuk source event terkait.
- Jangan menambah template/mapping COA di luar keputusan yang sudah disetujui tanpa batch keputusan baru.
- Jangan membuat jurnal di client.
- Jangan mengizinkan edit/delete jurnal posted.
- Jangan memakai Manual Journal untuk melewati source workflow.
- Jangan mengaktifkan enforcement sampai data existing, mapping, error queue, test, rollout, dan rollback siap.

---

## 13. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-17 | Sistem memakai accrual accounting | APPROVED |
| 2026-07-17 | Setiap company memperoleh template COA retail dasar | APPROVED |
| 2026-07-17 | Kode COA manual dan unik per company | APPROVED |
| 2026-07-17 | Automatic Journal dari source document; posted immutable dan correction via reversal | APPROVED |
| 2026-07-17 | Manual Journal hanya Finance/Company Admin/Super Admin dengan description wajib | APPROVED |
| 2026-07-17 | Satu ledger per company dengan store/warehouse dimension | APPROVED |
| 2026-07-17 | Currency awal hanya IDR | APPROVED |
| 2026-07-17 | Period bulanan dikunci Finance dan hanya Company Admin/Super Admin dapat reopen dengan audit | APPROVED |
| 2026-07-17 | Account type standar, prefix template 1xxx-8xxx editable, dan hierarchy maksimal tiga tingkat | APPROVED |
| 2026-07-17 | Normal balance otomatis tetapi dapat dioverride role berwenang dengan warning/audit | APPROVED |
| 2026-07-17 | Akun terpakai immutable untuk delete/type; nama/kode masih editable dengan audit | APPROVED |
| 2026-07-17 | Opening Balance manual/Excel dibuat Finance dan di-approve Company Admin | APPROVED |
| 2026-07-17 | Automatic Journal valid langsung posted; Manual Journal approval configurable dengan maker-checker | APPROVED |
| 2026-07-17 | Finance melihat balance dan melakukan reconciliation per COA tanpa mengubah jurnal posted | APPROVED |
| 2026-07-17 | Default reconcilable accounts mencakup Kas/Bank/AR/AP/clearing/Customer Balance/Ketul receivable | APPROVED |
| 2026-07-17 | Reconciliation mendukung many-to-many dan partial; suggestion selalu dikonfirmasi Finance | APPROVED |
| 2026-07-17 | Mutasi Bank diimport CSV/Excel dengan preview/mapping/partial success/duplicate protection | APPROVED |
| 2026-07-17 | Biaya bank memakai adjustment account; unreconcile hanya period terbuka atau setelah reopen | APPROVED |
| 2026-07-17 | Paket laporan minimum Finance telah ditentukan | APPROVED |
| 2026-07-17 | Operational accounting date memakai posted event; Stock Opname memakai posting Adjustment dan menyimpan counted_at | APPROVED |
| 2026-07-17 | Backdated hanya period open; locked-period event menjadi PRIOR_PERIOD_ADJUSTMENT pada next open period | APPROVED |
| 2026-07-17 | Reopen period diajukan Finance dan disetujui Company Admin/Super Admin; Manual Journal tidak melewati lock | APPROVED |
| 2026-07-17 | Pajak bersifat optional entitlement per company; toggle hanya Super Admin | APPROVED sebagai boundary; diperluas per modul 2026-07-19 |
| 2026-07-17 | Template COA lengkap dan akun yang tidak dipakai dapat dinonaktifkan | APPROVED |
| 2026-07-17 | Template leaf COA retail default disetujui; kode/nama editable dan system function/type terkunci setelah dipakai | APPROVED |
| 2026-07-17 | Clearing Setoran Kas memakai Aset Kas dalam Perjalanan, bukan Kewajiban | APPROVED sebagai koreksi akuntansi |
| 2026-07-17 | Optional Pajak Masukan/Keluaran inactive ketika entitlement modul terkait mati | APPROVED; diperjelas 2026-07-19 |
| 2026-07-17 | Mapping jurnal POS dasar merupakan configurable Transaction Rule per company, bukan akun hard-coded | APPROVED |
| 2026-07-17 | Finance/Company Admin/Super Admin dapat mengatur mapping; perubahan versioned dan hanya berlaku ke event baru | APPROVED |
| 2026-07-17 | Utang Ketul Customer memakai akun template terpisah sebelum payout, konversi Balance, atau Offset | APPROVED |
| 2026-07-17 | Utang Refund Customer memakai akun template terpisah antara Credit Note dan pembayaran/konversi saldo | APPROVED |
| 2026-07-17 | Opening Stock membuat FIFO awal dan Debit Inventory/Credit Opening Clearing; Company Admin menjadi poster | APPROVED |
| 2026-07-17 | Stock Gain memakai validated cost suggestion, Stock Loss memakai FIFO aktual, dan correction melalui reversal | APPROVED |
| 2026-07-17 | Goods Receipt mengakui Inventory/AP Provisional; invoice Finance mereklasifikasi AP final dan mengalokasikan variance | APPROVED |
| 2026-07-17 | Template menambah Piutang Refund Supplier dan Selisih Harga Beli/HPP | APPROVED |
| 2026-07-19 | Tax entitlement independen untuk Sales dan Purchase; hanya Super Admin men-toggle setiap modul | APPROVED |
| 2026-07-19 | Template menambah Uang Muka Supplier untuk overpayment AP | APPROVED |
| 2026-07-19 | Template menambah Selisih Kas Lebih Belum Diselesaikan dan Beban Selisih Kas | APPROVED |
| 2026-07-19 | Template menambah Retur Penjualan Ketul dan Utang/Kredit Vendor Ketul | APPROVED |
| 2026-07-19 | Write-off memakai Bad Debt/AR dan Recovery memakai Recovery Income tanpa membuka jurnal lama | APPROVED |
| 2026-07-19 | Bukti/foto sementara memakai external Drive link, bukan Supabase Storage | APPROVED |
| 2026-07-20 | Payment elektronik offline yang belum valid memakai Piutang Pembayaran Offline sampai verified, dibayar pengganti, atau di-write-off | APPROVED |
| 2026-07-20 | Offline Price Variance hanya data analitik dan tidak membuat jurnal otomatis | APPROVED |
| 2026-07-20 | Payment method/fee effective-dated per company/store; split fee dihitung per payment leg | APPROVED |
| 2026-07-20 | Company-borne gateway fee menjadi Beban Administrasi; customer-borne surcharge menjadi Pendapatan Penggantian Biaya Pembayaran | APPROVED |
| 2026-07-20 | Template menambah Selisih Setoran Kurang dalam Investigasi; under/over-deposit diselesaikan append-only tanpa membuka Session/Setor Kas final | APPROVED |
| 2026-07-20 | Customer/Supplier Debit/Credit Note memakai posted source, original tax snapshot, configurable approval, dan immutable posting | APPROVED |
| 2026-07-20 | Transaction Category mengikat permanent system key ke versioned account-function mapping dengan explicit fallback dan HOLD/ERROR | APPROVED |
| 2026-07-20 | Settlement variance menjadi reconciliation exception dan tidak otomatis gain/loss | APPROVED |
| 2026-07-20 | Tax Rule effective-dated memakai Product Category default/Product override dan scope Sales/Purchase terpisah | APPROVED |
| 2026-07-20 | Sales inclusive; Purchase invoice inclusive/exclusive; calculation PER_DOCUMENT default atau PER_LINE | APPROVED |
| 2026-07-20 | Return/reversal memakai original tax snapshot; Tempo payment tidak repost tax; bad-debt tax tidak otomatis | APPROVED |
| 2026-07-20 | Purchase three-way matching partial/many-to-many memakai allocation line dan tidak membuat stock dari invoice | APPROVED |
| 2026-07-20 | Residual AP Provisional tidak auto-expire; controlled close mengoreksi Inventory/FIFO dan HPP variance | APPROVED |
| 2026-07-20 | FIFO unit cost/base quantity memakai precision tinggi dan jurnal IDR dibulatkan pada boundary dokumen | APPROVED |
| 2026-07-20 | Weight variance bersifat logistik dan tidak membuat financial/stock event otomatis | APPROVED |
| 2026-07-20 | Financial report memakai POSTED; Draft/Hold/Pending tersedia terpisah untuk operational delay analysis | APPROVED |
| 2026-07-20 | Cut-off timezone/as-of, prior-period presentation, report formula, FIFO-vs-GL, dan AR/AP residual dikunci | APPROVED |
