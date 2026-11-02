# POS Retail Pickup Document Boundary

## Tujuan

Migration `20261030130000` membuat consumer policy dokumen process-aware:

- direct `POS + RETAIL_CONFIRM_INVOICE + PICKUP` tetap membuat Invoice tetapi
  tidak membuat Delivery Document/Surat Jalan baru;
- Retail Delivery, Backoffice, adopted cutover, existing Delivery Document dan
  histori tetap memakai behavior sebelumnya;
- Stock, FIFO, negative-stock allocation, Payment, Finance dan cashier session
  tidak diubah.

## Urutan wajib

1. Jangan menjalankan ulang migration `20261030120000` atau behavior lama.
2. Jalankan lengkap SELECT-only
   `supabase/diagnostics/pos_retail_pickup_document_boundary_preflight.sql`.
3. Lanjut hanya bila seluruh contract `PASS`, exact conflict `ROOT_CAUSE` dengan
   `violation_rows=0`, state `NOT_INSTALLED`, dan runtime boundary kosong.
4. Jalankan migration
   `supabase/migrations/20261030130000_pos_retail_pickup_document_boundary.sql`
   tepat satu kali.
5. Jalankan rollback-only
   `supabase/tests/pos_retail_pickup_document_boundary_behavior.sql`.
6. Hanya setelah behavior PASS, jalankan SELECT-only
   `supabase/diagnostics/pos_retail_pickup_document_boundary_postflight.sql`.
7. Setelah semua database gate PASS, lakukan authenticated smoke satu Pickup,
   satu Delivery, retry Pickup yang sama, dan satu flow Backoffice.

## Expected behavior

- Exact Pickup: Posted + `LEGACY_POSTED`, Invoice satu, Delivery nol.
- Bawang Bombay dengan Stock negatif: kebutuhan stok ditutup oleh
  `negative_stock_sale_allocations`; FIFO positif boleh nol.
- Exact retry: tidak menambah Movement, Event, Payment, Invoice, FIFO,
  authorization, atau negative allocation.
- Semua efek behavior test di-rollback.

## Failure dan forward fix

- Preflight `BLOCKER`: jangan jalankan migration.
- Migration error: jangan jalankan potongan file, jangan menghapus ledger, dan
  jangan mengulang migration lama.
- Behavior error: hentikan postflight dan POS smoke; audit seluruh downstream.
- Setelah migration live, koreksi berikutnya wajib migration forward baru.
  Jangan menghapus Delivery Document historis atau menulis ulang Sale Posted.

## Status

`PRODUCTION PREFLIGHT PASS / DATABASE LIVE / BEHAVIOR PASS / POSTFLIGHT PASS /
AUTHENTICATED SMOKE AND UAT PENDING`. Migration, behavior and postflight must
not be rerun.
