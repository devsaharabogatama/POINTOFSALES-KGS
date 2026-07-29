# G2 Phase 43 — Grouped Product Import UI

## Status

`READY FOR AUTHENTICATED SMOKE TEST`

Database Phase 42 beserta forward fix `20260727140000`, postflight, behavioral
test, dan regression Phase 40/38 sudah dikonfirmasi user seluruhnya PASS.
Phase ini tidak memiliki migration database baru.

## Outcome

Menu **Import & Export** kini mendukung **Produk + Satuan** dengan kontrak CSV
fixed `product_v1`:

```text
product_key,sku,product_name,category_name,image_url,is_active,uom_name,factor_to_base,purchase_allowed,sales_allowed,purchase_price,sale_price,barcode,sales_tax_rule_name,purchase_tax_rule_name,weight_per_largest_uom_kg
```

- satu `product_key` mewakili satu Product;
- satu baris mewakili satu UOM Product;
- preview mengelompokkan seluruh UOM di bawah nama Product dan SKU;
- UI menampilkan nama Category/UOM/Tax, bukan UUID atau kode UOM internal;
- ringkasan create/update/skip/error dihitung per Product group;
- export update menambahkan `internal_id` sebagai identitas backend;
- stok, Opening Stock, movement, FIFO, dan master referensi tidak dibuat;
- Bundle tetap export-only dan akan ditolak bila diubah melalui import.

## Evidence lokal

```text
backoffice npm.cmd run lint  PASS
backoffice npm.cmd run build PASS
```

Build mendeteksi route dinamis `/api/master/import-export` dan
`/api/master/import-jobs/[id]`.

## Smoke test

1. Restart Backoffice dan login sebagai Company Owner/Admin.
2. Buka **Import & Export**, pilih **Produk + Satuan**.
3. Unduh template. Pastikan header sama persis dengan kontrak di atas dan tidak
   menampilkan UUID/kode UOM sebagai input user.
4. Buat CSV satu Product dengan minimal dua baris UOM:
   - `product_key`, SKU, nama, kategori, status, pajak, dan berat sama;
   - satu UOM memiliki `factor_to_base = 1`;
   - UOM kemasan memiliki faktor lebih besar;
   - minimal satu baris `purchase_allowed = true`;
   - minimal satu baris `sales_allowed = true`.
5. Klik validasi. Pastikan preview menampilkan satu header Product dan detail
   UOM berdasarkan nama, faktor, fungsi beli/jual, dan harga.
6. Pastikan ringkasan menyebut **Product baru/diperbarui** dan **Grup error**,
   bukan menghitung setiap UOM sebagai Product terpisah.
7. Commit lalu periksa menu Product: Product dan seluruh UOM tersimpan.
8. Pastikan stok Product tidak berubah dan tidak ada Opening Stock/movement.
9. Export Product, ubah field non-struktural memakai mode ID internal, lalu
   validasi/konfirmasi update.
10. Bila ada Bundle existing, pastikan percobaan mutasinya ditolak dengan pesan
    bahwa Bundle belum didukung oleh import.

## Compatibility

- tujuh simple master existing tetap memakai UI dan RPC lama;
- public import job signatures tidak berubah;
- Product manual CRUD tetap memakai guarded atomic Product-UOM RPC;
- Opening Stock menunggu G3;
- Product Brand menunggu canonical master tersendiri.

## Next safe step

Setelah smoke di atas PASS, tutup Phase 43 `COMPLETE`. Lanjutkan dependency
order fixed import ke Product-Supplier melalui preflight SELECT-only; jangan
membuka stock import atau workflow Purchase transaksi.
