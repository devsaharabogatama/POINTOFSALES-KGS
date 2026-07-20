# Spesifikasi Expense dan Arus Kas Non-Penjualan

**Status:** Pembahasan business workflow aktif  
**Tanggal pembukaan:** 2026-07-17  
**Boundary:** Dokumentasi dahulu; jangan membuat schema, RPC, API, atau UI sebelum keputusan pada dokumen ini cukup lengkap.

---

## 1. Tujuan

Dokumen ini menjadi sumber utama pengeluaran operasional serta pergerakan uang non-penjualan di toko/POS. Desain mengutamakan istilah sederhana untuk Cashier tanpa menghilangkan kebutuhan rekonsiliasi Finance.

Scope:

- POS Expense dengan sumber Cash atau Transfer/Bank;
- requested amount, uang yang dicairkan, biaya aktual, uang kembali, dan outstanding;
- Cash In non-penjualan;
- dampak Cash Out sebagai movement drawer;
- Cashier Session, approval opsional, bukti, reversal, dan integrasi Finance;
- exceptional settlement Customer Balance bila digunakan.

Cash Advance tidak menjadi jenis transaksi atau menu terpisah. Kebutuhan uang muka operasional ditangani di dalam flow Expense.

---

## 2. Model Sederhana untuk Operasional

Sistem memisahkan dua dimensi:

1. **Tujuan bisnis:** apakah uang menjadi Expense atau hanya berpindah tempat.
2. **Movement uang:** apakah Cash masuk/keluar dari drawer atau pembayaran terjadi melalui Transfer/Bank.

| Kejadian | Expense | Cash drawer |
|---|---:|---:|
| Beli bensin Rp30.000 dengan Cash | Rp30.000 | Cash Out Rp30.000 |
| Beli bensin Rp30.000 dengan Transfer | Rp30.000 | Tidak berubah |
| Pindah Rp1.000.000 dari drawer ke rekening/brankas | Rp0 | Cash Out Rp1.000.000 |
| Top-up uang kecil ke drawer | Rp0 | Cash In sesuai nominal |

`CASH_OUT` bukan menu biaya tersendiri. Ia adalah movement yang timbul dari Expense Cash atau pemindahan uang non-expense. `CASH_IN` dipakai untuk top-up/pengembalian non-penjualan dan selalu menyimpan sumber.

---

## 3. Expense dengan Pengajuan dan Uang Kembali

Satu dokumen Expense dapat mencakup pengajuan awal sampai penyelesaian:

```text
requested_amount
disbursed_amount
actual_expense_amount
returned_amount
outstanding_amount
```

Invariant:

```text
outstanding_amount = disbursed_amount - actual_expense_amount - returned_amount
```

Nilai `disbursed_amount`, `actual_expense_amount`, dan `returned_amount` merupakan total dari event detail append-only, bukan angka yang ditimpa langsung.

Contoh bensin:

```text
requested    = 50.000
disbursed    = 50.000
actual       = 30.000
returned     = 20.000
outstanding  = 0
```

Untuk metode Cash, pencairan Rp50.000 menjadi Cash Out sesi dan pengembalian Rp20.000 menjadi Cash In sesi; laporan Expense hanya Rp30.000. Untuk Transfer, Cashier tetap melihat nominal yang diajukan, tetapi drawer tidak berubah.

- Jika biaya aktual melebihi pencairan, Cashier membuat additional disbursement pada Expense yang sama. Additional disbursement menyimpan approval/config snapshot dan source payment tersendiri.
- Expense wajib menyimpan `responsible_party` yang memegang/menerima uang agar outstanding dapat ditelusuri. Pihak tersebut dapat berupa Cashier, Store Manager, pegawai lain, atau pihak eksternal.
- Sebelum `DISBURSED`, Draft/Submitted masih dapat diedit sesuai authority. Setelah ada pencairan, nilai lama tidak diedit; perubahan hanya melalui additional disbursement, actual settlement, return, correction, atau reversal.
- Pengembalian Cash boleh terjadi pada sesi berikutnya. Cash In dibukukan pada sesi yang menerima uang, tetapi tetap mereferensikan Expense dan sesi pencairan asal.
- Draft/Submitted yang belum memiliki disbursement boleh dibatalkan pembuatnya. Cancellation menyimpan actor, waktu, dan alasan opsional.
- Setelah disbursed, Expense tidak dapat dibatalkan langsung. Jika kegiatan tidak jadi, seluruh dana wajib dikembalikan dan dokumen ditutup sebagai `SETTLED_NO_EXPENSE`.
- Jika nominal/kategori salah setelah settled, Store Manager mengajukan correction dan Finance membuat reversal serta dokumen pengganti. Histori lama tidak diedit.

