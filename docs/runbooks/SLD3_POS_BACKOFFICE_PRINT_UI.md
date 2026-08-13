# SLD-3 POS, Backoffice, dan Printable Document UAT

**Status:** SUPERSEDED / UAT ON HOLD — approved SLD-R1—R4 revision  
**Database dependency:** SLD-2 user-reported ALL PASS

Jangan gunakan runbook ini sebagai closing acceptance sebelum
`SLD_DELIVERY_FEE_REVISION_PLAN.md` selesai. Implementasi awal tetap menjadi
compatibility baseline, tetapi final checkout, ongkir, Finance, offline, dan
Return akan diverifikasi melalui SLD-R1—R4.

## Implementasi

- POS menyediakan `Ambil sendiri` atau `Perlu dikirim` sebelum draft/post.
- Delivery mewajibkan nama penerima, telepon, dan alamat; data Customer menjadi
  default tetapi tetap dapat dikoreksi untuk transaksi tersebut.
- Payload online, draft, dan offline mempertahankan snapshot fulfillment.
- Setelah transaksi sukses cart tetap di-reset dan operator dapat membuka
  struk thermal, Invoice A4, serta Surat Jalan A4 bila delivery.
- Backoffice `Sales -> Invoice & Surat Jalan` menyediakan daftar, pencarian,
  filter fulfillment, detail final, print/reprint, dan lifecycle Surat Jalan.
- UUID hanya dipakai sebagai identitas internal dan tidak ditampilkan.
- Print membuka tab baru; bukan download paksa. Template memakai snapshot final,
  termasuk logo yang direferensikan saat transaksi.
- Perubahan status hanya melalui guarded RPC. Surat Jalan tidak menulis Stock,
  Payment, Financial Event, atau Journal baru.

## Local Evidence

Jalankan dari root workspace:

```powershell
Set-Location .\pwa
npm.cmd run lint
npm.cmd run build

Set-Location ..\backoffice
npm.cmd run lint
npm.cmd run build
```

Expected: seluruh command exit `0`. Warning ukuran chunk Vite yang sudah dikenal
bukan failure gate.

## Manual UAT — POS

1. Login kasir, buka sesi, pilih Store/Terminal/Gudang.
2. Post Sale `Ambil sendiri`; pastikan sukses, cart kosong, Invoice tersedia,
   dan Surat Jalan tidak tersedia.
3. Post Sale `Perlu dikirim` untuk Customer bernama; review penerima, telepon,
   alamat, jadwal, dan catatan. Pastikan Invoice dan Surat Jalan tersedia.
4. Ulangi delivery dengan Walk-In. Empty penerima/telepon/alamat harus diblokir;
   setelah diisi eksplisit Sale boleh diposting.
5. Buka Invoice dan Surat Jalan. Keduanya harus membuka tab baru, memakai nomor
   manusia, nama UOM, data snapshot, dan layout A4 yang dapat dicetak.
6. Uji logo aktif dan Company tanpa logo. Dokumen tanpa logo tetap rapi.
7. Uji Sale cash, transfer/split, TEMPO yang tersedia, Bundle, serta satu Sale
   offline lalu sync. Tidak boleh ada retry posting setelah Sale sebenarnya
   sukses hanya karena loader dokumen/print gagal.

## Manual UAT — Backoffice

1. Masuk sebagai Owner/Admin/Store Manager. Buka `Sales -> Invoice & Surat
   Jalan`; cari berdasarkan Invoice, Surat Jalan, Customer, dan Store.
2. Periksa Pickup tidak mempunyai Surat Jalan dan Delivery mempunyainya.
3. Buka detail dan print/reprint Invoice/SJ. Nomor UUID tidak boleh tampil.
4. Lifecycle happy path: `Siap dikirim -> Dalam perjalanan -> Terkirim`.
5. Cancel hanya boleh dari `Siap dikirim`, memakai modal aplikasi dengan alasan.
6. Escape menutup detail dan modal konfirmasi ketika operasi tidak sedang jalan.
7. Finance/Accounting dapat melihat dokumen sesuai catalog tetapi tidak mendapat
   tombol mutation delivery. Role tanpa modul Sales tidak melihat card/fast link;
   direct API tetap harus `403`/not found sesuai server authority.
8. Switch Company A/B. List, detail, print, dan mutation tidak boleh membawa
   state atau dokumen Company sebelumnya.

## Regression / Acceptance

- Jalankan kembali postflight SLD-2 setelah UAT.
- Pastikan jumlah Stock Movement, Payment, Financial Event, dan Journal tidak
  berubah karena print atau lifecycle pengiriman.
- Return tetap mereferensikan Invoice sumber dan tidak membuat Invoice baru.
- Exact reprint hanya menambah event audit print; snapshot final tidak berubah.

SLD-3 baru boleh ditandai COMPLETE setelah manual UAT di atas dikonfirmasi.
Sesudah itu next safe step adalah PRD-1 full pre-deploy regression.
