# G4 Phase 27 — Sales Return PWA Draft UI

**Status:** READY FOR AUTHENTICATED TABLET SMOKE

Phase ini membuka pembuatan **Draft Return Penjualan** pada PWA setelah
database behavior Phase 26 dan regression checkout/inventory/security lulus.

## Scope yang Dibuka

- tombol `Return` hanya tersedia saat Session kasir terbuka dan online;
- pencarian invoice posted menggunakan `list_returnable_sales`;
- Customer, Produk, dan UOM tampil dengan nama user-facing;
- quantity dibatasi oleh sisa quantity yang masih dapat diretur;
- kondisi line: Layak Jual, Rusak, atau Tanpa Barang Kembali;
- kondisi Rusak wajib memilih Gudang Rusak aktif;
- refund Cash/Transfer memakai Payment Method Store yang eligible;
- nilai refund dan pembulatan dihitung otomatis dari snapshot Sale asal;
- submit memanggil `save_sales_return_draft` dan selalu menghasilkan `DRAFT`.

## Boundary

- Kasir tidak dapat posting Return pada UI ini;
- mode approval tetap `REQUIRED`; Store Manager/Company Admin melakukan review
  dan posting melalui Backoffice pada fase berikutnya;
- Customer Balance, TEMPO, split refund, report, Finance journal, dan Offline
  Return belum dibuka;
- UI tidak memperoleh direct write ke table Return/Stock/Payment;
- server tetap memvalidasi source, cumulative quantity, refund exact-total,
  warehouse, Payment Method, tenant, actor, dan Session.

## Smoke Test

1. restart PWA dan hard refresh;
2. login, pilih Terminal/Gudang, lalu buka Session;
3. klik `Return` di header;
4. cari invoice posted dari Store yang sama;
5. pilih satu item dan quantity partial;
6. simpan sebagai Layak Jual dengan refund Cash;
7. pastikan notice menampilkan nomor `RET-*` dan status menunggu persetujuan;
8. verifikasi stock/kas belum berubah karena dokumen masih Draft;
9. ulangi dengan kondisi Rusak dan pastikan Gudang Rusak wajib dipilih;
10. ulangi Transfer dan pastikan tujuan serta referensi wajib;
11. tekan Escape dan klik backdrop untuk memastikan modal tertutup;
12. matikan jaringan dan pastikan tombol Return disabled.

Jangan posting atau memeriksa final stock dari UI ini. Review/post Backoffice
adalah gate berikutnya.

## Evidence Lokal

- `npm.cmd run lint`: PASS;
- `npm.cmd run build`: PASS;
- tidak ada migration baru; UI memakai RPC Phase 26 yang sudah live.
