# G4 Phase 9 — Split Payment PWA UI

## Status

`READY FOR AUTHENTICATED TABLET SMOKE`

Database prerequisite `20260729150000_g4_phase8_payment_leg_identity.sql`,
postflight, behavioral test, dan regression telah dikonfirmasi sukses oleh user.

## Scope yang Dibuka

- satu Sale dapat dibayar dengan lebih dari satu Payment Method;
- setiap leg mempunyai `clientPaymentKey` stabil selama retry;
- nominal base setiap leg diisi Kasir dan totalnya wajib sama dengan total server;
- satu Payment Method hanya dapat dipilih satu kali;
- Cash menyimpan uang diterima dan change per leg;
- proof URL diminta per leg sesuai konfigurasi master;
- fee/surcharge ditampilkan sebagai estimasi, tetapi nilai persisted tetap
  dihitung server dari snapshot Payment Method;
- receipt existing menampilkan seluruh leg persisted.

Offline payment, Customer Balance, Ketul Offset, settlement, refund, dan Return
tetap tidak dibuka.

## Evidence Lokal

```text
pwa npm run lint  PASS
pwa npm run build PASS
```

Browser preview tidak dapat dihubungkan dari environment agent. Tidak ada
authenticated visual evidence yang diklaim.

Visual correction setelah smoke pertama:

- layout dua kolom di dalam checkout panel 350–420 px dihapus;
- seluruh field Payment leg memakai satu kolom dengan `min-width: 0`;
- aksi `Isi sisa` dipindahkan ke baris label agar tidak menekan input;
- header leg, tombol hapus, fee note, tombol tambah, dan summary disederhanakan
  agar tidak menghasilkan border/ikon bertumpuk;
- lint dan production build setelah correction tetap `PASS`.

## Manual Smoke Wajib

1. restart PWA dan lakukan hard refresh;
2. buka Session Kasir online dan masukkan Product sampai total server terbentuk;
3. pilih Cash, isi sebagian nominal, lalu klik `Tambah metode pembayaran`;
4. pilih metode kedua dan klik `Isi sisa`;
5. pastikan ringkasan menunjukkan `Sisa Rp 0`;
6. untuk Cash, isi uang diterima di atas nominal bagian dan pastikan receipt
   menunjukkan change yang benar;
7. untuk metode proof-required, pastikan submit tanpa HTTPS proof ditolak;
8. pastikan metode yang sudah dipakai disabled pada leg lain;
9. coba total kurang dan lebih; keduanya harus ditolak tanpa Payment, Movement,
   FIFO, atau Financial Event parsial;
10. Post transaksi valid dan pastikan receipt memuat kedua Payment Method;
11. ulangi Post/retry dari keadaan network lambat dan pastikan tidak ada leg
    ganda;
12. simpan lalu buka kembali Draft; payment lama tidak dipulihkan dan Kasir
    wajib mengonfirmasi pembagian pembayaran lagi;
13. ulangi pada tablet portrait dan landscape; seluruh input, tombol Hapus,
    `Isi sisa`, ringkasan, dan tombol Post harus terbaca.

## Compatibility

Single-payment tetap bekerja. Bila hanya ada satu leg dan nominalnya kosong,
PWA mengirim total penuh dari hasil repricing server. Client lama tanpa
`clientPaymentKey` tetap dinormalisasi oleh compatibility trigger Phase 8.

## Exit Gate

Phase ini dapat ditandai `COMPLETE` hanya setelah manual smoke di atas lulus.
Next safe step setelah itu adalah online end-to-end dan true concurrent
double-post stress. Offline queue tetap fase tersendiri.
