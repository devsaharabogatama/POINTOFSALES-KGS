# KGS POS PWA

Status saat ini: **online POS + Sale Draft edit-lock + Split Payment** untuk G4.
Daftar Draft per Store, heartbeat, takeover, force release, cancel, server
repricing, dan multi-metode exact-total sudah local-ready. Offline queue belum
diaktifkan.

## Menjalankan lokal

1. salin `.env.example` menjadi `.env`;
2. isi `VITE_SUPABASE_URL` dan anon/publishable key;
3. jalankan `npm install`;
4. jalankan `npm run dev`.

Untuk development di repository ini, bila nilai `.env` PWA masih placeholder,
Vite otomatis memakai `NEXT_PUBLIC_SUPABASE_URL` dan
`NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` dari `backoffice/.env.local`. Hanya dua
nilai publik tersebut yang diteruskan ke browser; service-role key tidak pernah
dibaca atau diekspos. Deployment PWA tetap wajib mengisi variable `VITE_*`
sendiri.

Jangan memasukkan service-role key ke PWA. Authentication memakai Supabase Auth
user dan seluruh query/RPC tetap melewati RLS serta active-company context.

## Flow aktif

1. Cashier login;
2. pilih Company aktif;
3. pilih Terminal POS dan Gudang penjualan;
4. masukkan modal kas fisik dan buka sesi;
5. pilih Product-UOM, Customer, Pricelist, diskon, rounding, dan satu atau
   beberapa Payment Method;
6. `Simpan Draft` memanggil `save_pos_sale_draft_with_pricelist`;
7. tombol `Draft` membuka daftar same-Store dan mengunci satu editor; saat
   dilanjutkan harga dihitung ulang dan payment wajib dikonfirmasi kembali;
8. `Konfirmasi & Post` menghitung ulang Draft dan memanggil
   `post_pos_sale_with_pricelist`;
9. shortage tetap menjadi Draft tanpa payment, movement, atau event final;
10. setelah `POSTED`, transaksi langsung direset sementara receipt tetap tampil;
11. struk membaca `receipt_snapshot` dan fallback browser membukanya pada tab
    cetak baru, bukan mengunduh file.

Setiap bagian Split Payment mempunyai key stabil untuk retry, nominal base,
Cash tender/change, proof URL, dan estimasi fee. Total bagian wajib menutup
total server; fee persisted tetap dihitung ulang oleh server dari snapshot
Payment Method.

Harga yang tampil sebelum Draft hanya fallback Product-UOM. Total final dan
harga per line yang berlabel hasil server berasal dari resolver canonical.
Pricelist `Otomatis` mengikuti assignment Customer lalu Global default.
Override Cashier hanya menampilkan Pricelist eligible dan divalidasi ulang
server-side.

Layout operasional dirancang tablet-first: katalog dan checkout menjadi dua
panel pada lebar tablet, checkout sticky dengan scroll sendiri, touch target
minimum 44 px, dan kembali satu kolom pada layar kecil.

## Stress test checkout staging

`npm.cmd run stress:g4-checkout` menguji Post concurrent pada satu Draft
disposable. Command ini benar-benar mem-post transaksi serta mengurangi
stok/FIFO, sehingga hanya boleh dipakai di staging/development setelah membaca
`docs/runbooks/G4_PHASE10_TRUE_CONCURRENT_POST_STRESS.md`. Script memakai akun
biasa, Company aktif terakhir, dan nomor Draft user-facing; credential/token
tidak dicetak.

## Boundary

- Mode offline terlihat tetapi checkout diblokir. Library Dexie lama belum
  menjadi execution path produksi.
- Endpoint `/api/pos/sync` mengembalikan `OFFLINE_SYNC_NOT_ENABLED` dan tidak
  menulis Sale.
- Customer Balance, Ketul, Return/Refund, Expense, Deposit, dan offline
  allowance/acknowledgement tetap menunggu gate roadmap masing-masing.
- Cashier biasa membutuhkan company membership dan assignment `CASHIER` aktif
  pada Store. Super Admin serta Company Owner/Admin memakai role inheritance
  yang disetujui. Store Manager dapat memakai POS hanya pada Store assignment
  aktifnya. Seluruhnya tetap membutuhkan Terminal aktif, Gudang
  `is_sale_source`, Payment Method eligible, dan sesi `OPEN`.
