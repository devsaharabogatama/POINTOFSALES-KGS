# G3 Phase 9 — Stock Adjustment API/UI

## Status

`READY FOR AUTHENTICATED SMOKE`

Database Phase 8 dikonfirmasi user seluruhnya sukses. Backoffice local-ready
menyediakan:

- menu `Inventory > Penyesuaian Stok`;
- list/detail `DRAFT`, `POSTED`, dan `CANCELED`;
- create/edit/post/cancel melalui guarded RPC canonical;
- input **stok fisik akhir**, bukan angka plus/minus;
- stok sistem, selisih masuk/keluar, dan nama Base UOM langsung terlihat;
- alasan hanya ditampilkan bila cocok dengan arah selisih;
- gain dapat memakai biaya terbaru sistem atau biaya manual dengan alasan;
- bukti FIFO, nilai, saldo akhir, dan source number pada Kartu Stok;
- seluruh modal dapat ditutup dengan `Esc`.

## Smoke utama

Restart Backoffice, login dengan Company Owner/Admin atau Super Admin:

1. Buka `Inventory > Penyesuaian Stok`.
2. Klik `Buat Penyesuaian`, pilih Gudang yang memiliki stok.
3. Pilih Product. Pastikan UI menampilkan nama Product, nama Base UOM, dan stok
   sistem tanpa UUID/kode UOM teknis.
4. Uji **loss**:
   - bila stok sistem 10 Ketul, isi stok fisik akhir 7;
   - pastikan UI menampilkan `Stok berkurang -3 Ketul`;
   - pilih alasan yang mengizinkan penurunan;
   - simpan Draft dan pastikan Stock Real belum berubah.
5. Edit dan simpan Draft sekali lagi, lalu Posting dengan checkbox konfirmasi.
6. Pastikan:
   - status `Sudah diposting`;
   - Stock Real menjadi 7;
   - detail menunjukkan FIFO layer dan nilai loss;
   - Kartu Stok menampilkan `Penyesuaian`, nomor `ADJ-...`, keluar 3, serta
     saldo akhir 7.
7. Uji **gain** pada Product/Gudang lain atau setelah loss:
   - isi stok fisik akhir lebih besar dari stok sistem;
   - kosongkan biaya untuk memakai suggested cost sistem, atau isi biaya manual
     beserta alasan;
   - simpan dan Posting;
   - pastikan saldo bertambah, FIFO gain layer terbentuk, dan detail nilai gain
     muncul.
8. Buat Draft lain lalu batalkan. Pastikan tidak ada saldo/FIFO/Movement baru.
9. Tekan `Esc` pada form, detail, dan konfirmasi; modal harus tertutup.

## Negative smoke

- stok fisik sama dengan stok sistem: form harus menolak karena tidak ada
  selisih;
- alasan `DECREASE` untuk selisih naik atau `INCREASE` untuk selisih turun
  tidak boleh dipilih/disimpan;
- biaya gain manual tanpa alasan: ditolak;
- bila stok berubah setelah Draft dibuat, Posting ditolak dan user diarahkan
  mengedit/simpan ulang Draft;
- dokumen final tidak dapat diedit atau diposting ulang dengan key baru.

## Role smoke

- Super Admin dan Company Owner/Admin: mutation dalam Company aktif;
- Store Manager: mutation hanya pada Gudang Store dalam assignment; Gudang
  lain ditolak server;
- Warehouse Admin, Finance, Accounting: read-only;
- user tanpa akses Inventory: menu tidak muncul.

## Compatibility dan boundary

- browser/API tidak mempunyai direct write ke saldo, FIFO, Movement, event,
  document, line, reason, atau audit;
- server menghitung ulang snapshot/difference dan melakukan posting atomic;
- UUID tetap internal;
- Finance event masih `HOLD`; jurnal belum dibuka;
- reason management UI, reversal UI, Stock Opname, G4 notification, dan G5
  Purchasing tetap deferred.

## Rollback

API/UI dapat dilepas tanpa perubahan data. Migration applied tidak boleh
diedit; temuan database ditangani dengan forward-only migration.
