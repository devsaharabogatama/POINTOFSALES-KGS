# G5 Phase 6 Goods Receipt PWA Smoke

Status: UI local-ready; authenticated tablet smoke menunggu user.

## Prasyarat

- migration `20260806040000` dan forward-fix `20260806050000` sudah applied;
- postflight dan behavioral test Phase 5 seluruhnya PASS;
- terdapat sesi Kasir `OPEN` pada Store tujuan Supplier Order;
- Supplier Order berstatus `CONFIRMED` atau `PARTIALLY_RECEIVED`;
- Gudang tujuan pembelian aktif;
- penerimaan rusak membutuhkan Gudang tipe `DAMAGED` aktif.

## Smoke minimum

1. Masuk PWA, buka sesi Kasir, lalu pilih `Terima Barang`.
2. Pastikan hanya Supplier Order Store aktif yang masih dapat diterima muncul.
3. Pastikan UI memakai nama Supplier, Gudang, Product, dan UOM, bukan UUID.
4. Isi sebagian quantity lalu `Simpan Draft`; stok tidak boleh berubah.
5. Tutup/buka modal, lanjutkan Draft sesi tersebut, dan periksa data pulih.
6. Aktifkan rincian rusak/ditolak. Total baik+rusak+ditolak wajib sama dengan
   jumlah aktual; UI harus menolak total yang berbeda.
7. Isi melebihi sisa order; warning over-receipt muncul tetapi Post diizinkan.
8. `Post & Tambah Stok`; pastikan notifikasi sukses muncul.
9. Verifikasi baik masuk Gudang tujuan, rusak masuk Gudang Rusak, dan ditolak
   tidak menambah stok.
10. Order parsial tetap muncul dengan sisa; order selesai tidak ditawarkan.
11. Buat Draft lain lalu `Batalkan`; Draft hilang dan stok tidak berubah.

## Boundary

- koneksi offline menonaktifkan `Terima Barang`;
- Draft tidak membuat Stock/FIFO/Movement/AP/Financial Event final;
- Post membuat satu final effect melalui RPC canonical;
- Supplier Invoice, matching, payment Supplier, Purchase Return, dan Journal
  final belum tersedia.
