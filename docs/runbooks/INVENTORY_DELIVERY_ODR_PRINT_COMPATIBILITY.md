# Inventory Surat Jalan ODR Print Compatibility

## Masalah dan akar sebab

Daftar Surat Jalan Inventory sudah menampilkan dokumen dari Order ODR, tetapi
detail dan audit unduh/print masih memanggil core Sales Document lama. Core lama
memakai visibilitas role Sales/POS dan menolak `WAREHOUSE_ADMIN`, walaupun role
tersebut sah memiliki `inventory.delivery_documents VIEW`. UI kemudian hanya
menampilkan `SALES_DELIVERY_OPERATION_FAILED` pada bulk download.

## Perubahan

- detail Surat Jalan membaca immutable `sales_delivery_documents.snapshot_payload`
  dan baris delivery secara langsung dalam Company aktif;
- audit PRINT ditulis langsung oleh RPC Inventory yang sama;
- kedua RPC tetap memerlukan effective capability
  `inventory.delivery_documents VIEW`;
- tidak ada perubahan status Order/SJ, Reservation, Stock, FIFO, Payment,
  Financial Event, Journal, ataupun snapshot;
- legacy dan ODR memakai response contract yang sama.

## Urutan manual

1. Jalankan
   `supabase/diagnostics/inventory_delivery_odr_print_preflight.sql`.
   `odr_delivery_print_read_scope=BACKFILL` adalah defect runtime yang akan
   ditutup migration; hentikan bila ada `BLOCKER`.
2. Jalankan
   `supabase/migrations/20260901110000_inventory_delivery_odr_print_compatibility.sql`.
3. Jalankan
   `supabase/tests/inventory_delivery_odr_print_compatibility_behavior.sql`.
   Script memilih Admin Gudang dan linked Delivery secara data-adaptive; semua
   audit test dibatalkan oleh `ROLLBACK`.
4. Jalankan
   `supabase/tests/inventory_delivery_odr_print_compatibility_postflight.sql`.
   Semua check selain inventory harus `PASS`.
5. Deploy/restart Backoffice, hard refresh, login sebagai Admin Gudang, lalu:
   buka detail SJ ODR, unduh satu PDF, print satu dokumen, dan bulk download
   campuran SJ lama/ODR.

## Rollback / forward-fix

Migration tidak melakukan backfill data. Jangan mengembalikan wrapper ke core
Sales lama karena itu menghidupkan kembali denial bagi Admin Gudang. Jika ada
drift response, lakukan forward migration baru sambil mempertahankan guard
Inventory, tenant scope, snapshot immutable, dan append-only print audit.
