# Spesifikasi Revenue dan Margin Allocation Bundle

**Status:** APPROVED untuk workflow, accounting boundary, dan reporting  
**Scope:** Bundle retail/POS dengan SKU khusus, komponen stock, revenue allocation, HPP, tax/diskon/rounding, dan return  
**Bukan scope:** Implementasi schema/API/UI atau Manufacture/BOM production

---

## 1. Prinsip Dasar

- Bundle adalah satu SKU komersial yang dipilih/scan secara eksplisit.
- Bundle tampil sebagai satu line pada POS, struk, Pro Forma, dan Invoice.
- Harga jual Bundle diisi/di-resolve sebagai harga Bundle, bukan jumlah wajib harga komponen.
- Bundle tidak memiliki stock fisik, FIFO batch, atau HPP mandiri.
- Stock dan HPP selalu mengikuti komponen `STOCK` aktual.
- Nested Bundle tidak didukung pada scope POS awal.

Baca bersama `PRODUCT_STOCK_MASTERDATA_SPEC.md`, `POS_DEVELOPMENT_NOTES.md`, `FINANCE_INTEGRATION_NOTES.md`, `TAX_ENGINE_SPEC.md`, dan `TRANSACTION_CATEGORY_ACCOUNT_MAPPING_SPEC.md`.

---

## 2. Dua Tampilan yang Dipisahkan

| Tampilan | Tujuan | Bentuk |
|---|---|---|
| Commercial | Apa yang dibeli customer | Satu SKU/line Bundle dengan harga final |
| Component Analytics | Produk fisik yang keluar dan membentuk margin | Beberapa component allocation line |

Component allocation tidak membuat sale/revenue kedua. Total analytic revenue wajib sama dengan revenue commercial Bundle.

---

## 3. Mode Accounting Revenue

### 3.1 Default MVP — `BUNDLE_ACCOUNT`

- Penjualan dikredit sebagai satu nilai ke Transaction Category/Product Category Bundle.
- Component allocation hanya digunakan untuk analisis revenue, HPP, margin, tax share, discount share, dan return basis.
- General Ledger tetap sederhana dan tidak memiliki revenue duplicate.

### 3.2 Future Optional — `COMPONENT_CATEGORY_SPLIT`

- Company dapat mengaktifkan split revenue journal ke kategori komponen.
- Total kredit seluruh komponen wajib sama dengan revenue Bundle.
- Hanya distribusi account/category yang berubah; total revenue, payment, tax, dan customer invoice tidak berubah.
- Mode effective-dated dan disimpan sebagai snapshot transaksi.
- Aktivasi membutuhkan seluruh component-category mapping valid; jika tidak, posting masuk HOLD/ERROR.

Default scope POS awal adalah `BUNDLE_ACCOUNT`. Mode split dipersiapkan secara kontrak, tetapi tidak wajib diimplementasikan pada MVP.

---

## 4. Snapshot Komponen

Saat Bundle diposting, simpan per komponen:

```text
component_product_id
component_uom_id
component_qty_per_bundle
sold_bundle_qty
total_component_qty
base_qty + conversion snapshot
standalone_resolved_unit_price snapshot
allocation_basis_value
allocation_weight
allocated_gross_revenue
allocated_discount
allocated_tax
allocated_rounding
allocated_net_revenue
fifo allocations
actual_cogs
product/category snapshot
```

Perubahan komposisi, harga, kategori, UOM, atau COA setelah posting tidak mengubah transaksi historis.

---

## 5. Urutan Basis Allocation

Gunakan satu basis konsisten untuk seluruh komponen transaksi:

```text
1. standalone resolved selling value
   = resolved unit price komponen x component quantity

2. jika total selling value = 0:
   actual component HPP proportion

3. jika total HPP = 0:
   base quantity proportion
```

`standalone resolved price` diambil pada waktu transaksi menggunakan customer/global/product fallback yang eligible, lalu disimpan sebagai snapshot analitik. Nilai tersebut tidak mengganti harga Bundle yang dibayar customer.

Formula:

```text
weight_i = basis_i / sum(all basis)
allocated_amount_i = bundle_amount x weight_i
```

---

## 6. Diskon, Pajak, dan Rounding

- Gross revenue, diskon line/transaksi, tax extracted, dan rounding dialokasikan menggunakan weight snapshot yang sama.
- Tax Bundle dihitung dari rule/snapshot SKU Bundle sesuai `TAX_ENGINE_SPEC.md`; alokasi tax ke komponen hanya analitik dan tidak menghitung tax baru per komponen.
- Jika future accounting split aktif, total revenue/tax journal tetap sama dengan commercial Bundle.
- Perbedaan precision ditempelkan ke komponen dengan nilai allocation terbesar; jika seri, gunakan urutan component line stabil.
- Setiap kelompok harus memenuhi:

```text
sum(component allocated gross)    = Bundle gross
sum(component allocated discount) = Bundle discount
sum(component allocated tax)      = Bundle tax
sum(component allocated rounding) = Bundle rounding
sum(component allocated net)      = Bundle net revenue
```