---

## 4. Boundary dan Guardrail

- Semua dokumen tenant-scoped menggunakan `company_id`; store wajib berada pada company yang sama.
- Event Cash wajib mereferensikan POS terminal, active Cashier Session, Cashier, dan waktu.
- Expense bukan Sale/Refund dan tidak membuat stock movement.
- Expense Cash serta pengembaliannya wajib masuk Ringkasan Tutup Sesi.
- Expense Transfer/Bank direkap tetapi tidak mengubah expected cash drawer.
- Dokumen posted tidak diedit/dihapus; koreksi memakai reversal append-only.
- Kategori Expense menjadi Master Data reusable per company.
- Kategori Expense menentukan akun biaya/COA tujuan. Metode pembayaran menentukan sisi Kas/Bank. Field COA boleh kosong pada fase dokumentasi/operasional sekarang, tetapi harus valid sebelum financial posting diaktifkan.
- Disbursement sebelum biaya final didebit ke Outstanding Expense Operasional dan dikredit ke Kas/Bank. Settlement memindahkan actual expense ke COA Kategori; return mengurangi outstanding.
- Exceptional settlement Customer Balance memakai kategori Expense khusus dengan mandatory source ledger. Approval Finance/Company Admin tetap wajib walaupun approval Expense umum nonaktif.
- Bukti dapat dikonfigurasi wajib atau opsional per kategori.
- Approval dapat diaktifkan/dinonaktifkan melalui konfigurasi operasional; audit tetap wajib dalam kedua mode.
- Company Admin mengatur default approval pada company dan Store Manager dapat mengatur override untuk store dalam scope-nya. Super Admin dapat melakukan seluruh konfigurasi dan tindakan operasional lintas-company tanpa pembatasan role bawahan.
- Feature visibility/entitlement hanya dapat diaktifkan/dinonaktifkan Super Admin.
- Service-role key dan mutation lintas-company tidak boleh berada di frontend.

---

## 5. Candidate Lifecycle

```text
DRAFT
-> SUBMITTED
-> APPROVED / REJECTED        (bila approval aktif)
-> PAYMENT_PENDING            (Transfer/Bank yang belum dieksekusi Finance)
-> DISBURSED
-> PARTIALLY_SETTLED
-> SETTLED / SETTLED_NO_EXPENSE
-> REVERSED                   (bila dikoreksi)
```

Jika approval dinonaktifkan, dokumen otomatis approved setelah submit, tetapi actor, waktu, dan snapshot konfigurasi wajib disimpan.

Scope awal tidak memakai limit nominal atau approval bertingkat. Ketika approval aktif, seluruh Expense mengikuti satu approval Store Manager/authority lebih tinggi. Additional disbursement juga mengikuti rule approval yang aktif pada saat permintaan tambahan dibuat.

Jika approval aktif, uang Cash baru boleh dikeluarkan setelah Store Manager atau authority yang lebih tinggi menyetujui. Karena itu `REJECTED` terjadi sebelum `DISBURSED` dan tidak mengubah drawer.

Untuk Transfer/Bank, Cashier mengajukan nominal dan tetap dapat melihat statusnya. Setelah approval bila diwajibkan, Finance mengeksekusi/mengonfirmasi transfer. Dokumen belum dianggap dibayar sebelum Finance confirmation.

---

## 6. Candidate Data

