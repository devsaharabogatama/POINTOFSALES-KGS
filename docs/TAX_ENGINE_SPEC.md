# Tax Engine Sales dan Purchase

**Status:** Business/design decision approved; belum menjadi bukti implementasi  
**Scope:** Entitlement, Master Tax Rule, kalkulasi, snapshot, jurnal, retur, dan Tempo  
**Tidak termasuk:** Integrasi e-Faktur/faktur pajak resmi, pelaporan pemerintah, dan klaim kepatuhan pajak

---

## 1. Prinsip dan Entitlement

- Pajak bersifat optional per company dan modul.
- Entitlement minimum adalah `SALES_TAX` dan `PURCHASE_TAX`; keduanya independen.
- Hanya Super Admin dapat mengaktifkan, menonaktifkan, atau menyembunyikan entitlement setiap modul.
- Setelah entitlement aktif, Finance dan Company Admin mengelola Master Tax, rate, account, effective date, serta rule dalam company.
- Entitlement nonaktif menyembunyikan input pajak dan membuat transaksi baru tanpa tax line. Histori/snapshot pajak lama tidak dihapus.
- Draft menghitung ulang memakai entitlement dan Tax Rule aktif ketika akan diposting. Dokumen posted tetap immutable.

---

## 2. Master Tax Minimum

```text
company_id
tax_code
tax_name
tax_scope = SALES | PURCHASE
rate_percent
calculation_scope = PER_LINE | PER_DOCUMENT
default_price_mode = INCLUSIVE | EXCLUSIVE
tax_account_function
is_recoverable nullable        -- khusus PURCHASE
effective_from
effective_to nullable
status = ACTIVE | INACTIVE
created_by / created_at
updated_by / updated_at
```

- `tax_code` unik dalam company.
- Satu Tax Rule hanya memiliki satu scope; rule Sales tidak dapat dipakai sebagai Purchase rule atau sebaliknya.
- Rate/rule effective-dated dan tidak boleh overlap secara ambigu pada target yang sama.
- Rule yang sudah dipakai tidak dihapus; gunakan inactive/end date.
- Perubahan hanya berlaku untuk posting baru. Setiap transaksi menyimpan snapshot rule/version.

---

## 3. Resolver Tax Rule

Urutan resolver awal:

```text
Product tax override aktif
-> default Tax Rule Product Category
-> no tax bila tidak ada rule eligible
```

- Product Category menyimpan default Sales Tax Rule dan Purchase Tax Rule secara terpisah.
- Produk dapat override masing-masing scope secara terpisah.
- Override dan category rule wajib berasal dari company yang sama, aktif, effective, dan sesuai entitlement modul.
- Tidak ada fallback lintas company atau pemilihan berdasarkan nama/kode hard-coded.
- Missing required account/rule membuat financial posting `HOLD/ERROR`, bukan menebak akun.

---

## 4. Inclusive dan Exclusive

### 4.1 Sales

Harga POS tetap `INCLUSIVE` ketika `SALES_TAX` aktif.

```text
tax_base = gross_tax_inclusive / (1 + rate)
tax_amount = gross_tax_inclusive - tax_base
```

Pricelist, diskon manual, dan rounding mengikuti pricing stack POS. Sistem menyimpan gross, tax base, tax amount, diskon, dan rounding secara terpisah agar tidak mencampurkan pajak dengan potongan harga.

### 4.2 Purchase

Supplier Invoice dapat memilih `INCLUSIVE` atau `EXCLUSIVE` sesuai invoice fisik Supplier.

```text
INCLUSIVE:
tax_base = gross / (1 + rate)
tax_amount = gross - tax_base

EXCLUSIVE:
tax_base = net_before_tax
tax_amount = tax_base x rate
gross = tax_base + tax_amount
```

Pilihan price mode disimpan pada invoice dan line snapshot. Cashier/Goods Receipt tidak mengarang pajak supplier; Finance memvalidasi pajak saat Supplier Invoice.

---

## 5. Calculation Scope dan Rounding

- Tax Rule memilih `PER_LINE` atau `PER_DOCUMENT`.
- Default awal adalah `PER_DOCUMENT` agar total pajak mudah direkonsiliasi terhadap invoice.
- `PER_LINE`: hitung dan bulatkan tax setiap line lalu jumlahkan.
- `PER_DOCUMENT`: kelompokkan line berdasarkan Tax Rule/rate, hitung total base/amount dengan precision tinggi, bulatkan sekali pada total group, lalu alokasikan residual ke line dengan tax base terbesar.
- Nilai final mengikuti precision IDR; intermediate calculation memakai precision lebih tinggi.
- Tax rounding disimpan terpisah dan tidak dicampurkan dengan rounding grand total POS Rp100.
- Metode kalkulasi, precision, residual allocation, dan hasil per line/document menjadi snapshot transaksi.

