# G3 Phase 5 — Stock Movement / Kartu Stok API/UI

## Status

`COMPLETE — AUTHENTICATED SMOKE PASS`

Database canonical Stock Movement `20260728150000` telah dikonfirmasi user
lulus migration, postflight, behavioral test, dan regression. Fase ini hanya
menambahkan read model Backoffice; tidak ada schema atau mutation stok baru.

## Scope

Halaman `Inventory > Kartu Stok` menampilkan ledger final tenant-scoped:

- waktu posting dan status final;
- nama Product dan SKU;
- nama Gudang;
- quantity masuk atau keluar dalam Base UOM snapshot;
- saldo setelah movement;
- jenis movement;
- nomor dokumen sumber bila resolver sumber tersedia;
- nama actor yang dapat dibaca melalui RLS, `Anda`, `Sistem`, atau label aman
  `User berwenang`;
- catatan movement.

Filter tersedia untuk pencarian, Gudang, jenis movement, dan rentang tanggal.
UUID Product, Gudang, source, dan actor tidak ditampilkan kepada user.

## Security dan compatibility

- endpoint memakai session user dan Company aktif;
- RLS tetap menjadi boundary server-side;
- endpoint tidak memakai service role dan tidak menyediakan mutation;
- ledger tetap immutable dan hanya dokumen posting yang membuat movement;
- source selain Opening memakai label aman sampai workflow resminya dibuka;
- G4 notification/inbox/Stock Request dan G5 Purchasing tetap deferred.

## Authenticated smoke test

1. Restart Backoffice, login, lalu buka `Inventory > Kartu Stok`.
2. Pastikan Opening Stock `POSTED` tampil sebagai `Stok Awal`.
3. Cocokkan Product, Gudang, quantity masuk, saldo setelah movement, dan Base
   UOM dengan dokumen serta `Stock Real`.
4. Pastikan nomor dokumen Stok Awal tampil dan tidak ada UUID di tabel.
5. Pastikan pencatat tampil sebagai nama, `Anda`, `Sistem`, atau
   `User berwenang`.
6. Uji pencarian, filter Gudang, jenis movement, dan rentang tanggal.
7. Pastikan tidak ada tombol edit, delete, posting, atau mutation stok.
8. Ganti Company dan pastikan data tenant sebelumnya tidak terlihat.

## Local evidence

- `npm.cmd run lint` — PASS
- `npm.cmd run build` — PASS; route
  `/api/inventory/stock-movements` terdeteksi
- `git diff --check` — dijalankan pada handoff phase ini
