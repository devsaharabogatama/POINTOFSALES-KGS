# ODR-5E Dispatch Advance Reconciliation

## Tujuan

Fase ini menghapus guard sementara ODR-5D dengan memasang aplikasi uang muka
Customer dan payment surcharge ke immutable Dispatch Finance source. Rebalance
dijalankan tepat sekali sesudah Stock/FIFO Dispatch dan sebelum transaksi SQL
selesai, sehingga kegagalan Finance tetap me-rollback seluruh Dispatch.

## Urutan eksekusi

1. Jalankan migration
   `supabase/migrations/20260828250000_odr_phase5e_dispatch_advance_reconciliation.sql`.
2. Jalankan behavioral rollback
   `supabase/tests/odr_phase5e_dispatch_advance_reconciliation_behavior.sql`.
3. Jalankan SELECT-only postflight
   `supabase/tests/odr_phase5e_dispatch_advance_reconciliation_postflight.sql`.
4. Kirim seluruh output behavioral dan postflight sebelum ODR-5F.

## Kontrak

- Surcharge berasal dari snapshot payment intent Order, bukan input Dispatch.
- Verified payment sebelum Dispatch mengurangi Customer Advance liability.
- Sisa non-TEMPO masuk Payment Clearing; sisa TEMPO masuk Customer Receivable.
- Partial Dispatch tidak mengambil fixed surcharge; Dispatch final menutup
  residual surcharge.
- Source hanya boleh direbalance sekali, ketika Event masih `HOLD` dan belum
  memiliki jurnal.
- Dispatch Event yang mendebit Customer Advance hanya dapat diposting setelah
  Event penerimaan advance terkait berstatus `POSTED`; urutan yang salah tetap
  `HOLD` dan dapat di-retry.
- Automatic posting tetap ditolak sampai ODR-5F closing reconciliation.

Behavioral harus menghasilkan satu `PASS`. Postflight hanya boleh berisi
`PASS` dan `INFO`.
