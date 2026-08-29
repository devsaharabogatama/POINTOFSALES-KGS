# ODR-3C Atomic Delivery Dispatch

Jalankan berurutan melalui Supabase SQL Editor:

1. `supabase/migrations/20260828140000_odr_phase3c_atomic_delivery_dispatch.sql`
2. `supabase/tests/odr_phase3c_atomic_delivery_dispatch_postflight.sql`
3. `supabase/tests/odr_phase3c_atomic_delivery_dispatch_behavior.sql`
4. ulangi postflight nomor 2.

Semua check selain `dispatch_runtime_inventory` wajib `PASS`.

Runtime ini hanya berlaku untuk Delivery baru yang mempunyai
`reservation_id`. Dispatch partial/full mengunci order, Delivery, reservation,
Product-Warehouse dan FIFO; quantity yang sama dicatat pada allocation,
reservation, On Hand, FIFO, dan Movement. Exact retry tidak memberi efek kedua.
`DELIVERED` hanya bukti penerimaan dan tidak mengurangi stok lagi.

Delivery historis (`reservation_id IS NULL`) tetap menggunakan jalur lama dan
tidak memperoleh backfill atau stock effect kedua. ODR-3C belum membuat
Financial Event/Journal; pengakuan ekonomi Dispatch tetap ODR-5.

Setelah SQL gate PASS, jangan langsung membuka UI. Lanjutkan authenticated smoke
dengan satu order baru: Confirm → cek Reserved Out → partial Dispatch → exact
retry → full Dispatch → Delivered, lalu ulangi seluruh reconciliation postflight.
