# Cash Session Close — Asynchronous Payment Verification

Tujuan: Tutup Sesi kasir tidak menunggu Finance memverifikasi setiap payment.
Cash tetap dicatat tepat sekali pada drawer ketika Order dikonfirmasi; antrean
verifikasi, audit, dan controlled Journal tetap diproses Finance kemudian.

## Urutan rollout

1. Jalankan `supabase/diagnostics/odr_cash_session_close_async_payment_preflight.sql`.
2. Stop bila ada `BLOCKER`.
3. Jalankan migration
   `supabase/migrations/20260829130000_cash_session_close_async_payment_verification.sql`.
4. Jalankan
   `supabase/tests/odr_cash_session_close_async_payment_postflight.sql`.
5. Stop bila ada `FAIL`.
6. Hard refresh PWA, lalu smoke transaksi Cash → Tutup Sesi tanpa tindakan
   Finance. Pastikan expected cash, actual cash, difference, serta Stock Request
   sesi tetap tampil normal.
7. Pastikan payment masih terlihat pada Finance → Verifikasi Bayar dan dapat
   diproses kemudian.

## Compatibility dan boundary

- Tidak mengubah payment intent, nominal, Cash drawer movement, Order,
  Reservation, Dispatch, Demand, Stock Request, Event, Journal, atau histori.
- Tidak mengaktifkan automatic Finance posting.
- Non-Cash dan Cash sama-sama boleh menunggu review Finance tanpa memblokir
  penutupan operasional kasir.
- Private close chain lama tetap dipakai agar projection Procurement tidak
  hilang.

## Forward-fix / rollback

Migration applied tidak boleh diedit atau dijalankan ulang. Jika ditemukan gap,
buat forward-fix baru. Rollback bisnis sementara adalah memproses semua pending
payment melalui Finance sebelum menutup sesi; jangan menghapus request, drawer
movement, audit, Event, atau Journal.
