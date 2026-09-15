# Purchase Daily Replenishment Step 4/6 — AUTO_PO Runtime

## Status

`LOCAL READY`. Jalankan hanya pada isolated Development
`fkywtxucmyjvpwdiqpix`. Production dan staging tidak boleh disentuh.

Step 3/6 `20260913120000` harus sudah live serta behavioral dan postflight-nya
PASS. Migration Step 3 yang sudah applied tidak diubah.

## Outcome

- Company dengan mode `AUTO_PO` dapat menjalankan generator setelah cutoff
  `23:59` waktu lokal Company.
- Sumber tetap hanya negative On Hand dikurangi open Purchase pada
  Product–Gudang yang sama.
- Line siap langsung menjadi PO `CONFIRMED`, dipisahkan per Supplier dan satu
  kelompok `SUPPLIER_PENDING`.
- Line `WAREHOUSE_SETUP_REQUIRED`, source/master invalid, request Gudang ambigu,
  atau quantity yang tidak exact terhadap UOM pembelian tetap berada dalam
  batch `DRAFT` dan tidak menggagalkan line siap.
- Batch menjadi `READY` hanya bila seluruh line sudah `ORDERED`; batch parsial
  tetap `DRAFT` agar blocker terlihat dan tidak dinyatakan selesai.
- Exact operation retry dan request kedua pada tanggal yang sama tidak membuat
  batch atau PO duplikat.
- Receipt, Stock Movement, FIFO, AP, Financial Event, Journal, Supplier Bill,
  Payment, scheduler, dan UI tidak diaktifkan pada gate ini.

Kelanjutan line tertahan setelah setup Gudang diperbaiki masuk Step 5/6. Step 4
tidak mengedit PO `CONFIRMED` dan tidak menebak Gudang.

## Impact map

- Direct: `purchase_daily_batch_operations`, `purchase_daily_batch_audit`,
  `purchase_daily_batches`, `purchase_daily_batch_lines`,
  `supplier_order_documents`, `supplier_order_lines`, dan exact allocation.
- Downstream read-only: preview Purchase menandai generator aktif pada
  `AUTO_RO` maupun `AUTO_PO`.
- Tidak berubah: mode `MANUAL`, generator/confirmation `AUTO_RO`, PO manual,
  POS Retail, session Kasir, Reservation, Transit, Stock/FIFO, AP, dan Finance.
- Concurrency: advisory transaction lock per Company dan row lock setting serta
  negative Stock.
- Idempotency: `(Company, operation UUID, request hash)` dan unique daily batch.
- Rollback setelah migration live adalah forward-fix additive; jangan menghapus
  PO atau histori operasi/audit.

## Urutan manual

Jalankan satu file penuh pada SQL Editor project isolated Development:

1. `supabase/diagnostics/purchase_daily_auto_po_runtime_preflight.sql`
2. `supabase/migrations/20260913130000_purchase_daily_auto_po_runtime.sql`
3. `supabase/diagnostics/purchase_daily_auto_po_runtime_postflight.sql`
4. `supabase/tests/purchase_daily_auto_po_runtime_behavior.sql`
5. ulangi `supabase/diagnostics/purchase_daily_auto_po_runtime_postflight.sql`

Stop jika ada SQL error, `BLOCKER`, atau `FAIL`. Jangan menjalankan migration
ulang bila ledger `20260913130000` sudah ada; kirim error lengkap untuk
forward-fix.

## Behavioral evidence yang wajib

Test membuat sendiri Category, tiga Product, Base UOM, Supplier, Product-
Supplier, Gudang penerimaan, Gudang non-penerimaan, dan negative On Hand di
dalam `BEGIN`/`ROLLBACK`. Test tidak membutuhkan Product/Supplier/Gudang
operasional existing.

Behavior membuktikan:

- mode `MANUAL` dan eksekusi sebelum cutoff ditolak;
- Product siap dan `SUPPLIER_PENDING` menghasilkan dua PO confirmed;
- Product tanpa Gudang penerimaan tetap tertahan tanpa allocation;
- exact retry dan same-date reuse tidak menggandakan PO;
- operation/audit/lineage exact;
- jumlah Receipt, Stock Movement, dan Finance Event tidak berubah.

## Status evidence

- Local file/static verification: wajib dicatat sebelum handoff.
- Database live: menunggu user menjalankan migration.
- Behavioral/postflight: menunggu output user seluruhnya PASS.
- Authenticated smoke/UAT: belum dibuka pada Step 4.
