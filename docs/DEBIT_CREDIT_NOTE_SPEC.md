# Spesifikasi Debit Note dan Credit Note

**Status:** APPROVED untuk workflow dan accounting boundary  
**Scope:** Koreksi nilai dokumen Sales/Purchase yang sudah posted  
**Bukan scope:** Implementasi schema/API/UI, faktur pajak resmi, atau perubahan stok tanpa Return

---

## 1. Tujuan dan Dependency

Dokumen ini menjadi source contract koreksi finansial setelah transaksi diposting. Note tidak boleh mengedit dokumen asli, menyamarkan perpindahan kas, atau mengubah stock secara langsung.

Baca bersama `FINANCE_CORE_ACCOUNTING_SPEC.md`, `FINANCE_INTEGRATION_NOTES.md`, `POS_DEVELOPMENT_NOTES.md`, `PRODUCT_STOCK_MASTERDATA_SPEC.md`, `TAX_ENGINE_SPEC.md`, dan `EXTERNAL_EVIDENCE_LINK_POLICY.md`.

---

## 2. Jenis Dokumen

| Jenis | Dampak utama |
|---|---|
| `CUSTOMER_CREDIT_NOTE` | Mengurangi Piutang Customer atau membentuk Utang Refund Customer |
| `CUSTOMER_DEBIT_NOTE` | Menambah Piutang Customer |
| `SUPPLIER_CREDIT_NOTE` | Mengurangi Utang Supplier atau membentuk Piutang Refund Supplier |
| `SUPPLIER_DEBIT_NOTE` | Menambah Utang Supplier |

UI wajib menampilkan label lengkap Customer/Supplier agar arah Note tidak ambigu.

---

## 3. Source dan Scope Koreksi

- Note wajib mengacu ke dokumen posted dalam company yang sama: Sale/Pro Forma, Invoice Penjualan, Supplier Invoice, Sales Return, atau Purchase Return.
- Free-standing Note dilarang. Koreksi ledger tanpa source operasional memakai Manual Journal terpisah.
- Note dapat full/partial, document-level/per-line, serta memiliki reason category dan note penjelasan.
- Reason category company memakai system group minimum `PRICE_CORRECTION`, `DISCOUNT_CORRECTION`, `TAX_CORRECTION`, `RETURN`, `BILLING_ERROR`, dan `OTHER`.
- Source snapshot, nomor, tanggal, currency, party, line, tax, dimension, dan account mapping version disimpan.

---

## 4. Financial-only vs Quantity-impact

Financial-only Note dapat mengubah AR/AP, revenue/contra revenue, purchase valuation/HPP variance, tax, atau refund balance, tetapi:

- tidak membuat stock movement;
- tidak mengubah product stock atau FIFO quantity;
- purchase price correction boleh membagi nilai ke remaining FIFO Inventory dan Selisih Harga Beli/HPP untuk quantity terjual.

Quantity-impact wajib memakai:

- Sales Return untuk barang customer yang kembali;
- Purchase Return untuk barang yang kembali ke supplier.

Return memproses quantity, condition, warehouse, FIFO, dan HPP. Note hanya memproses nilai serta mereferensikan Return. `NO_PHYSICAL_RETURN` tidak menambah stock atau membalik HPP.

---

## 5. Mapping Customer

### Customer Credit Note

```text
Debit  Retur dan Potongan Penjualan
Credit Piutang Customer
   atau Utang Refund Customer
```

Piutang dikurangi sampai nol; kelebihan menjadi Utang Refund Customer. Refund Cash/Transfer atau konversi Customer Balance adalah settlement terpisah.

### Customer Debit Note

```text
Debit  Piutang Customer
Credit Penjualan / account correction compatible
```

Note menambah outstanding. Penerimaan berikutnya tetap memakai Payment event.

---

## 6. Mapping Supplier

### Supplier Credit Note

Jika AP masih terbuka:

```text
Debit  Utang Supplier Final
Credit Persediaan remaining FIFO / Selisih Harga Beli-HPP / account correction
```

Jika invoice sudah dibayar atau nilai melebihi AP terbuka:

```text
Debit  Piutang Refund Supplier
Credit Persediaan remaining FIFO / Selisih Harga Beli-HPP / account correction
```

Refund supplier/offset invoice berikutnya merupakan settlement terpisah.

### Supplier Debit Note

