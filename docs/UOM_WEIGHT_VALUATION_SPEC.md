# UOM, Berat, Precision, dan Valuation

**Status:** Business/design decision approved; belum menjadi bukti implementasi  
**Scope:** Quantity precision, direct conversion, weight estimate, FIFO unit cost, UOM lintas dokumen, dan conversion versioning  
**Dependency:** `PRODUCT_STOCK_MASTERDATA_SPEC.md`, `PURCHASE_MATCHING_TOLERANCE_SPEC.md`, dan Finance source mapping

---

## 1. Base UOM dan Input Precision

- Setiap Produk STOCK memiliki tepat satu base/stock UOM terkecil.
- Semua on-hand, reservation, FIFO quantity, stock movement, opname, dan adjustment disimpan/dibandingkan dalam base UOM.
- UOM `allow_decimal = false` seperti PCS/PACK/DUS hanya menerima bilangan bulat.
- UOM `allow_decimal = true` menerima pecahan sesuai `decimal_precision`; default awal tiga digit.
- Input yang melebihi precision ditolak dengan pesan validasi dan tidak dibulatkan diam-diam.
- Produk dengan base UOM integer tidak boleh menerima kombinasi quantity x conversion factor yang menghasilkan pecahan base unit.

---

## 2. Direct Conversion dan Snapshot

- Semua UOM Produk menyimpan faktor langsung ke base UOM; kalkulasi tidak memakai rantai non-base.

```text
base_quantity = transaction_quantity x conversion_factor_to_base
```

- Faktor wajib positif dan menghasilkan quantity yang representable pada precision base UOM.
- Receipt, Supplier Invoice, Sale, Return, Transfer, Bundle, dan Stock Opname menyimpan transaction UOM, transaction quantity, conversion factor snapshot, serta resulting base quantity.
- Matching lintas dokumen membandingkan base quantity berdasarkan snapshot masing-masing, bukan master conversion terbaru.
- Harga beli/jual setiap UOM tetap manual dan independen; converted price hanya boleh menjadi referensi analitik, bukan mengganti nilai transaksi aktual.

---

## 3. Precision Internal dan Currency

- Input mengikuti precision UOM, tetapi intermediate conversion, allocation, dan FIFO unit cost memakai precision internal lebih tinggi.
- Target awal kalkulasi intermediate minimal enam digit desimal; tipe database final harus ditentukan setelah audit volume/range dan tidak boleh memakai floating-point binary untuk quantity/uang.
- Unit cost FIFO disimpan per base UOM dengan precision tinggi dan tidak dibulatkan pada setiap konsumsi kecil.
- Nilai jurnal IDR dibulatkan pada boundary dokumen/journal sesuai aturan Finance; total Debit dan Credit wajib tetap sama.
- Residual pembulatan allocation ditempatkan secara deterministik pada line bernilai terbesar dan disimpan sebagai audit snapshot.
- Residual tidak otomatis dianggap stock gain/loss atau mengubah physical quantity.

---

## 4. Berat

- Sistem menentukan UOM dengan faktor aktif terbesar sebagai weight reference;
  UI tidak meminta user memilih acuan berat secara terpisah.
- Berat UOM terbesar diisi manual.
- Berat UOM lain dihitung proporsional memakai faktor conversion ke base UOM.

```text
derived_weight(uom)
= reference_weight
  x conversion_factor(uom)
  / conversion_factor(reference_uom)
```

- Berat adalah estimasi operasional untuk logistik/ongkir dan boleh berbeda dari berat fisik karena kemasan atau pembulatan.
- Berat tidak menentukan on-hand quantity, FIFO quantity, harga beli, HPP, AP, atau revenue.
- Selisih berat fisik tidak membuat Stock Adjustment otomatis. Adjustment hanya dibuat bila physical base quantity memang berbeda melalui workflow stock resmi.
- Bundle weight adalah total estimasi berat seluruh komponen sesuai quantity/UOM snapshot.

