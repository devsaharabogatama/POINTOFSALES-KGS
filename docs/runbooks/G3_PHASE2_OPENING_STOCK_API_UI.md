# G3 Phase 2 — Opening Stock Backoffice API/UI

## Status

`READY FOR AUTHENTICATED SMOKE TEST`

Dependency database `20260728120000` sudah dikonfirmasi user berhasil bersama
postflight, behavioral test, dan regression. Fase ini tidak menambah migration.

## Boundary

Backoffice hanya memakai RPC:

- `save_opening_stock_document(...)` untuk membuat atau mengubah Draft;
- `post_opening_stock(...)` untuk Posting yang idempotent.

Browser tidak memperoleh hak menulis langsung ke `product_stocks`,
`stock_movements`, `product_batches`, atau tabel dokumen. Draft tidak mengubah
saldo. Posting membuat saldo, movement `OPENING_BALANCE`, FIFO opening layer,
Finance event `HOLD`, dan audit dalam satu transaksi.

## Smoke test wajib

1. Restart Backoffice lalu buka `Inventory > Stok Awal`.
2. Buat Draft untuk satu Product stok dan satu Gudang yang belum mempunyai
   movement. Isi quantity dalam Base UOM serta HPP per Base UOM.
3. Pastikan notifikasi menyatakan Draft belum mengubah stok.
4. Buka detail Draft; kolom stok aktual, movement, dan FIFO harus masih kosong.
5. Edit Draft dan simpan kembali untuk menguji optimistic versioning.
6. Login sebagai Company Owner/Admin atau Super Admin, pilih `Posting`, baca
   konfirmasi final, centang persetujuan, lalu posting.
7. Buka detail dokumen yang sudah diposting dan verifikasi:
   - stok aktual sama dengan quantity yang diposting;
   - movement bertipe `OPENING_BALANCE`;
   - FIFO tersisa sama dengan quantity dan HPP yang dimasukkan.
8. Buka `Inventory > Produk & Stok` dan `Minimum Stock`; saldo Product–Gudang
   yang sama harus tampil sebagai stok aktual dan dapat dibandingkan dengan
   batas Minimum Stock.
   - `Produk & Stok` menampilkan total saldo dan rincian saldo per Gudang.
   - `Minimum Stock` menampilkan batas, stok aktual, dan kondisi.
   - jika notifikasi aktif dan stok aktual lebih kecil atau sama dengan batas,
     baris menjadi merah serta muncul ringkasan `Stok menipis`.
9. Coba membuat Stok Awal kedua untuk pasangan yang sama. Product harus tidak
   tersedia di form atau server menolak dengan pesan riwayat stok sudah ada.
10. Pastikan tombol `Esc` menutup modal Draft, Posting, dan Detail.

## Role checks

- `FINANCE`, `ACCOUNTING`, dan `STORE_MANAGER` dapat menyiapkan Draft sesuai
  scope Gudang server-side, tetapi tidak dapat Posting.
- `COMPANY_OWNER`, `COMPANY_ADMIN`, dan Super Admin dapat Posting.
- `WAREHOUSE_ADMIN` tidak memperoleh menu Stok Awal pada contract saat ini.

## Compatibility

- tidak mengubah Product import, Minimum Stock, atau Opening Stock melalui CSV;
- tidak menjalankan worker jurnal legacy;
- Finance event tetap `HOLD` sampai gate posting jurnal dibuka;
- koreksi setelah Posting harus melalui Stock Adjustment pada fase berikutnya.
- notifikasi Minimum Stock saat ini berupa indikator real-time ketika halaman
  Backoffice dimuat/di-refresh; push notification, background scheduler, dan
  pembuatan order otomatis belum dibuka.

## Evidence lokal

- `npm.cmd run lint`
- `npm.cmd run build`
- `git diff --check`

Status menjadi `COMPLETE` hanya setelah seluruh smoke test authenticated di atas
dikonfirmasi user.