```text
Debit  Persediaan remaining FIFO / Selisih Harga Beli-HPP / account correction
Credit Utang Supplier Final
```

Pembayaran tambahan mengikuti Supplier Payment normal.

---

## 7. Pajak

- Note memakai tax snapshot source: tax code/rate, inclusive/exclusive mode, calculation scope, rounding, dan account mapping.
- Tax Rule terbaru tidak mengubah Note historis.
- Customer Note menyesuaikan Pajak Keluaran dan Supplier Note menyesuaikan Pajak Masukan hanya jika source memiliki tax line.
- Entitlement pajak yang kemudian dimatikan tidak menghapus reversal transaksi lama.
- Faktur pajak resmi/e-Faktur tetap deferred.

---

## 8. Allocation dan Validasi

- Allocation boleh partial dan many-to-many.
- Semua source dalam satu Note wajib memiliki company, currency, dan party yang sama.
- Simpan original, prior corrections, eligible remaining, allocated, dan residual.
- Cumulative correction tidak boleh melebihi remaining correctable/refundable value.
- Tolak nilai nol/negatif, duplicate, cross-tenant, dan source yang tidak eligible.
- Allocation, journal, AR/AP, refund balance, dan status diposting atomic serta idempotent.

---

## 9. Lifecycle dan Immutability

```text
DRAFT -> SUBMITTED -> APPROVED -> POSTED
DRAFT / SUBMITTED -> CANCELED
SUBMITTED -> REJECTED
POSTED -> REVERSED
```

- Draft editable oleh Finance maker.
- Note posted dan allocation immutable.
- Koreksi memakai full reversal yang mereferensikan Note asal, lalu replacement Note bila perlu.
- Reversal memakai snapshot asal dan accounting date sesuai period policy.
- Reversal Note tidak mengubah stock; stock hanya mengikuti Return/reversal Return.

---

## 10. Approval dan Authority

- Finance membuat, submit, dan mem-posting ketika approval tambahan nonaktif.
- Company Admin mengatur kebutuhan approval per company.
- Jika aktif, Company Admin/Super Admin menjadi approver dan maker tidak boleh menyetujui dokumen yang sama.
- Super Admin dapat melakukan seluruh aksi lintas company melalui workflow resmi.
- Cashier/Store Manager membuat source operasional sesuai authority, bukan Note finansial.
- Refund/payment tidak otomatis terjadi ketika Note posted.
- Authority wajib ditegakkan pada RLS/API/RPC, bukan hanya menu.

---

## 11. Audit dan Reporting

Simpan company/dimension, party, type/number/date/accounting date, source/Return reference, line dan nilai sebelum-tax-sesudah, reason/evidence URL, tax snapshot, mapping version, allocation/residual, actor/approval/posting, idempotency, serta reversal chain.

Note tampil pada Customer/Supplier Statement, AR/AP aging, Return reconciliation, tax report internal, General Ledger drill-down, dan exception report. Dokumen asli tetap menampilkan snapshot awal dan link Note; `net_after_notes` hanya nilai turunan.

---

## 12. Guardrail AI Agent

- Jangan membuat Note tanpa posted source.
- Jangan mengubah stock/FIFO dari Note.
- Jangan edit/delete source atau Note posted.
- Jangan mengganti Cash In, Expense, Payment, Refund, Return, atau Manual Journal dengan Note.
- Jangan memakai Tax Rule terbaru; gunakan snapshot source.
- Jangan membuat refund otomatis saat Customer Credit Note diposting.
- Jangan membuat schema/API/UI sebelum fase implementasi dibuka.

---

## 13. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-20 | Empat jenis Customer/Supplier Debit/Credit Note disediakan | APPROVED |
| 2026-07-20 | Note wajib posted source; koreksi tanpa source memakai Manual Journal | APPROVED |
| 2026-07-20 | Note dapat full/partial dan document/line-level dengan reason | APPROVED |
| 2026-07-20 | Financial Note tidak mengubah stock; quantity wajib melalui Return | APPROVED |
| 2026-07-20 | Customer Note memengaruhi AR/refund liability; Supplier Note memengaruhi AP/refund receivable | APPROVED |
| 2026-07-20 | Pajak Note memakai snapshot source | APPROVED |
| 2026-07-20 | Allocation partial/many-to-many dibatasi remaining eligible value | APPROVED |
| 2026-07-20 | Finance membuat/post; approval configurable; refund/payment terpisah; posted Note immutable | APPROVED |
