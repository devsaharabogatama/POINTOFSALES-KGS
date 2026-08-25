# POS TEMPO Transaction Date Rollout

## Outcome

Checkout TEMPO menampilkan tanggal transaksi/order yang ditetapkan server dan
tanggal jatuh tempo. Ketika Customer memiliki default tenor, PWA menyarankan
jatuh tempo dari tanggal transaksi ditambah tenor; kasir tetap dapat mengganti
tanggal jatuh tempo sebelum posting.

## Urutan rollout

1. Jalankan
   [`20260825110000_pos_tempo_transaction_date.sql`](../../supabase/migrations/20260825110000_pos_tempo_transaction_date.sql).
2. Jalankan
   [`pos_tempo_transaction_date_postflight.sql`](../../supabase/tests/pos_tempo_transaction_date_postflight.sql)
   dan pastikan seluruh baris `PASS`.
3. Pastikan ada sesi Cashier `OPEN`, lalu jalankan
   [`pos_tempo_transaction_date_behavior.sql`](../../supabase/tests/pos_tempo_transaction_date_behavior.sql).
4. Deploy PWA ke environment database yang sama.

## Smoke manual

1. Buka sesi POS online dan pilih Customer reguler yang mempunyai tenor kredit.
2. Aktifkan **Transaksi TEMPO**.
3. Pastikan tanggal transaksi tampil read-only dan jatuh tempo otomatis mengikuti
   tenor Customer.
4. Ganti jatuh tempo secara manual, simpan Draft, buka ulang Draft, dan pastikan
   tanggal transaksi lama serta jatuh tempo pilihan kasir tetap sama.
5. Post transaksi dan periksa Invoice/record Sale memakai tanggal transaksi dan
   jatuh tempo yang sama.
6. Pastikan Customer Walk-In tetap ditolak oleh kontrak TEMPO server.

## Compatibility

- Kolom database dan payload request tidak berubah.
- Response RPC hanya memperoleh field tambahan; client lama tetap kompatibel.
- Pembacaan tanggal setelah Save memakai wrapper `SECURITY DEFINER` dengan
  `search_path` tetap dan filter active Company; execute tetap hanya untuk
  `authenticated`/`service_role`, sedangkan core Save mengulang otorisasi.
- Save/Post tetap menetapkan serta memvalidasi transaksi di server.
- Offline TEMPO tetap tertutup.
