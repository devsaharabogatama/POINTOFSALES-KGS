# Sales Process Cutover Control UI — Step 4F/6

## Status

`LOCAL READY; AUTHENTICATED ISOLATED-DEVELOPMENT SMOKE PENDING`.

Step 4E database Apply harus sudah terpasang dan lulus behavioral/postflight.
Production dan staging tidak boleh dipakai untuk smoke tahap ini.

## Impact boundary

- UI hanya berada di `Pengaturan Modul > Sales` dan hanya dirender untuk
  Platform Super Admin.
- API server memverifikasi session, role Super Admin, dan Company aktif.
- Service role hanya membaca setting serta ID plan milik Company aktif agar
  browser tidak mendapat akses tabel cutover.
- Seluruh create/refresh/cancel/apply tetap melalui public RPC canonical.
- POS, Backoffice Sales, Stock, Reservation, FIFO, Payment, Invoice, dan
  Finance tidak memiliki endpoint mutation baru.

## Local verification

1. `cd backoffice`.
2. Pastikan environment mengarah ke isolated Supabase Development.
3. Jalankan `npm run dev`.
4. Login sebagai `localadmin@local.com` dan pilih Company uji.
5. Buka `Pengaturan Modul > Sales`.
6. Pastikan mode aktif dan mode tujuan tampil dengan nama yang dapat dibaca.
7. Pastikan tabel preview menampilkan nomor dokumen, status, keputusan,
   keterangan, dan bukan UUID sebagai label utama.
8. Buat rencana dengan alasan dan waktu berlaku. Pastikan ini belum mengganti
   mode Company.
9. Ubah satu Draft uji, lalu tekan `Refresh preview`; versi dan daftar harus
   mengikuti data terbaru.
10. Uji `Batalkan rencana`; mode Company tidak boleh berubah.
11. Buat rencana baru. Centang konfirmasi dan Apply hanya pada Company fixture
    Development. Pastikan mode berubah dan plan menjadi `APPLIED`.
12. Pastikan root dokumen baru pada mode nonaktif ditolak, sedangkan dokumen
    grandfathered tetap dapat diselesaikan melalui runtime asal.

## Stop conditions

Hentikan smoke dan kirim error bila:

- Company yang tampil tidak sama dengan selector workspace;
- jumlah/nomor dokumen berbeda dari preview database;
- Apply aktif sebelum waktu berlaku;
- stale preview tidak meminta refresh;
- ada efek parsial setelah Apply gagal;
- POS/Backoffice membuat root baru melalui mode yang sedang nonaktif.

Jangan melakukan Apply pada production sebelum deployment plan, backup,
maintenance boundary, dan UAT terpisah disetujui user.
