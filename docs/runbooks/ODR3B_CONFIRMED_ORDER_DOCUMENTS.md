# ODR-3B Confirmed Order Documents

Jalankan berurutan melalui Supabase SQL Editor:

1. `supabase/migrations/20260828130000_odr_phase3b_confirmed_order_documents.sql`
2. `supabase/tests/odr_phase3b_confirmed_order_documents_postflight.sql`
3. `supabase/tests/odr_phase3b_confirmed_order_documents_behavior.sql`
4. ulangi postflight nomor 2.

Semua check selain inventory `INFO` wajib `PASS`.

Migration ini membuat Confirm Sales Order dan snapshot Invoice/SJ menjadi satu
transaksi idempotent. Linked Delivery tidak dapat lagi di-Dispatch memakai RPC
status lama. Cancel sebelum Dispatch melepaskan reservation dan menutup SJ
`READY`. Tidak ada backfill dokumen historis dan belum ada mutation On Hand,
FIFO, Stock Movement, Payment, Financial Event, atau Journal.

Setelah gate ini PASS, lanjutkan ODR-3C atomic Dispatch. Jangan membuka tombol
Dispatch baru sebelum ODR-3C migration, behavior, postflight, dan smoke selesai.
