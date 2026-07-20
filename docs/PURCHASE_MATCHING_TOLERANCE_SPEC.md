# Purchase Three-Way Matching dan Tolerance

**Status:** Business/design decision approved; belum menjadi bukti implementasi  
**Scope:** Supplier Order, Goods Receipt, Supplier Invoice, tolerance, allocation many-to-many, dan AP Provisional  
**Dependency:** `PRODUCT_STOCK_MASTERDATA_SPEC.md`, `POS_DEVELOPMENT_NOTES.md`, `FINANCE_INTEGRATION_NOTES.md`, `TAX_ENGINE_SPEC.md`

---

## 1. Model Three-Way Matching

```text
Supplier Order
-> Goods Receipt / surat jalan
-> Supplier Invoice
-> Supplier Payment
```

- Supplier Order adalah commercial order dan snapshot estimasi, bukan stock/AP event.
- Goods Receipt posted mengakui quantity fisik accepted, FIFO provisional, Persediaan, dan AP Provisional.
- Supplier Invoice tervalidasi mengalokasikan receipt, mengganti estimasi menjadi nilai aktual, dan membentuk AP Final.
- Supplier Payment hanya menyelesaikan AP Final dan tidak mengulang inventory/expense.
- Semua dokumen/alokasi harus berasal dari company dan Supplier yang sama.

---

## 2. Partial dan Many-to-Many

- Partial receipt dan partial invoice didukung.
- Satu Supplier Order dapat memiliki banyak Goods Receipt.
- Satu Supplier Invoice dapat dialokasikan ke beberapa Supplier Order/Goods Receipt.
- Satu Goods Receipt dapat dialokasikan ke beberapa Supplier Invoice bertahap.
- Matching disimpan per line menggunakan quantity base UOM dan nilai IDR.
- Setiap allocation menyimpan order line, receipt line, invoice line, quantity, provisional value, actual value, tax/landed-cost reference, actor, time, dan idempotency key.
- Total allocated quantity/value tidak boleh melebihi source yang eligible. Posting wajib memakai row lock/constraint agar dua Finance user tidak melakukan double allocation.
- Sisa quantity/value tetap terlihat sebagai residual, bukan dianggap selesai karena header document sudah pernah matched.

---

## 3. Kondisi Goods Receipt

Quantity surat jalan dibagi menjadi:

```text
accepted_good_quantity
accepted_damaged_quantity
rejected_quantity
```

Invariant:

```text
accepted_good + accepted_damaged + rejected = delivered_quantity
```

- `ACCEPTED_GOOD` masuk stock saleable/tujuan normal, FIFO, dan AP Provisional.
- `ACCEPTED_DAMAGED` masuk stock/location `DAMAGED`, FIFO, dan AP Provisional karena barang secara bisnis diterima dari Supplier.
- `REJECTED` tidak masuk stock, FIFO, atau AP. Jika barang yang sudah accepted kemudian dikembalikan, gunakan Purchase Return.
- Field kondisi boleh disembunyikan pada form normal; tanpa input kondisi, seluruh delivered quantity dianggap `ACCEPTED_GOOD`.
- Hanya accepted quantity yang digunakan untuk invoice quantity matching.

---

## 4. Over-Receipt dan Approval

Over-receipt tidak disembunyikan atau dipotong ke ordered quantity. Quantity accepted aktual tetap menjadi stock/AP Provisional setelah receipt resmi posted.

Konfigurasi awal:

```text
over_receipt_policy = WARN_ONLY | REQUIRE_APPROVAL
quantity_tolerance_percent
quantity_tolerance_base_uom nullable
value_tolerance_percent
value_tolerance_amount nullable
```

- Company memiliki default; Supplier dapat mempunyai override dalam company yang sama.
- Supplier override yang aktif/effective mengalahkan company default.
- `WITHIN_TOLERANCE` dapat diposting normal dan tetap menyimpan variance.
- Di luar tolerance dengan `WARN_ONLY`, Cashier dapat melanjutkan setelah confirmation; receipt posted dan exception dikirim ke Store Manager/Finance.
- Di luar tolerance dengan `REQUIRE_APPROVAL`, receipt disimpan `WAITING_APPROVAL` dan belum menambah stock/AP sampai Store Manager, Company Admin, atau Super Admin menyetujui/posting.
- Approval hanya menyetujui quantity fisik yang benar-benar diterima; tidak mengubah ordered quantity historis.

---

## 5. Supplier Invoice Matching

Status matching minimum:

```text
UNMATCHED
PARTIALLY_MATCHED
MATCHED
WITHIN_TOLERANCE
EXCEPTION
HOLD
CLOSED
```

