# G4 Phase 5 — POS Online Integration Smoke

## Status

`READY FOR AUTHENTICATED SMOKE`

Database Phase 4 telah dikonfirmasi user lulus. Fase ini menghubungkan PWA
online ke active Company, Cashier Session, canonical Sale Draft/Post, dan
receipt snapshot. Tidak ada migration baru.

## Scope yang Diverifikasi

- login Supabase Auth;
- active Company;
- Terminal POS dan Gudang penjualan sesuai assignment Cashier;
- buka/tutup Cashier Session;
- Product-UOM dan Customer user-facing;
- Draft memakai harga/Pricelist/Tax resolver server;
- diskon line/transaksi dan rounding Rp100;
- satu payment leg online dan bukti HTTPS;
- TEMPO dengan Customer reguler dan due date;
- shortage kembali sebagai Draft tanpa final effect;
- Post menghasilkan receipt snapshot dan stok terbaru;
- offline checkout diblokir eksplisit.

Split payment UI, daftar/lock/takeover Draft, offline allowance/queue,
Return/Refund, Expense, Deposit, Customer Balance, dan Ketul belum termasuk
fase ini.

## Persiapan

1. migration sampai `20260729070000` sudah applied;
2. user memiliki company membership dan store membership `CASHIER` aktif;
3. Store memiliki Terminal aktif;
4. ada Gudang aktif dengan `is_sale_source = true`;
5. ada Product-UOM aktif untuk penjualan dan Payment Method eligible;
6. PWA `.env` hanya berisi Supabase URL dan anon/publishable key. Pada
   development repository, placeholder PWA akan fallback ke dua
   `NEXT_PUBLIC_*` Supabase value dari `backoffice/.env.local`; deployment PWA
   tetap wajib memakai `VITE_SUPABASE_URL` dan `VITE_SUPABASE_ANON_KEY`.

## Urutan Smoke

1. Hentikan proses PWA lama, lalu jalankan ulang `npm.cmd run dev` dari folder
   `pwa` agar konfigurasi environment dibaca ulang.
2. Login sebagai Cashier.
3. Pastikan pilihan Company menampilkan nama, bukan UUID.
4. Pilih Terminal dan Gudang; masukkan modal kas; buka sesi.
5. Pastikan kartu Product menampilkan nama Product dan nama UOM.
6. Tambahkan Product stok ke cart, lalu tekan `Simpan Draft`.
7. Pastikan label `Total server` terisi dan harga line berubah menjadi
   `hasil server`.
8. Pilih Customer berbeda dan simpan ulang; periksa harga dihitung ulang.
9. Uji diskon line, diskon transaksi, serta rounding `NONE`, `DOWN`, dan `UP`.
10. Pilih Tunai, isi uang diterima, lalu `Konfirmasi & Post`.
11. Pastikan receipt server tampil, invoice bukan nomor buatan browser, dan
    tombol cetak memakai snapshot posted.
12. Muat stok terbaru dan pastikan saldo berkurang.
13. Buat quantity melebihi stok dan Post; expected:
    - status tetap Draft;
    - notice requested/available/shortage tampil;
    - tidak ada receipt final.
14. Untuk electronic method yang `proof_mode = REQUIRED`, kosongkan URL;
    expected `PAYMENT_PROOF_REQUIRED`. Isi URL HTTPS lalu ulangi.
15. Uji TEMPO hanya dengan Customer reguler dan due date.
16. Putuskan koneksi; tombol Draft/Post disabled dan UI menampilkan
    `Offline diblokir`. Tidak boleh terbentuk invoice lokal palsu.
17. Isi kas fisik penutupan dan tutup sesi; periksa expected, actual, serta
    difference pada notice.

## Evidence Otomatis Lokal

```powershell
cd pwa
npm.cmd run lint
npm.cmd run build

cd ..\backoffice
npm.cmd run lint
npm.cmd run build
```

Expected seluruh command exit code `0`.

## Compatibility

- endpoint Backoffice `/api/pos/checkout` hanya meneruskan
  `save_pos_sale_draft` atau `post_pos_sale`;
- endpoint `/api/pos/sync` mengembalikan `409 OFFLINE_SYNC_NOT_ENABLED` dan
  tidak menulis transaksi;
- library Dexie lama tetap ada sebagai compatibility artifact, tetapi tidak
  dipanggil entrypoint PWA;
- service-role key tidak digunakan PWA.

## Rollback

UI dapat dikembalikan ke read-only/login-only tanpa membatalkan Sale yang telah
`POSTED`. Jangan menghapus Sale, Payment, Movement, FIFO allocation, receipt,
atau Financial Event. Jika runtime bermasalah, hentikan penggunaan PWA dan
pertahankan database canonical untuk diagnosis/forward fix.

## Next Safe Step

Setelah authenticated smoke ini lulus:

1. tutup online single-payment core;
2. lanjutkan Draft list/edit-lock dan split payment UI sesuai roadmap;
3. lakukan online E2E serta true concurrent double-post;
4. baru buka desain offline allowance/queue/acknowledgement.
