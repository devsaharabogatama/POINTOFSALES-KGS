# ODR-5C Dispatch Finance Runtime Preflight

Preflight ini adalah audit SELECT-only sebelum runtime Dispatch membuat source
Finance dan Financial Event. Ia tidak mengubah Dispatch, Stock, FIFO, Event,
queue, Journal, maupun master Finance.

## Jalankan

Jalankan satu file berikut melalui Supabase SQL Editor:

`supabase/diagnostics/odr_phase5c_dispatch_finance_runtime_preflight.sql`

Kirim seluruh output. Jangan menjalankan migration ODR-5C bila ada
`BLOCKER`.

## Hasil yang diharapkan

- dependency ODR-3C, ODR-5A, dan ODR-5B `PASS`;
- Finance queue serta Offline submission aktif nol;
- source Dispatch Finance masih nol;
- operasi Dispatch ODR lama tanpa source Finance nol;
- Invoice/SJ, allocation/Movement, periode, exact account mapping, dan approved
  posting rule `PASS`;
- `canonical_dispatch_finance_hook_state = SETUP` memang expected karena
  runtime baru belum dipasang;
- dua row `REVIEW` mengunci proportional partial Dispatch dan batas verifikasi
  pembayaran, bukan izin untuk mengubah transaksi historis.

## Gate berikutnya

Jika seluruh `BLOCKER` nol, migration ODR-5C boleh dibuat untuk:

1. menangkap satu immutable financial effect per operasi Dispatch;
2. mengalokasikan nilai komersial secara proporsional dan menutup residual pada
   Dispatch terakhir;
3. memakai actual FIFO/provisional negative cost dari allocation Dispatch;
4. membuat satu `SALE_DISPATCHED` Financial Event yang idempotent;
5. mempertahankan controlled posting dan seluruh jurnal legacy.

ODR-5D verifikasi pembayaran serta automatic posting tetap belum dibuka.
