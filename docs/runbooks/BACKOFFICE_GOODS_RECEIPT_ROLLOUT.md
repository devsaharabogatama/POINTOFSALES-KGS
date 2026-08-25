# Rollout Penerimaan Barang Backoffice

Fitur ini menambah channel Penerimaan Barang melalui Backoffice untuk Owner,
Company Admin, dan Warehouse Admin. PWA Kasir tetap tersedia dan tidak berubah.
Kedua channel memakai fungsi Post canonical yang sama untuk Stock, FIFO, AP
provisional, Financial Event, Supplier Order, idempotency, dan audit.

## Urutan SQL

1. Jalankan [`backoffice_goods_receipt_preflight.sql`](../../supabase/tests/backoffice_goods_receipt_preflight.sql). Jangan lanjut jika ada `BLOCKER`.
2. Jalankan [`20260825130000_backoffice_goods_receipt_channel.sql`](../../supabase/migrations/20260825130000_backoffice_goods_receipt_channel.sql).
3. Jalankan [`20260825131000_backoffice_goods_receipt_workspace_line_no_fix.sql`](../../supabase/migrations/20260825131000_backoffice_goods_receipt_workspace_line_no_fix.sql). Fresh database tetap menjalankannya sebagai ledger forward-fix no-loss.
4. Jalankan [`backoffice_goods_receipt_postflight.sql`](../../supabase/tests/backoffice_goods_receipt_postflight.sql). Seluruh baris wajib `PASS` atau `INFO`.
5. Jalankan [`backoffice_goods_receipt_behavior.sql`](../../supabase/tests/backoffice_goods_receipt_behavior.sql). Test membuat fixture synthetic sendiri dan selalu `ROLLBACK`.

## Smoke Backoffice

1. Login sebagai Warehouse Admin pada Company yang benar.
2. Buka **Purchase → Penerimaan Barang**.
3. Pilih Supplier Order, isi jumlah dan kondisi, lalu **Simpan Draft**.
4. Muat ulang dan lanjutkan Draft; pastikan isi tetap sama.
5. Klik **Post & Tambah Stok** satu kali. Pastikan PO menjadi partial/received,
   Stock/FIFO bertambah sekali, AP provisional dan Financial Event terbentuk.
6. Pastikan Warehouse Admin tanpa permission atau Company aktif yang berbeda
   tidak dapat membuka menu/API.

## Forward-fix

Jika rollout gagal, jangan menghapus dokumen atau histori. Hentikan sebelum
deploy UI dan buat migration forward-fix. Kolom channel bersifat additive;
histori lama dibackfill `POS` dan tetap mempunyai Session/Terminal asal.
