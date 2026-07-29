# G2 Phase 44 — Product-Supplier Import Preflight

## Status

`READY FOR MANUAL PREFLIGHT`

Diagnostic ini SELECT-only. Tidak ada migration, DDL, DML, TEMP table, function
call dengan side effect, grant, atau perubahan data.

## Tujuan

Memastikan live database aman sebelum tipe import fixed
`product_supplier_v1` ditambahkan:

```text
product_sku,supplier_name,purchase_uom_name,supplier_product_code,reference_purchase_price,is_preferred_supplier,is_active
```

Satu baris adalah satu relasi Product–Supplier. Product, Supplier, dan UOM
pembelian harus sudah tersedia dan aktif; import tidak membuat master referensi
otomatis.

## Cara menjalankan

Jalankan seluruh:

`supabase/diagnostics/g2_phase44_product_supplier_import_preflight.sql`

di Supabase SQL Editor, lalu kirim semua kolom:

```text
check_name,status,details
```

## Expected

- seluruh invariant berstatus `PASS`;
- `product_supplier_import_job_schema_state` berstatus `INFO` dan saat ini
  wajar bila whitelist job belum menerima `PRODUCT_SUPPLIER`;
- inventory dan direct privilege berstatus `INFO`;
- `nonterminal_import_jobs` harus `PASS` sebelum migration ditulis.

## Blocker yang harus dihentikan

- dependency Phase 42 belum lengkap;
- SKU Product, nama Supplier, atau nama UOM aktif ambigu;
- Product stok aktif tidak memiliki UOM pembelian;
- relasi existing lintas Company/orphan;
- relasi aktif menunjuk Product/Supplier/UOM nonaktif, UOM non-pembelian, atau
  Product Bundle;
- lebih dari satu preferred Supplier aktif per Product;
- nilai harga/version/metadata existing tidak valid;
- masih ada import job nonterminal.

## Boundary

- `last_purchase_price` tetap read-only dan hanya diperbarui oleh invoice
  Finance yang tervalidasi, bukan import;
- `supplier_product_code` tetap kode bisnis opsional milik Supplier;
- import tidak membuat Purchase Order, Receipt, stock, FIFO, AP, atau journal;
- preferred Supplier hanya rekomendasi; Store Manager tetap dapat memilih
  Supplier aktif lain saat Purchasing;
- Phase 43 Product Import UI smoke tetap harus ditutup terpisah.

## Next safe step

Jika seluruh invariant PASS dan hasil INFO sesuai expected, buat additive
Product-Supplier import validator/partial commit yang memakai guarded
`save_product_supplier(...)`, lalu postflight, behavioral test, regression
Phase 42/40/38, dan Backoffice UI.
