# G3 Phase 6 — Stock Transfer Preflight

## Status

`COMPLETE — LIVE PREFLIGHT REVIEWED`

## Alasan phase ini

Urutan modul Inventory yang disetujui menempatkan `Transfer Stok` setelah
`Stock Movement / Kartu Stok`. RPC legacy
`transfer_product_stock(uuid,uuid,uuid,numeric)` tidak boleh dipakai sebagai
contract production karena:

- quantity tidak divalidasi positif;
- saldo sumber tidak dikunci/di-update dengan guard concurrency atomic;
- tidak ada Draft/Posted source document;
- movement memakai `product_stocks` sebagai pseudo-source;
- idempotency, actor, snapshot, warehouse-role scope, dan perpindahan FIFO
  belum memenuhi G3.

Browser execute sudah ditutup sejak G1. Preflight ini tidak memanggil RPC
legacy dan tidak membuat transfer.

## Jalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

`supabase/diagnostics/g3_phase6_stock_transfer_preflight.sql`

Kirim seluruh output `check_name,status,details`.

## Interpretasi

- Semua `BLOCKER` harus `PASS`.
- `legacy_transfer_rpc_state = REVIEW` adalah expected bila routine server-only
  lama masih ada; routine tersebut akan dipensiunkan melalui migration
  forward-only, bukan diedit atau dipakai kembali.
- `legacy_transfer_movement_source = REVIEW` berarti ada transfer historis yang
  memerlukan explicit backfill/compatibility rule.
- `canonical_stock_transfer_schema_state = INFO` diperkirakan menunjukkan tiga
  tabel belum ada.
- `direct_stock_write_privilege` harus menunjukkan seluruh browser write
  `false`.

## Target migration bila preflight bersih

Migration berikutnya hanya boleh membuka canonical Transfer:

- dokumen `DRAFT -> POSTED/CANCELED`;
- source dan destination Gudang berbeda tetapi satu Company;
- quantity positif dalam Base UOM;
- source stock row lock dan nonnegative guard;
- FIFO layer dipindahkan tanpa mengubah total nilai Company;
- satu line menghasilkan pasangan `TRANSFER_OUT` dan `TRANSFER_IN` dengan
  source identity yang sama;
- posting atomic, idempotent, actor/time audited, dan immutable;
- Store/Warehouse role scope diverifikasi server-side;
- tidak membuka Adjustment, Opname, G4 notification, atau G5 Purchasing.

## Rollback

File ini SELECT-only sehingga tidak membutuhkan rollback.

## Live result 2026-07-28

- seluruh blocker `PASS`;
- `legacy_transfer_rpc_state = REVIEW` sesuai ekspektasi dan browser execute
  `false`;
- zero transfer history/legacy source/snapshot gap;
- saldo, FIFO, Base UOM, dan Finance category readiness `PASS`;
- canonical table masih absent sesuai `INFO`;
- satu saldo sumber positif pada Company yang memiliki tiga Gudang aktif.

Next gate:
`docs/runbooks/G3_PHASE6_STOCK_TRANSFER_FOUNDATION_ROLLOUT.md`.
