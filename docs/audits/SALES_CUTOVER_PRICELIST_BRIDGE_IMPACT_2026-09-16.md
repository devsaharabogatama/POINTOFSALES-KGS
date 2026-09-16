# Sales Cutover Pricelist Bridge Impact — 2026-09-16

## Outcome

Memperbaiki kegagalan Apply Retail → Office `BACKOFFICE_SALES_PRICELIST_MIXED`
tanpa menghitung ulang atau mengganti fakta komersial dokumen sumber.

## Root cause

Converter sudah membuktikan bahwa seluruh line Retail mempunyai paling banyak
satu `pricelist_id`, tetapi payload sementara ke Save Draft selalu mengirim
`selectedPricelistId = NULL`. Resolver AUTO Backoffice lalu dapat memilih
Pricelist berbeda per Product dan menolak Draft sementara sebagai mixed sebelum
converter mengembalikan snapshot Retail.

## Impact map

- Direct: satu private converter Retail → Office dan ledger migration.
- Data akhir: header target tetap memakai Pricelist sumber; setiap line tetap
  memakai harga, diskon, pajak, rule dan snapshot Retail sumber.
- Bridge memilih Pricelist sumber bila masih eligible; jika tidak, satu
  Customer/Global eligible hanya dipakai untuk validasi Draft sementara.
- Tidak berubah: classifier/preview/plan, mode Company, source retirement,
  procurement lineage, Reservation, Dispatch, Stock/FIFO, Payment, Cashier
  Session dan Finance.
- Compatibility: Pricelist historis/nonaktif tetap dipertahankan pada hasil.
- Concurrency/idempotency: lock, operation UUID dan transaction boundary
  existing tidak diubah. Apply gagal tetap rollback atomik.

## Risiko dan kontrol

Migration memeriksa anchor runtime dan fix procurement NULL yang sudah terpasang.
Behavioral membandingkan total, header Pricelist dan snapshot line sumber-target,
serta regression Draft/Scheduled/Reserved/retry/zero Stock-Finance effect.

## Rollback / forward-fix

Tidak ada row backfill. Setelah conversion baru commit, jangan downgrade fungsi.
Jika postflight/smoke gagal, hentikan Apply baru, pertahankan histori dan lakukan
forward-fix guarded dari definisi runtime aktual.
