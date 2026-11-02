# POS Retail Direct Post Order-Runtime Bridge

## Tujuan dan batas

Menutup kegagalan Pickup Retail ketika finalizer canonical mengubah
`sales_headers.document_status` dari `DRAFT` menjadi `POSTED`, sementara row ODR
masih mempunyai `order_runtime_status='DRAFT_INPUT'` atau `SCHEDULED`.

Bridge hanya berlaku bila seluruh kondisi berikut benar:

- source direct `POS`, atau `BACKOFFICE_CUTOVER` yang sudah diadopsi ke sesi
  Retail nyata dan menyimpan snapshot komersial preserved;
- process dan Company mode `RETAIL_CONFIRM_INVOICE`;
- status awal Draft dengan runtime `DRAFT_INPUT` atau `SCHEDULED`;
- tidak pernah dikonfirmasi sebagai Order dan tidak mempunyai Reservation;
- finalizer sedang melakukan transisi langsung ke `POSTED`.

Backoffice Sales Order/Invoice, reserved Order, historical Posted Sale, Stock,
FIFO, Payment dan Finance composer tidak ditulis ulang oleh migration ini.
Draft cutover yang masih detached tidak dibuka oleh bridge.

## Klasifikasi state sebelum rollout

Jalankan lengkap file SELECT-only:

`supabase/diagnostics/pos_retail_direct_post_order_runtime_bridge_preflight.sql`

Lanjut hanya bila tidak ada `BLOCKER`, exact Draft check PASS, runtime boundary
PASS, dan installation state adalah `NOT_INSTALLED`. Jika state
`INSTALLED_CONSISTENT`, jangan menjalankan migration; lanjut ke behavior. Jika
`PARTIAL_INCONSISTENT`, berhenti.

## Urutan rollout wajib

1. Hentikan final checkout POS sementara. Menyimpan Draft tetap tidak membuat
   efek final.
2. Jalankan preflight SELECT-only terbaru dan simpan seluruh output. Output
   lama enam baris belum mencakup inventory compatibility cutover; versi benar
   memiliki check `pos_retail_direct_post_cutover_compatibility`.
3. Jalankan migration
   `supabase/migrations/20261030120000_pos_retail_direct_post_order_runtime_bridge.sql`
   tepat satu kali.
4. Jalankan rollback-only behavior
   `supabase/tests/pos_retail_direct_post_order_runtime_bridge_behavior.sql`.
   Test memakai exact failed Draft dan me-rollback Sale, Stock, FIFO, Payment,
   Finance event dan document effect.
5. Hanya setelah behavior PASS, jalankan SELECT-only postflight
   `supabase/diagnostics/pos_retail_direct_post_order_runtime_bridge_postflight.sql`.
6. Ulangi satu Pickup nyata dari UI authenticated. Pastikan transaksi sukses,
   receipt dan Invoice ada, Surat Jalan tidak ada, serta tidak ada duplikasi
   Stock/Payment/Event pada retry.
7. Smoke satu Delivery Retail, satu draft `BACKOFFICE_CUTOVER` yang diadopsi ke
   sesi kasir, dan satu flow Backoffice aktif terpisah sebelum UAT ditutup.

## Failure path

- Preflight blocker: jangan jalankan migration.
- Migration error: transaksi migration rollback; jangan menghapus ledger atau
  menjalankan potongan SQL. Kembalikan error lengkap untuk audit.
- Behavior error: jangan klik checkout lagi dan jangan mengubah assertion agar
  hijau. Audit ulang root cause/downstream dari output exact.
- Current Production behavior failed with
  `Movement 1 / Event 1 / Payment 1 / Invoice 1 / Delivery 1 / FIFO 0` and was
  rolled back. Do not rerun step 4. Run only
  `supabase/diagnostics/pos_retail_direct_post_behavior_mismatch_diagnosis.sql`;
  classify KGS document policy and exact FIFO/negative-stock route before a
  replacement behavior or any Product/configuration correction is authored.
- Postflight blocker: hentikan UAT dan lakukan forward fix.

## Rollback / forward-fix

Sebelum ada Sale baru yang berhasil melalui bridge, trigger dan function dapat
dilepas pada maintenance window dengan verifikasi ledger yang sesuai. Setelah
Sale baru berhasil diposting, jangan mengubah histori atau menghapus ledger;
gunakan forward migration. Menonaktifkan bridge sesudah client direct-checkout
live akan mengembalikan error constraint dan bukan rollback operasional yang
aman.

## Status

`CLIENT DEPLOYED / 20261030120000 DATABASE LIVE / BEHAVIOR FAILED ON A
DOWNSTREAM EXPECTATION / ROOT CAUSE PROVEN`. Do not rerun this migration or its
old behavior. Continue only with
`POS_RETAIL_PICKUP_DOCUMENT_BOUNDARY.md` and migration `20261030130000`.

Focused source contract lokal `3/3 PASS`. Compile staging belum terbukti karena
trusted staging CA file tidak tersedia; TLS verification tidak diturunkan.
Setelah compatibility correction, focused runtime contract dijalankan ulang
`1/1 PASS`; `git diff --check` bersih. SHA-256 migration final candidate:
`f54de9666d46f07e355350a91a47ce9a64e163ebde66cd53ce026671f4ccae37`.
