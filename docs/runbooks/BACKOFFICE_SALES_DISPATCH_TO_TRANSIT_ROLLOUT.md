# Backoffice Sales Dispatch to Transit Rollout

Status 2026-09-09: preflight aman, migration berhasil diterapkan, serta
postflight dan rollback behavioral seluruhnya PASS menurut konfirmasi user
hanya pada isolated Development `fkywtxucmyjvpwdiqpix`. Authenticated UI smoke
dan UAT masih pending.

Gate `20260909151000` membuka mutation Dispatch Backoffice saja. Kuantitas
aktual berpindah dari Gudang operasional ke Transit
`SALES_DELIVERY_OUTBOUND` melalui core Stock Transfer canonical sehingga FIFO
batch, saldo kedua Gudang, dua Stock Movement, idempotency, dan audit tidak
ditulis ulang oleh modul Sales.

Reservation boleh melebihi On Hand saat Confirm bila Warehouse mengizinkan.
Dispatch berbeda: barang yang diberangkatkan harus mempunyai saldo fisik dan
FIFO. Kekurangan tetap menjadi sisa Reservation/DO untuk proses Purchasing atau
Backorder; sistem tidak membuat stok Transit fiktif.

Gate ini belum menjalankan penerimaan Customer, sale-out final, COGS final,
Qty To Invoice, Invoice, AR/Revenue, Payment, Financial Event, atau Journal.
POS retail tidak memakai RPC atau tabel baru ini.

## Impact map

- Direct: Backoffice Delivery, Reservation, Warehouse Transit, Stock Transfer,
  Product Stock, FIFO batch, Stock Movement, fulfillment audit.
- Downstream yang sengaja belum aktif: Customer receipt, Backorder creation,
  discrepancy, Return, Invoice, Payment, Finance.
- Compatibility: DO lama `READY` dapat diproses; POS Delivery/Dispatch tidak
  berubah; Stock Transfer manual tetap memakai RPC lama.
- Concurrency: operation UUID memperoleh advisory transaction lock, Delivery
  memakai master version, Stock Transfer mengunci pasangan Product/Warehouse.
- Retry: operation UUID + payload canonical yang sama mengembalikan hasil lama;
  payload berbeda ditolak.
- Rollback: kegagalan di validasi, Transit resolver, FIFO, Movement, atau update
  Delivery membatalkan seluruh transaksi. Setelah migration COMMIT, rollback
  dilakukan dengan forward-fix yang mencabut RPC; tabel lineage tidak di-drop.

## Urutan hanya isolated Development

1. Pastikan target project-ref tepat `fkywtxucmyjvpwdiqpix`.
2. Jalankan
   `supabase/diagnostics/backoffice_sales_dispatch_to_transit_preflight.sql`.
   Stop pada `BLOCKER`.
3. Apply
   `supabase/migrations/20260909151000_backoffice_sales_dispatch_to_transit.sql`.
4. Jalankan
   `supabase/diagnostics/backoffice_sales_dispatch_to_transit_postflight.sql`.
   Semua baris selain inventory harus `PASS` dan `violation_rows=0`.
5. Jalankan
   `supabase/tests/backoffice_sales_dispatch_to_transit_behavior.sql`.
   Test melakukan partial, exact retry, stale version, final Dispatch, lalu
   `ROLLBACK` seluruh fixture.
6. Restart/refresh Backoffice lokal. Dari Inventory > Surat Jalan, buka DO
   Backoffice `READY`, kirim sebagian, muat ulang, lalu kirim sisanya.
7. Verifikasi Stock Real/Kartu Stok: source berkurang, Transit bertambah,
   total Company tetap, dan belum ada Invoice/Finance effect.

Production `nbxjslqojexjfogamnjt` dan staging lama
`yjxpddwrjdczuqyixqwi` tidak boleh menjadi target gate ini.