---

## 5. Valuation dan UOM Lintas Dokumen

- Receipt dapat memakai UOM pembelian, Invoice UOM Supplier, dan Sale UOM penjualan yang berbeda.
- Quantity matching selalu memakai base quantity; nilai commercial tetap memakai harga UOM dokumen yang dipilih.
- Goods Receipt membuat FIFO provisional per base UOM dari estimated document value.
- Supplier Invoice mengalokasikan actual document value terhadap base quantity matched lalu merevaluasi remaining FIFO/HPP variance sesuai kontrak Purchase.
- Sale mengonsumsi FIFO base quantity aktual. HPP tidak dihitung dari sale price atau current converted purchase-price master.
- Return/reversal memakai conversion, base quantity, unit cost, dan FIFO source snapshot asli.
- Allocation value rounding tidak boleh mengubah quantity movement.

---

## 6. Perubahan Conversion Factor

- Conversion factor yang belum pernah dipakai boleh diedit dengan audit.
- Setelah ada movement/document posted, factor historis tidak diubah lewat edit/import biasa.
- Perubahan menggunakan version/effective date atau migration terkontrol dengan preview dampak, actor, alasan, dan rollback/forward-fix plan.
- Transaction baru memakai version aktif; transaction/FIFO lama mempertahankan snapshot/version asal.
- Base UOM Produk yang sudah memiliki movement tidak dapat diganti tanpa migration inventory khusus dan reconciliation penuh.
- Perubahan conversion tidak menghitung ulang invoice, journal, FIFO, stock movement, atau report historis.

---

## 7. Boundary Manufacture Masa Depan

- Manufacture nantinya memakai base UOM, conversion snapshot, stock movement, dan valuation contract yang sama.
- Bill of Materials/recipe akan menjadi domain Manufacture terpisah; Product Bundle POS bukan BOM dan tidak boleh diperluas diam-diam menjadi nested manufacturing structure.
- Consumption bahan, work-in-progress, yield, scrap, dan finished goods memerlukan source event/status/mapping Finance baru pada fase Manufacture.
- Tidak ada tabel/flow Manufacture yang dibuat pada fase POS sekarang hanya karena boundary ini sudah dicatat.

---

## 8. Guardrail Implementasi

- Gunakan numeric/decimal, bukan float, untuk quantity, factor, unit cost, dan weight.
- Resolver conversion server-side; client tidak boleh mengirim resulting base quantity sebagai nilai tepercaya.
- Constraint tenant/Product/UOM dan snapshot wajib divalidasi sebelum posting.
- Import tidak dapat mengubah base UOM/factor historis melalui upsert biasa.
- Test minimum mencakup integer UOM, decimal UOM, split FIFO, partial receipt/invoice, cross-UOM return, Bundle, conversion version, dan journal rounding balance.

---

## 9. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-20 | Input mengikuti precision UOM; UOM unit integer dan decimal default tiga digit | APPROVED |
| 2026-07-20 | Semua conversion langsung ke base UOM dan disnapshot per transaksi | APPROVED |
| 2026-07-20 | Intermediate quantity/FIFO memakai precision tinggi; nilai jurnal dibulatkan di boundary dokumen | APPROVED |
| 2026-07-20 | FIFO unit cost disimpan per base UOM tanpa pembulatan terlalu awal | APPROVED |
| 2026-07-20 | Berat hanya estimasi logistik dan bukan dasar stock/HPP | APPROVED |
| 2026-07-20 | Berat turunan dihitung proporsional; physical weight variance tidak auto-adjust stock | APPROVED |
| 2026-07-20 | Receipt/Invoice/Sale lintas UOM dibandingkan dalam base UOM memakai snapshot | APPROVED |
| 2026-07-20 | Conversion historis berubah hanya melalui version/migration terkontrol | APPROVED |
