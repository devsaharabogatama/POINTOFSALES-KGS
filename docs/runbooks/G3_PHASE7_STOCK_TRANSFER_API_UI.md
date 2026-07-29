# G3 Phase 7 — Stock Transfer API/UI

## Status

`COMPLETE`

User mengonfirmasi seluruh smoke sukses dan pekerjaan dapat dilanjutkan.

Database canonical Transfer Stok telah dikonfirmasi user:

- migration `20260728180000` sukses;
- seluruh 15 postflight `PASS`;
- behavioral test `PASS`;
- regression canonical Movement, Opening Stock, Minimum Stock, dan G1 closure
  `PASS`.

Backoffice local-ready menyediakan:

- menu `Inventory > Transfer Stok`;
- list dan detail Draft/Posted/Canceled;
- guarded create/edit/post/cancel melalui RPC canonical;
- pilihan Product hanya dari saldo positif Gudang asal;
- quantity selalu dalam nama Base UOM, bukan kode/UUID;
- bukti saldo asal/tujuan, movement OUT/IN, jumlah layer FIFO, dan nilai
  transfer setelah Posting;
- nomor dokumen Transfer pada Kartu Stok.

## Smoke test

Restart Backoffice, login sebagai Company Owner/Admin atau Warehouse Admin,
lalu:

1. Buka `Inventory > Transfer Stok`.
2. Buat Draft dari Gudang yang memiliki stok menuju Gudang lain.
3. Tambahkan Product dan isi quantity lebih kecil atau sama dengan `Stok
   tersedia`; simpan.
4. Pastikan Draft muncul dan saldo `Stock Real` belum berubah.
5. Edit Draft, simpan lagi, lalu buka detailnya.
6. Posting setelah mencentang konfirmasi.
7. Pastikan:
   - status menjadi `Sudah diposting`;
   - saldo Gudang asal berkurang tepat satu kali;
   - saldo Gudang tujuan bertambah dengan quantity yang sama;
   - detail menunjukkan dua movement dan FIFO layer;
   - `Kartu Stok` menampilkan `Transfer Keluar` dan `Transfer Masuk` dengan
     nomor dokumen Transfer yang sama.
8. Buat Draft kedua, lalu batalkan. Pastikan status `Dibatalkan` dan tidak ada
   perubahan saldo/movement.
9. Tekan `Esc` pada modal form/detail/konfirmasi; modal harus tertutup.

## Role smoke

- Super Admin, Company Owner/Admin, Warehouse Admin: dapat
  create/edit/post/cancel.
- Store Manager, Finance, Accounting: menu dan detail dapat dibaca, tombol
  mutation tidak muncul.
- User tanpa akses Inventory: menu tidak muncul.

## Compatibility dan boundary

- API memakai authenticated Supabase client dan active Company; tidak ada
  service-role pada browser/server route.
- Draft/Cancel tidak membuat stok atau movement.
- Posting final tetap divalidasi, dikunci, dan dibuat atomic oleh RPC database;
  `max` quantity pada form hanya bantuan UX.
- UUID tetap internal dan tidak ditampilkan pada UI.
- Adjustment, Opname, notification/Stock Request G4, dan Purchasing G5 tidak
  dibuka oleh fase ini.

## Rollback

UI/API dapat dihapus tanpa mengubah data. Database yang sudah applied tidak
boleh diedit atau di-rollback secara destruktif; temuan runtime diperbaiki
dengan forward fix.
