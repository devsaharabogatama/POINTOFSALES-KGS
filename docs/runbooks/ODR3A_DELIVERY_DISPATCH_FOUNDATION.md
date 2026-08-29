# ODR-3A Delivery Dispatch Foundation

Jalankan berurutan melalui Supabase SQL Editor pada database target:

1. `supabase/migrations/20260828120000_odr_phase3a_delivery_dispatch_foundation.sql`
2. `supabase/tests/odr_phase3a_delivery_dispatch_foundation_postflight.sql`
3. `supabase/tests/odr_phase3a_delivery_dispatch_foundation_behavior.sql`
4. ulangi `supabase/tests/odr_phase3a_delivery_dispatch_foundation_postflight.sql`

Gate lulus bila seluruh check selain inventory `INFO` berstatus `PASS`.

Migration ini additive. Ia menambah linkage Delivery–Reservation, lifecycle
`PARTIALLY_DISPATCHED`, dan ledger allocation immutable. Migration ini belum
membuat Invoice/SJ baru dan belum mengubah On Hand, FIFO, Stock Movement, Sale,
Payment, Financial Event, Journal, maupun dokumen historis.

Rollback operasional tidak menghapus schema. Bila runtime berikutnya belum
diterapkan, biarkan schema additive ini tidak terpakai dan lakukan forward-fix.
