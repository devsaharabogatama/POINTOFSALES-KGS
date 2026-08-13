# G6 Phase 8A — Sale dan Sales Return Posting Preflight

**Status:** SELECT-only ready  
**Mutation:** tidak ada

Jalankan seluruh
`supabase/diagnostics/g6_phase8a_sale_return_posting_preflight.sql` dan kirim
semua row. `BLOCKER` wajib nol. `BACKFILL` berarti conditional account function
belum mempunyai tepat satu mapping eksplisit. `sale_return_posting_runtime`
tetap `SETUP` sampai migration berikutnya.

Preflight memverifikasi ulang source terhadap immutable Event untuk total Sale,
pembayaran, pajak, FIFO/HPP, ongkir, rounding, surcharge, Return, refund, dan
restorasi FIFO. Ia juga memastikan setiap leg Cash/Bank/Clearing/Customer
Balance serta akun kondisional memiliki resolver yang tidak ambigu.
