# POS Scheduled TEMPO Order Rollout

## Tujuan

Menyimpan order TEMPO untuk tanggal mendatang tanpa menciptakan efek stok,
pembayaran, piutang, Financial Event, atau jurnal sebelum kasir melakukan Post.

## Urutan manual

1. Jalankan `supabase/tests/pos_scheduled_order_preflight.sql`.
2. Pastikan tidak ada `BLOCKER`.
3. Jalankan `supabase/migrations/20260827154000_pos_scheduled_tempo_order.sql`.
4. Jalankan `supabase/tests/pos_scheduled_order_postflight.sql`.
5. Jalankan `supabase/tests/pos_scheduled_order_behavior.sql`.
6. Deploy PWA setelah migration dan test SQL lulus.

## Smoke test

1. Buka sesi kasir dan pilih transaksi TEMPO.
2. Pilih tanggal order besok, jatuh tempo setelah tanggal order, lalu Simpan Draft.
3. Pastikan Draft tampil sebagai `Terjadwal` dan tombol Post ditolak sebelum tanggalnya.
4. Pastikan stok, pembayaran, piutang, Invoice, Surat Jalan, Financial Event, dan jurnal belum berubah.
5. Ubah tanggal Company/test menjadi tanggal rencana atau buat order dengan tanggal hari ini.
6. Muat ulang daftar Draft: order harus tampil sebagai `Order aktif` tanpa proses background.
7. Buka dari sesi kasir baru pada Store yang sama, hitung ulang harga, lalu Post.
8. Pastikan tanggal transaksi Finance adalah tanggal Post aktual, sedangkan tanggal rencana tetap tersimpan.
9. Pastikan rencana kirim dan jatuh tempo yang lebih awal dari tanggal rencana ditolak.
10. Pastikan Draft dari Store lain tetap tidak dapat dibuka.

## Compatibility dan forward-fix

- Draft lama dibaca sebagai `IMMEDIATE`.
- Order terjadwal hanya tersedia Online dan TEMPO.
- Aktivasi bersifat hasil query berdasarkan tanggal bisnis Company; tidak ada cron.
- Tidak ada rollback destruktif. Jika UI perlu ditarik, biarkan kolom dan runtime additive
  tetap tersedia, lalu lakukan forward-fix pada client.
