# Sinkronisasi Pembatalan Sales Order dan Invoice

Status: **LOCAL READY — rollout Supabase dan authenticated smoke masih manual**  
Migration: `20260830110000_sales_order_cancellation_invoice_sync.sql`

## Outcome

Pembatalan sebelum Dispatch memakai satu runtime untuk POS dan Backoffice:

- Reservation dilepas;
- Surat Jalan linked berstatus `CANCELED`;
- procurement demand/Stock Request dihitung ulang oleh composition ODR existing;
- Invoice snapshot tidak dihapus, tetapi list/detail/export menampilkan
  `Dibatalkan` dan print/PDF diberi watermark `DIBATALKAN`;
- payment intent `PENDING` non-Cash dibatalkan;
- payment intent Cash pada sesi `OPEN` dibatalkan dan drawer mendapat satu
  movement reversal yang idempotent.

Pembayaran `VERIFIED`, Order yang sudah Dispatch, dan Cash dari sesi yang sudah
ditutup tetap fail-closed. Kasus tersebut memerlukan reversal/Return resmi dan
tidak boleh diselesaikan dengan delete histori.

Forward-fix `20260830120000` merevisi batas Cash sesi tertutup: bila Kasir
mempunyai sesi `OPEN` pada Store yang sama, pengembalian Cash dicatat exact-once
pada sesi aktif tersebut. Sesi sumber yang telah `CLOSED` tetap immutable.
Tanpa sesi aktif Store yang sama, pembatalan tetap fail-closed.

## Urutan rollout

1. Jalankan
   [`sales_order_cancellation_invoice_sync_preflight.sql`](../../supabase/diagnostics/sales_order_cancellation_invoice_sync_preflight.sql).
2. Stop bila ada `BLOCKER`.
3. Jalankan
   [`20260830110000_sales_order_cancellation_invoice_sync.sql`](../../supabase/migrations/20260830110000_sales_order_cancellation_invoice_sync.sql).
4. Jalankan
   [`sales_order_cancellation_invoice_sync_postflight.sql`](../../supabase/tests/sales_order_cancellation_invoice_sync_postflight.sql).
5. Stop bila ada `FAIL`.
6. Jalankan
   [`sales_order_closed_session_cash_cancel_preflight.sql`](../../supabase/diagnostics/sales_order_closed_session_cash_cancel_preflight.sql).
7. Stop bila ada `BLOCKER`, lalu jalankan
   [`20260830120000_sales_order_closed_session_cash_cancel.sql`](../../supabase/migrations/20260830120000_sales_order_closed_session_cash_cancel.sql).
8. Jalankan
   [`sales_order_closed_session_cash_cancel_postflight.sql`](../../supabase/tests/sales_order_closed_session_cash_cancel_postflight.sql), dan stop bila ada `FAIL`.
9. Deploy/restart Backoffice dan PWA dari commit yang sama, lalu hard refresh.

## Authenticated smoke

Gunakan Company uji dan Order baru; jangan memakai transaksi historis penting.

1. Buat Order Cash, pastikan Reservation dan Invoice/SJ terbentuk.
2. Sebelum Dispatch, buka `Sales > Invoice Penjualan > Detail`, klik
   **Batalkan Order**, isi alasan, lalu konfirmasi.
3. Pastikan Invoice berstatus `Dibatalkan`, alasan/aktor/waktu terlihat, PDF dan
   print memiliki watermark.
4. Pastikan Surat Jalan linked `CANCELED`, Reservation `RELEASED`, Reserved Out
   berkurang, dan Cash drawer mempunyai reversal tepat satu kali.
5. Ulangi request cancel dengan idempotency yang sama melalui test client bila
   tersedia; tidak boleh muncul reversal kedua.
6. Negative test: Order yang sudah mulai Dispatch harus ditolak.
7. Negative test: payment `VERIFIED` harus ditolak dengan pesan reversal
   Finance; tidak boleh menghapus Event/Journal.
8. Tutup sesi sumber Order Cash, buka sesi baru pada Store yang sama, batalkan
   Order, lalu pastikan reversal hanya muncul pada sesi baru dan closing sesi
   sumber tidak berubah.
9. Negative test: ulangi tanpa sesi aktif Store yang sama; pembatalan harus
   ditolak tanpa perubahan Reservation, payment, atau drawer.
10. Uji cancel dari POS dan pastikan status yang sama langsung terlihat pada
   Backoffice setelah `Muat ulang`.

## Compatibility dan rollback

- Invoice snapshot, nomor Invoice, line, harga, Payment snapshot, dan audit
  historis tidak dimutasi.
- Legacy final Sale/Invoice tetap terbaca sebagai `Aktif`.
- Forward-fix rollback aman adalah mengembalikan wrapper/read RPC sebelumnya;
  jangan menghapus row `CANCELED`, reversal drawer, atau audit yang sudah sah.
- Migration tidak dijalankan agent ke database mana pun.