```text
id
document_no
company_id
store_id
pos_terminal_id nullable
cashier_session_id nullable
category_id
responsible_party_type
responsible_party_id nullable
responsible_party_name_snapshot
requested_amount
disbursed_amount
actual_expense_amount
returned_amount
outstanding_amount
payment_method                 CASH | TRANSFER | BANK
recipient
description
evidence_url nullable
expected_settlement_date nullable
source_document_type nullable
source_document_id nullable
status
approval_required_snapshot
created_by/at
submitted_by/at nullable
approved_by/at nullable
disbursed_by/at nullable
settled_by/at nullable
reversal_of_id nullable
canceled_by/at nullable
cancel_reason nullable
```

`evidence_url` mengikuti `EXTERNAL_EVIDENCE_LINK_POLICY.md`: Cashier menempelkan link Google Drive/HTTPS, Finance membuka link dari Backoffice, dan aplikasi tidak menyimpan binary foto/file. Link tidak otomatis mengonfirmasi payment.

Event detail minimum:

```text
expense_disbursements[]        amount, method, session, actor, approval snapshot
expense_settlements[]          actual amount, category, evidence, actor
expense_returns[]              amount, method, receiving session, actor
expense_corrections[]          before/after reference, reason, actor
```

Cash In membutuhkan source, amount, session, dan reference document yang jelas. Internal cash transfer belum masuk scope awal; Setor Kas tetap memakai workflow tersendiri.

### 6.1 Master Kategori Expense

```text
id
company_id
code
name
description nullable
expense_coa_id nullable        -- wajib sebelum financial posting aktif
evidence_policy               OPTIONAL | REQUIRED
approval_policy               USE_DEFAULT | REQUIRED | NOT_REQUIRED
default_payment_method nullable
is_active
created_by/at
updated_by/at
```

- Kategori menjadi routing utama akun Expense. Transaksi menyimpan snapshot category/COA/rule yang digunakan agar perubahan master tidak mengubah histori.
- Metode Cash memilih akun kas terkait sesi/store; Transfer/Bank memilih akun/clearing pembayaran. Detail akun final tetap fase Finance.
- Kode kategori unik dalam company dan boleh sama pada company lain.
- Kategori inactive tetap muncul pada histori tetapi tidak dapat dipakai Expense baru.

### 6.2 Role Matrix Awal

| Tindakan | Cashier | Store Manager | Finance | Company Admin | Super Admin |
|---|---:|---:|---:|---:|---:|
| Buat/submit Expense operasional | Ya | Ya | Ya | Ya | Ya |
| Pilih metode dan requested amount | Ya | Ya | Ya | Ya | Ya |
| Approve Expense store | Tidak | Ya | Ya | Ya | Ya |
| Keluarkan Cash setelah approval/auto-approval | Ya, sesi sendiri | Ya | Tidak melalui drawer POS | Ya | Ya |
| Eksekusi/konfirmasi Transfer | Tidak | Tidak | Ya | Ya | Ya |
| Isi actual expense dan uang kembali | Ya | Ya | Ya | Ya | Ya |
| Review settlement | Tidak | Ya | Ya | Ya | Ya |
| Reversal posted | Tidak | Sesuai scope | Ya | Ya | Ya |
| Ubah default approval company | Tidak | Tidak | Tidak | Ya | Ya |
| Override approval store | Tidak | Ya | Tidak | Ya | Ya |
| Toggle visibility feature | Tidak | Tidak | Tidak | Tidak | Ya |

Super Admin memiliki seluruh wewenang pada semua company dan tidak dibatasi oleh baris role bawahan di atas.

- Pembuat dapat cancel Draft/Submitted miliknya selama belum ada disbursement.
- Store Manager mengajukan correction terhadap settled Expense; Finance melakukan reversal/dokumen pengganti. Company Admin dan Super Admin mewarisi authority sesuai hierarchy.

---

## 7. Relasi dengan Workflow Lain

