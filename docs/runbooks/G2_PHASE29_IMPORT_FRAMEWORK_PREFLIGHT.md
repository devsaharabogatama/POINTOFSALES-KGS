# G2 Phase 29 — Master Import/Export Framework Preflight

## Tujuan

Menutup audit gap G2 `B-04` sebelum membangun import master bergaya Odoo.
Preflight mengukur data live, ambiguity reference, Product-UOM grouping,
protected history, Opening Stock eligibility, dan jalur import legacy.

File ini tidak membuat staging, tidak meng-upload file, dan tidak mengubah
master maupun stok.

Source of truth:

- `docs/POS_V1_IMPLEMENTATION_GATES.md` bagian G2;
- `docs/PRODUCT_STOCK_MASTERDATA_SPEC.md` bagian 10;
- `docs/PRE_BUILD_IMPLEMENTATION_GAP_AUDIT_2026-07-20.md` gap `B-04`.

## Boundary yang Dijaga

- Import Product tidak boleh membuat Category/UOM/Warehouse secara diam-diam;
- Opening Stock terpisah dari import Product dan belum dibangun pada phase ini;
- tepat satu mode reference per job: ID atau nama;
- nama reference wajib tenant-scoped dan tidak ambigu;
- Product beserta seluruh UOM adalah satu logical group atomic;
- kegagalan satu group tidak membatalkan group valid lain;
- protected field dengan movement/history tidak boleh diubah lewat bulk import;
- browser tidak boleh mengeksekusi RPC import legacy.

## Cara Menjalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

```text
supabase/diagnostics/g2_phase29_import_framework_preflight.sql
```

Kirim seluruh hasil `check_name,status,details`.

## Interpretasi Expected

- dependency dan data invariant harus `PASS`;
- `canonical_import_schema_state` expected masih melaporkan tiga tabel missing;
- `legacy_import_unsafe_contract` boleh `REVIEW`: ini membuktikan jalur lama
  memang harus diganti, bukan digunakan kembali;
- `brand_master_schema_state` adalah inventory keputusan scope, bukan izin
  membuat Brand diam-diam;
- Opening Stock hanya inventory. Implementasinya tetap menunggu atomic stock
  ledger G3.

## Next Safe Step

Setelah hasil live diterima, bangun foundation staging generic untuk job, row,
mapping/preview, partial-result, audit, dan downloadable error payload. Mulai
dari master non-stock; Product group menyusul setelah validator reference dan
atomic group stabil. Opening Stock tidak boleh ikut foundation import master.
