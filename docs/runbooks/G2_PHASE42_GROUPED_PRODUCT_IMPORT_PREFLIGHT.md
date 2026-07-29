# G2 Phase 42 — Grouped Product Import Preflight

## Status

`READY FOR MANUAL PREFLIGHT`

## Tujuan

Mengaudit kesiapan live database sebelum menambahkan Product ke generic Import
& Export. Satu Product dan seluruh Product-UOM wajib menjadi satu atomic group.
Preflight ini tidak mengubah schema atau data.

## Kontrak Group

Template fixed:

```text
product_key,sku,product_name,category_name,image_url,is_active,uom_name,factor_to_base,purchase_allowed,sales_allowed,purchase_price,sale_price,barcode,sales_tax_rule_name,purchase_tax_rule_name,weight_per_largest_uom_kg
```

Aturan utama:

- satu baris merepresentasikan satu UOM;
- seluruh baris dengan `product_key` yang sama adalah satu Product atomic;
- tepat satu UOM memiliki faktor `1` dan menjadi Base UOM;
- UOM aktif dengan faktor terbesar menjadi acuan berat;
- berat acuan wajib sama pada seluruh baris group;
- minimal satu UOM jual aktif dan satu UOM beli aktif untuk Product STOCK;
- Category, UOM, dan Tax Rule harus sudah ada dan tidak pernah dibuat otomatis;
- Product BUNDLE existing export-only sampai workflow komponen G3 dibuka;
- Opening Stock, stock balance, FIFO, movement, dan journal tidak disentuh.

## Cara Menjalankan

Jalankan seluruh file:

`supabase/diagnostics/g2_phase42_grouped_product_import_preflight.sql`

Kirim seluruh hasil `check_name,status,details`.

## Interpretasi

- `BLOCKER`: migration Product Import belum boleh ditulis;
- `REVIEW`: perlu keputusan/backfill eksplisit berdasarkan data live;
- `PASS`: invariant aman;
- `INFO`: inventory atau capability, bukan kegagalan.

Expected pada state bersih:

- dependency Phase 40 PASS;
- tidak ada duplicate/ambiguous reference;
- seluruh Product memiliki canonical Product-UOM group valid;
- tidak ada nonterminal import job;
- overload guarded Product + Product-UOM + Tax tersedia;
- `product_job_type_supported=false` masih expected sebelum migration;
- direct Product/Product-UOM browser write tetap `false`.

## Boundary Berikutnya

Migration hanya boleh ditulis setelah hasil live diterima. Implementasi wajib
melakukan validation/preview per Product group, optimistic version, explicit
update confirmation, atomic group commit melalui guarded RPC, dan partial
success antargroup.
