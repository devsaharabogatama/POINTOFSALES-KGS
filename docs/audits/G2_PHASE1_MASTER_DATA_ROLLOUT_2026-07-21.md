# Evidence Rollout G2 Fase 1 - Master Data Foundation

**Tanggal konfirmasi:** 2026-07-21
**Migration:** `20260721180000_g2_phase1_master_data_foundation.sql`
**Status:** COMPLETE

## Evidence yang Dikonfirmasi

- Preflight live Supabase menunjukkan Product, UOM, Product UOM Conversion, dan Warehouse masih nol row.
- Migration expand-only berhasil diterapkan.
- Postflight seluruhnya berhasil.
- Behavioral test tenant scope, master version, composite FK, dan historical UOM guard berhasil.
- Backoffice existing tetap menjadi compatibility target; canonical UI belum diaktifkan pada fase ini.

## Boundary yang Aktif

- `product_categories` dan `product_uoms` menjadi canonical master baru.
- UOM, Warehouse, dan Product memiliki `master_version` serta audit timestamp.
- Base UOM dan conversion factor tidak dapat diubah setelah Product mempunyai Stock Movement.
- New-master reads/writes mengikuti active Company dan RLS role manager.
- Kolom/tabel legacy tetap tersedia sampai API/form/import baru siap cutover.

## Keputusan Lanjutan

G2 fase 1 ditutup. Tahap berikutnya membangun API Backoffice canonical untuk
Product Category, UOM, dan Warehouse menggunakan session user serta active
Company context. API tidak memakai service-role dan mutation memakai optimistic
concurrency melalui `master_version`.