---

## 7. HPP dan Stock

- Checkout mengonsumsi FIFO per komponen dan warehouse sumber.
- HPP Bundle adalah jumlah actual FIFO cost seluruh komponen.
- Komponen gratis/promosi tetap mengurangi stock dan mengakui HPP penuh.
- Kekurangan salah satu komponen membuat Bundle tidak dapat diposting; transaksi tetap Draft/Hold sesuai negative-stock policy.
- Bundle virtual tidak memiliki product stock row yang dapat di-adjust/opname.
- Stock Movement tetap menampilkan source Bundle sale dan component line agar dapat ditelusuri.

---

## 8. Return dan Credit Note

### Full Return

- Menggunakan composition, allocation, tax, discount, rounding, FIFO, dan HPP snapshot asal.
- Seluruh komponen fisik diproses sesuai kondisi `SALEABLE`, `DAMAGED`, atau `NO_PHYSICAL_RETURN`.
- Financial correction mengikuti `DEBIT_CREDIT_NOTE_SPEC.md` tanpa menghitung ulang harga terkini.

### Partial Component Return

- Hanya komponen/quantity yang benar-benar kembali yang diproses stock/HPP-nya.
- Refundable/credit basis memakai original allocated net revenue komponen secara proporsional terhadap quantity return.
- Cumulative quantity dan nilai return tidak boleh melebihi snapshot eligible yang tersisa.
- `NO_PHYSICAL_RETURN` dapat mengoreksi nilai tanpa stock/HPP reversal.
- Selisih rounding koreksi ditempelkan secara deterministik agar total Credit Note sama dengan refund approved.

Return tidak mengedit sale Bundle atau allocation awal.

---

## 9. Reporting

Laporan menyediakan switch:

1. **Commercial Bundle View** — quantity Bundle, gross/net sales, discount, tax, refund, dan margin total.
2. **Component Analytics View** — allocated revenue, actual FIFO HPP, allocated margin, stock-out, dan return per komponen/category.

Report dapat difilter company, store, warehouse, Bundle SKU, component SKU/category, date, customer, dan transaction status. Drill-down menghubungkan Bundle sale, component allocation, FIFO, return, Credit Note, dan journal.

Laporan keuangan hanya memakai posted event. Draft/Hold/Pending dapat dianalisis terpisah tanpa masuk revenue.

---

## 10. Configuration dan Authority

- Company Admin/Finance mengatur accounting allocation mode company.
- Super Admin dapat mengatur semua company dan template default.
- Store Manager dapat mengelola komposisi/Bundle sesuai product authority, tetapi tidak mengubah accounting mode atau posted allocation.
- Cashier hanya menjual/meretur sesuai workflow dan tidak memilih allocation method.
- Perubahan mode effective-dated, audited, dan hanya berlaku untuk event baru.

---

## 11. Validation dan Idempotency

- Semua Bundle, komponen, UOM, category, warehouse, dan rule harus satu company.
- Komponen wajib active product `STOCK`; nested Bundle ditolak.
- Composition snapshot, stock consumption, allocation, HPP, tax, dan sale posting harus atomic.
- Allocation totals wajib exact setelah controlled residual handling.
- Retry memakai idempotency key sale yang sama dan tidak membuat component allocation/FIFO/journal duplicate.
- Missing account mapping pada optional split mode menahan seluruh financial posting.

---

## 12. Guardrail AI Agent

- Jangan membuat stock/FIFO untuk SKU Bundle virtual.
- Jangan mencatat revenue komersial dan component allocation sebagai dua pendapatan.
- Jangan menghitung harga Bundle dari harga komponen secara paksa.
- Jangan memakai harga/HPP/category terbaru untuk return historis.
- Jangan menghitung tax baru per komponen; gunakan tax Bundle snapshot.
- Jangan mendukung nested Bundle pada scope POS awal.
- Jangan membuat schema/API/UI sebelum fase implementasi dibuka.

---

## 13. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-20 | Bundle tetap satu SKU dan satu line komersial | APPROVED |
| 2026-07-20 | Stock/HPP selalu mengikuti komponen FIFO aktual | APPROVED |
| 2026-07-20 | MVP journal ke kategori Bundle; component allocation bersifat analitik dan tidak menduplikasi revenue | APPROVED |
| 2026-07-20 | Future company dapat mengaktifkan component-category revenue split | APPROVED sebagai extensibility contract |
| 2026-07-20 | Basis allocation: standalone selling value, lalu HPP, lalu base quantity | APPROVED |
| 2026-07-20 | Diskon, tax, dan rounding dialokasikan proporsional dengan residual ke line terbesar | APPROVED |
| 2026-07-20 | Return memakai original allocation snapshot; partial hanya komponen yang benar-benar dikoreksi | APPROVED |
| 2026-07-20 | Report mendukung commercial Bundle dan component revenue/HPP/margin view | APPROVED |