- Ringkasan Sesi menampilkan opening cash, Cash sale/payment, refund, Ketul Cash, Expense Cash Out, Expense Return Cash In, Cash In lain, Setor Kas, serta closing/variance.
- Exceptional settlement Customer Balance dapat memakai Expense khusus dengan reference ledger; workflow tersebut tidak boleh dijalankan Cashier secara bebas.
- Setor Kas yang sudah dibahas tetap menjadi dokumen tersendiri dan tidak boleh diklasifikasikan sebagai Expense.
- Transfer Expense harus menampilkan requested amount kepada Cashier dan menyimpan status eksekusi pembayaran agar tidak dianggap Cash drawer movement.
- Cashier mengisi biaya aktual dan uang kembali. Store Manager atau Finance mereview settlement sesuai scope; Company Admin dan Super Admin mewarisi kewenangan tersebut.
- Expense outstanding tidak memblokir tutup sesi. Sistem memberi warning, menyimpan keterkaitan ke sesi asal, dan membawa dokumen terbuka sampai diselesaikan pada sesi/waktu berikutnya.
- Scope awal tidak menyediakan menu internal cash transfer/pemindahan ke brankas. Gunakan Expense, Cash In, dan Setor Kas sesuai tujuan masing-masing.
- Cash In awal hanya mendukung `DRAWER_TOP_UP`, `EXPENSE_RETURN`, `CASHIER_SHORTAGE_TOP_UP`, dan `OTHER_WITH_REASON`. Setiap Cash In wajib mempunyai source/reason; Expense Return otomatis mereferensikan Expense.
- Cash In dibuat Cashier pada sesi aktif dan langsung menambah expected cash tanpa approval terpisah. Store Manager/Finance melakukan review.
- `CASHIER_SHORTAGE_TOP_UP` wajib mereferensikan sesi kekurangan. Top-up tidak mengubah/menghapus original shortage; laporan menampilkan shortage awal, top-up, dan residual variance secara terpisah.
- Mapping Finance dasar sudah disetujui: disbursement memakai Outstanding Expense, actual memakai akun Kategori Expense, dan return mengurangi outstanding. Account ID tetap configurable per company.
- Opening cash sesi hanya physical count dan tidak menciptakan jurnal. Top-up dari Brankas wajib memakai Cash In `DRAWER_TOP_UP` dengan source account jelas.
- Shortage diakui sebagai Piutang Kekurangan Kasir; top-up mengurangi piutang. Overage masuk liability sementara sampai diselesaikan Finance.
- Setor Bank memakai Kas dalam Perjalanan sampai mutasi Bank dikonfirmasi; tujuan Brankas memakai transfer Kas Laci ke Kas Besar.

### 7.1 Outstanding, Aging, dan Reporting

- `expected_settlement_date` bersifat opsional saat pengajuan.
- Dokumen dengan outstanding di atas nol setelah tanggal tersebut memperoleh flag `OVERDUE_SETTLEMENT`. Flag hanya warning dan tidak memblokir tutup sesi atau transaksi lain.
- Laporan outstanding dapat difilter berdasarkan responsible party, kategori, company/store, rentang tanggal, status, payment method, dan aging.
- Laporan menampilkan requested, seluruh disbursement, actual expense, return, outstanding, sesi asal/return, approval, evidence status, dan source/reversal.
- Output tersedia dalam Excel dan PDF.
- Status operasional dan aging dipisahkan agar `PARTIALLY_SETTLED` dapat sekaligus `OVERDUE_SETTLEMENT`.

### 7.2 Offline dan Idempotency

- Jika approval Expense nonaktif pada cached configuration, Expense Cash boleh dibuat lokal sebagai `PENDING_SYNC`, langsung mengurangi expected cash lokal, dan wajib memakai `client_expense_id`/idempotency key yang tetap saat retry.
- Jika approval aktif, offline hanya boleh menyimpan Draft. Cash tidak boleh dikeluarkan melalui sistem sampai online dan approval berhasil.
- Expense Transfer/Bank offline hanya Draft; tidak ada payment confirmation offline.
- Sync server memvalidasi company/store/session, category, config snapshot, amount, duplicate key, dan reference. Server tidak boleh membuat movement Cash dua kali.
- Bukti file dapat diantrikan setelah payload utama, tetapi status bukti wajib terlihat. Jika kategori mewajibkan bukti, settlement/posting final tidak boleh selesai sampai upload mendapat acknowledgement.