---

## 6. Jurnal

### 6.1 Sales Tax

```text
Sale tax-inclusive posted:
Debit  Kas / Bank / Clearing / Piutang (gross)
Credit Penjualan (tax base setelah pricing/diskon)
Credit Pajak Keluaran (tax amount)

Debit  HPP
Credit Persediaan
```

Payment berikutnya hanya menyelesaikan settlement/Piutang dan tidak membuat tax line baru.

### 6.2 Purchase Tax Recoverable

```text
Supplier Invoice:
Debit  Persediaan / Expense / account source (net tax base)
Debit  Pajak Masukan (recoverable tax)
Credit Utang Supplier Final (gross)
```

- Reklasifikasi AP Provisional dan price variance tetap mengikuti workflow Purchasing.
- Tax Purchase non-recoverable masuk acquisition cost Persediaan atau Expense sesuai Tax Rule/source allocation, bukan Pajak Masukan.
- `PURCHASE_TAX` dapat aktif walaupun `SALES_TAX` mati dan sebaliknya.

---

## 7. Snapshot, Retur, Reversal, dan Tempo

Snapshot minimum:

```text
tax_rule_id / rule_version
tax_code / tax_name
tax_scope
rate_percent
price_mode
calculation_scope
tax_base
tax_amount
tax_rounding
tax_account_id / account snapshot
is_recoverable nullable
effective rule reference
```

- Sales Return/Credit Note membalik Pajak Keluaran berdasarkan snapshot bagian transaksi asal yang diretur.
- Purchase Return/Debit-Credit Note membalik Pajak Masukan atau non-recoverable tax berdasarkan invoice/receipt asal.
- Partial return membalik pajak secara proporsional terhadap refundable base dan cumulative reversal tidak boleh melebihi tax original.
- Reversal memakai rule/account snapshot asli, bukan rate/master terkini.
- Sale Tempo mengakui Pajak Keluaran ketika sale posted. Cicilan/pelunasan tidak membuat pajak baru.
- Write-off Piutang tidak otomatis mengoreksi Pajak Keluaran. Bad-debt tax adjustment memerlukan workflow/rule Finance terpisah sebelum boleh diimplementasikan.

---

## 8. Report dan Boundary Kepatuhan

Laporan internal minimum:

- Sales Tax by period/rule/store/source;
- Purchase Tax recoverable/non-recoverable;
- Tax base, tax amount, rounding, return/reversal, dan net tax;
- missing/invalid Tax Rule/account;
- reconciliation tax ledger terhadap source document.

Tax Engine ini tidak otomatis menghasilkan dokumen resmi pemerintah, nomor faktur pajak, file upload otoritas, atau jaminan kepatuhan. Fitur tersebut membutuhkan spesifikasi baru mengenai identitas pajak company/customer/supplier, numbering, format, regulasi, approval, amendment, dan integrasi eksternal.

---

## 9. Guardrail Implementasi

- Seluruh Master Tax, assignment, snapshot, account, dan report tenant-scoped.
- Kalkulasi final dan jurnal dilakukan server-side; client hanya menampilkan preview.
- Rate/account dari client tidak dipercaya tanpa resolver server.
- Tax line posted tidak diedit; correction memakai return, Credit/Debit Note, atau reversal.
- Idempotency source transaction juga melindungi tax line dari duplikasi.
- Aktivasi entitlement tidak boleh langsung memaksa field existing menjadi `NOT NULL`; lakukan migration nullable, backfill, missing-mapping report, test, lalu enforcement bertahap.

---

## 10. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-20 | Master Tax company berisi kode, nama, rate, Sales/Purchase scope, account, status, dan effective date | APPROVED |
| 2026-07-20 | SALES_TAX dan PURCHASE_TAX independen dan hanya ditoggle Super Admin | APPROVED |
| 2026-07-20 | Finance/Company Admin mengatur rate, account, dan rule setelah entitlement aktif | APPROVED |
| 2026-07-20 | Product Category menjadi default Tax Rule dan Produk dapat override | APPROVED |
| 2026-07-20 | Sales tax-inclusive; Supplier Invoice Purchase dapat inclusive/exclusive | APPROVED |
| 2026-07-20 | PER_DOCUMENT menjadi default dan PER_LINE dapat dikonfigurasi | APPROVED |
| 2026-07-20 | Return/reversal memakai tax snapshot transaksi asli | APPROVED |
| 2026-07-20 | Tempo mengakui tax saat sale; payment tidak repost tax; bad-debt adjustment tidak otomatis | APPROVED |
