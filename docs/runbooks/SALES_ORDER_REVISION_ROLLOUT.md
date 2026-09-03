# Rollout Revisi Sales Order

Source of truth: [`../SALES_ORDER_REVISION_SPEC.md`](../SALES_ORDER_REVISION_SPEC.md).

Status saat file dibuat: local-ready. Database staging/production belum diubah
oleh agent dan fitur belum boleh dipakai sebelum seluruh gate berikut selesai.

## Urutan SQL

Jalankan di Supabase SQL Editor pada project target, satu file per eksekusi:

1. `supabase/diagnostics/sales_order_revision_preflight.sql`
2. `supabase/migrations/20260903100000_sales_order_revision_foundation.sql`
3. `supabase/migrations/20260903110000_sales_order_revision_runtime.sql`
4. `supabase/tests/sales_order_revision_contract_test.sql`
5. `supabase/diagnostics/sales_order_revision_postflight.sql`

Runtime eligibility UI juga berasal dari server melalui
`get_pos_sales_order_revision_eligibility`; tombol revisi tidak ditampilkan
untuk Order yang sudah mulai dikirim, sudah memiliki pembayaran VERIFIED, atau
sudah mempunyai Draft revisi aktif.

Hentikan pada SQL error, `BLOCKER`, atau `FAIL`. `SETUP` pada preflight hanya
berarti foundation belum dipasang. Jangan menjalankan ulang migration yang sudah
tercatat pada ledger; gunakan postflight untuk memeriksa hasilnya.

## Deploy client

Database harus lulus lebih dahulu. Setelah itu deploy PWA dan Backoffice dari
commit yang sama. Hard refresh kedua aplikasi agar bundle lama tidak tertahan
service worker/cache.

## Authenticated smoke wajib

Gunakan Company uji, satu Kasir dengan sesi `OPEN`, satu Order yang baru
dikonfirmasi, dan jangan memakai Order operasional aktif.

1. Pastikan Order belum Dispatch dan payment belum `VERIFIED`.
2. Buka **Order aktif**, cari Order, tekan **Revisi Order**, isi alasan.
3. Pastikan Draft pengganti langsung terbuka dan harga dihitung ulang.
4. Tutup editor tanpa konfirmasi; pastikan source masih aktif, Reserved Out dan
   Invoice/SJ source tidak berubah.
5. Buka kembali Draft revisi, ubah satu quantity, isi ulang payment, lalu
   konfirmasi.
6. Pastikan source menjadi canceled, Reserved Out source dilepas, Invoice/SJ
   source bertanda dibatalkan, replacement aktif dengan nomor Invoice/SJ baru,
   dan Reserved Out replacement sesuai quantity baru.
7. Buka Backoffice Invoice source dan replacement; pastikan linkage
   **Direvisi menjadi** / **Revisi dari** tampil.
8. Ulangi request confirm yang sama hanya pada pengujian API terkontrol; hasil
   harus replay dan tidak menambah Reservation, Invoice, SJ, payment request,
   atau audit ganda.
9. Buat revisi kedua lalu batalkan Draft revisinya. Source harus tetap aktif dan
   revision berstatus `ABANDONED`.
10. Negative test: Order yang sudah partial Dispatch dan Order dengan payment
    `VERIFIED` tidak boleh menawarkan/menjalankan revisi.

Setelah smoke, jalankan kembali postflight. Seluruh baris harus `PASS`/`INFO`.

## Forward-fix idempotency konfirmasi revisi

Authenticated UAT pertama menemukan `IDEMPOTENCY_PAYLOAD_CONFLICT` ketika
source dan replacement masih berada dalam demand scope sesi yang sama. Runtime
awal memakai satu operation UUID untuk dua aggregate mutation: cancel source
dan confirm replacement. Jalankan forward-fix berikut; jangan mengulang
migration `20260903110000`:

1. `supabase/diagnostics/sales_order_revision_idempotency_preflight.sql`
2. `supabase/migrations/20260903120000_sales_order_revision_idempotency_namespace_fix.sql`
3. `supabase/tests/sales_order_revision_idempotency_contract_test.sql`
4. `supabase/diagnostics/sales_order_revision_idempotency_postflight.sql`

`SETUP` pada check namespace preflight adalah expected sebelum migration.
Hentikan pada `BLOCKER`, SQL error, atau `FAIL`. Sesudah seluruh hasil bersih,
buka ulang Draft revisi yang sama dan tekan **Konfirmasi Order**; tidak perlu
membuat ulang Draft karena attempt yang gagal telah rollback atomik.

## Compatibility dan rollback operasional

- Order biasa yang bukan revision tetap memakai Confirm/Cancel runtime lama.
- Draft revision tidak mengubah Stock, FIFO, Movement, Finance, Reservation,
  Invoice, SJ, payment request, atau Purchasing source.
- Jangan rollback schema setelah revision dipakai. Jika masalah ditemukan,
  rollback operasional adalah kembali ke bundle client sebelumnya dan hentikan
  tombol Revisi; data lineage/audit tetap dipertahankan untuk forward-fix.