---

## 8. Keputusan yang Sudah Dikonfirmasi

- Cash Advance dihapus sebagai jenis/menu terpisah dan digabung ke Expense.
- Expense adalah pengeluaran operasional toko dan dapat dibayar dari Cash maupun Transfer/Bank.
- Cashier perlu dapat mencatat Expense operasional agar masuk laporan.
- Approval bersifat opsional dan dapat diaktifkan/dinonaktifkan.
- Expense mendukung pengajuan, pencairan, biaya aktual, dan uang kembali dalam satu alur.
- Kategori adalah Master Data per company; bukti configurable wajib/opsional per kategori.
- Hanya metode Cash yang mengubah drawer; Transfer tetap direkap dan requested amount terlihat oleh Cashier.
- Cashier, Store Manager, Finance, Company Admin, dan Super Admin dapat membuat Expense sesuai scope; Super Admin tidak dibatasi.
- Company Admin mengatur default approval company, Store Manager dapat override per store, dan Super Admin dapat mengatur semuanya.
- Approval nonaktif menghasilkan auto-approval setelah submit; approval aktif mewajibkan approval sebelum Cash dikeluarkan.
- Transfer baru dianggap dibayar setelah Finance/Company Admin/Super Admin mengonfirmasi eksekusi.
- Cashier mengisi actual expense/uang kembali; Store Manager atau Finance melakukan review.
- Expense outstanding tidak memblokir tutup sesi dan tetap dibawa sebagai dokumen terbuka dengan warning.
- Scope awal tidak memiliki menu Pemindahan Kas; cukup Expense, Cash In, dan Setor Kas.
- Scope awal tidak memakai limit/approval bertingkat; seluruh Expense mengikuti satu rule approval aktif/nonaktif.
- Pengembalian boleh masuk sesi berbeda dengan reference Expense/sesi asal; additional disbursement tetap satu dokumen.
- Expense menyimpan pihak penanggung jawab outstanding dan memakai event append-only setelah pencairan.
- Kategori Expense menentukan routing COA; COA boleh kosong sekarang tetapi wajib sebelum financial posting aktif.
- Cash In awal mendukung top-up drawer, Expense Return, top-up kekurangan Cashier, dan source lain dengan alasan.
- Offline Cash Expense hanya dapat `PENDING_SYNC` bila approval nonaktif; approval aktif dan Transfer hanya Draft.
- Draft/Submitted boleh dicancel pembuat sebelum disbursed; setelah disbursed hanya return/settlement/reversal.
- Full return tanpa Expense menghasilkan `SETTLED_NO_EXPENSE`.
- Correction settled diajukan Store Manager dan dieksekusi Finance melalui reversal + replacement.
- Settlement date opsional; overdue hanya warning. Outstanding report mendukung filter lengkap dan export Excel/PDF.
- Cash In tidak membutuhkan approval, sedangkan shortage top-up tetap mempertahankan original variance.
- Exceptional Customer Balance settlement selalu memakai kategori khusus dan approval Finance/Company Admin.

---

## 9. Keputusan Terbuka — Batch Berikutnya

1. Posting Finance, COA detail, dan periode accounting lock.
2. Retention evidence/export dan batas ukuran file berdasarkan kapasitas plan aktual.

---

## 10. Instruksi untuk AI Agent

- Baca dokumen ini lebih dahulu untuk task Expense/arus kas non-penjualan.
- Baca `POS_DEVELOPMENT_NOTES.md` hanya untuk Cashier Session/cash drawer dan `FINANCE_INTEGRATION_NOTES.md` hanya untuk jurnal.
- Routing kategori Expense ke COA mengikuti `TRANSACTION_CATEGORY_ACCOUNT_MAPPING_SPEC.md`; jangan hard-code nomor akun pada POS.
- Jangan membuat jenis `CASH_ADVANCE` baru; gunakan lifecycle Expense requested/disbursed/actual/returned/outstanding.
- Jangan menyamakan internal cash movement dengan Expense.
- Jangan mengubah expected cash tanpa source document dan audit trail.
- Untuk selisih Setor Kas, baca `DEPOSIT_VARIANCE_RESOLUTION_SPEC.md`; jangan memakai Expense untuk menyamarkan under/over-deposit.
- Jangan membuat UI/schema sebelum keputusan terbuka diselesaikan bertahap.

