# Retained Credit Note AR Split Fix Impact — 2026-09-19

## Problem yang dibuktikan

Credit Note retained Retail `CN-20260919-0000000012` senilai Rp78.400 tersimpan
sebagai Refund Liability Rp78.400 dan pengurang piutang Rp0. Invoice sumber
`INV-20260904-0000000236` tetap mempunyai piutang efektif pengiriman, sehingga
Penerimaan Customer masih menawarkan Rp5.428.520 alih-alih Rp5.350.120.

Root cause berada pada `private.post_retained_retail_credit_note_core`: pembagian
AR/refund membaca `sales_headers.sisa_piutang` legacy. Consumer Penerimaan
Customer membaca piutang efektif dari efek pengiriman.

## Impact map

- Direct: runtime posting Credit Note retained Retail dan satu Credit Note exact
  yang sudah salah klasifikasi.
- Tabel berubah: `backoffice_sales_credit_notes`, `backoffice_sales_returns`,
  serta satu Journal koreksi dan dua baris Journal baru.
- Finance: Refund salah yang sudah POSTED dibalik dengan dokumen Reversal dan
  Journal reversal source-linked; tidak dihapus. Journal koreksi append-only
  kemudian mendebit Customer Refund Liability dan mengkredit Customer
  Receivable Rp78.400. Seluruh Journal lama tidak diubah.
- Customer Receipt: otomatis membaca `ar_reduction_amount` yang benar melalui
  runtime alignment yang sudah terpasang.
- Tidak berubah: Stock, FIFO, Retail Sale/Invoice/lines, pembayaran historis,
  original Credit Note Journal, POS, Cashier Session, dan native Backoffice
  Credit Note path.

## Compatibility dan risiko

- Credit Note retained Retail berikutnya memakai receivable efektif pada tanggal
  Credit Note, tetap dikurangi Receipt dan prior Credit Note, serta tetap dibatasi
  nilai komersial Invoice.
- Migration mengunci source, bersifat transactional, menolak runtime drift,
  active Finance queue, Refund history, dan exact-data drift.
- Retry migration ditolak oleh ledger; Journal koreksi memakai idempotency key
  unik.
- Kondisi yang belum dapat dibuktikan secara lokal adalah state Production saat
  eksekusi. Karena itu preflight, behavior rollback-only, dan postflight wajib
  dijalankan manual berurutan.

## Status

LOCAL READY. DATABASE LIVE, authenticated smoke, dan UAT belum dinyatakan sampai
output manual Production diterima.
