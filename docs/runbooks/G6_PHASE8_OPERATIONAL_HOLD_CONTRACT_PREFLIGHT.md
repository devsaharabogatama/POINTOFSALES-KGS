# G6 Phase 8 — Operational HOLD Contract Preflight

**Status:** SELECT-only preflight ready  
**Scope:** sembilan kontrak operasional Finance yang masih `HOLD`  
**Mutation:** tidak ada

## Tujuan

Preflight ini membuktikan data live cukup untuk memperluas posting engine G6
dari `STOCK_OPENING` ke Sale, Sales Return, Goods Receipt, Supplier Invoice,
Supplier Payment, Expense Disbursement, Cash Deposit, Deposit Variance, dan
Stock Gain. Ia tidak membuat mapping, jurnal, queue, atau mengubah Event.

## Alasan wajib dijalankan lebih dulu

Sale dapat mempunyai split payment, TEMPO, Customer Balance, Cash, Transfer,
QRIS/Card, surcharge, pajak, rounding, dan ongkir. Engine tidak boleh menebak
akun lawan atau meratakan semua penerimaan ke Kas. Kontrak Purchase dan Cash
juga membawa snapshot akun yang berbeda. Satu migration generik tanpa audit
live dapat menghasilkan jurnal balanced tetapi salah akun.

## Langkah

1. Jalankan seluruh
   `supabase/diagnostics/g6_phase8_operational_hold_contracts_preflight.sql`.
2. Kirim semua row output tanpa dipotong.
3. Jangan preview/process Finance queue sebelum output direview.
4. `BLOCKER` harus nol. `BACKFILL` hanya boleh diselesaikan dengan mapping
   eksplisit dan compatible; jangan mengisi akun berdasarkan tebakan kode/nama.
5. `canonical_operational_posting_runtime=SETUP` dan rekonsiliasi
   FIFO–GL `DEFERRED` adalah expected pada preflight ini.

## Setelah output bersih

Implementasi dibuka per kelompok: Sale/Return, Purchase/AP, lalu Expense/Cash/
Inventory Gain. Setiap kelompok wajib memiliki migration, postflight,
rollback-safe behavior, idempotent replay, locked/prior-period test, dan
controlled single live Event sebelum historical batch.
