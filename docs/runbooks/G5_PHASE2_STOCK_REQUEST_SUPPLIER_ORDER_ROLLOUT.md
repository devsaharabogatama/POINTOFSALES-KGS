# G5 Phase 2 — Stock Request + Supplier Order Rollout

Status repository: local-ready, menunggu rollout manual Supabase.

## Tujuan

Membuka alur awal Purchasing tanpa mengubah stok atau Finance:

1. kasir membuat dan submit Stock Request dari sesi kasir aktif;
2. Store Manager/Company Admin/Super Admin membuat Supplier Order;
3. satu Order dapat mengalokasikan satu atau beberapa baris Request;
4. konfirmasi Order terkunci, versioned, idempotent, dan audited;
5. penerimaan barang, FIFO, AP, dan jurnal tetap belum dibuka pada fase ini.

Warehouse Admin dan Cashier tidak memperoleh kewenangan memilih Supplier atau
mengonfirmasi Supplier Order. Cashier hanya membuat kebutuhan Stock Request.

## Urutan rollout

Jalankan seluruh file berikut di Supabase SQL Editor, satu per satu:

1. `supabase/migrations/20260806010000_g5_phase2_stock_request_supplier_order_foundation.sql`
2. `supabase/diagnostics/g5_phase2_stock_request_supplier_order_postflight.sql`
3. `supabase/tests/g5_phase2_stock_request_supplier_order_tests.sql`

Expected:

- migration sukses satu kali;
- seluruh baris postflight berstatus `PASS` atau `INFO`, tanpa `FAIL`;
- behavioral test menampilkan notice `TEST PASSED`;
- behavioral test selalu `ROLLBACK` dan tidak menyisakan fixture.

Jika migration gagal, transaksi utuh di-rollback. Jangan mengedit schema manual;
kirim error lengkap agar dibuat forward-fix yang deterministik.

## Kontrak compatibility

- tabel legacy Purchase belum dipakai sebagai runtime baru;
- `confirm_purchase_order(UUID,UUID)` legacy dicabut dari browser bila masih ada;
- tidak ada write ke `product_stocks`, `product_batches`, `stock_movements`,
  `financial_events`, atau `journal_entries`;
- Goods Receipt baru dibuka sesudah Request/Order foundation dan UI-nya lolos.

## Next safe step

Setelah migration, postflight, dan behavioral test lulus: implementasikan UI Stock
Request di PWA dan UI Supplier Order di modul Purchase Backoffice. Jangan membuka
Goods Receipt sebelum kedua jalur UI tersebut tervalidasi.
