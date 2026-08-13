# SLD-R3 Delivery Checkout dan Print UAT

## Tujuan

Memastikan UI pengiriman memakai runtime SLD-R2 yang sudah database PASS tanpa
mengubah transaksi Pickup, menambah total dua kali, atau membocorkan ongkir ke
Surat Jalan.

## Persiapan

1. Restart PWA dan Backoffice, lalu hard refresh browser.
2. Gunakan Company aktif yang mempunyai Kasir, Terminal, Gudang penjualan,
   metode pembayaran, Customer reguler beralamat, dan stok cukup.
3. Pastikan Offline policy/allowance hanya diaktifkan saat menguji jalur Offline.

## UAT online

1. Buat cart biasa dan pastikan panel alamat tidak memenuhi cart.
2. Centang `Perlu dikirim`; modal harus terbuka dengan nama, telepon, dan alamat
   Customer sebagai nilai awal. Escape harus menutup modal tanpa native prompt.
3. Buka lagi, isi ongkir, simpan, dan pastikan ringkasan menunjukkan penerima
   serta nominal ongkir.
4. Post dengan satu payment; nominal otomatis harus sama dengan Product +
   ongkir. Ulangi dengan split payment dan TEMPO bila entitlement tersedia.
5. Cetak Invoice dengan toggle breakdown aktif: baris `Ongkir` tampil satu kali.
6. Ulangi dengan toggle mati: baris Ongkir tidak tampil, tetapi total akhir sama.
7. Cetak Surat Jalan: hanya identitas tujuan dan quantity Product yang tampil;
   tidak ada harga atau ongkir.
8. Simpan Delivery sebagai Draft, buka kembali, dan pastikan seluruh detail,
   ongkir, display mode, dan total dipulihkan.
9. Uji Pickup: tidak ada Surat Jalan dan ongkir harus nol.
10. Uji Walk-In Delivery: POST ditolak sampai penerima, telepon, dan alamat diisi.

## UAT offline

1. Siapkan snapshot/allowance, lalu putus koneksi.
2. Buat Delivery dengan ongkir dan payment Cash sebesar total Product + ongkir.
3. Simpan Offline, sambungkan kembali, dan sinkronkan sampai `POSTED`.
4. Buka final receipt/Invoice/SJ dan ulangi pemeriksaan total serta breakdown.
5. Pastikan replay/sync ulang tidak membuat Sale, Payment, Movement, Event,
   Invoice, atau ongkir kedua.

## Backoffice dan tenant

1. Buka Dokumen Penjualan dan cetak Invoice/SJ dari Backoffice.
2. Invoice harus mengikuti display mode snapshot; Surat Jalan tetap tanpa nilai.
3. Ganti ke Company kedua: dokumen Company pertama tidak boleh terlihat.

## Gate lulus

- tidak ada `PAYMENT_TOTAL_MISMATCH` atau double fee;
- payment/receivable dan grand total konsisten;
- Invoice presentation mode tidak mengubah angka final;
- Surat Jalan tidak menampilkan harga/ongkir;
- Draft/Offline/replay/tenant boundary aman.
