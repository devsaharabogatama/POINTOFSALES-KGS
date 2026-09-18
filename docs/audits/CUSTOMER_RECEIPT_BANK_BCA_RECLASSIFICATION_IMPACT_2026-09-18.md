# Customer Receipt BANK BCA Reclassification Impact

## Outcome

Seluruh Customer Receipt `DIRECT_BANK` milik KMS, SMS, dan LSM memakai exact
mapping `SALE_PAYMENT / BANK -> BANK BCA`. Receipt lama yang sudah mempunyai
jurnal ke akun `1130 Bank` dikoreksi dengan jurnal reklasifikasi append-only.

## Bukti akar masalah

- Ketiga Company sudah mempunyai akun aktif/postable `1010100-1 BANK BCA`.
- Rule baru sudah benar kategori dan fungsi, tetapi `effective_from` tersimpan
  tujuh jam setelah waktu pembuatan. Nilai lokal `datetime-local` dikirim tanpa
  offset lalu diparse server sebagai UTC.
- Resolver masih memilih fallback `1130 Bank` sebelum waktu efektif tersebut.

## Impact map

- Direct: Finance Master mapping `SALE_PAYMENT/BANK`, Customer Receipt jalur
  `DIRECT_BANK`, dan canonical Finance Journal.
- Downstream: saldo GL akun Bank lama dikredit dan BANK BCA didebit dengan nilai
  yang sama per Receipt; Trial Balance tetap balance.
- Tidak berubah: nominal/allocations/status Receipt, AR, Invoice, Payment Method,
  Cash Receipt, POS/Cashier Session, Stock/FIFO, Purchase, dan supplier payment.
- Compatibility: jurnal sumber tetap POSTED dan immutable. Koreksi baru memakai
  `source_type=CUSTOMER_RECEIPT_BANK_RECLASSIFICATION` dan `source_id=Receipt`.
- Concurrency/idempotency: advisory lock per Company, migration ledger, unique
  journal idempotency key, serta preflight active Finance queue.
- Rollback: jurnal POSTED tidak boleh dihapus. Kesalahan rollout dikoreksi dengan
  reversal source-linked pada periode terbuka.

## Batas yang belum dibuktikan lokal

Nilai kandidat Production, kelengkapan periode, dan hasil posting aktual hanya
dapat dibuktikan ketika preflight/migration/test/postflight dijalankan user pada
database target. Zero candidate bukan bukti behavior reklasifikasi.
