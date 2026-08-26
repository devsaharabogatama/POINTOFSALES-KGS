# Rollout Tanggal Mundur Order TEMPO dan Rencana Kirim

## Hasil yang Dibuka

- Kasir dapat memilih tanggal transaksi/order lampau hanya untuk penjualan
  `TEMPO`.
- Tanggal tersebut wajib berada pada `Accounting Period` berstatus `OPEN` atau
  `REOPENED`, tidak boleh di masa depan, dan jatuh tempo tidak boleh lebih awal.
- Rencana kirim boleh lampau, termasuk pencatatan order yang terlambat, tetapi
  tidak boleh lebih awal dari tanggal transaksi/order.
- `created_at` dan `posted_at` tetap waktu aktual sistem. `transaction_date`
  adalah tanggal efektif bisnis, tercatat bersama actor dan waktu pemilihannya.
- Financial Event `SALE_POSTED` memakai tanggal efektif. Stock Movement tetap
  memakai waktu posting aktual dan status pengiriman tidak otomatis `DELIVERED`.

## Urutan SQL

1. Jalankan
   [`pos_tempo_backdated_order_delivery_preflight.sql`](../../supabase/tests/pos_tempo_backdated_order_delivery_preflight.sql).
2. Hentikan rollout bila ada `BLOCKER`. `BACKFILL` periode berarti Company
   tersebut belum dapat memakai tanggal pada periode berjalan sampai periodenya
   dibuat/dibuka.
3. Jalankan
   [`20260826100000_pos_tempo_backdated_order_delivery.sql`](../../supabase/migrations/20260826100000_pos_tempo_backdated_order_delivery.sql).
4. Jalankan
   [`pos_tempo_backdated_order_delivery_postflight.sql`](../../supabase/tests/pos_tempo_backdated_order_delivery_postflight.sql).
   Seluruh baris harus `PASS` dan `violation_rows=0`.
5. Jalankan
   [`pos_tempo_backdated_order_delivery_behavior.sql`](../../supabase/tests/pos_tempo_backdated_order_delivery_behavior.sql).
   Hasil akhir harus memuat notice `PASS` tanpa exception.
6. Deploy PWA target, hard refresh/service-worker reload, lalu lakukan smoke test.

## Smoke Test

1. Buka sesi POS online dan pilih Customer reguler.
2. Aktifkan TEMPO, pilih tanggal kemarin pada periode terbuka, pilih jatuh tempo
   sesudahnya, simpan Draft, muat ulang Draft, dan pastikan tanggal tidak berubah.
3. Post transaksi. Pastikan Invoice menampilkan tanggal efektif, satu Financial
   Event dan satu jurnal tercipta tanpa duplikasi, serta `created_at/posted_at`
   tetap waktu aktual.
4. Ulangi dengan tanggal masa depan: harus ditolak.
5. Ulangi dengan periode `LOCKED` atau tanggal tanpa periode: harus ditolak.
6. Pilih Pengiriman dan tanggal kirim lampau sesudah tanggal order: harus lolos.
   Pilih tanggal kirim sebelum order: harus ditolak.
7. Pastikan dokumen pengiriman tetap menunggu konfirmasi gudang; pengisian
   rencana kirim tidak boleh otomatis mengubah status menjadi terkirim.
8. Regression: transaksi Cash/Transfer hari ini, Save Draft, Post, Offline, dan
   tutup sesi tetap berjalan seperti sebelumnya.

## Compatibility dan Forward-fix

- Client lama yang tidak mengirim `transactionAt` tetap memakai tanggal Draft
  server. Backdate tidak dibuka untuk Cash/Transfer atau Offline.
- Migration additive; tidak mengubah tanggal transaksi historis.
- Setelah migration dipakai untuk transaksi, jangan mencoba rollback dengan
  menghapus kolom. Forward-fix yang aman adalah menonaktifkan input PWA sambil
  mempertahankan metadata audit dan validator server.
