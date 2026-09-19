# Sales Return Net Commercial Presentation Rollout

## Outcome

Retur tidak lagi tampil sebagai label tanpa dampak. SO/Order Retail dan Invoice
menampilkan dokumen asli sebagai histori, quantity aktual yang kembali,
disposition `RESTOCK`/`DESTROY`, Credit Note posted, dan nilai komersial bersih.

## Impact map

- Direct: read-model Retur read-only, API Sales Order/retained Retail history,
  daftar/detail SO dan Invoice.
- Stock: tidak ada mutation baru. `RESTOCK` tetap berasal dari Customer Return
  Receipt canonical yang menambah `product_stocks` dan membuat
  `stock_movements`; `DESTROY` tidak menambah stock.
- Finance: tidak ada mutation baru. Hanya Credit Note `POSTED` yang mengurangi
  nilai bersih. Receipt fisik tanpa Credit Note menampilkan status menunggu
  Finance dan tidak menebak nilai koreksi.
- Compatibility: SO, Invoice, Return, Receipt, Credit Note, Payment, Journal,
  FIFO, dan histori lama tidak diubah.
- Retry/concurrency: read-model `STABLE`; tidak menambah mutation atau operation
  identity baru.

## Urutan manual Production

1. Jalankan penuh [preflight](../../supabase/diagnostics/sales_return_net_commercial_read_model_preflight.sql).
2. Berhenti jika ada `BLOCKER`.
3. Jalankan penuh [migration](../../supabase/migrations/20260919100000_sales_return_net_commercial_read_model.sql) satu kali.
4. Jalankan penuh [behavior test](../../supabase/tests/sales_return_net_commercial_read_model_behavior.sql). Test berakhir `ROLLBACK`.
5. Jalankan penuh [postflight](../../supabase/diagnostics/sales_return_net_commercial_read_model_postflight.sql).
6. Deploy client Backoffice setelah seluruh check non-INFO `PASS`.

## Authenticated smoke

Gunakan satu Retur penuh dan satu Retur parsial:

1. Buka SO/Order Retail sumber. Pastikan baris asli tetap ada dan panel Dampak
   Retur menunjukkan Qty SO, Qty kembali, Qty bersih, serta disposition.
2. Untuk Receipt yang belum mempunyai Credit Note posted, pastikan nilai bersih
   belum dikurangi dan pesan `menunggu Credit Note` tampil.
3. Post Credit Note melalui flow Finance canonical, lalu muat ulang.
4. Pastikan nilai bersih = total asli - seluruh Credit Note posted.
5. Pastikan daftar Invoice, detail Invoice, daftar SO, dan detail Order memberi
   angka yang konsisten.
6. Untuk `RESTOCK`, cocokkan movement source-linked dan kenaikan stock. Untuk
   `DESTROY`, pastikan tidak ada kenaikan stock.
7. Ulangi pada Retur asal Backoffice dan asal Retail retained.

## Forward-fix / rollback

Migration hanya menambah satu RPC read-only. Jika client harus dikembalikan,
rollback client tidak mengubah transaksi. Jangan menghapus dokumen atau
memundurkan Journal/Stock. Jika RPC bermasalah, lakukan forward-fix function
setelah membandingkan output dengan Return Receipt dan Credit Note sumber.

## Status

- Local client: verified lint, TypeScript, dan production build.
- Database Production: belum dijalankan pada saat dokumen ini dibuat.
- Authenticated smoke/UAT: menunggu rollout manual.
