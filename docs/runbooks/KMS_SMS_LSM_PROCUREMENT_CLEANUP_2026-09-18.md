# KMS/SMS/LSM Procurement Cleanup — 2026-09-18

## Tujuan

Membersihkan coverage Purchase lama pada KMS, SMS, dan LSM tanpa menghapus
histori dan tanpa mengubah Stock/FIFO atau Finance. Setelah cleanup, scheduler
`AUTO_RO` pukul 23:59 membaca On Hand negatif aktual tanpa dikurangi PO/Stock
Request lama. Hasil otomatis tetap RO harian; user mengonfirmasi RO menjadi PO.

## Scope yang disetujui

- mode ketiga Company tetap `AUTO_RO`;
- 52 PO `DRAFT`/`CONFIRMED` dengan net Receipt nol dibatalkan memakai runtime
  canonical;
- 95 header Stock Request `SUBMITTED`/`ORDERED` lama ditutup memakai runtime
  canonical; satu header tidak mempunyai line aktif dan tidak membawa quantity;
- Draft Goods Receipt milik PO yang dibatalkan ikut dibatalkan oleh runtime;
- PO KMS `PO-20260825-0000000015` tetap `RECEIVED` sebagai histori karena 202
  unitnya sudah diterima dan FIFO sumber sudah terpakai;
- Sales document, demand lineage, line, allocation, audit, Receipt Posted,
  Purchase Return, Bill, Payment, Stock, FIFO, Financial Event, dan Journal
  tidak dihapus atau ditulis ulang.

## Mengapa PO yang sudah diterima tidak dibatalkan

Empat FIFO source allocation untuk 202 unit sudah mempunyai sisa nol. Membuat
Purchase Return hanya agar PO bisa dibatalkan akan mencatat retur fisik palsu
dan merusak lineage biaya. PO berstatus `RECEIVED` tidak termasuk active PO
coverage resolver, sedangkan Stock Request induknya ditutup secara canonical.

## Urutan Production

1. Pastikan tidak ada user yang sedang membuat/konfirmasi PO atau menjalankan
   scheduler untuk ketiga Company.
2. Jalankan penuh
   [`purchase_three_company_full_cleanup_preflight_consolidated.sql`](../../supabase/diagnostics/purchase_three_company_full_cleanup_preflight_consolidated.sql).
   Gate Company sekarang mengharuskan `AUTO_RO`, bukan `AUTO_PO`.
3. Jika scope masih menunjukkan tepat 52 PO kosong, satu PO historis diterima,
   95 header Stock Request, tidak ada Bill/Payment, tidak ada daily RO, dan scheduler
   hari ini belum selesai, jalankan penuh
   [`cleanup_kms_sms_lsm_active_procurement_20260918.sql`](../../supabase/operations/cleanup_kms_sms_lsm_active_procurement_20260918.sql).
4. Operasi harus mengembalikan tiga baris `PASS`. Error apa pun berarti seluruh
   mutation rollback; jangan menjalankan potongan file.
5. Jalankan penuh
   [`purchase_three_company_full_cleanup_postflight.sql`](../../supabase/diagnostics/purchase_three_company_full_cleanup_postflight.sql).
6. Semua gate selain inventory `INFO` harus `PASS`.
7. Biarkan scheduler `AUTO_RO` berjalan pada cutoff berikutnya. Jangan jalankan
   generator manual bila scheduler untuk business date tersebut sudah berstatus
   `GENERATED` atau `NO_DEMAND`.

## Guard dan rollback

Operation memakai transaksi `REPEATABLE READ`, exact count/digest Production,
operation UUID deterministik, optimistic master version, audit canonical, dan
perbandingan full-row sebelum/sesudah untuk 22 snapshot data yang dilindungi. Perubahan
pada Product Stock, FIFO, Stock Movement, Purchase Return, Supplier Bill,
Supplier Payment, Financial Event, Journal, Sales, line, atau allocation membuat
seluruh transaksi gagal dan rollback.

Setelah commit, dokumen tidak dihapus. Rollback data tidak dilakukan dengan
UPDATE balik: PO/Request yang sudah final tetap menjadi histori. Jika keputusan
bisnis berubah, gunakan dokumen Purchase baru; jangan menghidupkan ulang dokumen
yang sudah `CANCELED`/`CLOSED`.

## Status verifikasi

- Preflight Production lama: tersedia dan menjadi anchor exact scope.
- Operation: `LOCAL READY`; belum dijalankan oleh agent ke Production.
- Postflight: `LOCAL READY`; menunggu hasil sesudah operation.
- Scheduler/smoke/UAT: belum dijalankan.
