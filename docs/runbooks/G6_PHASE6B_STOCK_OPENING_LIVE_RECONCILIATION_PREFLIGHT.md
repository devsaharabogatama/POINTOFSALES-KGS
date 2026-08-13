# G6 Corrective Phase 6B - Stock Opening Live Reconciliation Preflight

## Tujuan

Gate ini memastikan satu historical `STOCK_OPENING` live aman memasuki queue
terkontrol setelah Phase 6A reports lulus. File hanya membaca aggregate state;
ia tidak membuat queue, tidak mengubah event, dan tidak menulis jurnal.

## Jalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

`supabase/diagnostics/g6_phase6b_stock_opening_live_reconciliation_preflight.sql`

Kirim seluruh output sebelum memanggil RPC preview/approve/process.

## Expected

- `BLOCKER` harus nol;
- `REVIEW` harus nol sebelum live posting;
- `supported_stock_opening_live_run_scope = BACKFILL` expected bila event live
  masih menunggu;
- `stock_fifo_gl_live_baseline = BACKFILL` expected selama Inventory GL masih
  nol;
- unsupported event tetap `DEFERRED` dan tidak ikut queue;
- active queue wajib nol.

## Boundary

Jangan menjalankan queue dari SQL manual sebelum output ini direview. Setelah
aman, langkah berikutnya adalah preview satu active Company, verifikasi hash dan
jumlah event, approval eksplisit, process, lalu closing reconciliation. Tidak
ada jurnal manual untuk menutup selisih FIFO–GL.
