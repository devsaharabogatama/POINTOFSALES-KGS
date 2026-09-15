# Backoffice Sales Warehouse-authorized Negative Dispatch

Status: **LOCAL READY; MANUAL ISOLATED-DEVELOPMENT SQL GATE PENDING**.

Target hanya Supabase Development `fkywtxucmyjvpwdiqpix`. Jangan jalankan pada
production `nbxjslqojexjfogamnjt` atau staging lama.

## Outcome dan keputusan bisnis

Latest historical-clone evidence (2026-09-15, unit 46/88): preparation corrected
to select an Auth-backed actor and prepare Office mode only in outer rollback.
The setup marker is cleared BEFORE Sales RPC and the root-mode guard remains
enforced. Eight primary preflight PASS; migration installed; nine initial and
closing postflight PASS; all eight behavioral scenarios PASS. Five active clone
Companies remain Retail afterward; allocation/replenishment fixture rows zero.
This supersedes the preparation blocker below, not Production readiness.
Authenticated UI smoke/UAT and final fresh-clone rehearsal remain pending.

Historical-clone rehearsal (2026-09-15, unit 46/88) stopped BEFORE migration.
Primary preflight eight PASS, but preparation does not establish Office Company
mode before creating a new Office root. Unit 45 enforces that mode; read-only
[mode inventory](../../supabase/diagnostics/backoffice_sales_negative_dispatch_rehearsal_mode_inventory.sql)
confirmed all five active clone Companies are Retail. Do not run the existing
behavior as ready, bypass the root creation gate, or switch actual Company mode
to accommodate a fixture. Reconcile rollback-only preparation first. Migration
46, behavioral and postflight have not been executed on this clone.

- `warehouses.allow_negative_stock` tetap satu-satunya izin shortage baru bagi
  POS dan Backoffice.
- Backoffice DO boleh berangkat walaupun stok fisik/FIFO sumber kurang ketika
  Warehouse tersebut mengizinkan minus.
- Kekurangan dipindahkan ke Transit outbound sebagai FIFO provisional yang
  memiliki lineage khusus; customer tetap boleh mengonfirmasi penerimaan sebelum
  barang pengganti masuk.
- Barang masuk berikutnya menutup shortage. Nilai yang masih berada di Transit
  direvaluasi; variance barang yang sudah diterima customer masuk sumber koreksi
  COGS append-only melalui kontrak Finance existing.
- Stock Transfer biasa tetap menolak saldo kurang. POS tetap memakai allocation,
  guard, dan runtime sebelumnya.

## Impact map

- Direct: Backoffice Dispatch, Stock Transfer yang dibuat oleh Dispatch,
  Product Stock sumber/Transit, FIFO batch/allocation, dan audit Dispatch.
- Downstream: Customer Receipt membaca batch Transit yang sama; replenishment
  Goods Receipt menutup allocation shortage dan memasok variance COGS kepada
  Finance event existing.
- Tidak berubah: harga/tax/payment/Invoice, Cashier Session, POS UI/runtime,
  ordinary Stock Transfer, Sales Return, serta mode cutover.
- Compatibility: Dispatch lama tetap mempunyai lineage normal; tidak ada
  backfill atau perubahan row historis.
- Concurrency/retry: lock Product-Warehouse dan Delivery version tetap berlaku;
  operation UUID Dispatch tetap menjadi idempotency authority.
- Rollback: seluruh failure sebelum COMMIT bersifat atomic. Setelah ada Dispatch
  nyata, jangan drop allocation/batch; nonaktifkan izin minus pada Warehouse dan
  gunakan forward-fix.

## Urutan manual

Jalankan setiap file secara utuh di SQL Editor project Development:

1. [Preflight](../../supabase/diagnostics/backoffice_sales_negative_dispatch_preflight.sql)
2. Stop jika ada `BLOCKER` atau SQL error.
3. [Migration 20260911140000](../../supabase/migrations/20260911140000_backoffice_sales_negative_dispatch_runtime.sql)
4. [Postflight](../../supabase/diagnostics/backoffice_sales_negative_dispatch_postflight.sql)
5. Stop jika ada `FAIL`.
6. [Behavioral rollback](../../supabase/tests/backoffice_sales_negative_dispatch_behavior.sql)
7. Jalankan postflight kembali.
8. Authenticated smoke: aktifkan **Izinkan stok minus** pada Warehouse sumber,
   buka DO shortage, Dispatch, konfirmasi diterima, lalu periksa Stock Real,
   Transit, allocation, dan Finance setelah Goods Receipt pengganti.

Behavioral membuat Quotation/SO/DO sendiri dari master canonical, mengisolasi
stok Product di dalam transaksi, dan selalu `ROLLBACK`. Ia tidak membutuhkan
OPEN Cashier Session, Draft manual, atau Company kedua.

## Purchasing yang sengaja belum dibuka

User menetapkan PO kelak mengikuti shortage SO/DO per hari. Patch ini hanya
menyimpan sumber lineage yang diperlukan (`sales_order_id`, `delivery_order_id`,
Product, Warehouse, quantity, dan status replenishment). Pembuatan Request/PO,
supplier split, penggabungan harian, dan amendment PO final tetap task
Purchasing terpisah; tidak dibuat diam-diam oleh Dispatch ini.
