# G3 Phase 12 — Bundle Foundation Preflight

## Tujuan

Mengaudit kesiapan Bundle virtual sebelum migration composition/audit dan
server-side availability/expansion ditulis. Diagnostic ini hanya membaca data.

Requirement:

- `STK-006`;
- G3 Stock Ledger/FIFO/Bundle;
- Bundle commercial SKU tetap satu line;
- stok dan FIFO hanya milik komponen `STOCK`;
- nested Bundle dilarang.

## Boundary

Fase ini belum:

- mengaktifkan Bundle pada form Product;
- mengaktifkan checkout atau sales posting;
- membuat component revenue allocation;
- mengaktifkan Return/Credit Note Bundle;
- mengaktifkan Import Bundle;
- mengubah saldo, movement, FIFO, atau Product existing.

Checkout, idempotent sale posting, snapshot allocation, offline queue, dan
Return tetap G4. Preflight G3 fokus pada master composition, canonical component
UOM, virtual-stock invariant, dan kesiapan ledger.

## Menjalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

```text
supabase/diagnostics/g3_phase12_bundle_foundation_preflight.sql
```

Kirim seluruh output `check_name,status,details`.

## Interpretasi

- `BLOCKER`: data existing harus diselesaikan sebelum migration.
- `BACKFILL`: migration memerlukan backfill eksplisit yang dapat diverifikasi.
- `PASS`: invariant existing bersih.
- `INFO`: inventory/gap schema, bukan kegagalan.

Expected pada database yang belum memakai Bundle:

- dependencies `PASS`;
- seluruh invariant component/stock `PASS`;
- inventory Bundle dan component bernilai nol;
- `legacy_component_uom_backfill_scope` `PASS`;
- schema/RPC canonical masih `INFO`;
- direct table write mungkin masih `true` dari compatibility grant G1 dan harus
  ditutup saat guarded Bundle RPC tersedia.

## Keputusan Setelah Hasil

Jika tidak ada `BLOCKER`, langkah berikutnya adalah migration additive yang:

1. menjaga `product_bundle_items.qty` sebagai compatibility source selama
   backfill;
2. menambahkan canonical component UOM/quantity, ordering, version, dan audit;
3. menyediakan atomic guarded Product+composition save;
4. menolak nested/self/cross-Company/inactive component;
5. memastikan Bundle tidak mempunyai physical stock/FIFO;
6. menyediakan availability/expansion server contract untuk dipakai G4;
7. belum mengaktifkan checkout atau accounting allocation.
