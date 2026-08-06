# G4 Phase 61 — POS Negative Stock Operational UI

## Outcome

Menghubungkan runtime STK-006 yang sudah lulus Phase 60 ke konfigurasi
Backoffice dan reason/retry UX PWA tanpa membuka direct database write atau
memperluas exception ke Offline/Bundle.

## Batas yang Tetap Berlaku

- entitlement `pos_negative_stock_enabled` default OFF dan hanya Super Admin
  yang boleh mengubahnya;
- policy Company, opt-in Gudang, dan permission user hanya dimutasi melalui RPC
  guarded Phase 58 oleh Company Owner/Admin;
- Store Manager hanya dapat melihat konfigurasi;
- POS tidak menentukan eligibility sendiri. Modal alasan hanya muncul setelah
  server mengembalikan `NEGATIVE_STOCK_REASON_REQUIRED`;
- Offline, Bundle, import, dan user tanpa permission tetap fail-closed;
- reason tersimpan dalam payload Draft dan authorization audit server.

## Automated Evidence

Jalankan dari root repository:

```powershell
Set-Location backoffice
npm.cmd run lint
npm.cmd run build

Set-Location ..\pwa
npm.cmd run lint
npm.cmd run build
```

Expected: empat command exit code `0`; Next build mendeteksi route
`/api/platform/negative-stock-settings`.

## Authenticated Smoke

1. Restart Backoffice dan PWA, lalu hard refresh browser.
2. Sebagai Super Admin, buka `Pengaturan > Point of Sale` dan pastikan kartu
   `Stok Minus POS` tampil. Aktifkan entitlement hanya pada Company UAT.
3. Sebagai Company Owner/Admin pada Company yang sama:
   - aktifkan policy Company;
   - pertahankan `Kasir wajib mengisi alasan` aktif;
   - isi batas Company atau biarkan kosong;
   - opt-in tepat satu Gudang penjualan;
   - beri izin kepada satu user Kasir, isi alasan pemberian izin, limit, dan
     masa berlaku bila diperlukan.
4. Muat ulang halaman. Pastikan nama Gudang dan user tampil (UUID tidak tampil),
   version conflict tidak muncul, dan konfigurasi tersimpan.
5. Buka POS online menggunakan user yang diberi izin, Terminal/Gudang yang sama,
   lalu buat penjualan non-Bundle dengan quantity melebihi stok tetapi masih di
   bawah batas.
6. Tekan `Konfirmasi & Post`. Expected:
   - modal custom `Otorisasi stok minus` muncul;
   - tombol Post disabled sampai alasan terisi;
   - `Escape` menutup modal tanpa final effect;
   - setelah alasan diisi, retry menghasilkan Sale POSTED dan receipt.
7. Ulangi dengan limit terlampaui atau user/Gudang tanpa izin. Expected:
   transaksi tetap Draft `STOCK_SHORTAGE`; tidak ada Payment/Movement/Event
   final dan tidak ada tombol bypass.
8. Matikan koneksi dan coba item yang melebihi allowance Offline. Expected:
   stok minus tidak ditawarkan dan local commit ditolak.
9. Jika fixture Bundle tersedia, coba Bundle shortage. Expected: tetap Draft,
   tidak memakai STK-006.
10. Jalankan kembali closing postflight/behavior/regression Phase 60 bila smoke
    mengubah stok fixture UAT.

## Compatibility dan Forward Fix

Tidak ada migration pada Phase 61. Rollback UI dilakukan dengan mengembalikan
komponen/route/PWA payload change; database Phase 58/60 tetap additive dan
konfigurasi dapat dinonaktifkan berlapis melalui entitlement, policy, Gudang,
atau permission. Jangan menghapus history authorization/allocation.

## Exit Criteria

- Backoffice config save/reload PASS untuk Owner/Admin;
- Store Manager read-only dan user tanpa role ditolak;
- POS eligible menampilkan modal alasan dan Post hanya setelah server menerima;
- ineligible, Offline, Bundle, dan over-limit tetap fail-closed;
- receipt, Stock–Movement–FIFO, authorization, serta allocation dapat
  direkonsiliasi setelah transaksi UAT.
