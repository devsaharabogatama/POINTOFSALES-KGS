# ODR-6D Consumer Compatibility Rollout

Status: `DATABASE CLOSURE PASS; AUTHENTICATED UAT PENDING`.

## Tujuan

Menutup tiga blocker ODR-6D tanpa mengubah Order ODR menjadi Sale legacy
`POSTED`:

- Sales Return hanya memakai kuantitas yang benar-benar sudah Dispatch;
- AR Aging dan Customer Statement mengakui piutang TEMPO per Dispatch;
- Customer Receipt hanya dialokasikan ke piutang yang sudah Dispatch;
- pembayaran sebelum Dispatch tetap Customer Advance;
- Sale legacy `POSTED` tetap kompatibel.

## Urutan manual

Jalankan utuh dan berhenti pada SQL error atau `FAIL`:

1. [`20260829110000_odr_phase6d_sales_return_consumer_compatibility.sql`](../../supabase/migrations/20260829110000_odr_phase6d_sales_return_consumer_compatibility.sql)
2. [`20260829120000_odr_phase6d_tempo_ar_collection_compatibility.sql`](../../supabase/migrations/20260829120000_odr_phase6d_tempo_ar_collection_compatibility.sql)
3. [`odr_phase6d_consumer_compatibility_postflight.sql`](../../supabase/tests/odr_phase6d_consumer_compatibility_postflight.sql)
4. [`odr_phase6d_consumer_compatibility_behavior.sql`](../../supabase/tests/odr_phase6d_consumer_compatibility_behavior.sql)
5. [`odr_phase6d_e2e_closure_preflight.sql`](../../supabase/diagnostics/odr_phase6d_e2e_closure_preflight.sql)

Kedua migration transactional dan fail-closed. Live combined postflight,
behavior, dan closure preflight telah dilaporkan PASS. Patch core lama hanya diterapkan
jika definisi aktif cocok dengan kontrak yang diaudit; mismatch membatalkan
seluruh transaction.

## Smoke authenticated

1. Partial Dispatch order non-TEMPO; Return hanya menawarkan quantity partial.
2. Final Dispatch lalu Return sebagian; Return berikutnya tidak boleh melewati
   cumulative dispatched quantity.
3. Order TEMPO sebelum Dispatch tidak boleh menjadi invoice yang dapat
   dialokasikan pada Customer Receipt.
4. Setelah partial Dispatch, AR Aging, Statement, dan Customer Receipt hanya
   menampilkan nilai bagian yang sudah Dispatch.
5. Pembayaran terverifikasi sebelum Dispatch tetap Customer Advance.
6. Exact retry tidak boleh menggandakan Return, piutang, Event, atau Journal.
7. Satu Sale legacy `POSTED` tetap dapat memakai Return dan collection lama.

## Batas aman

- Tidak ada backfill Stock, FIFO, Return, Receipt, Event, atau Journal.
- Tidak ada perubahan Company posting policy atau browser direct table write.
- Physical Return dari bagian Dispatch negatif tetap fail-closed bila bukti
  FIFO tidak cukup. Jangan memaksa lewat direct table write.
- Jika masalah muncul setelah ledger tercatat, gunakan migration forward-fix
  baru; jangan mengedit migration applied atau ledger secara manual.
