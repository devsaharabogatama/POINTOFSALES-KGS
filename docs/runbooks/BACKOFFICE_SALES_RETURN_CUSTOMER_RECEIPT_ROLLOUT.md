# Backoffice Sales Return Step 2/5 — Customer Return Receipt Rollout

## Status

`DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS; AUTHENTICATED SMOKE/UAT PENDING`.

Paket ini dijalankan setelah Step 1/5 `20260917110000` PASS. Paket tidak
menjalankan deployment dan tidak menyentuh database secara otomatis.

## Dampak

- menambah Penerimaan Retur Customer terpisah dari Receipt Supplier dan Retur Retail;
- Gudang mem-post quantity aktual dan memilih `RESTOCK` atau `DESTROY` per line;
- satu Product boleh dipecah ke kedua disposition dalam receipt yang sama;
- `DESTROY` wajib catatan, tanpa foto dan tanpa approval kedua;
- `RESTOCK` menambah On Hand dan batch FIFO memakai cost Customer Receipt asal;
  `DESTROY` mengonsumsi lineage cost tetapi tidak menambah On Hand;
- Step ini tidak membuat/mengubah Invoice, Credit Note, pembayaran, refund,
  Financial Event, atau Journal.

## Urutan manual

Jalankan setiap file penuh di SQL Editor pada project target yang sama. Stop
pada SQL error, `BLOCKER`, atau `FAIL`.

Untuk instalasi baru:

1. [Preflight foundation](../../supabase/diagnostics/backoffice_sales_return_customer_receipt_preflight.sql)
2. [Migration foundation](../../supabase/migrations/20260917120000_backoffice_sales_return_customer_receipt.sql)

Untuk instalasi baru maupun database yang `20260917120000` sudah terpasang,
lanjutkan seluruh urutan berikut:

3. [Preflight immutable forward-fix](../../supabase/diagnostics/backoffice_sales_return_receipt_immutability_fix_preflight.sql)
4. [Migration immutable forward-fix](../../supabase/migrations/20260917121000_backoffice_sales_return_receipt_immutability_fix.sql)
5. [Preflight reject-only audit guard](../../supabase/diagnostics/backoffice_sales_return_receipt_audit_guard_fix_preflight.sql)
6. [Migration reject-only audit guard](../../supabase/migrations/20260917122000_backoffice_sales_return_receipt_audit_guard_fix.sql)
7. [Postflight](../../supabase/diagnostics/backoffice_sales_return_customer_receipt_postflight.sql)
8. [Behavioral rollback-only](../../supabase/tests/backoffice_sales_return_customer_receipt_behavior.sql)
9. Jalankan [Postflight](../../supabase/diagnostics/backoffice_sales_return_customer_receipt_postflight.sql) lagi.

Output `INFO` hanya inventory. Semua output non-`INFO` harus `PASS`.
Forward-fix memasang ulang guard canonical dan kelima trigger `ENABLE ALWAYS`;
behavioral assertion immutable tidak dihapus atau dilonggarkan.
Forward-fix `20260917122000` memisahkan guard finalisasi Receipt dari guard
reject-only untuk line/FIFO/operation/audit agar tidak ada conditional path
pada tabel histori tersebut.

## Behavioral coverage

- canonical SO → Dispatch → Customer menerima → Return Approved;
- split `RESTOCK` dan `DESTROY` pada satu Product;
- catatan wajib `DESTROY`, FIFO asal, dan RESTOCK-only On Hand;
- future date, stale version, cross-Company, exact retry dan immutable audit;
- zero Invoice/Financial Event/Journal effect dan seluruh fixture `ROLLBACK`.

## Authenticated smoke setelah SQL PASS

UI Step 2 belum diaktifkan pada paket ini. Dengan Warehouse Admin/Company Admin
dan Return uji `APPROVED`: post sebagian `RESTOCK`, post sebagian `DESTROY`
dengan catatan, retry operation UUID yang sama, lalu pastikan On Hand hanya naik
untuk `RESTOCK` serta Invoice/pembayaran sumber tidak berubah.

Status baru `DATABASE LIVE` setelah migration/postflight PASS, dan `SMOKE PASS`
setelah smoke authenticated selesai.

## Rollback / forward-fix

- Sebelum ada Receipt final, objek Step 2 dapat dilepas dalam transaksi
  terkontrol tanpa mengubah Step 1.
- Setelah ada Receipt final/Stock Movement, jangan drop/delete histori. Gunakan
  forward-fix dan dokumen reversal source-linked untuk koreksi Stock.
- Migration Step 1, Retur Retail, dan Receipt Supplier tidak boleh diubah.