---

## 11. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-17 | Cash Advance dihapus sebagai jenis terpisah dan diserap ke flow Expense | APPROVED |
| 2026-07-17 | Expense mendukung Cash/Transfer serta requested/disbursed/actual/returned/outstanding | APPROVED |
| 2026-07-17 | Approval Expense bersifat configurable aktif/nonaktif | APPROVED |
| 2026-07-17 | Kategori Expense reusable dan bukti configurable per kategori | APPROVED |
| 2026-07-17 | Transfer tidak mengubah drawer; requested amount tetap terlihat oleh Cashier | APPROVED |
| 2026-07-17 | Semua role terkait dapat membuat Expense sesuai scope; Super Admin memiliki seluruh wewenang lintas-company | APPROVED |
| 2026-07-17 | Company Admin mengatur default approval dan Store Manager dapat override per store; Super Admin dapat mengatur semua | APPROVED |
| 2026-07-17 | Approval nonaktif auto-approve; approval aktif wajib selesai sebelum Cash dikeluarkan | APPROVED |
| 2026-07-17 | Transfer dieksekusi/dikonfirmasi Finance dan belum dianggap dibayar sebelum confirmation | APPROVED |
| 2026-07-17 | Cashier mengisi actual/return, Manager/Finance review, dan outstanding tidak memblokir tutup sesi | APPROVED |
| 2026-07-17 | Scope awal cukup Expense, Cash In, dan Setor Kas tanpa menu internal cash transfer | APPROVED |
| 2026-07-20 | Under/over-deposit bukan Expense otomatis dan wajib diselesaikan melalui workflow variance terpisah | APPROVED |
| 2026-07-17 | Tidak ada approval bertingkat; jika aktif seluruh Expense memerlukan satu approval | APPROVED |
| 2026-07-17 | Return boleh masuk sesi berbeda dan additional disbursement tetap dalam satu Expense | APPROVED |
| 2026-07-17 | Responsible party wajib; setelah disbursed perubahan memakai event append-only | APPROVED |
| 2026-07-17 | Kategori Expense menentukan COA; COA boleh kosong sekarang tetapi wajib sebelum Finance posting aktif | APPROVED |
| 2026-07-17 | Cash In awal mencakup top-up, Expense Return, Cashier shortage top-up, dan source lain beralasan | APPROVED |
| 2026-07-17 | Offline Cash Expense PENDING_SYNC hanya saat approval nonaktif; approval aktif/Transfer hanya Draft | APPROVED |
| 2026-07-17 | Cancel hanya sebelum disbursed; full return tanpa biaya menjadi SETTLED_NO_EXPENSE | APPROVED |
| 2026-07-17 | Correction settled dibuat melalui request Store Manager dan reversal/replacement Finance | APPROVED |
| 2026-07-17 | Settlement date opsional; overdue warning tanpa blocking dan report dapat export Excel/PDF | APPROVED |
| 2026-07-17 | Cash In tanpa approval; shortage top-up tidak menghapus original variance | APPROVED |
| 2026-07-19 | Expense disbursement/actual/return memakai Outstanding Expense dan COA Kategori | APPROVED |
| 2026-07-19 | Opening cash tidak membuat jurnal; top-up membutuhkan Cash In dengan source | APPROVED |
| 2026-07-19 | Shortage menjadi receivable, overage menjadi liability sementara, dan resolution oleh Finance | APPROVED |
| 2026-07-19 | Setor Bank memakai Kas dalam Perjalanan; Setor Brankas langsung antar akun kas | APPROVED |
| 2026-07-19 | Bukti Expense/Transfer memakai external Drive link; tidak ada upload binary aplikasi | APPROVED |
| 2026-07-17 | Exceptional Customer Balance settlement selalu memakai kategori khusus dan approval Finance/Company Admin | APPROVED |
