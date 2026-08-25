# Rollout Override Harga per Terminal POS

Status: **local-ready; database rollout dan authenticated smoke belum dilakukan**

## Kontrak

- Default setiap Terminal adalah **nonaktif**.
- Harga awal tetap berasal dari resolver Pricelist canonical.
- Jika kebijakan Terminal aktif, kasir dengan sesi aktif dapat mengisi harga
  final per baris. Nilai itu tidak mengubah master Product-UOM/Pricelist.
- Server memvalidasi ulang Company, Store, Terminal, sesi aktif, actor, channel
  Online, dan nilai harga pada Save Draft maupun Post.
- Offline tidak menerima override harga.
- Line menyimpan harga canonical dan harga final beserta actor, Terminal, sesi,
  source, dan waktu resolve.

## Urutan manual Supabase

1. Jalankan [`pos_terminal_price_override_preflight.sql`](../../supabase/tests/pos_terminal_price_override_preflight.sql).
2. Berhenti jika ada `BLOCKER`.
3. Jalankan [`20260825120000_pos_terminal_price_override.sql`](../../supabase/migrations/20260825120000_pos_terminal_price_override.sql).
4. Jalankan [`pos_terminal_price_override_postflight.sql`](../../supabase/tests/pos_terminal_price_override_postflight.sql).
5. Berhenti jika ada `FAIL`.
6. Jalankan [`pos_terminal_price_override_behavior.sql`](../../supabase/tests/pos_terminal_price_override_behavior.sql).
7. Ulangi postflight dan pastikan tetap tanpa `FAIL`.
8. Deploy Backoffice dan PWA ke **staging** setelah database staging lulus.

## Smoke terautentikasi

Gunakan dua Terminal pada Company yang sama jika tersedia.

1. Terminal A: override harga OFF. Buka sesi, masukkan Product, pastikan kontrol
   ubah harga tidak tampil. Payload yang disisipi `overrideUnitPrice` harus
   ditolak `POS_TERMINAL_PRICE_OVERRIDE_DISABLED`.
2. Terminal B: aktifkan override harga dari Platform > Pengaturan POS. Buka
   sesi, pilih Customer/Pricelist, ubah satu harga, simpan Draft, lalu buka
   kembali Draft. Harga canonical dan label **Harga diubah** harus tetap ada.
3. Post transaksi Terminal B. Invoice, pembayaran, pajak, stok/FIFO/HPP, event,
   jurnal, dan total penjualan harus memakai harga final.
4. Matikan kebijakan Terminal B sebelum mencoba Post Draft lain yang masih
   mengandung override. Post harus ditolak.
5. Matikan koneksi. Kontrol override tidak tampil; payload Offline dengan
   override harus ditolak.
6. Ulangi Post dengan idempotency key yang sama. Tidak boleh timbul Sale,
   payment, stock movement, financial event, atau journal ganda.

## Forward-fix / rollback operasional

Migration bersifat additive dan tidak menghapus histori. Jika runtime bermasalah:

1. nonaktifkan `allow_price_override` pada semua Terminal melalui Backoffice;
2. pertahankan kolom snapshot dan function compatibility wrapper;
3. jangan menghapus Sale yang sudah Posted;
4. lakukan forward-fix pada wrapper resolver/reprice, lalu ulangi postflight dan
   smoke. Schema tidak di-drop karena snapshot mungkin sudah direferensikan
   histori final.
