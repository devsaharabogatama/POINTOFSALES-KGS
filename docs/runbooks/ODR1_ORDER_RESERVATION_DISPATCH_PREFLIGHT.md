# ODR-1 Order Reservation and Dispatch Preflight

## Tujuan

Mengambil baseline live sebelum ODR-2 tanpa mengubah schema, data, Stock, FIFO,
Payment, atau Finance.

## Langkah manual

1. Jalankan
   `supabase/diagnostics/odr_phase1_order_reservation_dispatch_preflight.sql`
   di Supabase SQL Editor pada database target.
2. Kirim seluruh hasil `check_name,status,details` untuk direview.
3. Jangan jalankan migration ODR-2 bila ada `BLOCKER`.

## Cara membaca hasil

- `BLOCKER`: invariant live yang sudah berlaku rusak atau ada proses nonterminal;
  perbaiki dahulu.
- `PASS`: kontrak existing aman untuk menjadi baseline.
- `REVIEW`: collision dengan arsitektur baru yang sudah diprediksi dan akan
  dipindahkan pada fase terkait.
- `SETUP`: schema/runtime ODR belum ada; ini normal pada ODR-1.
- `INFO`: inventory untuk menentukan backfill dan fixture.

Audit ini harus menghasilkan satu statement SELECT-only. Tidak ada migration,
RPC mutation, DML, atau transaction cleanup pada fase ini.

## Expected sebelum ODR-2

- tidak ada `BLOCKER`;
- current POS final-effect dan Delivery gap muncul sebagai `REVIEW`;
- planned ODR schema muncul sebagai `SETUP`;
- inventory Sale, Delivery, procurement, dan Finance sesuai data live.
