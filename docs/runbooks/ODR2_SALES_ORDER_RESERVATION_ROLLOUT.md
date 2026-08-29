# ODR-2 Sales Order and Reservation Rollout

## Status

Preflight live sudah PASS. ODR-2A foundation local-ready; runtime Confirm dan
reservation atomik tetap menunggu ODR-2B.

## Langkah saat ini

1. Jalankan
   `supabase/diagnostics/odr_phase2_sales_order_reservation_preflight.sql`.
2. Kirim seluruh hasil `check_name,status,details`.
3. `BLOCKER` wajib dibereskan sebelum migration dibuat/dijalankan.
4. `BACKFILL` menentukan converter Draft yang dibutuhkan.
5. `SETUP` untuk permission/schema reservation memang expected sebelum migration.

## ODR-2A manual rollout

1. Jalankan migration
   `supabase/migrations/20260828100000_odr_phase2a_sales_order_reservation_foundation.sql`.
2. Jalankan `supabase/tests/odr_phase2a_reservation_foundation_postflight.sql`.
3. Jalankan `supabase/tests/odr_phase2a_reservation_foundation_behavior.sql`.
4. Jalankan postflight sekali lagi; semua selain inventory harus `PASS`.

## ODR-2B runtime gate

Setelah ODR-2A PASS, jalankan
`supabase/diagnostics/odr_phase2b_atomic_reservation_runtime_preflight.sql`.
Audit ini menghitung `Available to Sell = On Hand - Reserved Out` dan memeriksa
policy/permission negative-stock untuk setiap shortage Draft. Runtime ODR-2B
tidak boleh memakai helper negative-stock lama yang hanya melihat On Hand.

Setelah corrected preflight seluruhnya `PASS`/expected `SETUP`, jalankan:

1. `supabase/migrations/20260828110000_odr_phase2b_atomic_sales_order_reservation_runtime.sql`;
2. `supabase/tests/odr_phase2b_atomic_reservation_runtime_postflight.sql`;
3. `supabase/tests/odr_phase2b_atomic_reservation_runtime_behavior.sql`;
4. postflight yang sama sekali lagi.

Behavioral test menggunakan satu Draft milik Kasir yang masih mempunyai sesi
aktif pada Store yang sama dan selalu `ROLLBACK`. Confirm/retry/cancel wajib
tidak mengubah On Hand, FIFO, Movement, Invoice, Payment, atau Financial Event.

## Rollback / forward-fix ODR-2B

- Sebelum ada reservation live, rollback teknis dapat menghapus tiga wrapper,
  dua private core, unique audit-operation index, dan ledger `20260828110000`.
- Setelah reservation live terbentuk, jangan menghapus row atau menurunkan
  schema. Nonaktifkan pemanggilan client dan gunakan forward-fix versioned;
  order terbuka dibatalkan hanya melalui RPC agar release dan audit tetap utuh.
- Migration ini tidak mengganti `post_pos_sale`; cutover UI dan retirement jalur
  final-effect lama baru dilakukan pada ODR-6 setelah ODR-3 sampai ODR-5 PASS.

## Batas fase

ODR-2 hanya akan membuat confirmed Sales Order dan reservation/availability.
ODR-2 belum boleh:

- mengurangi `product_stocks` atau FIFO saat Confirm;
- membuat Stock Movement atau journal saat Confirm;
- memindahkan stock effect Delivery sebelum ODR-3;
- menyinkronkan procurement sebelum ODR-4;
- membuka Payment verification sebelum ODR-5.

Sale `POSTED` historis tetap final dan tidak diberi reservation baru. Draft dan
Scheduled TEMPO hanya dikonversi melalui aksi server yang versioned/idempotent.

`sale_stock_requirements` pada Draft adalah snapshot kebutuhan Product/Bundle
yang dibuat server saat Draft disimpan. Keberadaannya expected dan akan menjadi
sumber reservation ODR-2; ia bukan final effect karena tidak mengubah On Hand,
FIFO, Movement, Payment, Financial Event, Invoice, atau Delivery.
