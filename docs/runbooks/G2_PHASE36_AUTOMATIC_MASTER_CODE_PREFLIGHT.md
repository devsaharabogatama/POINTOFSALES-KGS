# G2 Phase 36 — Automatic Hidden Master Code Preflight

## Status

`COMPLETE — LIVE RESULT PASS/INFO 2026-07-24`

## Outcome

Memastikan delapan master aman dipindahkan ke kode teknis otomatis tanpa
mengganti UUID, menulis ulang kode existing, atau merusak referensi historis.

Target:

- Product Category: `CAT-000001`;
- UOM: `UOM-000001`;
- Warehouse: `WH-000001`;
- Supplier: `SUP-000001`;
- Customer Category: `CC-000001`;
- Pricelist: `PL-000001`;
- Payment Method: `PAY-000001`;
- custom Transaction Category: `TC-000001`.

Product SKU, Customer code, COA account code, Tax code, barcode, dan kode Product
milik Supplier tidak termasuk target.

## Run

Jalankan seluruh file berikut di Supabase SQL Editor:

```text
supabase/diagnostics/g2_phase36_automatic_master_code_preflight.sql
```

Expected:

- tidak ada `BLOCKER`;
- dependency, target column, normalized name uniqueness, blank identity, dan
  required normalized-name index seluruhnya `PASS`;
- `existing_automatic_prefix_inventory` hanya informasi karena seluruh kode
  existing akan dipertahankan;
- `automatic_code_runtime_state` masih menunjukkan allocator belum ada;
- nonterminal import job harus nol sebelum migration.

Live result received:

- seluruh invariant hanya `PASS`/`INFO`;
- 8/8 target column dan normalized-name index tersedia;
- zero duplicate/blank identity dan zero nonterminal job;
- 41 legacy codes dipertahankan;
- allocator/counter/trigger belum ada, sesuai expected pre-migration state.

## Planned Forward Migration

- private tenant/entity counter dengan atomic row lock/upsert;
- immutable automatic code untuk record baru;
- existing code tetap utuh;
- no `MAX(code)+1`;
- wrapper RPC tanpa parameter kode bagi guarded master;
- direct-table master mendapatkan BEFORE INSERT allocator;
- code mutation ditutup setelah compatibility path diverifikasi;
- postflight dan concurrency behavioral test wajib sebelum UI cutover.

## Rollback / Forward-fix

Preflight ini SELECT-only. Migration berikutnya additive. Jika rollout gagal,
satu transaction rollback seluruh allocator/trigger/RPC. Setelah applied,
perbaikan menggunakan forward migration; kode yang sudah dialokasikan tidak
digunakan ulang dan gap nomor diperbolehkan.
