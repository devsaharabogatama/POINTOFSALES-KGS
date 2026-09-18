# Backoffice Sales Return Step 3/5 - Credit Note Rollout

## Status

`LOCAL READY`. Paket ini belum `DATABASE LIVE`, belum `SMOKE PASS`, dan belum
`UAT PASS` sampai seluruh gate manual di bawah dijalankan pada target database.

## Outcome

Step ini menghubungkan quantity Retur Customer yang sudah diterima Gudang ke
status penagihannya secara eksplisit:

- `UNINVOICED`: mengurangi Qty To Invoice;
- `DRAFT_INVOICE`: mengurangi baris Draft Invoice yang dipilih dan menandainya
  wajib dikonfirmasi ulang;
- `POSTED_INVOICE`: membuat satu Draft Credit Note per Invoice sumber.

Finance memilih Invoice/baris sumber. Server tidak menebak Invoice. Credit Note
posted mengurangi AR lebih dahulu; kelebihan terhadap outstanding menjadi
`CUSTOMER_REFUND_LIABILITY`. Step ini tidak membayar refund.

## Impact dan compatibility

- Direct: ledger quantity SO, Draft Invoice, schedule receivable, Credit Note,
  Financial Event, Journal, audit dan AR read-model.
- Tidak berubah: Stock/FIFO/disposition Step 2, DO/SJ, Retur Retail, Supplier
  Receipt/Return, Cashier Session dan pembayaran posted.
- Invoice posted tetap immutable. Nilai Product Credit Note berasal dari
  snapshot line Invoice sumber; ongkir default nol dan hanya dapat diisi Finance
  pada Draft dengan batas kumulatif ongkir Invoice sumber.
- Allocation tambahan ke Draft Credit Note menaikkan optimistic version; client
  yang memegang versi lama wajib memuat ulang. Quantity UOM/base memakai
  pembulatan canonical enam desimal.
- Draft Invoice pengganti tidak dibuat otomatis.
- Source allocation yang sudah disimpan bersifat append-only. Paket ini tidak
  membuka cancel/reallocation Credit Note karena policy koreksinya belum
  disetujui; jangan menghapus allocation atau histori secara manual.

## Urutan manual wajib

Jalankan setiap file secara penuh di SQL Editor, satu per satu, pada database
target yang sudah mempunyai Step 1 dan Step 2:

1. [Preflight](../../supabase/diagnostics/backoffice_sales_return_credit_note_preflight.sql)
2. [Foundation migration](../../supabase/migrations/20260917130000_backoffice_sales_return_credit_note_foundation.sql)
3. [Runtime migration](../../supabase/migrations/20260917131000_backoffice_sales_return_credit_note_runtime.sql)
4. [Behavioral test](../../supabase/tests/backoffice_sales_return_credit_note_behavior.sql)
5. [Postflight](../../supabase/diagnostics/backoffice_sales_return_credit_note_postflight.sql)

Stop segera jika ada SQL error, `BLOCKER`, atau `FAIL`. Jangan melompati file,
menjalankan selection parsial, memasukkan ledger manual, menghapus transaksi,
atau meneruskan ke Step 4.

Behavioral test adalah satu statement `DO` dengan rollback subtransaction
internal. Fixture Company mode, Customer, Stock/FIFO, SO/DO, Invoice,
pembayaran parsial, Retur, Credit Note dan Journal tidak menetap setelah test
selesai. Hasil sukses ditulis sebagai notice
`backoffice_sales_return_credit_note_behavior PASS`.

## Bukti yang wajib disimpan

- output lengkap preflight;
- sukses kedua migration dan dua versi ledger;
- notice `backoffice_sales_return_credit_note_behavior PASS` tanpa SQL error;
- seluruh postflight tanpa `BLOCKER`/`FAIL`;
- authenticated smoke: Finance membagi satu Retur ke ketiga tujuan, memeriksa
  Draft Invoice, mem-posting Credit Note, lalu memeriksa AR dan liability refund.

## Rollback dan forward-fix

- Sebelum migration: tidak ada perubahan database.
- Migration bersifat transactional dan fail-closed; error sebelum `COMMIT`
  merollback file tersebut.
- Setelah schema terpasang tetapi belum ada data operasional, masalah ditangani
  dengan migration forward-fix additive, bukan mengedit migration applied.
- Setelah Credit Note posted, jangan drop schema atau menghapus dokumen. Koreksi
  harus memakai dokumen reversal/forward-fix yang source-linked; contract
  reversal tersebut belum dibuka pada Step 3.

## Exit gate

Step 3 baru boleh disebut:

- `DATABASE LIVE` setelah kedua migration berhasil;
- `BEHAVIOR/POSTFLIGHT PASS` setelah output manual bersih;
- `SMOKE PASS` setelah authenticated flow nyata berhasil;
- `UAT PASS` hanya setelah user menyetujui hasil operasional.

Step 4 Refund Settlement baru dimulai setelah gate Step 3 tersebut selesai.
