# ODR-6A POS Order Cutover

## Status lokal

- POS online memanggil `confirm_pos_sales_order`, bukan final-post Sale legacy;
- Confirmed Order berpindah dari daftar Draft ke panel **Order**;
- Order aktif dan Order terjadwal ditampilkan terpisah;
- Cancel Order memakai RPC canonical dan melepas Reserved Out yang belum dikirim;
- Invoice A4 dan Surat Jalan hasil snapshot Confirm tetap dapat dicetak;
- nomor Invoice final `INV-*` dialokasikan setelah Reservation sukses dan
  sebelum snapshot Invoice/SJ dibuat;
- Order dengan Payment `PENDING` atau `VERIFIED` tidak dapat dibatalkan sampai
  Finance menyelesaikan Payment tersebut;
- checkout Offline baru fail-closed sampai reservation replay parity tersedia;
- PWA lint dan production build PASS.

ODR-6A menambah guard pembatalan dan forward-fix identitas Invoice. Seluruh
Company tetap memakai Finance `CONTROLLED`.

## Urutan rollout wajib

1. jalankan `supabase/migrations/20260828270000_odr_phase6a_pos_order_cutover_guard.sql`;
2. jalankan `supabase/tests/odr_phase6a_pos_order_cutover_guard_behavior.sql`;
3. jalankan `supabase/tests/odr_phase6a_pos_order_cutover_guard_postflight.sql`;
4. jalankan diagnostic SELECT-only
   `supabase/diagnostics/odr_phase6a_invoice_identity_forward_fix_preflight.sql`;
5. jalankan migration
   `supabase/migrations/20260828280000_odr_phase6a_invoice_identity_forward_fix.sql`;
6. jalankan
   `supabase/tests/odr_phase6a_invoice_identity_forward_fix_behavior.sql`;
7. jalankan
   `supabase/tests/odr_phase6a_invoice_identity_forward_fix_postflight.sql`;
8. deploy atau jalankan PWA hasil build terbaru;
9. lakukan authenticated smoke di bawah;
10. tutup dengan `supabase/tests/odr_phase6a_pos_order_cutover_postflight.sql`.

Jangan melanjutkan smoke UI sebelum kedua migration terpasang. `BACKFILL` pada
preflight identitas Invoice adalah repair scope yang diharapkan; stop pada
`BLOCKER`. Behavioral test harus menghasilkan satu `PASS`; seluruh postflight
hanya boleh menghasilkan `PASS` dan `INFO`.

## Authenticated smoke wajib

Gunakan Company dummy dan satu sesi Kasir aktif:

1. catat On Hand produk, buat Order non-TEMPO online, lalu klik
   **Konfirmasi Order**;
2. pastikan Order hilang dari Draft dan muncul pada panel **Order aktif**;
3. pastikan Invoice A4 dan Surat Jalan dapat dibuka;
   nomor Invoice pada keduanya wajib berbentuk `INV-YYYYMMDD-XXXXXXXXXX`, bukan
   `DRAFT-*`;
4. pastikan On Hand/FIFO belum berubah, sementara Reserved Out bertambah;
5. pastikan payment non-TEMPO masuk pending verification dan belum membuat
   Journal sebelum Finance memprosesnya;
6. buat satu Order TEMPO bertanggal mendatang dan pastikan muncul pada bagian
   **Order terjadwal** tanpa memenuhi Draft;
7. batalkan satu Order TEMPO/tanpa Payment yang belum dikirim, isi alasan, lalu
   pastikan reservation berstatus `RELEASED`;
8. pada Order non-TEMPO dengan Payment `PENDING`, pastikan pembatalan ditolak
   dengan pesan bahwa Payment harus diselesaikan Finance terlebih dahulu;
9. matikan koneksi dan pastikan checkout baru tidak dapat disimpan sebagai
   transaksi Offline; antrean historis tetap dapat dilihat/disinkronkan;
10. hard refresh dan pastikan daftar Order tetap sama;
11. jalankan
    `supabase/tests/odr_phase6a_pos_order_cutover_postflight.sql`.

Postflight hanya boleh menghasilkan `PASS` dan `INFO`. Stop pada `FAIL`.

## Compatibility

- Sale/Invoice/Journal final historis tidak diubah; hanya snapshot
  `ORDER_CONFIRM` yang salah menangkap `DRAFT-*` diperbaiki dan diaudit;
- `post_pos_sale_with_pricelist` tetap tersedia untuk histori dan dependency
  Offline lama, tetapi tidak berada dalam bundle checkout aktif;
- Return tetap memakai dokumen historis/final existing;
- Dispatch Stock dan verifikasi Finance belum dipindahkan UI sampai ODR-6B/6C.
