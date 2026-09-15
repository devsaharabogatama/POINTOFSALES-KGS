# Purchase Daily Replenishment Step 5/6A — Multi-Warehouse Receipt

Status paket: **LOCAL READY**. Target hanya project Supabase Development
terisolasi `fkywtxucmyjvpwdiqpix`. Jangan jalankan pada production/staging.

## Dampak yang dikunci

- PO harian Company-level diterima melalui satu Goods Receipt terpisah untuk
  setiap Gudang tujuan; satu Receipt tidak boleh mencampur line Gudang lain.
- Receipt manual/POS/Backoffice lama tetap memakai RPC dan perilaku canonical
  lama.
- Receipt `SUPPLIER_PENDING` memakai `products.cogs` sebagai biaya provisional
  default, boleh dioverride sebelum Post, dan biaya nol memerlukan konfirmasi
  eksplisit.
- Post pending Supplier menambah Stock/FIFO hanya untuk kondisi GOOD/DAMAGED,
  membuat Stock Movement, clearing append-only, dan Financial Event
  `HOLD_FOR_SUPPLIER_ASSIGNMENT`. Event ini dikeluarkan dari Purchase/AP queue.
- Penetapan Supplier wajib mencakup seluruh line Receipt, append-only per line,
  idempotent, dan menghasilkan event reklasifikasi HOLD untuk Step 6. Receipt
  posted tidak diubah.
- Tidak ada Supplier Bill, Payment, jurnal clearing, scheduler, atau UI baru
  dalam paket ini. Reklasifikasi clearing → AP provisional diselesaikan Step 6.
- Kelanjutan blocker sebagai PO supplemental yang telah disetujui user adalah
  Step 5/6B terpisah agar migration Receipt ini tidak mencampur mutation PO.

## Urutan manual

Jalankan file penuh, bukan selected text:

1. [Preflight](../../supabase/diagnostics/purchase_daily_multiwarehouse_receipt_preflight.sql)
2. [Migration](../../supabase/migrations/20260914100000_purchase_daily_multiwarehouse_receipt.sql)
3. [Behavioral test](../../supabase/tests/purchase_daily_multiwarehouse_receipt_behavior.sql)
4. [Postflight](../../supabase/diagnostics/purchase_daily_multiwarehouse_receipt_postflight.sql)

Preflight harus tidak memiliki `BLOCKER`. Behavioral harus selesai dengan
`TEST_PASS`; seluruh fixture dibungkus `BEGIN/ROLLBACK`. Postflight harus seluruh
`PASS/INFO`.

## Smoke setelah SQL PASS

Authenticated UI belum dibuka pada Step 5A. Smoke database dilakukan behavioral
test yang mencakup dua Gudang, penolakan mixed-Warehouse, biaya COGS dan override,
Stock/FIFO, clearing, queue exclusion, assignment per line, exact retry, serta
verifikasi Receipt posted tidak ditulis ulang.

## Rollback / forward-fix

Migration ini additive tetapi telah menambah history dan account catalog.
Setelah dipakai, jangan drop tabel/kolom dan jangan edit migration. Koreksi harus
forward-only dengan version baru. Sebelum migration, transaksi otomatis dapat
dihentikan dengan mengembalikan mode Company ke `MANUAL`; setelah ada Receipt
posted, data harus dipertahankan.
