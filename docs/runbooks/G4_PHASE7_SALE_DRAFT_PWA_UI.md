# G4 Phase 7 — Sale Draft PWA UI

## Outcome

PWA kasir menyediakan daftar Draft per Store, melanjutkan Draft dengan
single-editor lock, heartbeat, confirmed stale-lock takeover, Manager/Admin
force release, serta cancel yang tetap menyimpan histori.

Saat Draft dibuka kembali:

- payload item, Customer, Pricelist, diskon, pembulatan, dan TEMPO dipulihkan;
- harga dihitung ulang oleh server melalui guarded Draft RPC;
- payment lama tidak dipulihkan dan harus dikonfirmasi ulang oleh kasir;
- Draft tidak mereservasi stock dan tidak membuat payment, movement, financial
  event, atau journal final.

## Local Evidence

Jalankan dari `pwa/`:

```powershell
npm.cmd run lint
npm.cmd run build
```

Keduanya harus selesai tanpa error.

## Authenticated Tablet Smoke

1. buka sesi Kasir pada Terminal dan Gudang penjualan aktif;
2. buat cart, isi nama/catatan Draft, lalu klik `Simpan Draft`;
3. klik `Draft`, pastikan nomor, label, Customer, total, item, pembuat, dan waktu
   tampil tanpa UUID;
4. klik `Lanjutkan`, pastikan cart dipulihkan, harga server dihitung ulang, dan
   payment/tender/proof kosong;
5. pada sesi Kasir kedua di Store yang sama, pastikan Draft dengan lock aktif
   tidak dapat diedit;
6. biarkan lock melewati lima menit, lalu pastikan takeover membutuhkan
   konfirmasi;
7. sebagai Store Manager/Company Admin, coba `Lepas paksa`; alasan wajib dan
   tindakan harus muncul pada audit;
8. buka Draft lalu `Batalkan Draft`; alasan wajib, Draft hilang dari daftar
   aktif, dan tidak ada stock/payment/event final;
9. tekan `Escape` ketika panel Draft terbuka; panel harus tertutup;
10. pastikan takeover, force release, cancel, transaksi baru, dan tutup sesi
    memakai modal KGS POS—bukan `confirm`/`prompt` bawaan browser;
11. ulangi pada viewport tablet portrait dan landscape.

## Compatibility

- transaksi POSTED tetap mereset cart dan membuka receipt print-tab;
- Pricelist AUTO/override tetap diselesaikan server-side;
- public Save/Post tetap melewati edit-lock guard;
- single-payment online tetap aktif;
- offline queue dan split payment tetap belum dibuka.

## Exit Gate

Phase 7 dapat ditutup setelah local lint/build dan authenticated tablet smoke
di atas lulus. Gate aman berikutnya adalah split payment online; offline queue
tetap fase terpisah.