- `MATCHED`: seluruh allocation quantity/value sesuai source.
- `WITHIN_TOLERANCE`: ada variance tetapi masih dalam rule aktif.
- `EXCEPTION`: variance memerlukan review/resolution tetapi dokumen belum melanggar hard invariant.
- `HOLD`: invoice belum boleh diposting sebagai AP Final.
- Supplier Invoice quantity yang melebihi total accepted/uninvoiced receipt masuk `HOLD`.
- Invoice `HOLD` tidak boleh membuat stock atau FIFO. Resolusi dilakukan dengan Goods Receipt tambahan/koreksi fisik yang sah, allocation ke receipt eligible lain Supplier yang sama, Supplier Credit Note, atau correction document Finance yang sesuai.
- Finance/Company Admin tidak boleh override quantity invoice menjadi stock tanpa Goods Receipt.
- Harga invoice boleh berbeda dari order/estimate. Price variance mengikuti revaluation remaining FIFO dan Selisih Harga Beli/HPP untuk quantity yang sudah terjual.
- Pajak dan inclusive/exclusive mode mengikuti `TAX_ENGINE_SPEC.md`.

---

## 6. AP Provisional Residual

Goods Receipt:

```text
Debit  Persediaan (accepted quantity x estimated cost)
Credit AP Provisional
```

Supplier Invoice allocation:

```text
Debit  AP Provisional (allocated estimate)
Debit/Credit Persediaan atau Selisih Harga Beli/HPP (actual variance)
Credit AP Final (invoice actual, sebelum payment)
```

- Jika invoice hanya mencakup sebagian receipt, residual AP Provisional tetap outstanding untuk invoice berikutnya.
- Residual tidak kedaluwarsa atau berubah menjadi pendapatan otomatis.
- Jika Supplier menyatakan sisa tidak akan ditagih, Finance membuat Supplier Credit/`PROVISIONAL_CLOSE` beralasan dan Company Admin/Super Admin meng-approve sesuai maker-checker.
- Penutupan residual mengoreksi remaining Inventory/FIFO dan bagian quantity yang sudah terjual ke Selisih Harga Beli/HPP; tidak mengedit Goods Receipt atau journal lama.
- Purchase Return menyelesaikan quantity/value terkait melalui source return dan tidak boleh ditutup ulang sebagai provisional residual.

---

## 7. Tolerance Resolution

- Quantity tolerance dinilai dalam base UOM; value tolerance dalam IDR.
- Sistem menyimpan rule/version yang digunakan pada hasil matching.
- Tolerance memengaruhi status/approval, bukan menghapus variance dari report.
- Perbedaan harga yang masih dalam tolerance tetap memakai actual invoice untuk AP Final/valuation.
- Tolerance tidak otomatis membukukan gain/loss.
- Finance memilih resolution source yang sah: invoice allocation, additional receipt, Purchase Return, Supplier Credit/Debit Note, reclassification, atau provisional close.
- Semua resolution append-only dan menyimpan reason, actor, waktu, source, before/after residual.

---

## 8. Role dan UI

- Cashier menerima Goods Receipt pada store/order yang eligible dan melihat warning quantity, bukan HPP/COA.
- Store Manager, Company Admin, dan Super Admin dapat approve/post over-receipt sesuai scope.
- Finance memvalidasi Supplier Invoice, melakukan allocation/matching, melihat value variance, dan mengajukan provisional close.
- Company Admin/Super Admin menyetujui provisional close dan memiliki seluruh authority sesuai hierarchy.
- UI Finance menampilkan ordered, delivered, accepted good, accepted damaged, rejected, returned, invoiced, uninvoiced, estimated value, actual value, tax, dan residual.
- Filter/report minimum: company, Supplier, store/warehouse, order/receipt/invoice, status, aging residual, exception type, dan approver.

---

## 9. Guardrail Implementasi

- Matching dan posting server-side, atomic, idempotent, dan tenant-scoped.
- UOM conversion snapshot wajib tersedia sebelum membandingkan quantity.
- Jangan mencocokkan berdasarkan SKU/nama saja; gunakan immutable line/source ID.
- Jangan mengubah receipt/invoice posted melalui UPDATE/DELETE.
- Jangan membuat AP Final dari Goods Receipt atau stock dari Supplier Invoice.
- Jangan menutup residual otomatis hanya karena sudah melewati umur tertentu.
- Import invoice harus menjalankan preview/matching validation yang sama dengan input manual.

---

## 10. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-20 | Purchase memakai Supplier Order–Goods Receipt–Supplier Invoice three-way matching | APPROVED |
| 2026-07-20 | Receipt/Invoice mendukung partial dan allocation many-to-many | APPROVED |
| 2026-07-20 | Over-receipt tetap dapat diterima dengan warning/approval configurable | APPROVED |
| 2026-07-20 | Accepted good/damaged masuk stock/AP; rejected tidak masuk | APPROVED |
| 2026-07-20 | Invoice quantity di atas accepted receipt masuk HOLD dan tidak membuat stock | APPROVED |
| 2026-07-20 | Harga aktual boleh berbeda dan memakai Inventory/HPP price variance | APPROVED |
| 2026-07-20 | Residual AP Provisional menunggu invoice berikutnya atau Supplier Credit/provisional close | APPROVED |
| 2026-07-20 | Tolerance company dengan optional Supplier override menghasilkan MATCHED/WITHIN_TOLERANCE/EXCEPTION | APPROVED |
