# G5 Phase 7 Purchase Return Preflight

Status: SELECT-only diagnostic; belum membuka schema atau mutation Return.

## Tujuan

Memastikan Goods Receipt yang sudah `POSTED` dapat menjadi source Purchase
Return tanpa mengubah receipt historis, menggandakan stock/AP, atau mengembalikan
quantity yang sudah tidak tersedia pada FIFO/Gudang.

## Menjalankan

Jalankan seluruh isi:

`supabase/diagnostics/g5_phase7_purchase_return_preflight.sql`

Diagnostic tidak membuat tabel, function, temp table, atau data bisnis.

## Interpretasi

- `BLOCKER`: hentikan dan kirim seluruh output;
- `REVIEW`: kirim output untuk menentukan compatibility/backfill;
- `SETUP`: expected karena schema/RPC Purchase Return belum dibuat;
- `PASS`: invariant siap;
- `INFO`: inventory scope untuk desain migration/test berikutnya.

Expected sebelum foundation:

- `canonical_purchase_return_schema_state = SETUP`;
- `canonical_purchase_return_routine_state = SETUP`.

Seluruh baris lain harus `PASS` atau `INFO`. `non_open_goods_receipt_ap_source`
dapat `REVIEW` hanya bila ada proses matching lain yang sudah mengubah AP
provisional; jangan meneruskan otomatis bila itu muncul.

## Boundary

- Draft dibuat Kasir di PWA tanpa Stock/AP effect;
- review/post dilakukan Store Manager atau Company Admin/Super Admin di
  Backoffice saat barang benar-benar diserahkan;
- return hanya berasal dari receipt line accepted;
- invoice final/paid tidak ditulis ulang dan menunggu Credit Note/refund G6.
