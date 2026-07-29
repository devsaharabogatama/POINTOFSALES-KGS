# G3 Phase 11 — Stock Opname Backoffice API/UI

## Status

`READY FOR AUTHENTICATED SMOKE`

Database canonical Phase 10 sudah dikonfirmasi user lulus migration, 14-check
postflight, behavioral test, dan regression. Fase ini tidak memiliki migration.

## Scope

Backoffice menyediakan:

- daftar sesi Stock Opname per Company aktif;
- report per Gudang berisi snapshot awal, expected saat hitung, fisik,
  variance, counter, waktu hitung, dan status line;
- riwayat setiap percobaan hitung serta movement yang memicu recount;
- bukti dokumen Adjustment setelah Posting;
- aksi `Minta Hitung Ulang`, `Posting`, dan `Batalkan` melalui guarded RPC;
- modal yang dapat ditutup dengan tombol `Escape`;
- nama Product, Gudang, Base UOM, dan actor sebagai informasi user-facing.

Finance/Accounting memiliki akses report saja. Owner/Admin Company dan Store
Manager sesuai assignment dapat melakukan review. UUID tetap internal.

## Boundary

Pembuatan sesi dan input fisik tidak ditambahkan ke Backoffice. Flow approved
memerlukan kasir melakukan blind count dari POS tanpa melihat system quantity,
expected, variance, HPP, atau nilai.

PWA repository saat ini masih prototype dengan mock catalog dan belum memiliki
auth, active Company/Store/Terminal, Cashier Session, maupun offline queue
production. Karena itu UI blind count POS sengaja menunggu G4. Database Phase 10
sudah menyediakan `get_stock_opname_blind_session(...)` sebagai contract aman
untuk implementasi G4.

## Smoke Test

1. Restart Backoffice dan login.
2. Buka launcher `Inventory`, lalu pilih `Stock Opname`.
3. Pastikan halaman terbuka tanpa notifikasi schema-cache atau permission error.
4. Pada database tanpa sesi, pastikan empty state tampil dan tidak ada UUID.
5. Bila terdapat sesi `COMPLETED`, buka report:
   - nama Gudang/Product/UOM tampil;
   - expected, fisik, variance, counter, dan waktu tampil;
   - riwayat attempt/recount tampil bila tersedia;
   - `Escape` menutup detail.
6. Dengan role Finance/Accounting, pastikan tombol mutation tidak tampil.
7. Dengan Owner/Admin atau Store Manager yang valid:
   - recount hanya tersedia pada line `COUNTED`;
   - Posting meminta konfirmasi dan menghasilkan satu Adjustment;
   - cancel hanya tersedia sebelum final;
   - stale version menampilkan konflik dan tidak membuat partial mutation.
8. Setelah Posting, periksa `Stock Real`, `Kartu Stok`, `Penyesuaian Stok`, dan
   report Opname menunjuk dokumen yang sama.

## Evidence Lokal

- `npm.cmd run lint`: PASS.
- `npm.cmd run build`: PASS.
- Next.js mendeteksi route list, recount, post, dan cancel sebagai dynamic API.

## Rollback

UI/API dapat di-forward-fix atau dilepas dari navigation tanpa mengubah database
atau histori. Jangan rollback migration Phase 10 yang sudah applied.
